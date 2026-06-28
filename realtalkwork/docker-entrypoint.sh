#!/bin/sh
# 启动入口：修正挂载卷属主 → 启动 API 前预拉本地模型 → 降权运行。
# 为什么 chown：容器以非 root 的 realtalk 运行，但 bind mount 进来的 ./data/uploads、./data/* 等
#   目录按宿主属主（常是 root）挂载，realtalk 无写权限 → 例如 [Errno 13] Permission denied: 'uploads/voice'。
#   以 root 启动时先把数据目录 chown 给 realtalk，再用 gosu 降权运行真正的进程（兼顾安全与可写）。
# 为什么预拉模型：本地 whisper/Piper 模型默认「首次使用才下载」会让第一句卡顿/失败；
#   仅在启动 API（命令含 uvicorn）时跑一次预拉，在 fork 多 worker 之前完成、避免重复下载；
#   db-init 等其它命令不预拉。预拉失败只告警不阻断（见 app/prefetch_models.py）。
# 若已是非 root（如 k8s securityContext 指定了 runAsUser），跳过 chown 直接运行。
set -e

if [ "$(id -u)" = "0" ]; then
  for d in /app/uploads /app/models; do
    mkdir -p "$d" 2>/dev/null || true
    chown -R realtalk:realtalk "$d" 2>/dev/null || true
  done
  case "$*" in
    *uvicorn*) gosu realtalk python -m app.prefetch_models || true ;;
  esac
  exec gosu realtalk "$@"
fi

case "$*" in
  *uvicorn*) python -m app.prefetch_models || true ;;
esac
exec "$@"
