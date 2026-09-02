"""本地实时语音模型引擎：ASR(faster-whisper) + TTS(Qwen3-TTS) + LLM(llama.cpp 进程内或代理)。

设计目标（高并发/多活）：
- 三个引擎各自有并发信号量（ASR/LLM 吃 CPU/显存，TTS 较轻），超出排队而不是拖垮节点；
- 模型文件在启动时预拉到 MODELS_DIR（建议挂宿主机/PVC 持久卷），多副本共享同一份模型目录也安全（只读加载）；
- 引擎本身无会话状态——实时会话的上下文存 Redis（见 realtime.py），任何副本都能接管。
参数全部走 env（每节点部署项，不入库、不进管理台）。
"""
from __future__ import annotations

import asyncio
import io
import os
import tempfile
import threading
import urllib.request
import wave

MODELS_DIR = os.getenv("MODELS_DIR", "/models")
DEVICE = os.getenv("SPEECH_DEVICE", "cpu")                      # cpu / cuda / metal（Apple GPU，原生 macOS 部署）
ASR_MODEL = os.getenv("SPEECH_ASR_MODEL", "small")              # whisper 尺寸 tiny/base/small/medium/large-v3
LLM_REPO = os.getenv("SPEECH_LLM_REPO", "Qwen/Qwen2.5-1.5B-Instruct-GGUF")
LLM_FILE = os.getenv("SPEECH_LLM_FILE", "qwen2.5-1.5b-instruct-q4_k_m.gguf")
LLM_BASE_URL = os.getenv("SPEECH_LLM_BASE_URL", "")             # 设了则代理外部 OpenAI 兼容 LLM，不在本进程加载
LLM_CTX = int(os.getenv("SPEECH_LLM_CTX", "8192"))
TTS_MODEL = os.getenv("SPEECH_TTS_MODEL", "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice")
TTS_SPEAKER = os.getenv("SPEECH_TTS_SPEAKER", "Aiden")
TTS_QUANT = os.getenv("SPEECH_TTS_QUANT", "Q4_K_M")
TTS_ALLOW_REQUEST_VOICE = os.getenv("SPEECH_TTS_ALLOW_REQUEST_VOICE", "true").lower() == "true"
HF_BASE = (os.getenv("HF_ENDPOINT") or "https://huggingface.co").rstrip("/")

_ASR_SEM = asyncio.Semaphore(int(os.getenv("SPEECH_ASR_CONCURRENCY", "3")))
# LLM 并发必须为 1：llama.cpp 进程内单实例【非线程安全】，并发调用会崩溃重启整个容器。
# 需要更高并发时用 SPEECH_LLM_BASE_URL 代理外部 llama-server（多实例/连续批处理），而不是调大这里。
_LLM_SEM = asyncio.Semaphore(int(os.getenv("SPEECH_LLM_CONCURRENCY", "1")))
_TTS_SEM = asyncio.Semaphore(int(os.getenv("SPEECH_TTS_CONCURRENCY", "6")))

_WHISPER_FILES = ("config.json", "model.bin", "tokenizer.json", "vocabulary.txt")


def ensure_whisper_model(size: str) -> str:
    """直下 Systran/faster-whisper-<size> 模型文件（走 HF_ENDPOINT 镜像，绕开 huggingface_hub API）。"""
    dest = os.path.join(MODELS_DIR, f"faster-whisper-{size}")
    os.makedirs(dest, exist_ok=True)
    for fn in _WHISPER_FILES:
        target = os.path.join(dest, fn)
        if os.path.exists(target) and os.path.getsize(target) > 0:
            continue
        url = f"{HF_BASE}/Systran/faster-whisper-{size}/resolve/main/{fn}"
        tmp = target + ".part"
        urllib.request.urlretrieve(url, tmp)  # noqa: S310 — 固定可信仓库/镜像
        os.replace(tmp, target)
    return dest


_TTS_STEMS = {
    "Qwen/Qwen3-TTS-12Hz-0.6B-Base": "qwen-talker-0.6b-base",
    "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice": "qwen-talker-0.6b-customvoice",
    "Qwen/Qwen3-TTS-12Hz-1.7B-Base": "qwen-talker-1.7b-base",
    "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice": "qwen-talker-1.7b-customvoice",
    "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign": "qwen-talker-1.7b-voicedesign",
}


def ensure_tts_ggufs() -> tuple[str, str]:
    """直下 Qwen3-TTS 的 talker/codec GGUF 到 MODELS_DIR/qwen3-tts-gguf（与 S2S 进程共享同一份文件）。
    走 HF_ENDPOINT 镜像的 resolve 直链，绕开 huggingface_hub 的 metadata API。"""
    stem = _TTS_STEMS.get(TTS_MODEL)
    if not stem:
        raise ValueError(f"不支持的 Qwen3-TTS 模型：{TTS_MODEL}")
    quant = TTS_QUANT.upper()
    quant = {"Q4": "Q4_K_M", "Q8": "Q8_0", "FP32": "F32"}.get(quant, quant)
    dest = os.path.join(MODELS_DIR, "qwen3-tts-gguf")
    os.makedirs(dest, exist_ok=True)
    paths: list[str] = []
    for fn in (f"{stem}-{quant}.gguf", f"qwen-tokenizer-12hz-{quant}.gguf"):
        target = os.path.join(dest, fn)
        if not (os.path.exists(target) and os.path.getsize(target) > 0):
            url = f"{HF_BASE}/Serveurperso/Qwen3-TTS-GGUF/resolve/main/{fn}"
            tmp = target + ".part"
            urllib.request.urlretrieve(url, tmp)  # noqa: S310 — 固定可信仓库/镜像
            os.replace(tmp, target)
        paths.append(target)
    return paths[0], paths[1]


def ensure_llm_model() -> str:
    """直下 GGUF 到 MODELS_DIR（HF_ENDPOINT 镜像可用）。SPEECH_LLM_FILE 可为绝对路径直接使用。"""
    if os.path.isabs(LLM_FILE) and os.path.exists(LLM_FILE):
        return LLM_FILE
    target = os.path.join(MODELS_DIR, LLM_FILE)
    if os.path.exists(target) and os.path.getsize(target) > 0:
        return target
    os.makedirs(MODELS_DIR, exist_ok=True)
    url = f"{HF_BASE}/{LLM_REPO}/resolve/main/{LLM_FILE}"
    tmp = target + ".part"
    urllib.request.urlretrieve(url, tmp)  # noqa: S310
    os.replace(tmp, target)
    return target


class Engines:
    """惰性单例：REST 的 whisper / llama / Qwen3-TTS 各加载一次。"""

    _lock = threading.Lock()
    _whisper = None
    _llama = None
    _tts = None

    @classmethod
    def whisper(cls):
        if cls._whisper is None:
            with cls._lock:
                if cls._whisper is None:
                    from faster_whisper import WhisperModel

                    path = ensure_whisper_model(ASR_MODEL)
                    # CTranslate2 只认 cpu/cuda：metal 模式下 whisper 走 CPU int8
                    #（Apple Silicon NEON 下 small 模型接近实时，瓶颈不在 ASR）
                    whisper_device = "cuda" if DEVICE == "cuda" else "cpu"
                    compute = "float16" if DEVICE == "cuda" else "int8"
                    cls._whisper = WhisperModel(path, device=whisper_device, compute_type=compute)
        return cls._whisper

    @classmethod
    def llama(cls):
        if cls._llama is None:
            with cls._lock:
                if cls._llama is None:
                    from llama_cpp import Llama

                    path = ensure_llm_model()
                    cls._llama = Llama(
                        model_path=path,
                        n_ctx=LLM_CTX,
                        # cuda/metal 都把全部层放 GPU（metal=Apple 统一内存，llama.cpp 原生支持）
                        n_gpu_layers=-1 if DEVICE in ("cuda", "metal") else 0,
                        verbose=False,
                    )
        return cls._llama

    @classmethod
    def tts(cls):
        if cls._tts is None:
            with cls._lock:
                if cls._tts is None:
                    from qwentts_cpp import QwenTTS

                    # 不用 from_pretrained：其内部 hf_hub_download 对该第三方 GGUF 仓库
                    # 在 hf-mirror.com 等镜像上 metadata 不兼容，受限网络下运行时报
                    # LocalEntryNotFoundError（表现为 /audio/speech 500、App 有字幕没声音）。
                    # 与 sitecustomize.py 的 S2S 修复同策略：resolve 直下 + 显式本地路径。
                    talker, codec = ensure_tts_ggufs()
                    cls._tts = QwenTTS(talker, codec, use_fa=DEVICE == "cuda")
        return cls._tts


async def transcribe(audio_bytes: bytes, language: str | None, prompt: str | None = None) -> str:
    """ASR：语音→文字。language: en/zh/None(自动)。并发受限，超出排队。"""
    text, _words, _dur = await transcribe_verbose(audio_bytes, language, prompt)
    return text


async def transcribe_verbose(
    audio_bytes: bytes, language: str | None, prompt: str | None = None
) -> tuple[str, list[dict], float]:
    """ASR 词级详情：返回 (文本, words[{word,start,end,probability}], 音频时长秒)。
    词级 probability 供客户端发音标色（低置信≈发音待提高的近似信号）；start/end 供语速/停顿分析。"""
    async with _ASR_SEM:
        return await asyncio.to_thread(_transcribe_sync, audio_bytes, language, prompt)


def _transcribe_sync(audio_bytes: bytes, language: str | None, prompt: str | None) -> tuple[str, list[dict], float]:
    model = Engines.whisper()
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=True) as fh:
        fh.write(audio_bytes)
        fh.flush()
        segments, info = model.transcribe(
            fh.name, language=language or None, beam_size=1, vad_filter=True,
            initial_prompt=prompt or None, word_timestamps=True,
        )
        text, words = _collect_words(segments)
        if not text:   # 短句偶被 VAD 全滤 → 关 VAD 再试一次
            segments, info = model.transcribe(
                fh.name, language=language or None, beam_size=1, vad_filter=False, word_timestamps=True
            )
            text, words = _collect_words(segments)
    return text, words, float(getattr(info, "duration", 0.0) or 0.0)


# 反幻觉阈值：Whisper 对着静音/环境噪音会凭空编出成句的文本（实测「云很白,风很轻…」
# 这类诗句）。用解码置信度过滤：判为"无人声"的概率过高、或平均对数概率过低的段一律丢弃。
_NO_SPEECH_MAX = float(os.getenv("SPEECH_ASR_NO_SPEECH_MAX", "0.6"))
_AVG_LOGPROB_MIN = float(os.getenv("SPEECH_ASR_AVG_LOGPROB_MIN", "-1.0"))


def _collect_words(segments) -> tuple[str, list[dict]]:
    parts: list[str] = []
    words: list[dict] = []
    for seg in segments:   # segments 是生成器：迭代即触发实际解码
        # 丢掉低置信度段：这类几乎全是静音/噪音上的幻觉，放行会不停冒出假字幕并被翻译
        no_speech = float(getattr(seg, "no_speech_prob", 0.0) or 0.0)
        avg_lp = float(getattr(seg, "avg_logprob", 0.0) or 0.0)
        if no_speech > _NO_SPEECH_MAX or avg_lp < _AVG_LOGPROB_MIN:
            continue
        parts.append(seg.text)
        for w in (seg.words or []):
            words.append({
                "word": w.word.strip(),
                "start": round(float(w.start), 2),
                "end": round(float(w.end), 2),
                "probability": round(float(w.probability), 3),
            })
    return "".join(parts).strip(), words


async def chat(messages: list[dict], temperature: float = 0.6, max_tokens: int = 512, stream_cb=None) -> str:
    """LLM：OpenAI 消息格式 → 回复文本。stream_cb(delta) 逐段回调（实时通道用）。"""
    if LLM_BASE_URL:
        return await _chat_proxy(messages, temperature, max_tokens, stream_cb)
    async with _LLM_SEM:
        return await asyncio.to_thread(_chat_sync, messages, temperature, max_tokens, stream_cb)


def _chat_sync(messages, temperature, max_tokens, stream_cb) -> str:
    llm = Engines.llama()
    if stream_cb is None:
        out = llm.create_chat_completion(messages=messages, temperature=temperature, max_tokens=max_tokens)
        return (out["choices"][0]["message"]["content"] or "").strip()
    parts: list[str] = []
    for chunk in llm.create_chat_completion(messages=messages, temperature=temperature, max_tokens=max_tokens, stream=True):
        delta = (chunk["choices"][0].get("delta") or {}).get("content") or ""
        if delta:
            parts.append(delta)
            stream_cb(delta)
    return "".join(parts).strip()


async def _chat_proxy(messages, temperature, max_tokens, stream_cb) -> str:
    import httpx

    async with _LLM_SEM:
        async with httpx.AsyncClient(timeout=httpx.Timeout(120, connect=10)) as client:
            resp = await client.post(
                LLM_BASE_URL.rstrip("/") + "/chat/completions",
                json={"model": os.getenv("SPEECH_LLM_MODEL", "local"), "messages": messages, "temperature": temperature, "max_tokens": max_tokens},
                headers={"Authorization": f"Bearer {os.getenv('SPEECH_LLM_API_KEY', 'none')}"},
            )
            resp.raise_for_status()
            content = (resp.json()["choices"][0]["message"]["content"] or "").strip()
            if stream_cb:
                stream_cb(content)
            return content


async def synthesize(text: str, voice: str | None = None) -> bytes:
    """Qwen3-TTS：文字→WAV；REST 与实时通道使用同一模型配置和音色。"""
    async with _TTS_SEM:
        return await asyncio.to_thread(_synthesize_sync, text, voice)


def _synthesize_sync(text: str, voice: str | None) -> bytes:
    import numpy as np

    # 用户选择的 voice 同时用于 REST 朗读与 realtime；可在单音色部署中显式关闭覆盖。
    requested = (voice or "").strip()
    speaker = requested if (TTS_ALLOW_REQUEST_VOICE and requested) else TTS_SPEAKER
    language = "chinese" if any("\u3400" <= ch <= "\u9fff" for ch in text) else "english"
    samples, sample_rate = Engines.tts().synthesize(text=text, lang=language, speaker=speaker)
    pcm = (np.clip(samples, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()
    out = io.BytesIO()
    with wave.open(out, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm)
    return out.getvalue()


def wav_to_pcm16(wav_bytes: bytes) -> tuple[bytes, int]:
    """WAV → (裸 PCM16 mono, 采样率)，供实时通道按 OpenAI Realtime 惯例发 pcm 数据。"""
    with wave.open(io.BytesIO(wav_bytes), "rb") as w:
        rate = w.getframerate()
        frames = w.readframes(w.getnframes())
    return frames, rate
