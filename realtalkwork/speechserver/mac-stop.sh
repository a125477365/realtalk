#!/usr/bin/env bash
# 手动关闭本机(Mac)语音服务器（聚合器 :9100 + s2s 实时进程 :8765）。
# 用法：bash mac-stop.sh
ROOT="${REALTALK_SPEECH_HOME:-$HOME/realtalk-speech}"
echo "⏹  关闭语音服务器…"

# 按命令特征逐个结束：run 脚本 / s2s / 聚合器 uvicorn / speech-to-speech / 包裹的 caffeinate、micromamba
for pat in 'run_native_macos.sh' 's2s_native_macos.sh' 'uvicorn server:app' 'speech-to-speech --mode realtime' 'caffeinate -is' 'micromamba run -n speech'; do
  pkill -f "$pat" 2>/dev/null || true
done
sleep 2

# 兜底：谁还占着 9100/8765 就按端口结束
for p in 9100 8765; do
  pid=$(lsof -nP -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null || true)
  [ -n "$pid" ] && kill $pid 2>/dev/null || true
done
sleep 1
for p in 9100 8765; do
  pid=$(lsof -nP -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null || true)
  [ -n "$pid" ] && kill -9 $pid 2>/dev/null || true
done
sleep 1

if lsof -nP -iTCP:9100 -sTCP:LISTEN >/dev/null 2>&1 || lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "⚠️  仍有端口被占用，请再跑一次或手动检查：lsof -iTCP:9100 -iTCP:8765"
else
  echo "✅ 已全部关闭。"
fi
