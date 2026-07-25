"""B 类对话·实时通道：私教对话经「本地实时语音模型服务器」的 WS /v1/realtime 流式进行。

配置「B·对话语音模型」base_url 后自动派生实时通道地址启用；未配置/连接失败时调用方回退
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
import os
import wave


def resolve_conv_realtime_url() -> str:
    """B 类对话实时通道地址：由「B·对话语音模型」一张卡的 base_url 自动派生（ws(s)…/realtime）。
    空=未配置（沉浸式/私教回退分步管线）。"""
    from .voice_io import conv_realtime_url

    try:
        return conv_realtime_url()
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

    def __init__(self, url: str, session_id: str, language: str = "en",
                 live: bool = False, voice: str | None = None,
                 transcribe_only: bool = False):
        from .voice_io import resolve_conv_voice

        cv = resolve_conv_voice()
        self.is_openai = cv["is_openai"]
        self.api_key = cv["api_key"]
        self.model = cv["model"]
        self.voice = (voice or "").strip() or cv["voice"]   # 用户自选音色优先，未选用 B 卡默认
        # 只转写实时模式（实时翻译）：连续 VAD 分句、只吐转写不回话 → 强制 server_vad(live)
        self.transcribe_only = transcribe_only
        self.live = live or transcribe_only                  # 全双工/连续分句：轮次判定在服务端（server_vad）
        sep = "&" if "?" in url else "?"
        if self.is_openai:
            self.url = f"{url}{sep}model={self.model or 'gpt-realtime'}"
        else:
            # 只转写(实时翻译)：语种必须自动判定——用户可能说中文/英文，强制某一语种会把中文
            # 误识别成英文，导致翻译方向反了(说中文却念中文)。用 auto 让 whisper 自动判语种。
            lang = "auto" if transcribe_only else language
            extra = "&mode=transcribe" if transcribe_only else ""
            self.url = f"{url}{sep}session={session_id}&language={lang}{extra}"
        self.ws = None
        self.restored = False

    async def connect(self, timeout: float = 8.0):
        import websockets

        headers = [("Authorization", f"Bearer {self.api_key}")]
        # OpenAI Realtime GA（gpt-realtime 系）不需要 beta 头；beta 接口已于 2026-05-12 下线。
        # 仅当显式设 OPENAI_REALTIME_BETA=1（对接老 beta 端点/某些代理）时才带 OpenAI-Beta 头。
        if self.is_openai and os.getenv("OPENAI_REALTIME_BETA") == "1":
            headers.append(("OpenAI-Beta", "realtime=v1"))
        self.ws = await asyncio.wait_for(
            websockets.connect(self.url, additional_headers=headers, max_size=None), timeout=timeout
        )
        created = json.loads(await asyncio.wait_for(self.ws.recv(), timeout=timeout))
        self.restored = bool((created.get("session") or {}).get("restored"))
        # 轮次策略：live=服务端 VAD 全双工（自动判停+起声打断）；否则由我们 commit/response.create 驱动
        turn = {"type": "server_vad"} if self.live else None
        if self.is_openai:
            await self.send({"type": "session.update", "session": {
                "type": "realtime",
                "output_modalities": ["audio"],
                "audio": {
                    "input": {
                        "format": {"type": "audio/pcm", "rate": 24000},
                        "transcription": {"model": "whisper-1"},
                        "turn_detection": turn,
                    },
                    "output": {
                        "format": {"type": "audio/pcm"},
                        "voice": self.voice or "marin",
                    },
                },
            }})
        else:
            await self.send({"type": "session.update", "session": {
                "voice": self.voice or "",
                "sample_rate": 16000,
                "turn_detection": turn,
            }})
        return self

    async def recv_event(self, timeout: float) -> dict:
        """收一个上游事件（live 中继泵用）。"""
        return json.loads(await asyncio.wait_for(self.ws.recv(), timeout=timeout))

    async def send(self, obj: dict) -> None:
        await self.ws.send(json.dumps(obj, ensure_ascii=False))

    async def seed(self, instructions: str, history: list[dict[str, str]]) -> None:
        """新会话播种：人设+记忆 → instructions；近期历史逐条注入（服务端按预算裁剪并存 Redis）。
        OpenAI GA 严格 schema：session.update 需带 type=realtime；item 需带 type=message，
        assistant 历史的内容块必须是 output_text（input_text 会被 400 拒）。本地通道两者都兼容。"""
        session_patch: dict = {"instructions": instructions}
        if self.is_openai:
            session_patch["type"] = "realtime"
        await self.send({"type": "session.update", "session": session_patch})
        for item in history:
            is_user = item.get("speaker") == "user"
            content_type = "input_text" if (is_user or not self.is_openai) else "output_text"
            await self.send({"type": "conversation.item.create", "item": {
                "type": "message",
                "role": "user" if is_user else "assistant",
                "content": [{"type": content_type, "text": item.get("content", "")}],
            }})

    def _resample_16k_to_24k(self, chunk: bytes) -> bytes:
        """PCM16 mono 16k→24k：OpenAI Realtime 只接受 24kHz，App 上行是 16kHz。
        优先 audioop(ratecv 带状态防爆音)；Python≥3.13 没有 audioop 时用线性插值兜底。"""
        try:
            import audioop

            converted, self._ratecv_state = audioop.ratecv(chunk, 2, 1, 16000, 24000, self._ratecv_state)
            return converted
        except ImportError:
            import array

            src = array.array("h")
            src.frombytes(chunk)
            n = len(src)
            if n == 0:
                return b""
            out = array.array("h", bytes(0))
            for i in range(n * 3 // 2):   # 每 2 个输入样本产出 3 个输出样本
                pos = i * 2 / 3
                lo = int(pos)
                hi = min(lo + 1, n - 1)
                frac = pos - lo
                out.append(int(src[lo] * (1 - frac) + src[hi] * frac))
            return out.tobytes()

    _ratecv_state = None   # audioop.ratecv 的重采样连续性状态（每会话独立）

    async def append_audio(self, chunk: bytes) -> None:
        if self.is_openai:
            chunk = self._resample_16k_to_24k(chunk)
        await self.send({"type": "input_audio_buffer.append", "audio": base64.b64encode(chunk).decode()})

    async def commit_and_transcribe(self, timeout: float, audio_format: str = "pcm16", sample_rate: int = 16000) -> str:
        """commit 后等待转写事件（其余事件忽略）。audio_format 告知服务器如何封包（pcm16/m4a）。"""
        text, _words, _dur = await self.commit_and_transcribe_verbose(timeout, audio_format, sample_rate)
        return text

    async def commit_and_transcribe_verbose(
        self, timeout: float, audio_format: str = "pcm16", sample_rate: int = 16000
    ) -> tuple[str, list[dict], float]:
        """同 commit_and_transcribe，另返回词级详情与音频时长（本地语音服务器提供；OpenAI 无词级则为空）。"""
        if self.is_openai:
            await self.send({"type": "input_audio_buffer.commit"})   # GA 对未知字段严格
        else:
            await self.send({"type": "input_audio_buffer.commit", "format": audio_format, "sample_rate": sample_rate})
        while True:
            ev = json.loads(await asyncio.wait_for(self.ws.recv(), timeout=timeout))
            if ev.get("type") == "conversation.item.input_audio_transcription.completed":
                return (
                    (ev.get("transcript") or "").strip(),
                    ev.get("words") or [],
                    float(ev.get("duration") or 0.0),
                )
            if ev.get("type") == "error":
                raise RuntimeError(ev.get("message") or "实时通道转写失败")

    async def create_response(self, timeout: float) -> tuple[str, str, bytes | None]:
        """response.create 后收文本流+语音流；返回 (回复文本, 中文翻译, WAV字节或None)。
        事件名三代兼容：本地(response.text.done 带 translation)、OpenAI Realtime beta(v1：
        response.audio.delta/audio_transcript.done)、OpenAI Realtime GA(gpt-realtime/gpt-realtime-2：
        response.output_audio.delta/output_audio_transcript.done/output_text.done)。"""
        await self.send({"type": "response.create"})
        text = ""
        translation = ""
        pcm = bytearray()
        rate = 24000 if self.is_openai else 22050
        while True:
            ev = json.loads(await asyncio.wait_for(self.ws.recv(), timeout=timeout))
            kind = ev.get("type")
            if kind in ("response.text.done", "response.output_text.done"):
                text = (ev.get("text") or "").strip() or text
                translation = (ev.get("translation") or "").strip() or translation
            elif kind in ("response.audio_transcript.done", "response.output_audio_transcript.done"):
                # OpenAI：口播文本（GA 版事件名带 output_ 前缀）
                text = text or (ev.get("transcript") or "").strip()
            elif kind in ("response.audio.delta", "response.output_audio.delta"):
                rate = int(ev.get("sample_rate") or rate)
                try:
                    pcm.extend(base64.b64decode(ev.get("delta", "")))
                except Exception:  # noqa: BLE001
                    pass
            elif kind == "response.done":
                if pcm or self.is_openai:
                    # OpenAI GA：done 严格最后（音频必在其前），无需等待
                    return text, translation, (_pcm_to_wav(bytes(pcm), rate) if pcm else None)
                # 本地 s2s：TTS 与 LLM 并行流式，多路并发抢 GPU 时 TTS 会慢于文本 →
                # response.done 可能先于音频尾流到达（单路空闲时音频总在 done 前到齐，
                # 双路并发实测必现空音频）。done 后宽限排水：最多等 8s 首个 delta，
                # 收到后以 1.2s 无新事件视为流尾。等不到则返回 None，由上层 REST TTS 兜底。
                loop = asyncio.get_event_loop()
                deadline = loop.time() + 8.0
                try:
                    while True:
                        wait = 1.2 if pcm else max(0.1, deadline - loop.time())
                        ev2 = json.loads(await asyncio.wait_for(self.ws.recv(), timeout=wait))
                        k2 = ev2.get("type")
                        if k2 in ("response.audio.delta", "response.output_audio.delta"):
                            rate = int(ev2.get("sample_rate") or rate)
                            try:
                                pcm.extend(base64.b64decode(ev2.get("delta", "")))
                            except Exception:  # noqa: BLE001
                                pass
                        elif k2 in ("response.audio.done", "response.output_audio.done"):
                            break
                        elif not pcm and loop.time() >= deadline:
                            break
                except asyncio.TimeoutError:
                    pass
                return text, translation, (_pcm_to_wav(bytes(pcm), rate) if pcm else None)
            elif kind == "error":
                raise RuntimeError(str(ev.get("message") or ev.get("error") or "实时通道推理失败")[:200])

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
