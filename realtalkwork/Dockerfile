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

# api 后端不再内置任何语音引擎（ASR/TTS 全部走 OpenAI 兼容 API：本地语音服务器 speechserver/ 或云端）。

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
# API_BIND_PORT 默认 8000（bridge 模式：容器内固定 8000，对外靠端口映射）；host 模式下由
# docker-compose.host.yml 置为对外端口 ${API_PORT}，让 uvicorn 直接绑定宿主端口。
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${API_BIND_PORT:-8000} --proxy-headers --workers ${WEB_CONCURRENCY:-4}"]
