# RealTalk 单容器语音服务器（REST + speech-to-speech realtime，共用模型配置）
# CPU 开箱即用；GPU：构建时 --build-arg DEVICE=cuda（llama-cpp 走 cu124 预编译轮子，宿主需 nvidia 运行时）
FROM python:3.12-slim

ARG DEVICE=cpu
ARG LLAMA_CPU_PORTABLE=true
ENV PYTHONUNBUFFERED=1 SPEECH_DEVICE=${DEVICE}

RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg curl ca-certificates libgomp1 libsndfile1 \
    && rm -rf /var/lib/apt/lists/*
ARG TARGETARCH

WORKDIR /srv
COPY requirements.txt .
# CUDA 使用预编译轮子。CPU 默认从源码构建最保守版本：关闭 AVX/F16C/AVX2/FMA 等 SIMD，
# 兼容无 AVX 的 NAS/iStoreOS 小主机；否则预编译 CPU wheel 会在首次 LLM 推理时 exit 132。
RUN if [ "$DEVICE" = "cuda" ]; then \
      pip install --no-cache-dir llama-cpp-python \
        --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cu124 ; \
    elif [ "$LLAMA_CPU_PORTABLE" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends build-essential cmake \
      && if [ "${TARGETARCH:-amd64}" = "arm64" ]; then \
           export CMAKE_ARGS="-DGGML_NATIVE=OFF"; \
         else \
           export CMAKE_ARGS="-DGGML_NATIVE=OFF -DGGML_AVX=OFF -DGGML_AVX_VNNI=OFF -DGGML_AVX2=OFF -DGGML_BMI2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_AVX512=OFF -DGGML_AVX512_VBMI=OFF -DGGML_AVX512_VNNI=OFF"; \
         fi \
      && export FORCE_CMAKE=1 \
      && pip install --no-cache-dir --no-binary=llama-cpp-python llama-cpp-python \
      && apt-get purge -y --auto-remove build-essential cmake \
      && rm -rf /var/lib/apt/lists/* ; \
    else \
      pip install --no-cache-dir llama-cpp-python \
        --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cpu ; \
    fi \
    && pip install --no-cache-dir -r requirements.txt \
    && if [ "$DEVICE" = "cpu" ]; then \
         pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu \
           "torch==2.7.1+cpu" "torchaudio==2.7.1+cpu" \
         && if [ "${TARGETARCH:-amd64}" = "arm64" ]; then WHEEL_ARCH=aarch64; else WHEEL_ARCH=x86_64; fi \
         && pip install --no-cache-dir \
           "https://huggingface.co/datasets/andito/qwentts-cpp-python-wheels/resolve/main/whl/cpu/qwentts_cpp_python-0.3.0%2Bcpu-py3-none-manylinux_2_34_${WHEEL_ARCH}.manylinux_2_35_${WHEEL_ARCH}.whl" ; \
       else \
         pip install --no-cache-dir torch torchaudio \
         && if [ "${TARGETARCH:-amd64}" = "arm64" ]; then WHEEL_ARCH=aarch64; else WHEEL_ARCH=x86_64; fi \
         && pip install --no-cache-dir \
           "https://huggingface.co/datasets/andito/qwentts-cpp-python-wheels/resolve/main/whl/cu124/qwentts_cpp_python-0.3.0%2Bcu124-py3-none-manylinux_2_35_${WHEEL_ARCH}.whl" ; \
       fi \
    && pip install --no-cache-dir "speech-to-speech[faster-whisper]==0.2.10" \
    && python -c "import nltk; nltk.download('punkt_tab'); nltk.download('averaged_perceptron_tagger_eng')"

COPY server.py engine.py realtime.py realtime_s2s.py sitecustomize.py ./
COPY s2s-entrypoint.sh unified-entrypoint.sh ./
RUN chmod +x /srv/s2s-entrypoint.sh /srv/unified-entrypoint.sh

ENV MODELS_DIR=/models SPEECH_PORT=9100 HF_HOME=/models/huggingface XDG_CACHE_HOME=/models/cache
VOLUME /models
EXPOSE 9100

HEALTHCHECK --interval=30s --timeout=5s --start-period=600s --retries=5 \
  CMD curl -fs http://127.0.0.1:9100/health || exit 1

ENTRYPOINT ["/srv/unified-entrypoint.sh"]
