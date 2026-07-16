#!/usr/bin/env bash
# RealTalk 语音服务器 · macOS 原生安装（Apple Silicon，Metal GPU 全速构建）
#
# 与 Docker 部署互不影响：Docker 版为兼容无 AVX 的旧 Xeon 关闭了全部 SIMD（很慢）；
# 本脚本在 Mac 上用原生优化构建（NEON 全开 + llama.cpp/ggml Metal GPU），速度提升一个量级。
# 不需要管理员权限：micromamba 独立环境装在 $REALTALK_SPEECH_HOME（默认 ~/realtalk-speech）。
#
# 用法：bash install_native_macos.sh   （装完用同目录 run_native_macos.sh 启动）
set -euo pipefail

ROOT="${REALTALK_SPEECH_HOME:-$HOME/realtalk-speech}"
PIP_MIRROR="${PIP_MIRROR:-https://pypi.tuna.tsinghua.edu.cn/simple}"
HF="${HF_ENDPOINT:-https://hf-mirror.com}"
export MAMBA_ROOT_PREFIX="$ROOT/mamba"

mkdir -p "$ROOT" "$ROOT/src" "$ROOT/models/faster-whisper-small" "$ROOT/models/qwen3-tts-gguf"
cd "$ROOT"

# 1) micromamba（用户目录级包管理器）+ Python 3.12 + cmake/ninja
if [ ! -x bin/micromamba ]; then
  curl -Ls --retry 8 https://micro.mamba.pm/api/micromamba/osx-arm64/latest -o mm.tar.bz2
  tar -xjf mm.tar.bz2 bin/micromamba && rm -f mm.tar.bz2
fi
./bin/micromamba env list | grep -q " speech " || \
  ./bin/micromamba create -y -n speech -c conda-forge python=3.12 cmake ninja

# 2) Python 依赖（llama-cpp-python 源码构建：macOS arm64 默认启用 Metal）
./bin/micromamba run -n speech pip install --no-cache-dir --retries 10 -i "$PIP_MIRROR" \
  llama-cpp-python fastapi uvicorn httpx faster-whisper

# 3) qwentts.cpp 原生构建（Qwen3-TTS 运行时；ggml 在 macOS 默认启用 Metal）
if [ ! -d src/qwentts-cpp-python ]; then
  git clone --depth 1 https://github.com/andimarafioti/qwentts-cpp-python.git src/qwentts-cpp-python
fi
if [ ! -d src/qwentts.cpp ]; then
  git clone --recursive https://github.com/ServeurpersoCom/qwentts.cpp.git src/qwentts.cpp
  git -C src/qwentts.cpp checkout 9dbe7ea26a01b30fccb117ae5e86807c1dc23d42
  git -C src/qwentts.cpp submodule update --init --recursive
fi
( cd src/qwentts-cpp-python && \
  "$ROOT/bin/micromamba" run -n speech python scripts/build_native.py \
      --source "$ROOT/src/qwentts.cpp" --backend cpu --clean --jobs "$(sysctl -n hw.ncpu)" && \
  "$ROOT/bin/micromamba" run -n speech pip install --no-cache-dir --force-reinstall --no-deps . )

# 4) 模型文件（约 2.4GB；已存在则跳过。走 HF 镜像 resolve 直链）
cd "$ROOT/models"
for f in config.json model.bin tokenizer.json vocabulary.txt; do
  [ -s "faster-whisper-small/$f" ] || curl -Ls --retry 8 --retry-all-errors -C - \
    -o "faster-whisper-small/$f" "$HF/Systran/faster-whisper-small/resolve/main/$f"
done
[ -s qwen2.5-1.5b-instruct-q4_k_m.gguf ] || curl -Ls --retry 8 --retry-all-errors -C - \
  -o qwen2.5-1.5b-instruct-q4_k_m.gguf "$HF/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
[ -s qwen3-tts-gguf/qwen-talker-0.6b-customvoice-Q4_K_M.gguf ] || curl -Ls --retry 8 --retry-all-errors -C - \
  -o qwen3-tts-gguf/qwen-talker-0.6b-customvoice-Q4_K_M.gguf "$HF/Serveurperso/Qwen3-TTS-GGUF/resolve/main/qwen-talker-0.6b-customvoice-Q4_K_M.gguf"
[ -s qwen3-tts-gguf/qwen-tokenizer-12hz-Q4_K_M.gguf ] || curl -Ls --retry 8 --retry-all-errors -C - \
  -o qwen3-tts-gguf/qwen-tokenizer-12hz-Q4_K_M.gguf "$HF/Serveurperso/Qwen3-TTS-GGUF/resolve/main/qwen-tokenizer-12hz-Q4_K_M.gguf"

echo "✅ 安装完成。启动：bash $(dirname "$0")/run_native_macos.sh"
