#!/usr/bin/env bash
# RealTalk 语音服务器 · macOS 原生启动（先跑 install_native_macos.sh 完成安装）
#
# - SPEECH_DEVICE=metal：LLM 全部层进 Apple GPU；whisper 走 CPU int8；Qwen3-TTS ggml(Metal)
# - 实时通道 (/v1/realtime) 原生部署暂不带 s2s 进程：API 后端连不上会自动回退分步管线，
#   App 自动降级为点按对话，功能不受影响
# - 保持后台常驻：bash run_native_macos.sh --daemon   （nohup + caffeinate 防休眠）
set -euo pipefail

ROOT="${REALTALK_SPEECH_HOME:-$HOME/realtalk-speech}"
export MAMBA_ROOT_PREFIX="$ROOT/mamba"
export MODELS_DIR="${MODELS_DIR:-$ROOT/models}"
export SPEECH_DEVICE="${SPEECH_DEVICE:-metal}"
export SPEECH_ASR_MODEL="${SPEECH_ASR_MODEL:-small}"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export SPEECH_PORT="${SPEECH_PORT:-9100}"

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

if [ "${1:-}" = "--daemon" ]; then
  # caffeinate：服务运行期间阻止 Mac 休眠（合盖仍会休眠，建议插电+设置里关闭自动休眠）
  nohup caffeinate -is "$ROOT/bin/micromamba" run -n speech \
    uvicorn server:app --host 0.0.0.0 --port "$SPEECH_PORT" \
    > "$ROOT/speech.log" 2>&1 &
  echo "已后台启动（日志 $ROOT/speech.log）。本机地址：http://$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1):$SPEECH_PORT/v1"
else
  exec "$ROOT/bin/micromamba" run -n speech \
    uvicorn server:app --host 0.0.0.0 --port "$SPEECH_PORT"
fi
