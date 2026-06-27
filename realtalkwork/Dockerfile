FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# ffmpeg：高级会员大音频文件分段转写需要
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
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

ARG WITH_LOCAL_TTS=true
RUN if [ "$WITH_LOCAL_TTS" = "true" ]; then pip install piper-tts==1.2.0; fi

COPY app ./app
COPY docs ./docs
COPY web-frontend ./web-frontend

RUN mkdir -p /app/uploads /app/models && chown -R realtalk:realtalk /app/uploads /app/models

USER realtalk
EXPOSE 8000

# WEB_CONCURRENCY 控制 worker 进程数（建议 = CPU 核数）
CMD uvicorn app.main:app --host 0.0.0.0 --port 8000 --proxy-headers --workers ${WEB_CONCURRENCY:-4}
