#!/bin/sh
# 启动入口：修正挂载卷属主 → 降权运行 API。
# 为什么 chown：容器以非 root 的 realtalk 运行，但 bind mount 进来的 ./data/uploads、./data/* 等
#   目录按宿主属主（常是 root）挂载，realtalk 无写权限 → 例如 [Errno 13] Permission denied: 'uploads/voice'。
#   以 root 启动时先把数据目录 chown 给 realtalk，再用 gosu 降权运行真正的进程（兼顾安全与可写）。
# API 后端不承载本地模型；语音模型下载与预热由独立 speech 容器负责。
# 若已是非 root（如 k8s securityContext 指定了 runAsUser），跳过 chown 直接运行。
set -e

if [ "$(id -u)" = "0" ]; then
  for d in /app/uploads /app/models; do
    mkdir -p "$d" 2>/dev/null || true
    chown -R realtalk:realtalk "$d" 2>/dev/null || true
  done
  exec gosu realtalk "$@"
fi

exec "$@"
