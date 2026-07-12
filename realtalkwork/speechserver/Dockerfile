# RealTalk 本地实时语音模型服务器（ASR faster-whisper + TTS Piper + LLM llama.cpp）
# CPU 开箱即用；GPU：构建时 --build-arg DEVICE=cuda（llama-cpp 走 cu124 预编译轮子，宿主需 nvidia 运行时）
FROM python:3.12-slim

ARG DEVICE=cpu
ARG LLAMA_CPU_PORTABLE=true
ENV PYTHONUNBUFFERED=1 SPEECH_DEVICE=${DEVICE}

RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Piper 官方独立二进制（TTS，中英双音色混读）——按目标架构选包（x86_64 / arm64 服务器都能跑）
ARG TARGETARCH
RUN case "${TARGETARCH:-amd64}" in \
      arm64) PIPER_ARCH=aarch64 ;; \
      *)     PIPER_ARCH=x86_64 ;; \
    esac \
    && curl -fsSL -o /tmp/piper.tgz \
      "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_${PIPER_ARCH}.tar.gz" \
    && mkdir -p /opt && tar -xzf /tmp/piper.tgz -C /opt && rm /tmp/piper.tgz

WORKDIR /srv
COPY requirements.txt .
# CUDA 使用预编译轮子。CPU 默认从源码构建便携版本：关闭 AVX2/FMA，兼容 Xeon E5 等
# 只有 AVX、没有 AVX2/FMA 的旧服务器；否则预编译 CPU wheel 会在首次 LLM 推理时 exit 132。
RUN if [ "$DEVICE" = "cuda" ]; then \
      pip install --no-cache-dir llama-cpp-python \
        --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cu124 ; \
    elif [ "$LLAMA_CPU_PORTABLE" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends build-essential cmake \
      && if [ "${TARGETARCH:-amd64}" = "arm64" ]; then \
           export CMAKE_ARGS="-DGGML_NATIVE=OFF"; \
         else \
           export CMAKE_ARGS="-DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX_VNNI=OFF -DGGML_AVX2=OFF -DGGML_BMI2=OFF -DGGML_FMA=OFF -DGGML_AVX512=OFF -DGGML_AVX512_VBMI=OFF -DGGML_AVX512_VNNI=OFF"; \
         fi \
      && export FORCE_CMAKE=1 \
      && pip install --no-cache-dir --no-binary=llama-cpp-python llama-cpp-python \
      && apt-get purge -y --auto-remove build-essential cmake \
      && rm -rf /var/lib/apt/lists/* ; \
    else \
      pip install --no-cache-dir llama-cpp-python \
        --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cpu ; \
    fi \
    && pip install --no-cache-dir -r requirements.txt

COPY server.py engine.py realtime.py realtime_s2s.py tts_piper.py ./

ENV MODELS_DIR=/models TTS_LOCAL_MODEL_DIR=/models PIPER_BIN=/opt/piper/piper SPEECH_PORT=9100
VOLUME /models
EXPOSE 9100

HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=5 \
  CMD curl -fs http://127.0.0.1:9100/health || exit 1

CMD ["python", "server.py"]
