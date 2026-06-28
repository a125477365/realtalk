FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# ffmpeg：高级会员大音频文件分段转写需要；gosu：入口脚本修正挂载卷属主后降权运行
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg gosu \
    && rm -rf /var/lib/apt/lists/*

RUN addgroup --system realtalk && adduser --system --ingroup realtalk realtalk

COPY requirements.txt ./
RUN pip install --upgrade pip && pip install -r requirements.txt
RUN pip install python-multipart

# 本地语音转写（faster-whisper，CPU int8）与本地语音合成（Piper，CPU）。
# 默认随镜像装好：ASR/TTS 与 API 同容器,无论运维后面用云端付费模型还是本地开源模型,
# 切换只是改 ASR_MODE/TTS_MODE 配置即可,不必重建镜像。
# 想要更小的「纯云端」镜像可在构建时传 --build-arg WITH_LOCAL_ASR=false / WITH_LOCAL_TTS=false。
# 模型文件首次使用时才下载到 /app/models（不烤进镜像；建议挂持久卷）。
ARG WITH_LOCAL_ASR=true
RUN if [ "$WITH_LOCAL_ASR" = "true" ]; then pip install faster-whisper==1.0.3; fi

# 用 Piper 官方独立二进制（pip 的 piper-tts 依赖 piper-phonemize，无 py3.12 wheel）。
# 二进制小(~20MB)、自带 espeak-ng 数据;音色模型与 whisper 一样在运行期下载到 /app/models。
# 下载失败【不阻断整体构建】(仅本地TTS不可用,云端TTS与其余功能照常);受限网络可重建或改用云端TTS。
ARG WITH_LOCAL_TTS=true
RUN if [ "$WITH_LOCAL_TTS" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
      && arch="$(dpkg --print-architecture)" \
      && case "$arch" in amd64) p=x86_64 ;; arm64) p=aarch64 ;; armhf) p=armv7l ;; *) p=x86_64 ;; esac \
      && ( curl -fsSL --retry 3 "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_${p}.tar.gz" -o /tmp/piper.tgz \
           && tar -xzf /tmp/piper.tgz -C /opt && rm -f /tmp/piper.tgz \
           || echo "WARN: Piper 二进制下载失败,本地TTS暂不可用(可重建/用云端TTS)" ) \
      && rm -rf /var/lib/apt/lists/* ; \
    fi

COPY app ./app
COPY docs ./docs
COPY web-frontend ./web-frontend
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

RUN mkdir -p /app/uploads /app/models && chown -R realtalk:realtalk /app/uploads /app/models

# 不在此处 USER realtalk：入口脚本以 root 启动→chown 挂载卷→gosu 降权到 realtalk 运行。
EXPOSE 8000

# WEB_CONCURRENCY 控制 worker 进程数（建议 = CPU 核数）。CMD 作为参数传给入口脚本，
# 用 sh -c 让 ${WEB_CONCURRENCY} 在降权后展开。
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port 8000 --proxy-headers --workers ${WEB_CONCURRENCY:-4}"]
