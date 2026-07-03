"""语音合成（TTS）服务层：把一段文本合成成音频字节。

两种后端，管理台可切（与 ASR 一致的取舍）：
- cloud：OpenAI 兼容 `/audio/speech`（base_url/api_key/model/voice 可在管理台在线配置）。
- local：服务器本地命令行（Piper/Coqui 等），命令模板由部署（env）控制。

mode / 本地命令由部署控制（env / setup.sh），管理台只配置云端 base_url/api_key/model 与可选音色。
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


def resolve_tts_config() -> dict[str, Any]:
    from .storage import db

    overrides = db.get_app_settings_map(["tts_base_url", "tts_api_key", "tts_model", "tts_voices", "tts_default_voice"])
    return {
        "mode": settings.tts_mode,                          # 每节点（env）
        "base_url": overrides.get("tts_base_url"),           # 系统共享：只读 DB
        "api_key": overrides.get("tts_api_key"),
        "model": overrides.get("tts_model"),
        "voices": overrides.get("tts_voices") or settings.tts_voices,  # 音色清单留内置默认兜底（非密钥、纯展示）
        "default_voice": overrides.get("tts_default_voice"),
        "local_command": settings.tts_local_command,        # 每节点（env）
        "format": settings.tts_format,                      # 每节点（env）
        "dev_mode": settings.tts_dev_mode,                  # 每节点（env）
    }


def tts_configured() -> bool:
    config = resolve_tts_config()
    if config["dev_mode"]:
        return True
    if config["mode"] == "local":
        return bool(config["local_command"])
    return bool(config["base_url"] and config["api_key"])


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


def _synthesize_local(config: dict[str, Any], text: str, voice: str) -> tuple[bytes, str]:
    template = config["local_command"]
    if not template:
        raise RuntimeError("本地 TTS 命令未配置")
    fmt = (config["format"] or "mp3").lower()
    workdir = tempfile.mkdtemp(prefix="rt-tts-")
    out = os.path.join(workdir, f"tts.{fmt}")
    try:
        cmd = (
            template.replace("{text}", text.replace('"', '\\"'))
            .replace("{voice}", voice)
            .replace("{out}", out)
        )
        # 文本同时经【标准输入】喂给命令（Piper 等本地引擎据此合成，长文本/特殊字符不必走命令行转义；
        # 仍保留 {text} 占位以兼容自定义命令）。
        proc = subprocess.run(cmd, shell=True, input=text, capture_output=True, text=True, timeout=120)
        if proc.returncode != 0 or not os.path.exists(out):
            raise RuntimeError(f"本地 TTS 命令失败（{proc.returncode}）：{(proc.stderr or proc.stdout)[:300]}")
        with open(out, "rb") as fh:
            return fh.read(), content_type_for(fmt)
    finally:
        import shutil

        shutil.rmtree(workdir, ignore_errors=True)


async def synthesize(text: str, voice: str | None = None, use_cache: bool = True) -> tuple[bytes, str]:
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
    is_local_ready = bool(config["mode"] == "local" and config["local_command"])

    if config["dev_mode"] and not is_cloud_ready and not is_local_ready:
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
        if config["mode"] == "local":
            if not is_local_ready:
                raise RuntimeError("本地 TTS 命令未配置，请在部署时设置 TTS_LOCAL_COMMAND")
            audio, ct = await asyncio.to_thread(_synthesize_local, config, text, voice)
        else:
            if not is_cloud_ready:
                raise RuntimeError("语音合成服务未配置，请在管理台「系统设置 → 语音合成」中配置")
            async with httpx.AsyncClient(timeout=httpx.Timeout(60, connect=15)) as client:
                resp = await client.post(
                    config["base_url"].rstrip("/") + "/audio/speech",
                    headers={"Authorization": f"Bearer {config['api_key']}"},
                    json={"model": config["model"], "input": text, "voice": voice, "response_format": fmt},
                )
            resp.raise_for_status()
            audio, ct = resp.content, content_type_for(fmt)
    finally:
        _synth_sem().release()

    if cache_key is not None:
        _cache_set(cache_key, audio)
    return audio, ct


# ============================================================
# 语音识别（练习用）：复用 ASR 配置，转写时用参考句做偏置实现「宽容容错」
# ============================================================

async def transcribe(audio_bytes: bytes, suffix: str = ".m4a", reference_text: str | None = None,
                     language: str = "en") -> str:
    """把一小段练习录音转成文字。cloud 用参考句 prompt 做偏置（宽容识别），local 直接转写，dev 回参考句。"""
    from .audio_pipeline import resolve_asr_config, _transcribe_local

    config = resolve_asr_config()
    is_cloud = bool(config["base_url"] and config["api_key"])
    is_local = bool(config["mode"] == "local" and config["local_command"])
    if config["dev_mode"] and not is_cloud and not is_local:
        return (reference_text or "").strip()  # 开发模式：假定识别到参考句，链路可端到端联调

    workdir = tempfile.mkdtemp(prefix="rt-asr-")
    path = Path(workdir) / f"clip{suffix or '.m4a'}"
    path.write_bytes(audio_bytes)
    try:
        if config["mode"] == "local":
            if not is_local:
                raise RuntimeError("本地转写命令未配置")
            # 口语练习是英语 → 明确传 en，避免本地 whisper 误当中文转写导致空输出
            return (await asyncio.to_thread(_transcribe_local, config, path, Path(workdir), language)).strip()
        if not is_cloud:
            raise RuntimeError("语音识别服务未配置，请在管理台「系统设置」中配置 ASR")
        data = {"model": config["model"], "language": language, "response_format": "json"}
        if reference_text:
            data["prompt"] = reference_text  # whisper 把 prompt 当上下文偏置 → 更宽容地识别成目标句
        async with httpx.AsyncClient(timeout=httpx.Timeout(120, connect=15)) as client:
            with path.open("rb") as fh:
                resp = await client.post(
                    config["base_url"].rstrip("/") + "/audio/transcriptions",
                    headers={"Authorization": f"Bearer {config['api_key']}"},
                    data=data,
                    files={"file": (path.name, fh, "audio/mpeg")},
                )
        resp.raise_for_status()
        return str(resp.json().get("text", "")).strip()
    finally:
        import shutil

        shutil.rmtree(workdir, ignore_errors=True)


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
