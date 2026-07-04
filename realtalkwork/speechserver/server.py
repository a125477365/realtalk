"""RealTalk 本地实时语音模型服务器 —— OpenAI 兼容 API。

对外只暴露 4 个接口（api 后端/管理台把对应 Base URL 指到本服务即可全量切换，无需改代码）：
  POST /v1/audio/transcriptions   语音→文字（multipart file + model/language/prompt），兼容 whisper 接口
  POST /v1/audio/speech           文字→语音 WAV（json: input/voice/response_format），兼容 tts 接口
  POST /v1/chat/completions       文字对话（OpenAI 消息格式），兼容 chat 接口
  WS   /v1/realtime               实时通道：上传语音流+文字上下文 → 返回用户转写+文本流+语音流
                                  （OpenAI Realtime 事件子集，见 realtime.py；上下文存 Redis 支持多活）
  GET  /health                    健康检查（k8s/compose 探针）

高并发：ASR/LLM/TTS 各自并发信号量排队（engine.py）；多副本无共享进程状态，实时上下文在 Redis。
"""
from __future__ import annotations

import time

from fastapi import FastAPI, File, Form, UploadFile, WebSocket
from fastapi.responses import JSONResponse, Response

import engine
import realtime

app = FastAPI(title="RealTalk Speech Server", version="1.0")


@app.get("/health")
def health() -> dict:
    return {"ok": True, "device": engine.DEVICE, "asr": engine.ASR_MODEL,
            "llm": engine.LLM_BASE_URL or engine.LLM_FILE, "tts": [engine.TTS_VOICE_EN, engine.TTS_VOICE_ZH]}


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model: str = Form(default="whisper-1"),      # 兼容字段，实际用本地 whisper
    language: str = Form(default=""),
    prompt: str = Form(default=""),
    response_format: str = Form(default="json"),
) -> JSONResponse:
    audio = await file.read()
    text = await engine.transcribe(audio, language or None, prompt or None)
    return JSONResponse({"text": text})


@app.post("/v1/audio/speech")
async def speech(payload: dict) -> Response:
    text = str(payload.get("input", "")).strip()
    if not text:
        return JSONResponse({"error": "input 为空"}, status_code=400)
    wav = await engine.synthesize(text, str(payload.get("voice") or "") or None)
    return Response(content=wav, media_type="audio/wav")


@app.post("/v1/chat/completions")
async def chat_completions(payload: dict) -> JSONResponse:
    messages = payload.get("messages") or []
    content = await engine.chat(
        messages,
        temperature=float(payload.get("temperature", 0.6)),
        max_tokens=int(payload.get("max_tokens", 1024)),
    )
    now = int(time.time())
    return JSONResponse({
        "id": f"chatcmpl-local-{now}",
        "object": "chat.completion",
        "created": now,
        "model": str(payload.get("model", "local")),
        "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": sum(len(str(m.get("content", ""))) for m in messages) // 4,
                  "completion_tokens": len(content) // 4,
                  "total_tokens": 0},
    })


@app.websocket("/v1/realtime")
async def realtime_ws(websocket: WebSocket) -> None:
    await realtime.handle_session(websocket)


if __name__ == "__main__":
    import uvicorn

    # 启动期预拉模型（whisper/gguf/piper 音色），失败打日志不阻断——首个请求仍会按需下载
    try:
        engine.ensure_whisper_model(engine.ASR_MODEL)
        if not engine.LLM_BASE_URL:
            engine.ensure_llm_model()
        import tts_piper
        for v in (engine.TTS_VOICE_EN, engine.TTS_VOICE_ZH):
            tts_piper._ensure_voice(v)
        print("[speech] 模型预拉完成", flush=True)
    except Exception as exc:  # noqa: BLE001
        print(f"[speech] 模型预拉失败(首个请求会重试)：{exc}", flush=True)
    uvicorn.run(app, host="0.0.0.0", port=int(__import__("os").getenv("SPEECH_PORT", "9100")))
