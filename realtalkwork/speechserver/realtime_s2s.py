"""把 RealTalk 既有实时事件桥接到 HuggingFace speech-to-speech 原生 Realtime 服务。

该模块只做协议适配，不参与 ASR/LLM/TTS 推理：
  public :9100/v1/realtime -> same-container native S2S :8765/v1/realtime

保留 9100 作为唯一对外地址，因此 App、Web、管理端仍只填一份 Base URL。LLM 反向调用
同一容器的 /v1/chat/completions，真正与 REST 对话/场景生成共用同一个 llama.cpp GGUF 实例。
"""
from __future__ import annotations

import asyncio
import base64
import json
import os
from typing import Any

from fastapi import WebSocket, WebSocketDisconnect


S2S_URL = os.getenv("SPEECH_S2S_REALTIME_URL", "ws://127.0.0.1:8765/v1/realtime")
COMMIT_SILENCE_MS = max(128, int(os.getenv("SPEECH_S2S_COMMIT_SILENCE_MS", "750")))


def _translate_session_update(event: dict[str, Any]) -> dict[str, Any]:
    """旧 RealTalk session 字段 -> speech-to-speech 使用的 GA audio 嵌套字段。"""
    source = dict(event.get("session") or {})
    # 已是标准 Realtime GA 格式时原样保留；只补 type，避免丢客户端未来字段。
    if "audio" in source:
        source.setdefault("type", "realtime")
        return {"type": "session.update", "session": source}

    target: dict[str, Any] = {"type": "realtime"}
    if "instructions" in source:
        target["instructions"] = source["instructions"]
    rate = int(source.get("sample_rate") or 16000)
    audio: dict[str, Any] = {}
    if source.get("voice"):
        audio["output"] = {"voice": str(source["voice"])}
    turn = source.get("turn_detection")
    if isinstance(turn, dict):
        turn = dict(turn)
        # 旧实现使用 silence_ms；OpenAI GA/S2S 用 silence_duration_ms。
        if "silence_ms" in turn and "silence_duration_ms" not in turn:
            turn["silence_duration_ms"] = turn.pop("silence_ms")
        # S2S 的 ServerVad 没有 min_speech_ms；保留阈值/打断/静音等兼容字段。
        turn.pop("min_speech_ms", None)
        audio["input"] = {"turn_detection": turn}
    if audio:
        target["audio"] = audio
    # 当前 speech-to-speech 固定在服务端用 PCM16 16k 处理；rate 仅用于兼容层 commit 静音帧。
    target["_realtalk_input_rate"] = rate
    return {"type": "session.update", "session": target}


def _translate_server_event(event: dict[str, Any], public_session_id: str) -> dict[str, Any]:
    """补齐老后端依赖的 duration/采样率，其他 OpenAI Realtime 事件原样转发。"""
    kind = event.get("type")
    if kind == "session.created":
        return {
            "type": "session.created",
            "session": {"id": public_session_id, "restored": False, "realtalk_protocol": "speech-to-speech"},
        }
    if kind == "conversation.item.input_audio_transcription.completed":
        usage = event.get("usage") or {}
        event["duration"] = float(usage.get("seconds") or 0.0)
        event.setdefault("words", [])  # 原 API 的发音评分读取该字段；S2S 不提供词级置信度。
    if kind in ("response.output_audio.delta", "response.audio.delta"):
        # speech-to-speech 的公开事件未携带 sample_rate；它的 PCM 出口固定为 16k。
        event["sample_rate"] = 16000
    return event


async def handle_session(client: WebSocket) -> None:
    """在两个 WebSocket 间双向转发，兼容手动 commit 和 server_vad 全双工。"""
    import websockets

    await client.accept()
    public_session_id = client.query_params.get("session") or "s2s"
    try:
        async with websockets.connect(S2S_URL, max_size=None, ping_interval=20, ping_timeout=20) as upstream:
            # 先给调用方建立完成信号；S2S 的原始 session 配置不泄漏到兼容 API。
            initial = json.loads(await asyncio.wait_for(upstream.recv(), timeout=15))
            await client.send_text(json.dumps(_translate_server_event(initial, public_session_id), ensure_ascii=False))

            async def to_upstream() -> None:
                async for raw in client.iter_text():
                    try:
                        event = json.loads(raw)
                    except ValueError:
                        continue
                    kind = event.get("type")
                    if kind == "session.close":
                        # S2S 没有跨连接 Redis 会话，应用后端会在下次连接时从数据库重新播种。
                        return
                    if kind == "session.update":
                        outgoing = _translate_session_update(event)
                        # 这是兼容层私有提示，不能送给 S2S 的严格 Pydantic schema。
                        outgoing["session"].pop("_realtalk_input_rate", None)
                        await upstream.send(json.dumps(outgoing, ensure_ascii=False))
                        continue
                    if kind == "input_audio_buffer.clear":
                        # speech-to-speech 没有 clear 事件；cancel 能安全清掉当前回复，之后新音频重新起轮。
                        await upstream.send(json.dumps({"type": "response.cancel"}))
                        continue
                    if kind == "input_audio_buffer.commit":
                        # S2S 的 VAD 以静音判句，历史客户端的 commit 是立即断流；补一小段静音让
                        # 最后一个词可靠落盘，再把 commit 交给它做缓冲校验。
                        silence = b"\x00\x00" * (16000 * COMMIT_SILENCE_MS // 1000)
                        await upstream.send(json.dumps({
                            "type": "input_audio_buffer.append",
                            "audio": base64.b64encode(silence).decode("ascii"),
                        }))
                        await upstream.send(json.dumps({"type": "input_audio_buffer.commit"}))
                        continue
                    if kind == "conversation.item.create":
                        # RealTalk 的旧播种协议把所有历史文本标作 input_text；S2S 的
                        # OpenAI GA schema 要求 assistant 历史使用 output_text。
                        item = dict(event.get("item") or {})
                        if item.get("role") == "assistant":
                            content = []
                            for part in item.get("content") or []:
                                part = dict(part) if isinstance(part, dict) else part
                                if isinstance(part, dict) and part.get("type") == "input_text":
                                    part["type"] = "output_text"
                                content.append(part)
                            item["content"] = content
                        event = {**event, "item": item}
                    # conversation.item.create / append / response.create / response.cancel 都是原生事件。
                    await upstream.send(json.dumps(event, ensure_ascii=False))

            async def to_client() -> None:
                async for raw in upstream:
                    try:
                        event = json.loads(raw)
                    except ValueError:
                        continue
                    event = _translate_server_event(event, public_session_id)
                    await client.send_text(json.dumps(event, ensure_ascii=False))

            upstream_task = asyncio.create_task(to_upstream())
            client_task = asyncio.create_task(to_client())
            done, pending = await asyncio.wait((upstream_task, client_task), return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            for task in done:
                exc = task.exception()
                if exc:
                    raise exc
    except WebSocketDisconnect:
        return
    except Exception as exc:  # noqa: BLE001
        try:
            await client.send_text(json.dumps({"type": "error", "message": f"speech-to-speech realtime unavailable: {exc}"[:300]}))
        except Exception:  # noqa: BLE001
            pass
    finally:
        try:
            await client.close()
        except Exception:  # noqa: BLE001
            pass
