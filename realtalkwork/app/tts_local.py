"""本地语音合成脚本（Piper 独立二进制，CPU 可用）。

镜像构建（WITH_LOCAL_TTS=true，默认开）装好 Piper 官方二进制到 /opt/piper；
TTS_LOCAL_COMMAND 设为  python /app/app/tts_local.py {voice} {out}

约定（与 voice_io._synthesize_local 配合）：
- 待合成文本从【标准输入】读入（长文本/特殊字符不必走命令行转义）；
- 第 1 个参数是音色（Piper voice 名，如 en_US-lessac-medium）；第 2 个是输出 WAV 路径 {out}
  （故本地 TTS 的 TTS_FORMAT 应为 wav）。

音色模型与本地 ASR 的 whisper 模型一样【首次使用时下载】到 TTS_LOCAL_MODEL_DIR（默认 /app/models，
建议挂持久卷）。受限网络可用 PIPER_VOICES_BASE 指向镜像站。
"""
from __future__ import annotations

import array
import os
import subprocess
import sys
import tempfile
import urllib.request
import wave

PIPER_BIN = os.getenv("PIPER_BIN", "/opt/piper/piper")
MODEL_DIR = os.getenv("TTS_LOCAL_MODEL_DIR", "/app/models")
# HuggingFace 上 rhasspy/piper-voices；受限网络可换镜像（如 https://hf-mirror.com/rhasspy/piper-voices/resolve/main）
VOICES_BASE = os.getenv("PIPER_VOICES_BASE", "https://huggingface.co/rhasspy/piper-voices/resolve/main")


def _hf_rel(voice: str) -> str:
    """en_US-lessac-medium → en/en_US/lessac/medium/en_US-lessac-medium"""
    lang_region, name, quality = voice.split("-", 2)
    lang = lang_region.split("_")[0]
    return f"{lang}/{lang_region}/{name}/{quality}/{voice}"


def _ensure_voice(voice: str) -> tuple[str, str]:
    onnx = os.path.join(MODEL_DIR, voice + ".onnx")
    cfg = onnx + ".json"
    if os.path.exists(onnx) and os.path.exists(cfg):
        return onnx, cfg
    os.makedirs(MODEL_DIR, exist_ok=True)
    rel = _hf_rel(voice)
    for url, dst in ((f"{VOICES_BASE}/{rel}.onnx", onnx), (f"{VOICES_BASE}/{rel}.onnx.json", cfg)):
        tmp = dst + ".part"
        urllib.request.urlretrieve(url, tmp)   # noqa: S310 — 固定可信镜像
        os.replace(tmp, dst)
    return onnx, cfg


def _is_zh(ch: str) -> bool:
    return "一" <= ch <= "鿿"


def _segment_by_lang(text: str) -> list[tuple[bool, str]]:
    """把混合文本按中文/非中文切成连续段，[(is_zh, 文本)…]；纯标点/空白段并入前一段，避免单独合成。

    例：「你可以说 I'd like a burger 会更自然」→ [(True,'你可以说 '),(False,\"I'd like a burger \"),(True,'会更自然')]
    """
    raw: list[tuple[bool, list[str]]] = []
    for ch in text:
        z = _is_zh(ch)
        if raw and raw[-1][0] == z:
            raw[-1][1].append(ch)
        else:
            raw.append((z, [ch]))
    segs: list[tuple[bool, str]] = []
    for z, chars in raw:
        s = "".join(chars)
        has_content = any(_is_zh(c) or c.isalnum() for c in s)
        if not has_content and segs:                 # 纯标点/空白 → 并入前段（跟前段的音色一起读）
            segs[-1] = (segs[-1][0], segs[-1][1] + s)
        elif has_content:
            segs.append((z, s))
    return segs or [(False, text)]


def _synthesize(voice: str, text: str, out_path: str) -> int:
    """用指定音色合成 text 到 out_path（WAV）。返回 Piper 退出码（0=成功）。"""
    onnx, cfg = _ensure_voice(voice)
    proc = subprocess.run(
        [PIPER_BIN, "--model", onnx, "--config", cfg, "--output_file", out_path],
        input=text.encode("utf-8"), capture_output=True,
    )
    if proc.returncode != 0:
        print(f"piper 合成失败（{proc.returncode}）：{proc.stderr.decode('utf-8', 'ignore')[:200]}", file=sys.stderr)
    return proc.returncode


def _resample_mono16(frames: bytes, src_rate: int, dst_rate: int) -> bytes:
    """16-bit 单声道 PCM 最近邻重采样（短句够用，避免引入 numpy 依赖）。"""
    if src_rate == dst_rate:
        return frames
    a = array.array("h")
    a.frombytes(frames)
    n = len(a)
    m = max(1, int(n * dst_rate / src_rate))
    out = array.array("h", bytes(2 * m))
    for i in range(m):
        out[i] = a[min(int(i * src_rate / dst_rate), n - 1)]
    return out.tobytes()


def _concat_wavs(parts: list[str], out_path: str) -> bool:
    """把多段 WAV 拼成一个（以第一段的声道/位宽/采样率为准，必要时重采样后拼接）。"""
    target = None
    pcm = bytearray()
    for p in parts:
        with wave.open(p, "rb") as w:
            nch, sw, fr = w.getnchannels(), w.getsampwidth(), w.getframerate()
            data = w.readframes(w.getnframes())
        if target is None:
            target = (nch, sw, fr)
        if (nch, sw) == (target[0], target[1]) and sw == 2 and nch == 1:
            data = _resample_mono16(data, fr, target[2])
        pcm.extend(data)
    if target is None:
        return False
    with wave.open(out_path, "wb") as w:
        w.setnchannels(target[0])
        w.setsampwidth(target[1])
        w.setframerate(target[2])
        w.writeframes(bytes(pcm))
    return True


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: tts_local.py <voice> <out_wav>  (text via stdin)", file=sys.stderr)
        return 2
    en_voice = sys.argv[1].strip()
    out_path = sys.argv[2]
    zh_voice = os.getenv("PIPER_ZH_VOICE", "zh_CN-huayan-medium")
    text = sys.stdin.read().strip()
    if not text:
        print("empty text on stdin", file=sys.stderr)
        return 2

    if not os.path.exists(PIPER_BIN):
        print(f"未找到 Piper 二进制（{PIPER_BIN}）：镜像需以 WITH_LOCAL_TTS=true 构建", file=sys.stderr)
        return 3

    # 中英混合（指导解说常见）按语种分段，各用对应音色合成后拼接；纯单语种时只有一段，与原来等价。
    segments = _segment_by_lang(text)
    workdir = tempfile.mkdtemp(prefix="rt-tts-seg-")
    try:
        parts: list[str] = []
        for idx, (is_zh, seg_text) in enumerate(segments):
            voice = zh_voice if is_zh else en_voice
            seg_out = os.path.join(workdir, f"{idx}.wav")
            try:
                if _synthesize(voice, seg_text, seg_out) == 0 and os.path.exists(seg_out):
                    parts.append(seg_out)
            except Exception as exc:  # noqa: BLE001 — 单段失败跳过，不让整句无声
                print(f"音色 {voice} 段合成失败：{exc}", file=sys.stderr)
        if not parts:
            return 5
        if len(parts) == 1:
            os.replace(parts[0], out_path)
        elif not _concat_wavs(parts, out_path):
            os.replace(parts[0], out_path)   # 拼接失败兜底用第一段
        return 0 if os.path.exists(out_path) else 5
    finally:
        import shutil

        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
