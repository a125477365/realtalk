#!/usr/bin/env bash
# RealTalk 部署引导：选择要部署的应用 → 逐应用设置参数 → 一键容器化部署。
# 支持分布式：在不同机器上分别运行本脚本、各自勾选应用并填写对端地址即可。
# 用法：cd realtalkwork && bash setup.sh
set -euo pipefail

cd "$(dirname "$0")"

BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
say()  { printf '%s\n' "${BOLD}$*${RESET}"; }
note() { printf '%s\n' "${YELLOW}  ➜ $*${RESET}"; }

ask() { # ask "提示" "默认值"
  local prompt="$1" default="${2:-}" input
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " input
    REPLY_VALUE="${input:-$default}"
  else
    read -r -p "$prompt: " input
    REPLY_VALUE="$input"
  fi
}

ask_secret() {
  local prompt="$1" input
  read -r -s -p "$prompt: " input
  echo
  REPLY_VALUE="$input"
}

rand() { LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "${1:-32}"; }

say "=============================================="
say " RealTalk 部署引导（可分布式拆机部署）"
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

# ============ 第 1 步：选择本机要部署的应用 ============
say "[1] 选择本机要部署的应用（逗号分隔可多选）"
echo "    1) 后端 API（含可选内置 PostgreSQL）"
echo "    2) 管理台（运营/财务/模型配置）"
echo "    3) 用户 Web 端（充值/会员/场景/录音上传）"
ask "要部署哪些应用？" "1,2,3"
SEL=",$REPLY_VALUE,"
DEPLOY_BACKEND=false; DEPLOY_ADMIN=false; DEPLOY_WEB=false
[[ "$SEL" == *",1,"* ]] && DEPLOY_BACKEND=true
[[ "$SEL" == *",2,"* ]] && DEPLOY_ADMIN=true
[[ "$SEL" == *",3,"* ]] && DEPLOY_WEB=true
$DEPLOY_BACKEND || $DEPLOY_ADMIN || $DEPLOY_WEB || { say "未选择任何应用，退出。"; exit 1; }

PROFILES=()
ENV_LINES=("# ===== 由 setup.sh 生成（$(date '+%Y-%m-%d %H:%M:%S')）=====")

API_UPSTREAM_DEFAULT="http://api:8000"

# ============ 第 2 步：后端参数 ============
if $DEPLOY_BACKEND; then
  echo; say "[2] 后端 API 参数"
  PROFILES+=("backend")

  ask "API 对外端口" "8000"
  ENV_LINES+=("API_PORT=$REPLY_VALUE")
  API_PORT="$REPLY_VALUE"

  note "数据库二选一：内置 PostgreSQL 容器，或填写已有数据库连接串（分布式/托管库）。"
  ask "使用内置 PostgreSQL 容器？(yes=内置 / no=外部数据库)" "yes"
  if [ "$REPLY_VALUE" = "yes" ]; then
    PROFILES+=("backend-db")
    ask "PostgreSQL 数据目录" "./data/postgres"
    PG_DATA_DIR="$REPLY_VALUE"
    ENV_LINES+=("POSTGRES_DATA_DIR=$PG_DATA_DIR")

    # 关键：PostgreSQL 只在数据目录为空时用 POSTGRES_PASSWORD 初始化密码。
    # 若目录已初始化（存在 PG_VERSION），新密码不会生效，必须沿用旧密码或清空目录。
    PG_INITED=false
    [ -f "$PG_DATA_DIR/PG_VERSION" ] && PG_INITED=true

    if $PG_INITED; then
      echo
      note "检测到 $PG_DATA_DIR 已是一个已初始化的 PostgreSQL 数据目录。"
      note "PostgreSQL 不会用新密码覆盖已有目录，否则后端会因密码不一致连不上库。"
      ask "如何处理？(keep=沿用原密码 / reset=清空目录重新初始化)" "keep"
      if [ "$REPLY_VALUE" = "reset" ]; then
        ask "确认清空 $PG_DATA_DIR 中的全部数据库数据？此操作不可恢复 (yes/no)" "no"
        if [ "$REPLY_VALUE" = "yes" ]; then
          rm -rf "${PG_DATA_DIR:?}/"* "${PG_DATA_DIR:?}/".* 2>/dev/null || true
          PG_INITED=false
          note "已清空，将重新初始化。"
        else
          note "未清空，按沿用原密码处理。"
          PG_INITED=true
        fi
      fi
    fi

    if $PG_INITED; then
      note "请输入该数据目录原本的 PostgreSQL 密码（最初部署设置的，老版本默认为 realtalk）。"
      ask "原 PostgreSQL 密码" "realtalk"
      PG_PW="$REPLY_VALUE"
    else
      ask "PostgreSQL 密码（回车自动生成）" "$(rand 20)"
      PG_PW="$REPLY_VALUE"
    fi

    # 写入完整连接串（compose 不支持嵌套变量插值，且需与内置库密码一致）
    ENV_LINES+=(
      "POSTGRES_USER=realtalk"
      "POSTGRES_PASSWORD=$PG_PW"
      "POSTGRES_DB=realtalk"
      "DATABASE_URL=postgresql+psycopg://realtalk:${PG_PW}@postgres:5432/realtalk?sslmode=disable"
    )
  else
    note "示例：postgresql+psycopg://user:pass@db.example.com:5432/realtalk?sslmode=require"
    ask "数据库连接串 DATABASE_URL" ""
    [ -n "$REPLY_VALUE" ] || { say "外部数据库必须填写连接串"; exit 1; }
    ENV_LINES+=("DATABASE_URL=$REPLY_VALUE")
  fi

  ask "JWT 密钥（回车自动生成）" "$(rand 48)"
  ENV_LINES+=("JWT_SECRET=$REPLY_VALUE")

  ask "管理员用户名" "admin"
  ENV_LINES+=("ADMIN_USERNAME=$REPLY_VALUE")
  ask "管理员初始密码（至少 8 位，登录后请改密）" "admin123456"
  ENV_LINES+=("ADMIN_PASSWORD=$REPLY_VALUE")

  note "AI 模型可跳过，部署后在管理台「系统设置 → AI 模型对接」配置（推荐）。"
  ask "AI Base URL（回车跳过）" ""
  AI_BASE_URL="$REPLY_VALUE"
  if [ -n "$AI_BASE_URL" ]; then
    ask_secret "AI API Key"; AI_KEY="$REPLY_VALUE"
    ask "模型名称" "doubao-seed-1-6-251015"
    ENV_LINES+=("AI_BASE_URL=$AI_BASE_URL" "AI_API_KEY=$AI_KEY" "AI_MODEL=$REPLY_VALUE")
  else
    ENV_LINES+=("AI_BASE_URL=" "AI_API_KEY=" "AI_MODEL=")
  fi

  ask "worker 进程数（建议=CPU核数）" "4"
  ENV_LINES+=("WEB_CONCURRENCY=$REPLY_VALUE")

  ENV_LINES+=(
    "REALTALK_REGION=prod"
    "TRIAL_DAYS=30"
    "DAILY_TOKEN_LIMIT_FREE=8000"
    "DAILY_TOKEN_LIMIT_BASIC=120000"
    "DAILY_TOKEN_LIMIT_PREMIUM=400000"
    "UPLOAD_DATA_DIR=./data/uploads"
    "ASR_BASE_URL=" "ASR_API_KEY=" "ASR_MODEL=whisper-1" "ASR_DEV_MODE=false"
    "# 登录：生产接入微信开放平台后改 false 并填写凭据（App 与网站应用分开申请）"
    "WECHAT_AUTH_DEV_MODE=true"
    "WECHAT_APP_ID=" "WECHAT_APP_SECRET="
    "WECHAT_WEB_APP_ID=" "WECHAT_WEB_APP_SECRET="
    "# 邮箱注册默认关闭（防垃圾邮箱薅取免费试用），仅微信认证"
    "EMAIL_AUTH_ENABLED=false"
    "PAYMENT_RECEIVER_NAME=RealTalk"
    "WECHAT_RECEIVER_ACCOUNT=" "ALIPAY_RECEIVER_ACCOUNT="
    "PAYMENT_DEV_AUTO_CONFIRM=true"
    "WECHAT_MCHID=" "WECHAT_API_KEY=" "WECHAT_NOTIFY_URL="
    "ALIPAY_APP_ID=" "ALIPAY_PRIVATE_KEY=" "ALIPAY_PUBLIC_KEY=" "ALIPAY_NOTIFY_URL="
    "EMAIL_DEV_MODE=true"
  )
fi

# ============ 第 3 步：管理台参数 ============
if $DEPLOY_ADMIN; then
  echo; say "[3] 管理台参数"
  PROFILES+=("admin")
  ask "管理台对外端口" "8001"
  ENV_LINES+=("ADMIN_PORT=$REPLY_VALUE")
  if $DEPLOY_BACKEND; then
    note "后端在同机部署，管理台自动走内部网络 $API_UPSTREAM_DEFAULT"
  else
    ask "后端 API 地址（另一台机器）" "http://192.168.1.10:8000"
    API_UPSTREAM_DEFAULT="$REPLY_VALUE"
  fi
fi

# ============ 第 4 步：用户 Web 端参数 ============
if $DEPLOY_WEB; then
  echo; say "[4] 用户 Web 端参数"
  PROFILES+=("web")
  ask "用户 Web 端对外端口" "8002"
  ENV_LINES+=("WEB_PORT=$REPLY_VALUE")
  if ! $DEPLOY_BACKEND && ! $DEPLOY_ADMIN; then
    ask "后端 API 地址（另一台机器）" "http://192.168.1.10:8000"
    API_UPSTREAM_DEFAULT="$REPLY_VALUE"
  fi
fi

ENV_LINES+=("API_UPSTREAM=$API_UPSTREAM_DEFAULT")
IFS=,; ENV_LINES+=("COMPOSE_PROFILES=${PROFILES[*]}"); unset IFS

# ============ 写入 .env 并部署 ============
echo; say "[5] 生成 .env（应用: ${PROFILES[*]}）"
printf '%s\n' "${ENV_LINES[@]}" > .env
say ".env 已生成。"

echo
ask "是否立即构建并启动？(yes/no)" "yes"
if [ "$REPLY_VALUE" = "yes" ]; then
  command -v docker >/dev/null 2>&1 || { say "未检测到 docker，请安装后执行：docker compose up -d --build"; exit 1; }
  docker compose up -d --build
  if $DEPLOY_BACKEND; then
    say "等待 API 就绪…"
    for _ in $(seq 1 30); do
      curl -fs "http://127.0.0.1:${API_PORT:-8000}/health" >/dev/null 2>&1 && break
      sleep 2
    done
    curl -fs "http://127.0.0.1:${API_PORT:-8000}/health" >/dev/null 2>&1 \
      && say "${GREEN}✔ API 已就绪${RESET}" \
      || say "API 尚未就绪：docker compose logs -f api"
  fi
fi

echo
say "=============================================="
say " 部署完成，本机入口："
say "=============================================="
$DEPLOY_BACKEND && echo "  后端 API：    http://<本机IP>:${API_PORT:-8000}  （App 服务地址指向这里）"
$DEPLOY_ADMIN   && echo "  管理台：      http://<本机IP>:${ADMIN_PORT:-8001}"
$DEPLOY_WEB     && echo "  用户 Web 端： http://<本机IP>:${WEB_PORT:-8002}"
cat <<'EOF'
 常用命令：docker compose ps / logs -f api / down
 跨机部署：在其他机器重复运行 bash setup.sh，只勾选该机的应用并填写后端地址。
EOF
