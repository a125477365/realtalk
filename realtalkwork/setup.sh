#!/usr/bin/env bash
# RealTalk 一键安装引导：交互式生成 .env 并启动 Docker 服务。
# 用法：cd realtalkwork && bash setup.sh
set -euo pipefail

cd "$(dirname "$0")"

BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'

say()  { printf '%s\n' "${BOLD}$*${RESET}"; }
note() { printf '%s\n' "${YELLOW}  ➜ $*${RESET}"; }

ask() { # ask "提示" "默认值" -> REPLY_VALUE
  local prompt="$1" default="${2:-}" input
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " input
    REPLY_VALUE="${input:-$default}"
  else
    read -r -p "$prompt: " input
    REPLY_VALUE="$input"
  fi
}

ask_secret() { # 不回显
  local prompt="$1" input
  read -r -s -p "$prompt: " input
  echo
  REPLY_VALUE="$input"
}

say "=============================================="
say " RealTalk 后端 + 管理台 安装引导"
say "=============================================="
echo

if [ -f .env ]; then
  ask "检测到已有 .env，是否覆盖重新生成？(yes/no)" "no"
  if [ "$REPLY_VALUE" != "yes" ]; then
    say "已保留现有 .env。直接执行：docker compose up -d --build"
    exit 0
  fi
  cp .env ".env.bak.$(date +%Y%m%d%H%M%S)"
  note "旧配置已备份。"
fi

# ---------- 基础 ----------
say "[1/6] 基础配置"
note "JWT_SECRET 用于签发用户登录令牌，必须保密；回车自动生成强随机值。"
ask "JWT 密钥（回车自动生成）" "$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 48)"
JWT_SECRET="$REPLY_VALUE"

ask "API 对外端口" "8000"
API_PORT="$REPLY_VALUE"
ask "管理台对外端口" "8001"
ADMIN_PORT="$REPLY_VALUE"

# ---------- 数据库 ----------
echo; say "[2/6] 数据库（Docker 内置 PostgreSQL）"
note "数据默认持久化到 ./data/postgres，可改为任意宿主机目录。"
ask "PostgreSQL 数据目录" "./data/postgres"
POSTGRES_DATA_DIR="$REPLY_VALUE"
ask "PostgreSQL 密码（回车自动生成）" "$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 20)"
POSTGRES_PASSWORD="$REPLY_VALUE"

# ---------- 管理员 ----------
echo; say "[3/6] 管理台初始账号"
note "首次启动自动创建超级管理员；登录后请立即在「修改密码」中更换。"
ask "管理员用户名" "admin"
ADMIN_USERNAME="$REPLY_VALUE"
ask "管理员初始密码（至少 8 位）" "admin123456"
ADMIN_PASSWORD="$REPLY_VALUE"

# ---------- AI 模型 ----------
echo; say "[4/6] AI 大模型（可跳过，之后在管理台「系统设置 → AI 模型对接」中配置）"
note "支持任意 OpenAI 兼容服务：火山方舟/豆包、DeepSeek、通义千问、Kimi、智谱等。"
note "未配置时翻译/场景生成使用内置模板兜底，功能可用但质量有限。"
ask "AI Base URL（回车跳过）" ""
AI_BASE_URL="$REPLY_VALUE"
AI_API_KEY=""
AI_MODEL=""
if [ -n "$AI_BASE_URL" ]; then
  ask_secret "AI API Key"
  AI_API_KEY="$REPLY_VALUE"
  ask "模型名称" "doubao-seed-1-6-251015"
  AI_MODEL="$REPLY_VALUE"
fi

# ---------- 支付 ----------
echo; say "[5/6] 收款配置"
note "正式接入微信支付/支付宝需要商户号与证书（见 .env 注释）；"
note "未接入前可填「个人收款码账号」，用户转账后在管理台「充值订单」人工确认到账。"
ask "微信收款账号/备注（回车跳过）" ""
WECHAT_RECEIVER_ACCOUNT="$REPLY_VALUE"
ask "支付宝收款账号（回车跳过）" ""
ALIPAY_RECEIVER_ACCOUNT="$REPLY_VALUE"
ask "是否启用开发模式自动确认到账（生产请选 no）(yes/no)" "yes"
if [ "$REPLY_VALUE" = "yes" ]; then PAYMENT_DEV_AUTO_CONFIRM=true; else PAYMENT_DEV_AUTO_CONFIRM=false; fi

# ---------- 写入 .env ----------
echo; say "[6/6] 生成 .env"
cat > .env <<EOF
# ===== 由 setup.sh 生成（$(date '+%Y-%m-%d %H:%M:%S')）=====

# 基础
JWT_SECRET=${JWT_SECRET}
REALTALK_REGION=prod
TOKEN_TTL_HOURS=720
RETENTION_DAYS=3
HISTORY_RETENTION_DAYS=90
REQUIRE_PRO_FOR_AI=false

# 端口（docker compose 使用）
API_PORT=${API_PORT}
ADMIN_PORT=${ADMIN_PORT}

# 数据库（docker compose 使用）
POSTGRES_USER=realtalk
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=realtalk
POSTGRES_DATA_DIR=${POSTGRES_DATA_DIR}

# 管理台
ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
ADMIN_FRONTEND_URL=http://localhost:${ADMIN_PORT}

# AI 模型（也可在管理台「系统设置」中配置，管理台配置优先生效）
AI_BASE_URL=${AI_BASE_URL}
AI_API_KEY=${AI_API_KEY}
AI_MODEL=${AI_MODEL}
AI_TIMEOUT_SECONDS=40
# 成本估算单价（分/百万 tokens），用于管理台支出统计
AI_INPUT_PRICE_PER_1M_CENTS=80
AI_OUTPUT_PRICE_PER_1M_CENTS=200

# 登录（生产接入微信开放平台后改为 false 并填写 APP_ID/SECRET）
WECHAT_AUTH_DEV_MODE=true
WECHAT_APP_ID=
WECHAT_APP_SECRET=

# 收款
PAYMENT_RECEIVER_NAME=RealTalk
WECHAT_RECEIVER_ACCOUNT=${WECHAT_RECEIVER_ACCOUNT}
ALIPAY_RECEIVER_ACCOUNT=${ALIPAY_RECEIVER_ACCOUNT}
PAYMENT_DEV_AUTO_CONFIRM=${PAYMENT_DEV_AUTO_CONFIRM}

# 微信支付（原生支付，正式商户必填）
WECHAT_MCHID=
WECHAT_API_KEY=
WECHAT_NOTIFY_URL=
# 支付宝（当面付，正式商户必填）
ALIPAY_APP_ID=
ALIPAY_PRIVATE_KEY=
ALIPAY_PUBLIC_KEY=
ALIPAY_NOTIFY_URL=

# 邮件（找回密码；EMAIL_DEV_MODE=true 时不真正发信）
EMAIL_DEV_MODE=true
SMTP_HOST=
SMTP_PORT=587
SMTP_USERNAME=
SMTP_PASSWORD=
SMTP_FROM=RealTalk <noreply@realtalk.local>
APP_BASE_URL=https://realtalk.app

# Apple 内购（上架 App Store 时配置）
APPLE_PRODUCT_ID=realtalk.pro.monthly
APPLE_BUNDLE_ID=com.realtalk.app
APPLE_USE_SANDBOX=true
APPLE_IAP_DEV_BYPASS=true
EOF
say ".env 已生成。"

# ---------- 启动 ----------
echo
ask "是否立即构建并启动服务？(yes/no)" "yes"
if [ "$REPLY_VALUE" = "yes" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    say "未检测到 docker，请先安装 Docker 后执行：docker compose up -d --build"
    exit 1
  fi
  docker compose up -d --build
  echo
  say "等待服务就绪…"
  for _ in $(seq 1 30); do
    if curl -fs "http://127.0.0.1:${API_PORT}/health" >/dev/null 2>&1; then break; fi
    sleep 2
  done
  curl -fs "http://127.0.0.1:${API_PORT}/health" >/dev/null 2>&1 \
    && say "${GREEN}✔ API 已就绪${RESET}" \
    || say "API 尚未就绪，可执行 docker compose logs -f api 查看日志"
fi

echo
say "=============================================="
say " 安装完成，下一步："
say "=============================================="
cat <<EOF
 1. 管理台：   http://<服务器IP>:${ADMIN_PORT}
    账号：${ADMIN_USERNAME} / 你设置的密码（登录后请立即修改密码）
 2. 配置模型： 管理台 → 系统设置 → AI 模型对接（可随时切换服务商，立即生效）
 3. 看板：     管理台 → 数据概览（收入 / AI 支出 / 用户 / 练习量多维统计）
 4. 充值对账： 管理台 → 充值订单（个人收款码模式下在此人工确认到账）
 5. iOS App：  修改 realtalk/realtalk/AppConfig.swift 中 apiBaseURL 为
               http://<服务器IP>:${API_PORT} 后用 Xcode 构建运行
 常用命令：    docker compose logs -f api   查看日志
               docker compose down          停止服务
EOF
