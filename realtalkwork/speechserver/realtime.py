"""实时通道：上传语音流 + 文字上下文 → 返回「用户转写 + 文本流 + 语音流」。

事件协议 = OpenAI Realtime 的子集（api 后端现有的 /roleplay/voice 转发器无需大改即可对接）：
  客户端→服务端: session.update / conversation.item.create / input_audio_buffer.append(base64)
                / input_audio_buffer.commit / response.create / response.cancel
  服务端→客户端: session.created / conversation.item.input_audio_transcription.completed
                / response.created / response.text.delta|done / response.audio.delta(base64 pcm16)|done
                / response.done / error

【live 全双工模式】（对齐 GPT-Live 范式；session.update 带 turn_detection={"type":"server_vad"} 开启）：
  客户端只管持续上行 pcm16 音频（无需 commit/response.create），轮次判定全在服务端——
  能量 VAD 自动判停 → 自动转写 + 推理 + 推回；AI 回复期间用户开口 = 打断：
  服务端发 response.cancelled 并把新一句当作新轮次。事件对齐 OpenAI server_vad 语义
  （input_audio_buffer.speech_started / speech_stopped），未来切 GPT-Live API 仅需事件名映射。

多活/高并发：会话上下文（instructions + 历史）存 Redis（key spx:ctx:<session>，5 分钟滑动 TTL，
每次使用重算；收到 session.close 立即删除）——
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


def _pcm16_to_wav(pcm: bytes, rate: int = 16000) -> bytes:
    import io
    import wave

    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()

_CTX_TTL = int(os.getenv("SPEECH_CTX_TTL_SECONDS", "300"))   # 5 分钟滑动：每次使用重算；主动结束立即删除
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


def _delete_ctx(session: str) -> None:
    r = _redis_client()
    if r is not None:
        try:
            r.delete(f"spx:ctx:{session}")
        except Exception:  # noqa: BLE001
            pass
    _local_ctx.pop(session, None)


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
    pending_user_text: str | None = None
    response_task: asyncio.Task | None = None
    send_lock = asyncio.Lock()

    # ---- live 全双工（server_vad）状态：轮次判定在服务端 ----
    live = False
    live_rate = 16000                 # live 模式固定裸 pcm16 上行
    vad_silence_ms = 800              # 停顿多久判"说完"
    vad_min_speech_ms = 400           # 有效人声下限（低于视为噪音丢弃）
    noise_floor = 0.15                # 自适应环境底噪
    heard_speech = False
    voiced_ms = 0.0
    silent_ms = 0.0
    preroll = bytearray()             # 说话前的预滚（保句首），未开口时限长
    PREROLL_MAX_BYTES = 16000         # ~0.5s @16k16bit

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
            translation = ""
            if "⟦ZH⟧" in reply:
                reply, _, translation = reply.partition("⟦ZH⟧")
                reply, translation = reply.strip(), translation.strip()
            await _sj({"type": "response.text.done", "text": reply, "translation": translation})
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

    def _rms(chunk: bytes) -> float:
        """pcm16 块能量（0-1 归一），live VAD 用。"""
        n = len(chunk) // 2
        if n == 0:
            return 0.0
        acc = 0.0
        for i in range(0, n * 2, 2):
            v = int.from_bytes(chunk[i:i + 2], "little", signed=True) / 32768.0
            acc += v * v
        return min(1.0, (acc / n) ** 0.5 * 8.0)

    async def _live_turn() -> None:
        """live 自动轮次：判停 → 转写 → 事件 → 自动推理（无需客户端 commit/response.create）。"""
        nonlocal heard_speech, voiced_ms, silent_ms, response_task
        audio = bytes(audio_buf)
        audio_buf.clear()
        heard_speech = False
        voiced_ms = 0.0
        silent_ms = 0.0
        await _sj({"type": "input_audio_buffer.speech_stopped"})
        text, words, duration = await engine.transcribe_verbose(_pcm16_to_wav(audio, live_rate), language)
        await _sj({"type": "conversation.item.input_audio_transcription.completed",
                   "transcript": text, "words": words, "duration": duration})
        if text.strip():
            _cancel_response()
            response_task = asyncio.create_task(_respond(text))

    async def _live_feed(chunk: bytes) -> None:
        """live 模式每个音频块：能量 VAD 状态机——起声打断进行中的回复；停顿自动成轮。"""
        nonlocal noise_floor, heard_speech, voiced_ms, silent_ms, response_task
        level = _rms(chunk)
        chunk_ms = max(1.0, len(chunk) / 2 / live_rate * 1000)
        if not heard_speech:
            noise_floor = min(0.5, noise_floor * 0.92 + level * 0.08)
        speech_thresh = noise_floor + 0.10
        silence_thresh = noise_floor + 0.045

        if heard_speech:
            audio_buf.extend(chunk)
        else:
            preroll.extend(chunk)
            if len(preroll) > PREROLL_MAX_BYTES:
                del preroll[:len(preroll) - PREROLL_MAX_BYTES]

        if level >= speech_thresh:
            if not heard_speech:
                heard_speech = True
                audio_buf.extend(preroll)   # 句首预滚并入
                preroll.clear()
                # 起声即打断：AI 正在回复 → 取消并通知（客户端应立即停止播放）
                if response_task and not response_task.done():
                    _cancel_response()
                    await _sj({"type": "response.cancelled"})
                await _sj({"type": "input_audio_buffer.speech_started"})
            voiced_ms += chunk_ms
            silent_ms = 0.0
        elif heard_speech:
            if level <= silence_thresh:
                silent_ms += chunk_ms
            else:
                silent_ms = 0.0
            if silent_ms >= vad_silence_ms:
                if voiced_ms >= vad_min_speech_ms:
                    await _live_turn()
                else:
                    # 纯噪音：静默丢弃回到聆听
                    audio_buf.clear()
                    heard_speech = False
                    voiced_ms = 0.0
                    silent_ms = 0.0

    restored = bool(ctx.get("history")) or bool(ctx.get("instructions"))
    await _sj({"type": "session.created", "session": {"id": session, "restored": restored}})
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
                if "turn_detection" in sess:
                    td = sess.get("turn_detection") or {}
                    live = (td.get("type") == "server_vad")
                    if live:
                        vad_silence_ms = int(td.get("silence_ms") or td.get("silence_duration_ms") or 800)
                        vad_min_speech_ms = int(td.get("min_speech_ms") or 400)
                        live_rate = int(sess.get("sample_rate") or 16000)
                if sess.get("sample_rate"):
                    live_rate = int(sess["sample_rate"])
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
            elif kind == "input_audio_buffer.clear":
                audio_buf.clear()
                preroll.clear()
                heard_speech = False
                voiced_ms = 0.0
                silent_ms = 0.0
            elif kind == "input_audio_buffer.append":
                try:
                    chunk = base64.b64decode(ev.get("audio", ""))
                except Exception:  # noqa: BLE001
                    continue
                if live:
                    await _live_feed(chunk)   # 全双工：VAD/轮次/打断全在服务端
                else:
                    audio_buf.extend(chunk)
            elif kind == "input_audio_buffer.commit":
                _cancel_response()
                audio = bytes(audio_buf)
                audio_buf.clear()
                if not audio:
                    continue
                if (ev.get("format") or "").lstrip(".") in ("pcm16", "pcm"):
                    audio = _pcm16_to_wav(audio, int(ev.get("sample_rate") or 16000))
                text, words, duration = await engine.transcribe_verbose(audio, language)
                # words/duration：词级置信度与时长（发音标色/语速分析），调用方可忽略
                await _sj({"type": "conversation.item.input_audio_transcription.completed",
                           "transcript": text, "words": words, "duration": duration})
                # 对齐 OpenAI 语义：commit 只转写；等调用方发 response.create 才推理
                # （api 后端沉浸式要先做评分/进度判断再决定说什么，必须能只拿转写）
                pending_user_text = text
            elif kind == "response.create":
                _cancel_response()
                response_task = asyncio.create_task(_respond(pending_user_text))
                pending_user_text = None
            elif kind == "response.cancel":
                _cancel_response()
            elif kind == "session.close":
                # 用户主动结束：立即删除 Redis 上下文（不等 TTL）
                _delete_ctx(session)
                break
    except WebSocketDisconnect:
        pass
    finally:
        _cancel_response()
