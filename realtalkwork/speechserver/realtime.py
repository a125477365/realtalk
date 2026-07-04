"""实时通道：上传语音流 + 文字上下文 → 返回「用户转写 + 文本流 + 语音流」。

事件协议 = OpenAI Realtime 的子集（api 后端现有的 /roleplay/voice 转发器无需大改即可对接）：
  客户端→服务端: session.update / conversation.item.create / input_audio_buffer.append(base64)
                / input_audio_buffer.commit / response.create / response.cancel
  服务端→客户端: session.created / conversation.item.input_audio_transcription.completed
                / response.created / response.text.delta|done / response.audio.delta(base64 pcm16)|done
                / response.done / error

多活/高并发：会话上下文（instructions + 历史）存 Redis（key spx:ctx:<session>，30 分钟滑动 TTL）——
连接断开换到任何一个副本，带同一个 ?session= 重连即可续聊；未配 REDIS_URL 时退化为进程内存（单机可用）。
音频缓冲只存在于当前 WS 连接内（一句话的生命周期），无需跨节点。
"""
from __future__ import annotations

import asyncio
import base64
import json
import os
import uuid

from fastapi import WebSocket, WebSocketDisconnect

import engine

_CTX_TTL = int(os.getenv("SPEECH_CTX_TTL_SECONDS", "1800"))
_HISTORY_BUDGET_CHARS = int(os.getenv("SPEECH_CTX_BUDGET_CHARS", "12000"))
_redis = None
_local_ctx: dict[str, dict] = {}   # 无 Redis 时的单机退化


def _redis_client():
    global _redis
    if _redis is None and os.getenv("REDIS_URL"):
        import redis

        _redis = redis.Redis.from_url(
            os.environ["REDIS_URL"], decode_responses=True,
            socket_timeout=5, socket_connect_timeout=5, retry_on_timeout=True,
        )
    return _redis


def _load_ctx(session: str) -> dict:
    r = _redis_client()
    if r is not None:
        try:
            raw = r.get(f"spx:ctx:{session}")
            if raw:
                r.expire(f"spx:ctx:{session}", _CTX_TTL)   # 滑动 TTL
                return json.loads(raw)
        except Exception:  # noqa: BLE001 — Redis 抖动退化为空上下文，不断服务
            pass
        return {"instructions": "", "history": []}
    return _local_ctx.setdefault(session, {"instructions": "", "history": []})


def _save_ctx(session: str, ctx: dict) -> None:
    # 历史按字符预算裁剪（保最近），防上下文无限膨胀
    used, kept = 0, []
    for item in reversed(ctx.get("history", [])):
        cost = len(str(item.get("content", ""))) + 8
        if kept and used + cost > _HISTORY_BUDGET_CHARS:
            break
        kept.append(item)
        used += cost
    ctx["history"] = list(reversed(kept))
    r = _redis_client()
    if r is not None:
        try:
            r.set(f"spx:ctx:{session}", json.dumps(ctx, ensure_ascii=False), ex=_CTX_TTL)
        except Exception:  # noqa: BLE001
            pass
    else:
        _local_ctx[session] = ctx


async def handle_session(ws: WebSocket) -> None:
    await ws.accept()
    session = ws.query_params.get("session") or uuid.uuid4().hex
    ctx = _load_ctx(session)
    voice = ""
    language = ws.query_params.get("language") or "en"
    audio_buf = bytearray()
    response_task: asyncio.Task | None = None
    send_lock = asyncio.Lock()

    async def _sj(obj: dict) -> None:
        async with send_lock:
            await ws.send_text(json.dumps(obj, ensure_ascii=False))

    def _cancel_response() -> None:
        nonlocal response_task
        if response_task and not response_task.done():
            response_task.cancel()
        response_task = None

    async def _respond(user_text: str | None) -> None:
        """一轮推理：转写已发；LLM 文本流 + TTS 语音流推回。"""
        try:
            messages = []
            if ctx.get("instructions"):
                messages.append({"role": "system", "content": ctx["instructions"]})
            messages.extend(ctx.get("history", []))
            if user_text:
                messages.append({"role": "user", "content": user_text})
            await _sj({"type": "response.created"})
            deltas: list[str] = []
            loop = asyncio.get_running_loop()

            def on_delta(d: str) -> None:
                deltas.append(d)
                asyncio.run_coroutine_threadsafe(_sj({"type": "response.text.delta", "delta": d}), loop)

            reply = await engine.chat(messages, stream_cb=on_delta)
            await _sj({"type": "response.text.done", "text": reply})
            if user_text:
                ctx["history"].append({"role": "user", "content": user_text})
            ctx["history"].append({"role": "assistant", "content": reply})
            _save_ctx(session, ctx)
            if reply:
                wav = await engine.synthesize(reply, voice or None)
                pcm, rate = engine.wav_to_pcm16(wav)
                chunk = rate // 2 * 2   # ~0.5s/帧
                for i in range(0, len(pcm), chunk):
                    await _sj({"type": "response.audio.delta",
                               "delta": base64.b64encode(pcm[i:i + chunk]).decode(),
                               "sample_rate": rate})
                await _sj({"type": "response.audio.done"})
            await _sj({"type": "response.done"})
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            try:
                await _sj({"type": "error", "message": str(exc)[:200]})
            except Exception:  # noqa: BLE001
                pass

    await _sj({"type": "session.created", "session": {"id": session}})
    try:
        while True:
            raw = await ws.receive_text()
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            kind = ev.get("type", "")
            if kind == "session.update":
                sess = ev.get("session") or {}
                if "instructions" in sess:
                    ctx["instructions"] = str(sess.get("instructions") or "")
                if sess.get("voice"):
                    voice = str(sess["voice"])
                if sess.get("language"):
                    language = str(sess["language"])
                _save_ctx(session, ctx)
                await _sj({"type": "session.updated"})
            elif kind == "conversation.item.create":
                # 文字上下文注入（如场景台词/翻译好的提示），不触发回复
                item = ev.get("item") or {}
                parts = item.get("content") or []
                text = " ".join(str(p.get("text", "")) for p in parts if isinstance(p, dict)).strip()
                if text:
                    ctx["history"].append({"role": item.get("role", "user"), "content": text})
                    _save_ctx(session, ctx)
            elif kind == "input_audio_buffer.append":
                try:
                    audio_buf.extend(base64.b64decode(ev.get("audio", "")))
                except Exception:  # noqa: BLE001
                    pass
            elif kind == "input_audio_buffer.commit":
                _cancel_response()
                audio = bytes(audio_buf)
                audio_buf.clear()
                if not audio:
                    continue
                text = await engine.transcribe(audio, language)
                await _sj({"type": "conversation.item.input_audio_transcription.completed", "transcript": text})
                if text:
                    response_task = asyncio.create_task(_respond(text))
            elif kind == "response.create":
                _cancel_response()
                response_task = asyncio.create_task(_respond(None))
            elif kind == "response.cancel":
                _cancel_response()
    except WebSocketDisconnect:
        pass
    finally:
        _cancel_response()
