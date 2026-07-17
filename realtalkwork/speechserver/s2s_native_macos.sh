#!/usr/bin/env bash
# RealTalk 实时通道 s2s 进程 · macOS 原生（Apple Silicon / MLX）
#
# speech-to-speech 0.2.10 在 Darwin 自带 MLX(Apple GPU 原生) 的 Qwen3-TTS，所以 Mac 上
# 走它的原生 MLX 路径——不需要 Docker/Linux 那套 faster-qwen3-tts(ggml) 桥接
# （后者要 transformers<5，会和 s2s 要的 transformers==5.6.2 撞车）。
#
# 分工：
#   - STT: faster-whisper（CTranslate2 无 Metal → CPU int8，ASR 本就够快）
#   - LLM: responses-api → 回调聚合器 :9100/v1 的同一个 llama.cpp(Metal)，不重复加载 LLM
#   - TTS: qwen3 经 sitecustomize.py 桥接到 qwentts.cpp(ggml/Metal)——与 REST 的
#          /audio/speech 读同一目录同一套 GGUF 权重（models/qwen3-tts-gguf，Q4_K_M），
#          两进程各自加载进内存（与 ASR 的共用方式一致）
#
# 由 run_native_macos.sh 在后台拉起，监听 ws://127.0.0.1:8765/v1/realtime；
# 聚合器(server.py, SPEECH_REALTIME_ENGINE=s2s)把 :9100/v1/realtime 桥接到它。
set -uo pipefail

ROOT="${REALTALK_SPEECH_HOME:-$HOME/realtalk-speech}"

# 节点配置文件 $ROOT/speech.env：与 run_native_macos.sh 同一套读取逻辑（只补未设置的变量，
# 已导出的优先）。通常本脚本由 run 脚本拉起、env 已就绪；这里兜底支持单独运行本脚本。
if [ -f "$ROOT/speech.env" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in ''|\#*) continue ;; esac
    _key="${_line%%=*}"
    case "$_key" in *[!A-Za-z0-9_]*|'') continue ;; esac
    [ -n "${!_key:-}" ] || export "$_key=${_line#*=}"
  done < "$ROOT/speech.env"
  unset _line _key
fi

export MAMBA_ROOT_PREFIX="$ROOT/mamba"
export MODELS_DIR="${MODELS_DIR:-$ROOT/models}"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export HF_HOME="${HF_HOME:-$MODELS_DIR/huggingface}"
export SPEECH_S2S_PROCESS=1                       # 激活 sitecustomize 的 ggml 桥接
export SPEECH_DEVICE="${SPEECH_DEVICE:-metal}"    # 桥接按 cpu/metal 生效
# sitecustomize.py 与本脚本同目录：进 PYTHONPATH 才会被 Python 自动导入
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
  --faster_whisper_stt_gen_language "${SPEECH_S2S_ASR_LANGUAGE:-en}" \
  --llm_backend responses-api \
  --model_name "${SPEECH_S2S_LLM_MODEL:-local}" \
  --responses_api_base_url "${SPEECH_S2S_LLM_BASE_URL:-http://127.0.0.1:9100/v1}" \
  --responses_api_api_key "${SPEECH_S2S_LLM_API_KEY:-local}" \
  --responses_api_stream \
  --tts qwen3 \
  --qwen3_tts_model_name "${SPEECH_TTS_MODEL:-Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice}" \
  --qwen3_tts_speaker "${SPEECH_TTS_SPEAKER:-Aiden}" \
  --qwen3_tts_language "${SPEECH_S2S_TTS_LANGUAGE:-auto}" \
  --enable_live_transcription \
  --live_transcription_min_silence_ms "${SPEECH_S2S_MIN_SILENCE_MS:-500}" \
  --ws_host 127.0.0.1 \
  --ws_port "${SPEECH_S2S_PORT:-8765}"
