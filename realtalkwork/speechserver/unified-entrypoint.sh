#!/bin/sh
set -eu

s2s_pid=""
api_pid=""

shutdown() {
  [ -z "$s2s_pid" ] || kill "$s2s_pid" 2>/dev/null || true
  [ -z "$api_pid" ] || kill "$api_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap shutdown INT TERM EXIT

python server.py &
api_pid=$!

if [ "${SPEECH_REALTIME_ENGINE:-s2s}" = "s2s" ]; then
  # s2s 启动时会立即用 /v1/responses 预热 LLM。必须先等 REST 真正完成 bind，
  # 否则首次 connection refused 会使 s2s 退出，继而触发本脚本的整体重启循环。
  ready=false
  for _ in $(seq 1 120); do
    if curl -fsS http://127.0.0.1:"${SPEECH_PORT:-9100}"/openapi.json >/dev/null 2>&1; then
      ready=true
      break
    fi
    kill -0 "$api_pid" 2>/dev/null || exit 1
    sleep 0.5
  done
  if [ "$ready" != true ]; then
    echo "[speech] REST 服务未在 60 秒内就绪，停止启动 s2s" >&2
    exit 1
  fi
  /srv/s2s-entrypoint.sh &
  s2s_pid=$!
fi

# 任一核心进程退出都让容器退出，由 Compose/Kubernetes 统一重启，避免半健康状态。
while kill -0 "$api_pid" 2>/dev/null; do
  if [ -n "$s2s_pid" ] && ! kill -0 "$s2s_pid" 2>/dev/null; then
    wait "$s2s_pid" || exit $?
  fi
  sleep 2
done
wait "$api_pid"
