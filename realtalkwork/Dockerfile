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

COPY app ./app
COPY docs ./docs
COPY web-frontend ./web-frontend

RUN mkdir -p /app/uploads && chown realtalk:realtalk /app/uploads

USER realtalk
EXPOSE 8000

# WEB_CONCURRENCY 控制 worker 进程数（建议 = CPU 核数）
CMD uvicorn app.main:app --host 0.0.0.0 --port 8000 --proxy-headers --workers ${WEB_CONCURRENCY:-4}
