from __future__ import annotations

"""高级会员实时语音大模型对练：后端做 WebSocket 透明转发 + 场景/护栏指令注入 + 结束评分。

设计要点（对应需求第 4 项）：
- 后端不处理音频，只在客户端与「OpenAI 兼容 Realtime API」之间转发事件（音频以 base64 走 JSON 事件）；
- 但会注入并强制 session 指令（场景台词 + 护栏），并过滤客户端试图覆盖指令/工具的 session.update，
  保证「只做口语练习、按场景台词、不越界、不涉政/敏感」；
- 累积转写，结束后用文本模型给出评分与分析。
"""

import asyncio
import json
from dataclasses import dataclass

from .settings import settings

_DB_KEYS = ["realtime_base_url", "realtime_api_key", "realtime_model", "realtime_voice"]

_GUARDRAILS = (
    "You are an English speaking-practice voice partner. Strict rules: "
    "1) You ONLY do English oral practice, working through the scene lines below turn by turn. "
    "2) Refuse anything unrelated to these scene lines; if the user goes off-topic, gently bring them "
    "back to the current line. "
    "3) NEVER discuss politics, national leaders, government policy or institutions, religion, ethnicity, "
    "or any sensitive data; if asked, briefly decline and return to the practice. "
    "4) Speak natural, idiomatic English; give short pronunciation/grammar corrections, then move on. "
    "（你只能做英语口语练习，必须按下面的场景台词逐句交流，不得回答与台词无关的内容，"
    "绝不谈论政治、国家领导人、国家政策制度或任何敏感话题。）"
)


_PRICE_KEYS = [
    "realtime_input_text_price_per_1m_cents",
    "realtime_input_audio_price_per_1m_cents",
    "realtime_output_text_price_per_1m_cents",
    "realtime_output_audio_price_per_1m_cents",
]


@dataclass(frozen=True)
class RealtimeConfig:
    base_url: str
    api_key: str | None
    model: str
    voice: str

    @property
    def enabled(self) -> bool:
        return bool(self.api_key and self.base_url)


@dataclass(frozen=True)
class RealtimePricing:
    """实时语音计费单价（分/百万 token），文本/音频分开。"""

    input_text: float
    input_audio: float
    output_text: float
    output_audio: float


def resolve_realtime_config() -> RealtimeConfig:
    from .storage import db

    try:
        ov = db.get_app_settings_map(_DB_KEYS)
    except Exception:  # noqa: BLE001
        ov = {}
    return RealtimeConfig(
        base_url=ov.get("realtime_base_url") or settings.realtime_base_url,
        api_key=ov.get("realtime_api_key") or settings.realtime_api_key,
        model=ov.get("realtime_model") or settings.realtime_model,
        voice=ov.get("realtime_voice") or settings.realtime_voice,
    )


def _price(ov: dict, key: str, fallback: float) -> float:
    raw = ov.get(key)
    if raw in (None, ""):
        return fallback
    try:
        return float(raw)
    except (TypeError, ValueError):
        return fallback


def resolve_realtime_pricing() -> RealtimePricing:
    from .storage import db

    try:
        ov = db.get_app_settings_map(_PRICE_KEYS)
    except Exception:  # noqa: BLE001
        ov = {}
    return RealtimePricing(
        input_text=_price(ov, _PRICE_KEYS[0], settings.realtime_input_text_price_per_1m_cents),
        input_audio=_price(ov, _PRICE_KEYS[1], settings.realtime_input_audio_price_per_1m_cents),
        output_text=_price(ov, _PRICE_KEYS[2], settings.realtime_output_text_price_per_1m_cents),
        output_audio=_price(ov, _PRICE_KEYS[3], settings.realtime_output_audio_price_per_1m_cents),
    )


def realtime_usage_cost_cents(usage: dict, pricing: RealtimePricing) -> float:
    """按文本/音频分开的单价，将 Realtime usage 折算为费用（分）。"""
    return round(
        usage.get("input_text", 0) / 1_000_000 * pricing.input_text
        + usage.get("input_audio", 0) / 1_000_000 * pricing.input_audio
        + usage.get("output_text", 0) / 1_000_000 * pricing.output_text
        + usage.get("output_audio", 0) / 1_000_000 * pricing.output_audio,
        4,
    )


def build_session_instructions(scenario, selected_role: str) -> str:
    lines: list[str] = []
    for line in scenario.lines[:60]:
        who = "USER" if line.target_role == selected_role else "AI"
        lines.append(f"- [{who}] zh: {line.source_text} | en: {line.english}")
    body = "\n".join(lines)
    return (
        f"{_GUARDRAILS}\n\n"
        f"Scene: {scenario.title}. {scenario.summary}\n"
        f"The user plays role '{selected_role}'. Walk through the lines in order: you speak the AI lines, "
        f"the user speaks the USER lines (correct them briefly, then continue). Lines:\n{body}"
    )


async def proxy_session(client_ws, instructions: str, config: RealtimeConfig) -> tuple[list[dict], dict]:
    """在客户端与上游 Realtime API 之间转发；返回 (转写, token 用量) 用于评分与计费。"""
    import websockets

    transcript: list[dict] = []
    # 累积 token 用量（来自上游 response.done 事件的 usage，文本/音频分开）
    usage = {"input_text": 0, "input_audio": 0, "output_text": 0, "output_audio": 0}
    url = config.base_url
    if "model=" not in url:
        url = f"{url}{'&' if '?' in url else '?'}model={config.model}"
    headers = [("Authorization", f"Bearer {config.api_key}"), ("OpenAI-Beta", "realtime=v1")]

    async with websockets.connect(url, additional_headers=headers, max_size=None) as upstream:
        # 注入并强制 session 指令（场景台词 + 护栏）
        await upstream.send(json.dumps({
            "type": "session.update",
            "session": {
                "instructions": instructions,
                "voice": config.voice,
                "modalities": ["audio", "text"],
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": {"model": "whisper-1"},
                "turn_detection": {"type": "server_vad"},
            },
        }))

        # 任一端结束（客户端发 realtalk.end、断线、或上游关闭）即停止转发；
        # 客户端主动结束时不关闭客户端连接，便于随后回传评分。
        stop = asyncio.Event()

        async def client_to_upstream() -> None:
            try:
                async for message in client_ws.iter_text():
                    try:
                        data = json.loads(message)
                    except ValueError:
                        continue
                    # 客户端主动结束：停止本次对练（不转发给上游）
                    if data.get("type") == "realtalk.end":
                        break
                    # 禁止客户端覆盖系统指令 / 注入工具，护栏只能由服务端控制
                    if data.get("type") == "session.update":
                        sess = data.get("session") or {}
                        sess.pop("instructions", None)
                        sess.pop("tools", None)
                        data["session"] = sess
                    await upstream.send(json.dumps(data))
            except Exception:  # noqa: BLE001 — 任一端断开即结束
                pass
            finally:
                stop.set()

        async def upstream_to_client() -> None:
            try:
                async for raw in upstream:
                    if isinstance(raw, (bytes, bytearray)):
                        continue  # 音频走 base64 JSON 事件，二进制忽略
                    try:
                        ev = json.loads(raw)
                    except ValueError:
                        await client_ws.send_text(raw)
                        continue
                    kind = ev.get("type", "")
                    if kind == "conversation.item.input_audio_transcription.completed":
                        transcript.append({"role": "user", "text": ev.get("transcript", "")})
                    elif kind == "response.audio_transcript.done":
                        transcript.append({"role": "ai", "text": ev.get("transcript", "")})
                    elif kind == "response.done":
                        _accumulate_usage(usage, ev)
                    await client_ws.send_text(raw)
            except Exception:  # noqa: BLE001
                pass
            finally:
                stop.set()

        tasks = [asyncio.create_task(client_to_upstream()), asyncio.create_task(upstream_to_client())]
        await stop.wait()
        for task in tasks:
            if not task.done():
                task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
    return transcript, usage


def _accumulate_usage(usage: dict, event: dict) -> None:
    """从 Realtime API 的 response.done 事件累积 token 用量（文本/音频分开）。"""
    data = (event.get("response") or {}).get("usage") or {}
    in_details = data.get("input_token_details") or {}
    out_details = data.get("output_token_details") or {}
    # 优先用细分；缺失时回退到总输入/输出（全部当文本，至少不丢账）
    in_text = in_details.get("text_tokens")
    in_audio = in_details.get("audio_tokens")
    out_text = out_details.get("text_tokens")
    out_audio = out_details.get("audio_tokens")
    if in_text is None and in_audio is None:
        in_text, in_audio = data.get("input_tokens", 0), 0
    if out_text is None and out_audio is None:
        out_text, out_audio = data.get("output_tokens", 0), 0
    usage["input_text"] += int(in_text or 0)
    usage["input_audio"] += int(in_audio or 0)
    usage["output_text"] += int(out_text or 0)
    usage["output_audio"] += int(out_audio or 0)


async def test_realtime_connection() -> dict:
    """管理台「测试连接」：实际向实时语音 API 发起一次 WebSocket 握手并收一帧事件，
    验证 Base URL / API Key / 模型可用（握手即校验鉴权与模型，收到 session.created 表示通道可用）。"""
    import time

    config = resolve_realtime_config()
    if not config.enabled:
        return {"ok": False, "message": "未配置 API Key 或 Base URL"}
    try:
        import websockets
    except Exception:  # noqa: BLE001
        return {"ok": False, "message": "服务器未安装 websockets 依赖"}

    url = config.base_url
    if "model=" not in url:
        url = f"{url}{'&' if '?' in url else '?'}model={config.model}"
    headers = [("Authorization", f"Bearer {config.api_key}"), ("OpenAI-Beta", "realtime=v1")]

    started = time.monotonic()
    try:
        async with websockets.connect(
            url, additional_headers=headers, max_size=None, open_timeout=10
        ) as ws:
            raw = await asyncio.wait_for(ws.recv(), timeout=10)
        latency_ms = int((time.monotonic() - started) * 1000)
        event = ""
        try:
            event = str((json.loads(raw) or {}).get("type", ""))
        except Exception:  # noqa: BLE001
            pass
        return {
            "ok": True,
            "message": f"连接成功（{latency_ms}ms）",
            "model": config.model,
            "latency_ms": latency_ms,
            "event": event,
        }
    except asyncio.TimeoutError:
        return {"ok": False, "message": "连接超时（10s）：请检查 Base URL 与网络"}
    except Exception as exc:  # noqa: BLE001
        code = getattr(getattr(exc, "response", None), "status_code", None) or getattr(exc, "status_code", None)
        if code:
            hint = {
                401: "鉴权失败，请检查 API Key",
                403: "无权限或区域不可用",
                404: "模型或路径不存在，请检查 Base URL 与模型",
                429: "请求过于频繁/额度受限",
            }.get(int(code), "")
            return {"ok": False, "message": f"握手失败 HTTP {code}" + (f"：{hint}" if hint else "")}
        return {"ok": False, "message": f"连接失败：{str(exc)[:160]}"}


async def score_voice_session(transcript: list[dict], scenario, user_id: str | None) -> dict:
    """结束后让文本模型给出评分(0-100)与中文分析。模型不可用时回退一个简单结果。"""
    if not transcript:
        return {"score": 0, "analysis": "本次没有有效对话内容。"}

    from .ark_client import _chat_completion, _extract_json, resolve_ai_config

    convo = "\n".join(f"{'用户' if t['role'] == 'user' else 'AI'}: {t['text']}" for t in transcript if t.get("text"))
    system = (
        "你是英语口语评测官，只输出 JSON，不要 Markdown。根据用户在该场景下的英语口语表现给出评分与建议。"
    )
    user = (
        f"场景：{scenario.title}。\n对话记录：\n{convo}\n\n"
        '输出 JSON：{"score": 0-100 的整数, "analysis": "中文总评：发音/语法/流利度亮点与最该改的 2-3 点"}'
    )
    if not resolve_ai_config().enabled:
        return {"score": 75, "analysis": "已完成本轮语音对练。配置文本模型后可获得更详细的评分与建议。"}
    try:
        content = await _chat_completion(
            [{"role": "system", "content": system}, {"role": "user", "content": user}],
            temperature=0.2,
            kind="voice_score",
            user_id=user_id,
        )
        data = _extract_json(content)
        return {"score": int(data.get("score", 0)), "analysis": str(data.get("analysis", "")).strip()}
    except Exception:  # noqa: BLE001
        return {"score": 70, "analysis": "已完成本轮语音对练。"}
