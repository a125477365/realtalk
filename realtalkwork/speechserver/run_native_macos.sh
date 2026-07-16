#!/usr/bin/env bash
# RealTalk 语音服务器 · macOS 原生启动（先跑 install_native_macos.sh 完成安装）
#
# - SPEECH_DEVICE=metal：LLM 全部层进 Apple GPU；whisper 走 CPU int8；Qwen3-TTS ggml(Metal)
# - 实时通道 (/v1/realtime)：装了 speech-to-speech 时自动拉起 s2s 进程(:8765)，聚合器桥接过去
#   → 私教沉浸式全双工可用；未装则聚合器桥接失败、后端自动回退分步管线、App 降级点按（不报错）
# - 保持后台常驻：bash run_native_macos.sh --daemon   （nohup + caffeinate 防休眠）
set -uo pipefail

ROOT="${REALTALK_SPEECH_HOME:-$HOME/realtalk-speech}"
export MAMBA_ROOT_PREFIX="$ROOT/mamba"
export MODELS_DIR="${MODELS_DIR:-$ROOT/models}"
export SPEECH_DEVICE="${SPEECH_DEVICE:-metal}"
export SPEECH_ASR_MODEL="${SPEECH_ASR_MODEL:-small}"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export SPEECH_PORT="${SPEECH_PORT:-9100}"
export SPEECH_REALTIME_ENGINE="${SPEECH_REALTIME_ENGINE:-s2s}"

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
MB="$ROOT/bin/micromamba"

# 实时通道 s2s 子进程：装了 speech-to-speech 才拉起（监听 127.0.0.1:8765）。
# 已在跑就不重复启动；聚合器通过 SPEECH_S2S_REALTIME_URL 桥接过去。
maybe_start_s2s() {
  "$MB" run -n speech python -c "import speech_to_speech" >/dev/null 2>&1 || {
    echo "ℹ️  未安装 speech-to-speech，跳过 s2s（实时通道将回退分步管线）。装它：bash $ROOT/install_s2s.sh"
    return 0
  }
  if lsof -nP -iTCP:"${SPEECH_S2S_PORT:-8765}" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ℹ️  s2s 已在 :${SPEECH_S2S_PORT:-8765} 运行，复用。"
    return 0
  fi
  echo "▶️  拉起 s2s 实时进程 → ws://127.0.0.1:${SPEECH_S2S_PORT:-8765}/v1/realtime"
  nohup caffeinate -is bash "$DIR/s2s_native_macos.sh" > "$ROOT/s2s.log" 2>&1 &
}

maybe_start_s2s

if [ "${1:-}" = "--daemon" ]; then
  # caffeinate：服务运行期间阻止 Mac 休眠（合盖仍会休眠，建议插电+设置里关闭自动休眠）
  nohup caffeinate -is "$MB" run -n speech \
    uvicorn server:app --host 0.0.0.0 --port "$SPEECH_PORT" \
    > "$ROOT/speech.log" 2>&1 &
  echo "已后台启动（日志 $ROOT/speech.log）。本机地址：http://$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1):$SPEECH_PORT/v1"
else
  # 前台运行（LaunchAgent 走这里）：同样用 caffeinate 防休眠
  exec caffeinate -is "$MB" run -n speech \
    uvicorn server:app --host 0.0.0.0 --port "$SPEECH_PORT"
fi
