#!/usr/bin/env bash
# RealTalk 实时通道(s2s) · macOS 原生依赖安装（可选；私教沉浸式全双工需要它）
#
# 先跑 install_native_macos.sh 装好基础环境，再跑本脚本装 speech-to-speech 那一套。
# 基础语音（REST 的 ASR/TTS/LLM、点按对话、REST 朗读）不需要 s2s；只有「私教沉浸式
# 全双工实时通道」需要。装完 run_native_macos.sh 会自动拉起 s2s 进程。
#
# 用法：bash install_s2s_macos.sh
set -uo pipefail

ROOT="${REALTALK_SPEECH_HOME:-$HOME/realtalk-speech}"
export MAMBA_ROOT_PREFIX="$ROOT/mamba"
MB="$ROOT/bin/micromamba"
PIP_MIRROR="${PIP_MIRROR:-https://pypi.tuna.tsinghua.edu.cn/simple}"
log(){ echo "[$(date '+%H:%M:%S')] $*"; }

[ -x "$MB" ] || { echo "先运行 install_native_macos.sh"; exit 1; }

# torch/torchaudio(Apple MPS 轮子) + speech-to-speech(实时编排) + faster-qwen3-tts(ggml TTS 桥接)
# 大依赖(torch/mlx-audio/lingua 等约数百 MB)：弱网多次重试
log "安装 speech-to-speech 依赖（torch + speech-to-speech==0.2.10 + faster-qwen3-tts）…"
for attempt in 1 2 3 4 5; do
  "$MB" run -n speech pip install --retries 10 --timeout 120 -i "$PIP_MIRROR" \
    torch torchaudio "speech-to-speech[faster-whisper]==0.2.10" faster-qwen3-tts websockets \
    && { log "pip 安装成功"; break; }
  log "第 $attempt 次失败，重试…"; sleep 5
done

log "下载 nltk 数据（s2s 句子切分用）…"
"$MB" run -n speech python - <<'PY'
import nltk
for pkg in ("punkt_tab", "averaged_perceptron_tagger_eng"):
    try: nltk.download(pkg, quiet=True); print("nltk", pkg, "OK")
    except Exception as e: print("nltk", pkg, "FAIL", str(e)[:80])
PY

log "校验可导入…"
"$MB" run -n speech python -c "import torch, speech_to_speech, faster_qwen3_tts; print('OK torch', torch.__version__, 'mps', torch.backends.mps.is_available())"

# 同步给 launchd 用的代码副本（launchd 读不了 ~/Documents）
mkdir -p "$ROOT/app"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
cp -f "$SRC_DIR"/*.py "$SRC_DIR"/s2s_native_macos.sh "$SRC_DIR/run_native_macos.sh" "$ROOT/app/" 2>/dev/null || true

echo "✅ s2s 依赖就绪。重启服务即自动拉起实时通道："
echo "   launchctl unload ~/Library/LaunchAgents/com.realtalk.speech.plist; launchctl load ~/Library/LaunchAgents/com.realtalk.speech.plist"
