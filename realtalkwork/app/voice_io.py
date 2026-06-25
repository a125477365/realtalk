"""语音合成（TTS）服务层：把一段文本合成成音频字节。

两种后端，管理台可切（与 ASR 一致的取舍）：
- cloud：OpenAI 兼容 `/audio/speech`（base_url/api_key/model/voice 可在管理台在线配置）。
- local：服务器本地命令行（Piper/Coqui 等），命令模板由部署（env）控制。

mode / 本地命令由部署控制（env / setup.sh），管理台只配置云端 base_url/api_key/model 与可选音色。
"""
from __future__ import annotations

import asyncio
import os
import struct
import subprocess
import tempfile
from typing import Any

import httpx

from .settings import settings

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
        "mode": settings.tts_mode,
        "base_url": overrides.get("tts_base_url") or settings.tts_base_url,
        "api_key": overrides.get("tts_api_key") or settings.tts_api_key,
        "model": overrides.get("tts_model") or settings.tts_model,
        "voices": overrides.get("tts_voices") or settings.tts_voices,
        "default_voice": overrides.get("tts_default_voice") or settings.tts_default_voice,
        "local_command": settings.tts_local_command,
        "format": settings.tts_format,
        "dev_mode": settings.tts_dev_mode,
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
        proc = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=120)
        if proc.returncode != 0 or not os.path.exists(out):
            raise RuntimeError(f"本地 TTS 命令失败（{proc.returncode}）：{(proc.stderr or proc.stdout)[:300]}")
        with open(out, "rb") as fh:
            return fh.read(), content_type_for(fmt)
    finally:
        import shutil

        shutil.rmtree(workdir, ignore_errors=True)


async def synthesize(text: str, voice: str | None = None) -> tuple[bytes, str]:
    """把文本合成为音频，返回 (音频字节, content_type)。文本为空抛错。"""
    text = (text or "").strip()
    if not text:
        raise RuntimeError("待合成文本为空")
    config = resolve_tts_config()
    voice = normalize_voice(voice)
    fmt = (config["format"] or "mp3").lower()

    is_cloud_ready = bool(config["base_url"] and config["api_key"])
    is_local_ready = bool(config["mode"] == "local" and config["local_command"])

    if config["dev_mode"] and not is_cloud_ready and not is_local_ready:
        return _silent_wav(), content_type_for("wav")

    if config["mode"] == "local":
        if not is_local_ready:
            raise RuntimeError("本地 TTS 命令未配置，请在部署时设置 TTS_LOCAL_COMMAND")
        return await asyncio.to_thread(_synthesize_local, config, text, voice)

    if not is_cloud_ready:
        raise RuntimeError("语音合成服务未配置，请在管理台「系统设置 → 语音合成」中配置")
    async with httpx.AsyncClient(timeout=httpx.Timeout(60, connect=15)) as client:
        resp = await client.post(
            config["base_url"].rstrip("/") + "/audio/speech",
            headers={"Authorization": f"Bearer {config['api_key']}"},
            json={"model": config["model"], "input": text, "voice": voice, "response_format": fmt},
        )
    resp.raise_for_status()
    return resp.content, content_type_for(fmt)
