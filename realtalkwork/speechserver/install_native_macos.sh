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
  llama-cpp-python fastapi uvicorn httpx faster-whisper python-multipart

# 3) qwentts.cpp 原生构建（Qwen3-TTS 运行时；ggml 在 macOS 默认启用 Metal）
if [ ! -d src/qwentts-cpp-python ]; then
  git clone --depth 1 https://github.com/andimarafioti/qwentts-cpp-python.git src/qwentts-cpp-python
fi
if [ ! -d src/qwentts.cpp ]; then
  git clone --recursive https://github.com/ServeurpersoCom/qwentts.cpp.git src/qwentts.cpp
  git -C src/qwentts.cpp checkout 9dbe7ea26a01b30fccb117ae5e86807c1dc23d42
  git -C src/qwentts.cpp submodule update --init --recursive
fi
# 2.1) Metal 着色器 bf16 补丁：qwentts 自定义内核（snake/col2im 等）的 bf16 模板实例化
# 没按 ggml 惯例加 GGML_METAL_HAS_BF16 防护——运行时 JIT 编译在新 Metal 编译器上报
# 「duplicate explicit instantiation」→ Metal 后端初始化失败（no GGML backend available）。
python3 - "$ROOT/src/qwentts.cpp/ggml/src/ggml-metal/ggml-metal.metal" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
out, wrapped = [], 0
for line in lines:
    if ('host_name("kernel_' in line and '_bf16"' in line and 'bfloat' in line
            and (not out or 'GGML_METAL_HAS_BF16' not in out[-1])):
        out += ['#if defined(GGML_METAL_HAS_BF16)', line, '#endif']
        wrapped += 1
    else:
        out.append(line)
open(p, "w").write("\n".join(out))
print(f"bf16 内核防护补丁：包裹 {wrapped} 处（0=已打过）")
PYEOF

( cd src/qwentts-cpp-python && \
  "$ROOT/bin/micromamba" run -n speech python scripts/build_native.py \
      --source "$ROOT/src/qwentts.cpp" --backend cpu --clean --jobs "$(sysctl -n hw.ncpu)" \
      "--cmake-arg=-DGGML_METAL=ON" "--cmake-arg=-DGGML_BACKEND_DL=OFF" "--cmake-arg=-DGGML_NATIVE=ON" && \
  "$ROOT/bin/micromamba" run -n speech pip install --no-cache-dir --force-reinstall --no-deps . )

# 2.2) 全量拷贝构建产物：官方拷贝清单只有 4 个无版本名——libqwen 链接的是带版本名
# （libggml-metal.0.dylib 等），缺了运行时解析不到 Metal 后端。
SITE="$(./bin/micromamba run -n speech python -c 'import qwentts_cpp, os; print(os.path.join(os.path.dirname(qwentts_cpp.__file__), "lib"))')"
cp -f src/qwentts-cpp-python/build/qwentts-cpp/*.dylib "$SITE/"
echo "已拷贝全部原生库（含 Metal 后端）→ $SITE"

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

# 5) 开机自启（LaunchAgent）。注意：launchd 读不了 ~/Documents（TCC 权限），
# 所以把服务代码复制到 $ROOT/app 运行；更新代码后重跑本脚本即可同步。
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/app"
cp -f "$SRC_DIR"/*.py "$SRC_DIR/run_native_macos.sh" "$ROOT/app/"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.realtalk.speech.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.realtalk.speech</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$ROOT/app/run_native_macos.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$ROOT/speech.log</string>
    <key>StandardErrorPath</key><string>$ROOT/speech.log</string>
</dict>
</plist>
PLIST
launchctl unload "$HOME/Library/LaunchAgents/com.realtalk.speech.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.realtalk.speech.plist"

echo "✅ 安装完成并已设为开机自启。日志：$ROOT/speech.log"
echo "   本机地址：http://$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1):9100/v1"
