#!/bin/sh
# RealTalk 语音服务器(Mac)DHCP 漂移自愈脚本。
# 语音服务器（Mac）走 Wi-Fi + DHCP，IP 时常变化（.90→.92→.82…），后端配置指向旧 IP 后
# 全站 AI 立刻不可用。本脚本由 cron 每分钟运行：当前配置地址还活着则秒退；不通则扫描本网段
# 找到 :9100 的语音服务器（/health 带 device 字段）并把后端「模型/ASR/对话语音」配置改到新 IP。
#
# 部署（在跑后端的那台机器上，一次性）：
#   cp deploy/speech-ip-watch.sh /root/ && chmod +x /root/speech-ip-watch.sh
#   echo '* * * * * /root/speech-ip-watch.sh' >> /etc/crontabs/root
#   /etc/init.d/cron enable; /etc/init.d/cron restart
# 治本仍建议给 Mac 固定 IP（路由器 DHCP 保留 / Mac 静态 IP）——本脚本是兜底自愈。
set -u
B="${RT_API:-http://127.0.0.1:8000}"
SUBNET="${RT_SUBNET:-192.168.6}"
JAR="/tmp/rt_admin.jar"
LOG="/tmp/rt_speech_ip.log"
ADMIN_USER="${RT_ADMIN_USER:-admin}"
ADMIN_PW="${RT_ADMIN_PW:-admin123456}"

# 语音服务器可能有多台：Mac(device=metal，快)和本机 .3(device=cpu，慢兜底)。优先用 metal。
# 1) 当前配置地址若还是 metal 且在线 → 秒退（常态，一条 curl）。
cur=$(curl -s -m3 "$B/admin/api/settings/tts" 2>/dev/null | sed -n 's/.*"base_url":"http:\/\/\([0-9.]*\):9100.*/\1/p')
if [ -n "$cur" ]; then
  curdev=$(curl -fs -m3 "http://$cur:9100/health" 2>/dev/null | sed -n 's/.*"device":"\([a-z]*\)".*/\1/p')
  [ "$curdev" = "metal" ] && exit 0   # 已指向在线的 Mac，无需动
fi

# 2) 扫描本网段（并发），记录每个 :9100 语音服务器的 "ip device"
rm -f /tmp/rt_found
i=2
while [ "$i" -le 254 ]; do
  ip="$SUBNET.$i"
  ( d=$(curl -fs -m2 "http://$ip:9100/health" 2>/dev/null)
    case "$d" in *'"device"'*) echo "$ip $(echo "$d" | sed -n 's/.*"device":"\([a-z]*\)".*/\1/p')" >> /tmp/rt_found ;; esac ) &
  i=$((i+1))
done
wait
# 优先 metal(Mac)，否则任意在线的(如 .3 cpu 兜底)
found=$(awk '$2=="metal"{print $1; exit}' /tmp/rt_found 2>/dev/null)
[ -z "$found" ] && found=$(awk 'NR==1{print $1}' /tmp/rt_found 2>/dev/null)
[ -z "$found" ] && { echo "$(date) 未找到语音服务器" >> "$LOG"; exit 1; }
[ "$found" = "$cur" ] && exit 0

# 3) 更新后端配置到新 IP（模型中心 / A·场景ASR / 通用ASR / B·对话语音模型）
NEW="http://$found:9100/v1"
curl -s -m5 -c "$JAR" -X POST "$B/admin/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PW\"}" >/dev/null 2>&1
curl -s -m10 -b "$JAR" -X POST "$B/admin/api/settings/model" -H 'Content-Type: application/json' \
  -d "{\"provider\":\"custom\",\"base_url\":\"$NEW\",\"api_key\":\"local-metal\",\"model\":\"local\"}" >/dev/null 2>&1
curl -s -m10 -b "$JAR" -X POST "$B/admin/api/settings/asr" -H 'Content-Type: application/json' \
  -d "{\"scope\":\"scenario\",\"base_url\":\"$NEW\",\"api_key\":\"local\",\"model\":\"whisper-1\"}" >/dev/null 2>&1
curl -s -m10 -b "$JAR" -X POST "$B/admin/api/settings/asr" -H 'Content-Type: application/json' \
  -d "{\"scope\":\"\",\"base_url\":\"$NEW\",\"api_key\":\"local\",\"model\":\"whisper-1\"}" >/dev/null 2>&1
curl -s -m10 -b "$JAR" -X POST "$B/admin/api/settings/tts" -H 'Content-Type: application/json' \
  -d "{\"base_url\":\"$NEW\",\"api_key\":\"local-metal\",\"model\":\"\"}" >/dev/null 2>&1
echo "$(date) 语音服务器地址 ${cur:-?} → $found，已更新后端配置" >> "$LOG"
