"""B 类对话·实时通道：私教对话经「本地实时语音模型服务器」的 WS /v1/realtime 流式进行。

配置 conv_realtime_base_url（DB，管理台可改，现读生效）后启用；未配置/连接失败时调用方回退
原有分步管线（ASR→LLM→TTS），私教不因本地服务异常而中断。

工作方式（App 协议不变，见 main.freetalk_stream）：
- 会话 id = ft-<user_id>：语音服务器把进行中的上下文存 Redis（5 分钟滑动 TTL），
  断线/换后端副本重连自动续上；App 主动退出时发 session.close 立即清理。
- 新会话（restored=false）时播种：私教人设指令 + 用户记忆 + 近期历史（来自本库 freetalk_messages）。
- App 音频帧【边收边转发】给语音服务器（input_audio_buffer.append），commit 后拿转写、
  再 response.create 拿文本流+语音流；语音 pcm 累积封成 WAV 推回 App（App 播放协议不变）。
"""
from __future__ import annotations

import asyncio
import base64
import io
import json
import wave


def resolve_conv_realtime_url() -> str:
    """现读 DB：B 类对话实时通道地址（如 ws://speech:9100/v1/realtime）。空=未启用。"""
    from .storage import db

    try:
        return (db.get_app_setting_str("conv_realtime_base_url") or "").strip()
    except Exception:  # noqa: BLE001
        return ""


def _pcm_to_wav(pcm: bytes, rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


class ConvRealtimeSession:
    """与本地语音服务器实时通道的一条上游连接（每个私教 WS 一条）。"""

    def __init__(self, url: str, session_id: str, language: str = "en"):
        sep = "&" if "?" in url else "?"
        self.url = f"{url}{sep}session={session_id}&language={language}"
        self.ws = None
        self.restored = False

    async def connect(self, timeout: float = 8.0):
        import websockets

        self.ws = await asyncio.wait_for(websockets.connect(self.url, max_size=None), timeout=timeout)
        created = json.loads(await asyncio.wait_for(self.ws.recv(), timeout=timeout))
        self.restored = bool((created.get("session") or {}).get("restored"))
        return self

    async def send(self, obj: dict) -> None:
        await self.ws.send(json.dumps(obj, ensure_ascii=False))

    async def seed(self, instructions: str, history: list[dict[str, str]]) -> None:
        """新会话播种：人设+记忆 → instructions；近期历史逐条注入（服务端按预算裁剪并存 Redis）。"""
        await self.send({"type": "session.update", "session": {"instructions": instructions}})
        for item in history:
            await self.send({"type": "conversation.item.create", "item": {
                "role": "user" if item.get("speaker") == "user" else "assistant",
                "content": [{"type": "input_text", "text": item.get("content", "")}],
            }})

    async def append_audio(self, chunk: bytes) -> None:
        await self.send({"type": "input_audio_buffer.append", "audio": base64.b64encode(chunk).decode()})

    async def commit_and_transcribe(self, timeout: float) -> str:
        """commit 后等待转写事件（其余事件忽略）。"""
        await self.send({"type": "input_audio_buffer.commit"})
        while True:
            ev = json.loads(await asyncio.wait_for(self.ws.recv(), timeout=timeout))
            if ev.get("type") == "conversation.item.input_audio_transcription.completed":
                return (ev.get("transcript") or "").strip()
            if ev.get("type") == "error":
                raise RuntimeError(ev.get("message") or "实时通道转写失败")

    async def create_response(self, timeout: float) -> tuple[str, bytes | None]:
        """response.create 后收文本流+语音流；返回 (回复文本, WAV字节或None)。"""
        await self.send({"type": "response.create"})
        text = ""
        pcm = bytearray()
        rate = 22050
        while True:
            ev = json.loads(await asyncio.wait_for(self.ws.recv(), timeout=timeout))
            kind = ev.get("type")
            if kind == "response.text.done":
                text = (ev.get("text") or "").strip()
            elif kind == "response.audio.delta":
                rate = int(ev.get("sample_rate") or rate)
                try:
                    pcm.extend(base64.b64decode(ev.get("delta", "")))
                except Exception:  # noqa: BLE001
                    pass
            elif kind == "response.done":
                return text, (_pcm_to_wav(bytes(pcm), rate) if pcm else None)
            elif kind == "error":
                raise RuntimeError(ev.get("message") or "实时通道推理失败")

    async def cancel_response(self) -> None:
        try:
            await self.send({"type": "response.cancel"})
        except Exception:  # noqa: BLE001
            pass

    async def close(self, wipe_context: bool) -> None:
        """wipe_context=True（用户主动结束）→ 通知服务端立即删除 Redis 上下文。"""
        try:
            if wipe_context:
                await self.send({"type": "session.close"})
        except Exception:  # noqa: BLE001
            pass
        try:
            await self.ws.close()
        except Exception:  # noqa: BLE001
            pass
