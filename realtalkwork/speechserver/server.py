"""RealTalk 本地实时语音模型服务器 —— OpenAI 兼容 API。

对外只暴露 4 个接口（api 后端/管理台把对应 Base URL 指到本服务即可全量切换，无需改代码）：
  POST /v1/audio/transcriptions   语音→文字（multipart file + model/language/prompt），兼容 whisper 接口
  POST /v1/audio/speech           文字→语音 WAV（json: input/voice/response_format），兼容 tts 接口
  POST /v1/chat/completions       文字对话（OpenAI 消息格式），兼容 chat 接口
  WS   /v1/realtime               默认代理 speech-to-speech 原生 Realtime：上传语音流+文字上下文
                                  → 返回用户转写+文本流+语音流（legacy 模式才用 realtime.py + Redis）
  GET  /health                    健康检查（k8s/compose 探针）

高并发：REST ASR/LLM/TTS 各自并发信号量排队（engine.py）；S2S 原生服务独立按管线数限流。
"""
from __future__ import annotations

import os
import time

from fastapi import FastAPI, File, Form, Request, UploadFile, WebSocket
from fastapi.responses import JSONResponse, Response, StreamingResponse

import engine
import realtime
import realtime_s2s

app = FastAPI(title="RealTalk Speech Server", version="1.0")


@app.exception_handler(Exception)
async def _err(request: Request, exc: Exception) -> JSONResponse:
    # OpenAI 风格错误体：调用方(api 后端)能解析出可读原因，而不是裸 500 文本
    return JSONResponse({"error": {"message": str(exc)[:300], "type": type(exc).__name__}}, status_code=500)


@app.get("/health")
def health():
    realtime_ready = True
    if os.getenv("SPEECH_REALTIME_ENGINE", "s2s").lower() == "s2s":
        try:
            import urllib.request

            with urllib.request.urlopen("http://127.0.0.1:8765/v1/pool", timeout=1) as response:  # noqa: S310
                realtime_ready = response.status == 200
        except Exception:  # noqa: BLE001
            realtime_ready = False
    body = {"ok": realtime_ready, "device": engine.DEVICE, "asr": engine.ASR_MODEL,
            "llm": engine.LLM_BASE_URL or engine.LLM_FILE,
            "tts": {"model": engine.TTS_MODEL, "speaker": engine.TTS_SPEAKER},
            "realtime_engine": os.getenv("SPEECH_REALTIME_ENGINE", "s2s"),
            "realtime_backend": os.getenv("SPEECH_S2S_REALTIME_URL", "")}
    return JSONResponse(body, status_code=200 if realtime_ready else 503)


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model: str = Form(default="whisper-1"),      # 兼容字段，实际用本地 whisper
    language: str = Form(default=""),
    prompt: str = Form(default=""),
    response_format: str = Form(default="json"),
) -> JSONResponse:
    audio = await file.read()
    text, words, duration = await engine.transcribe_verbose(audio, language or None, prompt or None)
    if response_format == "verbose_json":
        # OpenAI verbose_json 子集 + 词级 probability（发音标色/语速分析用）
        return JSONResponse({"text": text, "duration": duration, "words": words})
    return JSONResponse({"text": text})


@app.post("/v1/audio/speech")
async def speech(payload: dict) -> Response:
    text = str(payload.get("input", "")).strip()
    if not text:
        return JSONResponse({"error": "input 为空"}, status_code=400)
    wav = await engine.synthesize(text, str(payload.get("voice") or "") or None)
    return Response(content=wav, media_type="audio/wav")


@app.post("/v1/chat/completions")
async def chat_completions(payload: dict):
    messages = payload.get("messages") or []
    if payload.get("stream"):
        # speech-to-speech 的原生 Realtime 管线把这里当作上游 LLM。直接转发
        # llama.cpp 的 token 回调，才能让 Qwen TTS 在整句完成前开始合成。
        import asyncio
        import json

        loop = asyncio.get_running_loop()
        queue: asyncio.Queue[str] = asyncio.Queue()
        completed = asyncio.Event()
        failure: list[Exception] = []

        def on_delta(delta: str) -> None:
            loop.call_soon_threadsafe(queue.put_nowait, delta)

        async def run() -> None:
            try:
                await engine.chat(
                    messages,
                    temperature=float(payload.get("temperature", 0.6)),
                    max_tokens=int(payload.get("max_tokens", 1024)),
                    stream_cb=on_delta,
                )
            except Exception as exc:  # noqa: BLE001
                failure.append(exc)
            finally:
                completed.set()

        task = asyncio.create_task(run())

        async def events():
            created = int(time.time())
            try:
                while not completed.is_set() or not queue.empty():
                    try:
                        delta = await asyncio.wait_for(queue.get(), timeout=0.25)
                    except asyncio.TimeoutError:
                        continue
                    item = {
                        "id": f"chatcmpl-local-{created}", "object": "chat.completion.chunk",
                        "created": created, "model": str(payload.get("model", "local")),
                        "choices": [{"index": 0, "delta": {"content": delta}, "finish_reason": None}],
                    }
                    yield "data: " + json.dumps(item, ensure_ascii=False) + "\n\n"
                if failure:
                    raise failure[0]
                yield "data: " + json.dumps({
                    "id": f"chatcmpl-local-{created}", "object": "chat.completion.chunk",
                    "created": created, "model": str(payload.get("model", "local")),
                    "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                }, ensure_ascii=False) + "\n\n"
                yield "data: [DONE]\n\n"
            finally:
                if not task.done():
                    task.cancel()

        return StreamingResponse(events(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

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
    if os.getenv("SPEECH_REALTIME_ENGINE", "s2s").lower() == "s2s":
        await realtime_s2s.handle_session(websocket)
    else:
        # 应急回退：原 RealTalk 实现仍完整保留。用于资源不足或升级 speech-to-speech 时临时兜底。
        await realtime.handle_session(websocket)


if __name__ == "__main__":
    import uvicorn

    # 启动期预拉 ASR/LLM 文件。Qwen3-TTS 由 S2S 启动时加载，REST 首次调用复用相同配置。
    try:
        engine.ensure_whisper_model(engine.ASR_MODEL)
        if not engine.LLM_BASE_URL:
            engine.ensure_llm_model()
        print("[speech] 模型预拉完成", flush=True)
    except Exception as exc:  # noqa: BLE001
        print(f"[speech] 模型预拉失败(首个请求会重试)：{exc}", flush=True)
    uvicorn.run(app, host="0.0.0.0", port=int(__import__("os").getenv("SPEECH_PORT", "9100")))
