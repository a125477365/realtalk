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

# REST 是其余三个 OpenAI 兼容端点的核心服务。原生实时进程失败时，不能为了 WS
# 把 REST 一起杀掉并触发 Docker 重建循环；保留 REST、延时重试 s2s，health 会在
# 实时服务重新可用后自动转为 healthy。
while kill -0 "$api_pid" 2>/dev/null; do
  if [ -n "$s2s_pid" ] && ! kill -0 "$s2s_pid" 2>/dev/null; then
    wait "$s2s_pid" || s2s_code=$?
    echo "[speech] 原生实时服务已退出（${s2s_code:-0}），15 秒后重试；REST 服务继续可用" >&2
    s2s_pid=""
    sleep 15
    kill -0 "$api_pid" 2>/dev/null || break
    /srv/s2s-entrypoint.sh &
    s2s_pid=$!
  fi
  sleep 2
done
wait "$api_pid"
