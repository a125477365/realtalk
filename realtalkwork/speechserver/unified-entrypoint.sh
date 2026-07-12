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
