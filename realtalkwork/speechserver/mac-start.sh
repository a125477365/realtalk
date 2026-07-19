#!/usr/bin/env bash
# 手动启动本机(Mac)语音服务器 —— 不开机自启，关机后需再手动跑本脚本。
# 用法：bash mac-start.sh    （在项目 realtalkwork/speechserver 目录下）
# 关闭：bash mac-stop.sh
set -uo pipefail
ROOT="${REALTALK_SPEECH_HOME:-$HOME/realtalk-speech}"
SRC="$(cd "$(dirname "$0")" && pwd)"
PORT="$(sed -n 's/^SPEECH_PORT=//p' "$ROOT/speech.env" 2>/dev/null | tail -1)"; PORT="${PORT:-9100}"

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "✅ 语音服务器已在 :$PORT 运行（bash mac-stop.sh 可关闭）。"; exit 0
fi

# 同步最新服务代码到 $ROOT/app（手动启动也统一用该目录，保证跑的是项目最新代码）
mkdir -p "$ROOT/app"
cp -f "$SRC"/*.py "$SRC/run_native_macos.sh" "$SRC/s2s_native_macos.sh" "$ROOT/app/" 2>/dev/null || true

echo "▶️  后台启动语音服务器（不自启）… 首次加载 7B 需 1~2 分钟。"
nohup caffeinate -is bash "$ROOT/app/run_native_macos.sh" > "$ROOT/speech.log" 2>&1 &
disown

for i in $(seq 1 150); do
  if curl -fs -m3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "✅ 已就绪："; curl -s "http://127.0.0.1:$PORT/health"; echo
    echo "   局域网地址 http://$(ipconfig getifaddr en0 2>/dev/null):$PORT/v1（后端自愈脚本会自动跟上IP）"
    exit 0
  fi
  sleep 2
done
echo "⚠️  150s 内未就绪。看日志：tail -f $ROOT/speech.log"
exit 1
