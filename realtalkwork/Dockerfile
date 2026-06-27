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

# 本地语音转写（faster-whisper，CPU int8）。仅当 setup.sh 选择「本地转写」时安装，
# 避免云端 ASR 部署也背上这份依赖。
ARG WITH_LOCAL_ASR=false
RUN if [ "$WITH_LOCAL_ASR" = "true" ]; then pip install faster-whisper==1.0.3; fi

# 本地语音合成（Piper，CPU）。仅当 setup.sh 选择「本地 Piper TTS」时安装，云端 TTS 部署不背这份依赖。
# 音色模型首次合成时自动下载到 /app/models（与本地 ASR 共用持久卷）。
ARG WITH_LOCAL_TTS=false
RUN if [ "$WITH_LOCAL_TTS" = "true" ]; then pip install piper-tts==1.2.0; fi

COPY app ./app
COPY docs ./docs
COPY web-frontend ./web-frontend

RUN mkdir -p /app/uploads /app/models && chown -R realtalk:realtalk /app/uploads /app/models

USER realtalk
EXPOSE 8000

# WEB_CONCURRENCY 控制 worker 进程数（建议 = CPU 核数）
CMD uvicorn app.main:app --host 0.0.0.0 --port 8000 --proxy-headers --workers ${WEB_CONCURRENCY:-4}
