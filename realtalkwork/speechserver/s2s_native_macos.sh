#!/usr/bin/env bash
# RealTalk 实时通道 s2s 进程 · macOS 原生（Apple Silicon）
#
# 与 Docker 的 s2s-entrypoint.sh 等价，但按 Mac 现实做了三处适配：
#   1. faster-whisper(CTranslate2) 没有 Metal 后端 → STT 强制 cpu/int8（ASR 本就够快）
#   2. VAD/编排层用 cpu（speech_to_speech 的 device 是 torch 设备名，无 "metal"）
#   3. Qwen3-TTS 经 sitecustomize.py 的 ggml 桥接 → 自动吃 Apple GPU（Metal），
#      所以这里 --qwen3_tts_device 传什么都不影响真正的 GPU 使用
#
# 由 run_native_macos.sh 在后台拉起，监听 ws://127.0.0.1:8765/v1/realtime；
# 聚合器(server.py, SPEECH_REALTIME_ENGINE=s2s)把 :9100/v1/realtime 桥接到它。
set -uo pipefail

ROOT="${REALTALK_SPEECH_HOME:-$HOME/realtalk-speech}"
export MAMBA_ROOT_PREFIX="$ROOT/mamba"
export MODELS_DIR="${MODELS_DIR:-$ROOT/models}"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export SPEECH_S2S_PROCESS=1        # 让 sitecustomize.py 激活 qwentts.cpp(ggml/Metal) 桥接
export SPEECH_DEVICE="${SPEECH_DEVICE:-metal}"   # sitecustomize 据此走 ggml(metal) 而非 torch

# sitecustomize.py 与 server 代码同目录：加进 PYTHONPATH 才能在 s2s 进程里被自动导入
DIR="$(cd "$(dirname "$0")" && pwd)"
export PYTHONPATH="${DIR}${PYTHONPATH:+:$PYTHONPATH}"

exec "$ROOT/bin/micromamba" run -n speech speech-to-speech \
  --mode realtime \
  --device cpu \
  --num_pipelines "${SPEECH_S2S_PIPELINES:-1}" \
  --stt faster-whisper \
  --faster_whisper_stt_model_name "$MODELS_DIR/faster-whisper-${SPEECH_ASR_MODEL:-small}" \
  --faster_whisper_stt_device cpu \
  --faster_whisper_stt_compute_type "${SPEECH_S2S_ASR_COMPUTE_TYPE:-int8}" \
  --faster_whisper_stt_gen_language "${SPEECH_S2S_ASR_LANGUAGE:-auto}" \
  --llm_backend responses-api \
  --model_name "${SPEECH_S2S_LLM_MODEL:-local}" \
  --responses_api_base_url "${SPEECH_S2S_LLM_BASE_URL:-http://127.0.0.1:9100/v1}" \
  --responses_api_api_key "${SPEECH_S2S_LLM_API_KEY:-local}" \
  --responses_api_stream \
  --tts qwen3 \
  --qwen3_tts_model_name "${SPEECH_TTS_MODEL:-Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice}" \
  --qwen3_tts_device cpu \
  --qwen3_tts_dtype "${SPEECH_S2S_TTS_DTYPE:-float32}" \
  --qwen3_tts_speaker "${SPEECH_TTS_SPEAKER:-Aiden}" \
  --qwen3_tts_language "${SPEECH_S2S_TTS_LANGUAGE:-auto}" \
  --no_qwen3_tts_non_streaming_mode \
  --enable_live_transcription \
  --live_transcription_min_silence_ms "${SPEECH_S2S_MIN_SILENCE_MS:-500}" \
  --ws_host 127.0.0.1 \
  --ws_port "${SPEECH_S2S_PORT:-8765}"
