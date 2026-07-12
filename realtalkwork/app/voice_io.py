"""语音合成（TTS）服务层：把一段文本合成成音频字节。

云端与本地均通过 OpenAI 兼容 `/audio/speech` 调用；本地 speech 服务使用 Qwen3-TTS。
管理台配置 base_url/api_key/model 与可选音色。
"""
from __future__ import annotations

import asyncio
import base64
import difflib
import hashlib
import os
import re
import struct
import subprocess
import tempfile
from pathlib import Path
from typing import Any

import httpx

from .settings import settings


class TTSOverloaded(Exception):
    """合成并发已满，过载保护：调用方应返回 429 让客户端稍后重试。"""


# 合成并发上限（懒初始化绑定到运行中的事件循环）
_SYNTH_SEM: asyncio.Semaphore | None = None


def _synth_sem() -> asyncio.Semaphore:
    global _SYNTH_SEM
    if _SYNTH_SEM is None:
        _SYNTH_SEM = asyncio.Semaphore(max(1, settings.tts_max_concurrency))
    return _SYNTH_SEM


# ---- TTS 结果缓存（Redis；台词重复→命中率高，刷同文本=命中缓存，省云端 $ 与 CPU）----

def _redis():
    try:
        from .capture_store import capture_store

        return getattr(capture_store, "r", None)
    except Exception:  # noqa: BLE001
        return None


def _tts_cache_key(text: str, voice: str, fmt: str) -> str:
    h = hashlib.sha256(f"{voice}|{fmt}|{text}".encode("utf-8")).hexdigest()[:40]
    return f"rt:tts:{h}"


def _cache_get(key: str) -> bytes | None:
    r = _redis()
    if r is None:
        return None
    try:
        val = r.get(key)  # capture_store 客户端 decode_responses=True → 取回 base64 字符串
        if not val:
            return None
        r.expire(key, settings.tts_cache_ttl_seconds)  # 滑动过期：被取用就续期
        return base64.b64decode(val)
    except Exception:  # noqa: BLE001 — 缓存失败不影响主流程
        return None


def _cache_set(key: str, audio: bytes) -> None:
    r = _redis()
    if r is None or len(audio) > 2 * 1024 * 1024:  # 单条 TTS 很小；超 2MB 不缓存兜底
        return
    try:
        r.set(key, base64.b64encode(audio).decode("ascii"), ex=settings.tts_cache_ttl_seconds)
    except Exception:  # noqa: BLE001
        pass

_FORMAT_CONTENT_TYPE = {
    "mp3": "audio/mpeg",
    "wav": "audio/wav",
    "opus": "audio/ogg",
    "aac": "audio/aac",
    "flac": "audio/flac",
    "pcm": "audio/L16",
}


def content_type_for(fmt: str) -> str:
    return _FORMAT_CONTENT_TYPE.get((fmt or "mp3").lower(), "application/octet-stream")


def resolve_conv_voice() -> dict[str, Any]:
    """B 类【对话】语音模型（一张卡）：conv_voice_base_url 一个地址派生全部端点——
    ASR=/audio/transcriptions、TTS=/audio/speech、LLM=/chat/completions、实时通道=ws(s)…/realtime。
    每次调用现读 DB、实时生效。"""
    from .storage import db

    ov = db.get_app_settings_map(["conv_voice_base_url", "conv_voice_api_key", "conv_voice_model", "conv_voice_voice"])
    base = (ov.get("conv_voice_base_url") or settings.conv_voice_base_url or "").strip().rstrip("/")
    return {
        "base_url": base,
        "api_key": (ov.get("conv_voice_api_key") or settings.conv_voice_api_key or "").strip(),
        "model": (ov.get("conv_voice_model") or settings.conv_voice_model or "").strip(),
        "voice": (ov.get("conv_voice_voice") or settings.conv_voice_voice or "").strip(),
        "is_openai": "openai" in base.lower(),
    }


def conv_realtime_url() -> str:
    """由 B 类语音模型 base_url 派生实时通道地址：http(s)→ws(s) + /realtime；未配置返回空。"""
    cv = resolve_conv_voice()
    base = cv["base_url"]
    if not base:
        return ""
    ws = base.replace("https://", "wss://", 1).replace("http://", "ws://", 1)
    return ws + "/realtime"


def resolve_tts_config() -> dict[str, Any]:
    """B 类【对话】TTS：由 conv_voice 派生（未配置回退通用 tts_*）。
    模型/格式自动推断：OpenAI→tts-1/mp3；本地语音服务器→qwen3-tts/wav。"""
    from .storage import db

    cv = resolve_conv_voice()
    overrides = db.get_app_settings_map(["tts_base_url", "tts_api_key", "tts_model", "tts_voices", "tts_default_voice"])
    if cv["base_url"]:
        return {
            "base_url": cv["base_url"],
            "api_key": cv["api_key"],
            "model": "tts-1" if cv["is_openai"] else "qwen3-tts",
            "voices": overrides.get("tts_voices") or settings.tts_voices,
            "default_voice": cv["voice"] or overrides.get("tts_default_voice"),
            "format": "mp3" if cv["is_openai"] else "wav",
            "dev_mode": settings.tts_dev_mode,
        }
    return {
        "base_url": overrides.get("tts_base_url"),
        "api_key": overrides.get("tts_api_key"),
        "model": overrides.get("tts_model"),
        "voices": overrides.get("tts_voices") or settings.tts_voices,
        "default_voice": overrides.get("tts_default_voice"),
        "format": settings.tts_format,
        "dev_mode": settings.tts_dev_mode,
    }


def tts_configured() -> bool:
    config = resolve_tts_config()
    return config["dev_mode"] or bool(config["base_url"] and config["api_key"])


# ==== 分端点计费（a=ASR按分钟 / b=TTS按百万字符 / d=实时通道按分钟；单价 DB 可改现读）====

def _voice_price(key: str, fallback: float) -> float:
    from .storage import db

    try:
        raw = db.get_app_setting_str(key)
        return float(raw) if raw not in (None, "") else fallback
    except Exception:  # noqa: BLE001
        return fallback


def record_asr_cost(user_id: str | None, seconds: float, kind: str = "asr") -> None:
    """a 类：语音→文字按分钟计费（不足 1 分钟按 1 分钟）。单价 0 = 不计费不记账。"""
    if not user_id or seconds <= 0:
        return
    price = _voice_price("asr_price_per_minute_cents", settings.asr_price_per_minute_cents)
    if price <= 0:
        return
    import math

    from .storage import db

    db.record_ai_usage(user_id=user_id, kind=kind, model="asr", prompt_tokens=0, completion_tokens=0,
                       cost_cents=round(max(1, math.ceil(seconds / 60)) * price, 4), latency_ms=0)


def record_tts_cost(user_id: str | None, chars: int) -> None:
    """b 类：文字→语音按字符计费（分/百万字符）。缓存命中不计（没有真正合成）。"""
    if not user_id or chars <= 0:
        return
    price = _voice_price("tts_price_per_1m_chars_cents", settings.tts_price_per_1m_chars_cents)
    if price <= 0:
        return
    from .storage import db

    db.record_ai_usage(user_id=user_id, kind="tts", model="tts", prompt_tokens=0, completion_tokens=0,
                       cost_cents=round(chars / 1_000_000 * price, 4), latency_ms=0)


def record_conv_voice_cost(user_id: str | None, seconds: float) -> None:
    """d 类：实时通道按会话分钟整体计费——通道内已含 ASR/LLM/TTS，绝不再按 a/b/c 重复计。"""
    if not user_id or seconds <= 0:
        return
    price = _voice_price("conv_voice_price_per_minute_cents", settings.conv_voice_price_per_minute_cents)
    if price <= 0:
        return
    import math

    from .storage import db

    db.record_ai_usage(user_id=user_id, kind="voice_conv", model="realtime", prompt_tokens=0, completion_tokens=0,
                       cost_cents=round(max(1, math.ceil(seconds / 60)) * price, 4), latency_ms=0)


def available_voices() -> list[str]:
    config = resolve_tts_config()
    return [v.strip() for v in (config["voices"] or "").split(",") if v.strip()]


def default_voice() -> str:
    config = resolve_tts_config()
    voices = available_voices()
    dv = (config["default_voice"] or "").strip()
    if dv and (not voices or dv in voices):
        return dv
    return voices[0] if voices else "alloy"


def normalize_voice(voice: str | None) -> str:
    """把请求的音色规整到可选列表内，非法或空则回落默认音色。"""
    voices = available_voices()
    v = (voice or "").strip()
    if v and (not voices or v in voices):
        return v
    return default_voice()


def _silent_wav(seconds: float = 0.3, rate: int = 16000) -> bytes:
    """开发模式占位：生成一段静音 WAV，保证客户端能播放、链路可端到端联调。"""
    n = int(seconds * rate)
    data = b"\x00\x00" * n
    return (
        b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
        + b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
        + b"data" + struct.pack("<I", len(data)) + data
    )


async def synthesize(text: str, voice: str | None = None, use_cache: bool = True,
                     user_id: str | None = None) -> tuple[bytes, str]:
    """把文本合成为音频，返回 (音频字节, content_type)。文本为空抛错。

    use_cache：是否走 Redis 合成缓存。手工点读/试听同一句可能反复听 → 缓存(默认)；
    沉浸式/实时回合的 AI 回复每句基本唯一、只随流推送一次、不会复用 → 传 False 不进 Redis，
    避免动态语音把 Redis 撑大。
    """
    text = (text or "").strip()
    if not text:
        raise RuntimeError("待合成文本为空")
    config = resolve_tts_config()
    voice = normalize_voice(voice)
    fmt = (config["format"] or "mp3").lower()

    is_cloud_ready = bool(config["base_url"] and config["api_key"])

    if config["dev_mode"] and not is_cloud_ready:
        return _silent_wav(), content_type_for("wav")   # dev：便宜，不缓存不限并发

    ct = content_type_for(fmt)
    cache_key = _tts_cache_key(text, voice, fmt) if use_cache else None
    if cache_key is not None:
        cached = _cache_get(cache_key)
        if cached is not None:
            return cached, ct   # 命中缓存：秒回，不消耗合成资源（刷同一文本也只命中缓存）

    # 并发上限：合成位满则过载（调用方返回 429），避免突发把上游/CPU 打满
    try:
        await asyncio.wait_for(_synth_sem().acquire(), timeout=3.0)
    except asyncio.TimeoutError as exc:
        raise TTSOverloaded("语音合成繁忙，请稍后再试") from exc
    try:
        if not is_cloud_ready:
            raise RuntimeError("B·对话语音合成未配置，请在管理台「系统设置 → B·对话语音模型」中配置")
        async with httpx.AsyncClient(timeout=httpx.Timeout(60, connect=15)) as client:
            resp = await client.post(
                config["base_url"].rstrip("/") + "/audio/speech",
                headers={"Authorization": f"Bearer {config['api_key']}"},
                json={"model": config["model"], "input": text, "voice": voice, "response_format": fmt},
            )
        resp.raise_for_status()
        # content_type 以响应头为准（本地语音服务器返回 wav），头缺失回落配置推断
        audio, ct = resp.content, (resp.headers.get("content-type") or content_type_for(fmt)).split(";")[0]
    finally:
        _synth_sem().release()

    record_tts_cost(user_id, len(text))   # b 类计费：真正合成才计（缓存命中在上面已 return）
    if cache_key is not None:
        _cache_set(cache_key, audio)
    return audio, ct


# ============================================================
# 语音识别（练习用）：复用 ASR 配置，转写时用参考句做偏置实现「宽容容错」
# ============================================================

def _pcm16_to_wav(pcm: bytes, rate: int = 16000) -> bytes:
    """裸 PCM16 mono → WAV（流式上行的音频帧在提交时封包）。"""
    return (
        b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE"
        + b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
        + b"data" + struct.pack("<I", len(pcm)) + pcm
    )


def _estimate_seconds(audio_bytes: bytes, suffix: str) -> float:
    """估算音频时长（计费用）：wav/pcm16@16k 按字节精确；压缩格式按 ~32kbps 估算。"""
    if suffix in (".wav", ".pcm16"):
        return len(audio_bytes) / 32000.0
    return len(audio_bytes) / 4000.0


async def transcribe(audio_bytes: bytes, suffix: str = ".m4a", reference_text: str | None = None,
                     language: str = "en", user_id: str | None = None) -> str:
    """把一小段练习录音转成文字（OpenAI 兼容 /audio/transcriptions，参考句 prompt 偏置宽容识别）。
    B 类【对话】：地址由 conv_voice 一张卡派生（未配置回退通用 asr_*）。suffix=.pcm16 表示裸 PCM16@16k
    （客户端流式上行），提交前封成 WAV。成功后按分钟计费（a 类）。"""
    text, _words, _dur = await transcribe_verbose(audio_bytes, suffix, reference_text, language, user_id)
    return text


async def transcribe_verbose(audio_bytes: bytes, suffix: str = ".m4a", reference_text: str | None = None,
                             language: str = "en", user_id: str | None = None) -> tuple[str, list[dict], float]:
    """转写 + 词级详情：返回 (文本, words[{word,start,end,probability}], 音频时长秒)。
    词级 probability 供发音标色；本地语音服务器支持 verbose_json，云端不带词级时 words 为空。"""
    cv = resolve_conv_voice()
    if cv["base_url"]:
        base_url, api_key, model = cv["base_url"], cv["api_key"], "whisper-1"
    else:
        from .storage import db

        ov = db.get_app_settings_map(["asr_base_url", "asr_api_key", "asr_model"])
        base_url, api_key, model = ov.get("asr_base_url"), ov.get("asr_api_key"), ov.get("asr_model") or "whisper-1"
    if settings.asr_dev_mode and not (base_url and api_key):
        return (reference_text or "").strip(), [], 0.0  # 开发模式：假定识别到参考句，链路可端到端联调
    if not (base_url and api_key):
        raise RuntimeError("B·对话语音转写未配置，请在管理台「系统设置 → B·对话语音模型」中配置")

    seconds = _estimate_seconds(audio_bytes, suffix)
    if suffix == ".pcm16":
        audio_bytes, suffix = _pcm16_to_wav(audio_bytes), ".wav"
    data = {"model": model, "language": language, "response_format": "verbose_json"}
    if reference_text:
        data["prompt"] = reference_text  # whisper 把 prompt 当上下文偏置 → 更宽容地识别成目标句
    async with httpx.AsyncClient(timeout=httpx.Timeout(120, connect=15)) as client:
        resp = await client.post(
            base_url.rstrip("/") + "/audio/transcriptions",
            headers={"Authorization": f"Bearer {api_key}"},
            data=data,
            files={"file": (f"clip{suffix}", audio_bytes, "audio/mpeg")},
        )
    resp.raise_for_status()
    record_asr_cost(user_id, seconds)   # a 类计费：调一次算一次
    body = resp.json()
    words = body.get("words") if isinstance(body.get("words"), list) else []
    duration = float(body.get("duration") or seconds or 0.0)
    return str(body.get("text", "")).strip(), words, duration


def _tokens(s: str) -> list[str]:
    return [w for w in re.sub(r"[^\w']", " ", (s or "").lower()).split() if w]


def pronunciation_diff(recognized: str, reference: str) -> list[dict]:
    """逐词对比：参考句每个词是否在识别结果中按序出现。未出现≈漏读/读错，供发音纠正提示。"""
    ref = _tokens(reference)
    rec = _tokens(recognized)
    ok = [False] * len(ref)
    matcher = difflib.SequenceMatcher(a=ref, b=rec, autojunk=False)
    for tag, i1, i2, _j1, _j2 in matcher.get_opcodes():
        if tag == "equal":
            for i in range(i1, i2):
                ok[i] = True
    return [{"word": ref[i], "ok": ok[i]} for i in range(len(ref))]
