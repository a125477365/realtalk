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

  # 是否为「全新数据库」：只有新建库时才需要把模型/语音等 DB 存储参数初始化进库；
  # 连接已有库（外部库，或沿用已初始化的内置数据目录）则这些配置库里已有，不再重复询问。
  FRESH_DB=false
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
          # 先停容器，否则 PostgreSQL 锁文件导致删不掉
          if docker compose ps --format '{{.Name}}' 2>/dev/null | grep -q postgres; then
            note "正在停止 PostgreSQL 容器…"
            docker compose stop postgres 2>/dev/null || true
            sleep 2
          fi
          rm -rf "${PG_DATA_DIR:?}/"* "${PG_DATA_DIR:?}/".* 2>/dev/null
          # 验证是否真正清空
          if [ -f "$PG_DATA_DIR/PG_VERSION" ]; then
            echo
            say "⚠️  清空失败！数据目录可能被占用或权限不足。"
            note "请手动执行以下命令后重新运行本脚本："
            echo "    docker compose down"
            echo "    rm -rf ${PG_DATA_DIR}/*"
            echo "    rm -rf ${PG_DATA_DIR}/.*  2>/dev/null"
            echo "    bash setup.sh"
            exit 1
          fi
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
      FRESH_DB=true   # 新初始化的内置库 → 需要把模型/语音等参数写入并落库
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

  # ---- 采集分块暂存 Redis（强制配置：内置容器 / 远程地址）----
  echo
  note "对话采集分块暂存必须使用 Redis（多活部署下本地文件会导致 chunk 落在不同机器上无法汇总）。"
  echo "    1) 内置 Redis 容器（与内置数据库一样在本机起一个）"
  echo "    2) 远程 / 已有 Redis（填写连接串）"
  ask "选择 Redis 部署方式" "1"
  REDIS_CHOICE="$REPLY_VALUE"
  if [ "$REDIS_CHOICE" != "1" ] && [ "$REDIS_CHOICE" != "2" ]; then
    say "Redis 是必选项，只能选择 1 或 2。"; exit 1
  fi
  REDIS_PORT_VAL=""
  if [ "$REDIS_CHOICE" = "1" ]; then
    PROFILES+=("backend-redis")
    ask "Redis 数据目录" "./data/redis"
    ENV_LINES+=("REDIS_DATA_DIR=$REPLY_VALUE")
    note "内置 Redis 容器对外端口，默认不使用 6379（避免与宿主机已有 Redis 冲突）。"
    ask "Redis 对外端口" "6380"
    REDIS_PORT_VAL="$REPLY_VALUE"
    ENV_LINES+=("REDIS_PORT=$REDIS_PORT_VAL")
    ENV_LINES+=("REDIS_URL=redis://redis:6379/0")
  else
    note "示例：redis://:你的密码@redis.example.com:6379/0（走 TLS 用 rediss://）"
    ask "Redis 连接串 REDIS_URL" ""
    [ -n "$REPLY_VALUE" ] || { say "Redis 是必选项，必须填写连接串"; exit 1; }
    ENV_LINES+=("REDIS_URL=$REPLY_VALUE")
  fi

  ask "JWT 密钥（回车自动生成强随机密钥）" "$(rand 48)"
  ENV_LINES+=("JWT_SECRET=$REPLY_VALUE")

  ask "管理员用户名" "admin"
  ENV_LINES+=("ADMIN_USERNAME=$REPLY_VALUE")
  note "管理员初始密码默认自动生成强随机值（请记下，登录后可在管理台改密）。"
  ask "管理员初始密码（回车=自动生成）" "$(rand 16)"
  ADMIN_PW_VALUE="$REPLY_VALUE"
  ENV_LINES+=("ADMIN_PASSWORD=$ADMIN_PW_VALUE")

  # 以下「AI 模型 / 实时语音」属于保存在数据库（app_settings）的参数：
  # 仅在新建数据库时询问并写入（首次启动会落库）；连接已有库时库里已有，跳过询问，可在管理台改。
  if $FRESH_DB; then
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

    # ---- 高级会员实时语音大模型（OpenAI 兼容 Realtime API，可跳过）----
    note "高级会员实时语音对练（可跳过，建议部署后在管理台「系统设置」配置）。"
    ask "实时语音 Base URL（OpenAI 兼容 Realtime WSS，回车跳过）" ""
    RT_BASE="$REPLY_VALUE"
    if [ -n "$RT_BASE" ]; then
      ask_secret "实时语音 API Key"; RT_KEY="$REPLY_VALUE"
      ask "实时语音模型" "gpt-4o-realtime-preview"; RT_MODEL="$REPLY_VALUE"
      ask "语音音色" "alloy"; RT_VOICE="$REPLY_VALUE"
      note "实时语音计费单价（分/百万 token），文本/音频分开；用量计入用户当月费用额度（会员月费50%）。"
      ask "  输入·文本 单价" "400"; RT_P_IT="$REPLY_VALUE"
      ask "  输入·音频 单价" "2800"; RT_P_IA="$REPLY_VALUE"
      ask "  输出·文本 单价" "1600"; RT_P_OT="$REPLY_VALUE"
      ask "  输出·音频 单价" "5600"; RT_P_OA="$REPLY_VALUE"
      ENV_LINES+=("REALTIME_BASE_URL=$RT_BASE" "REALTIME_API_KEY=$RT_KEY" "REALTIME_MODEL=$RT_MODEL" "REALTIME_VOICE=$RT_VOICE")
      ENV_LINES+=("REALTIME_INPUT_TEXT_PRICE_PER_1M_CENTS=$RT_P_IT" "REALTIME_INPUT_AUDIO_PRICE_PER_1M_CENTS=$RT_P_IA" "REALTIME_OUTPUT_TEXT_PRICE_PER_1M_CENTS=$RT_P_OT" "REALTIME_OUTPUT_AUDIO_PRICE_PER_1M_CENTS=$RT_P_OA")
    else
      ENV_LINES+=("REALTIME_BASE_URL=wss://api.openai.com/v1/realtime" "REALTIME_API_KEY=" "REALTIME_MODEL=gpt-4o-realtime-preview" "REALTIME_VOICE=alloy")
    fi

    # ---- 语音转写 ASR（高级会员上传录音转文字，DB 存储参数，仅新建库时配置）----
    echo
    note "高级会员上传录音的转文字方式："
    echo "    1) 云端语音模型（OpenAI 兼容 API，需密钥，质量稳定）"
    echo "    2) 服务器本地 whisper（自动安装，免密钥，占用本机算力）"
    echo "    3) 暂不配置（之后在管理台或重跑本脚本再设）"
    ask "选择 ASR 方式" "3"
    ASR_CHOICE="$REPLY_VALUE"
    WITH_LOCAL_ASR=false
    ASR_MODE_VAL="cloud"; ASR_BASE=""; ASR_KEY=""; ASR_MODEL_VAL="whisper-1"
    ASR_LOCAL_CMD=""; ASR_LOCAL_MODEL_VAL="small"; ASR_DEV="false"
    if [ "$ASR_CHOICE" = "1" ]; then
      ask "ASR Base URL" "https://api.openai.com/v1"; ASR_BASE="$REPLY_VALUE"
      ask_secret "ASR API Key"; ASR_KEY="$REPLY_VALUE"
      ask "ASR 模型名称" "whisper-1"; ASR_MODEL_VAL="$REPLY_VALUE"
    elif [ "$ASR_CHOICE" = "2" ]; then
      note "将自动在后端镜像中安装 faster-whisper（CPU），首次转写会下载模型到 ./data/whisper-models。"
      note "模型越大越准也越慢：tiny/base/small/medium（小机器建议 small）。"
      ask "本地 whisper 模型大小" "small"; ASR_LOCAL_MODEL_VAL="$REPLY_VALUE"
      WITH_LOCAL_ASR=true
      ASR_MODE_VAL="local"
      ASR_LOCAL_CMD="python /app/app/asr_local.py {input}"
    else
      ASR_DEV="false"
    fi
    ENV_LINES+=(
      "WITH_LOCAL_ASR=$WITH_LOCAL_ASR"
      "WHISPER_MODEL_DIR=./data/whisper-models"
      "ASR_MODE=$ASR_MODE_VAL"
      "ASR_BASE_URL=$ASR_BASE" "ASR_API_KEY=$ASR_KEY" "ASR_MODEL=$ASR_MODEL_VAL"
      "ASR_LOCAL_COMMAND=$ASR_LOCAL_CMD" "ASR_LOCAL_MODEL=$ASR_LOCAL_MODEL_VAL"
      "ASR_DEV_MODE=$ASR_DEV"
    )

    note "额度参数已设为默认值（非会员每天 1000 token / 5 分钟录音，基础 12 万 / 高级 40 万），可在管理台「系统设置 → 额度」调整。"
  else
    note "连接已有数据库：AI 模型 / 实时语音 / ASR 等配置沿用库中已有值（如需修改请到管理台「系统设置」）。"
    # 已有库时 ASR 仍需写入 .env 默认值（WITH_LOCAL_ASR 影响 Docker 构建），但不询问用户
    ENV_LINES+=(
      "WITH_LOCAL_ASR=false"
      "WHISPER_MODEL_DIR=./data/whisper-models"
      "ASR_MODE=cloud"
      "ASR_BASE_URL=" "ASR_API_KEY=" "ASR_MODEL=whisper-1"
      "ASR_LOCAL_COMMAND=" "ASR_LOCAL_MODEL=small"
      "ASR_DEV_MODE=false"
    )
  fi

  ask "worker 进程数（建议=CPU核数）" "4"
  ENV_LINES+=("WEB_CONCURRENCY=$REPLY_VALUE")

  # ---- 语音文件服务器（高级会员上传录音）----
  note "高级会员上传的录音文件，会按【文件 MD5】路由到「可处理语音的服务器」，由其每小时定时任务转写并生成场景。"
  note "可处理语音的【服务器列表】在【管理台 → 系统设置 → 语音文件服务器】中配置（格式 ip:port;ip:port），未配置则语音上传直接报错。"
  ask "本机是否作为语音文件服务器（处理上传的录音文件）？(yes/no)" "no"
  VOICE_NODE_ADDR_VAL=""
  if [ "$REPLY_VALUE" = "yes" ]; then
    note "请填【本机在语音服务器列表中的地址 ip:port】，其它服务器须能通过它访问本机；服务据此判断某文件是否归本机处理。"
    note "首次启动时本机地址会自动加入【管理台 → 系统设置 → 语音文件服务器】列表，之后可在管理台删除（删除后重启不会再自动加回）。"
    ask "本机语音服务地址 VOICE_NODE_ADDR（如 192.168.6.3:8000；必填）" ""
    VOICE_NODE_ADDR_VAL="$REPLY_VALUE"
    [ -z "$VOICE_NODE_ADDR_VAL" ] && note "未填本机地址 → 本机不会注册为语音服务器，也不会自动加入列表。"
  fi
  ENV_LINES+=("VOICE_NODE_ADDR=$VOICE_NODE_ADDR_VAL")

  # ---- 微信登录（高级，可选）----
  echo
  note "微信登录：默认开发模拟模式（任意设备直接登录，便于联调）。"
  ask "现在配置正式微信登录凭据吗？(yes/no)" "no"
  if [ "$REPLY_VALUE" = "yes" ]; then
    ask "移动应用 AppID（微信开放平台 · 移动应用）" ""
    WX_APPID="$REPLY_VALUE"
    ask_secret "移动应用 AppSecret"; WX_SECRET="$REPLY_VALUE"
    ask "网站应用 AppID（用于 Web 扫码登录，可留空）" ""
    WX_WEB_APPID="$REPLY_VALUE"
    WX_WEB_SECRET=""
    [ -n "$WX_WEB_APPID" ] && { ask_secret "网站应用 AppSecret"; WX_WEB_SECRET="$REPLY_VALUE"; }
    ENV_LINES+=(
      "WECHAT_AUTH_DEV_MODE=false"
      "WECHAT_APP_ID=$WX_APPID" "WECHAT_APP_SECRET=$WX_SECRET"
      "WECHAT_WEB_APP_ID=$WX_WEB_APPID" "WECHAT_WEB_APP_SECRET=$WX_WEB_SECRET"
    )
  else
    ENV_LINES+=(
      "WECHAT_AUTH_DEV_MODE=true"
      "WECHAT_APP_ID=" "WECHAT_APP_SECRET="
      "WECHAT_WEB_APP_ID=" "WECHAT_WEB_APP_SECRET="
    )
  fi

  # ---- 支付（高级，可选）----
  echo
  note "支付：默认开发模式（下单后可手动确认到账，便于联调）。正式收款需商户资质。"
  ask "现在配置正式支付参数吗？(yes/no)" "no"
  PAY_DEV_CONFIRM=true
  WX_MCHID=""; WX_APIKEY=""; WX_NOTIFY=""
  ALI_APPID=""; ALI_PRIV=""; ALI_PUB=""; ALI_NOTIFY=""
  RECV_NAME="RealTalk"; WX_RECV=""; ALI_RECV=""
  if [ "$REPLY_VALUE" = "yes" ]; then
    PAY_DEV_CONFIRM=false
    ask "收款主体名称（显示给用户）" "RealTalk"
    RECV_NAME="$REPLY_VALUE"
    note "支付回调必须验签后才入账（防伪造通知白嫖会员）。这些凭证也可稍后在管理台「支付验签配置」维护。"
    ask "配置微信支付商户？(yes/no)" "no"
    if [ "$REPLY_VALUE" = "yes" ]; then
      ask "微信支付商户号 MCHID" ""; WX_MCHID="$REPLY_VALUE"
      ask_secret "微信支付 APIv3 密钥（回调验签解密用）"; WX_APIKEY="$REPLY_VALUE"
      ask "微信平台证书序列号（回调验签用，可留空稍后在管理台填）" ""; WX_SERIAL="$REPLY_VALUE"
      ask "微信平台证书 PEM 文件路径（回调验签用，可留空稍后在管理台粘贴）" ""; WX_CERT_PATH="$REPLY_VALUE"
      WX_CERT=""
      if [ -n "$WX_CERT_PATH" ] && [ -f "$WX_CERT_PATH" ]; then
        # 多行 PEM → 字面 \n 单行写入 .env（后端 _multiline_env 还原）
        WX_CERT="$(sed ':a;N;$!ba;s/\n/\\n/g' "$WX_CERT_PATH")"
      fi
      ask "微信支付回调地址 NOTIFY_URL" "https://your-domain.com/payment/wechat/webhook"; WX_NOTIFY="$REPLY_VALUE"
    fi
    ask "配置支付宝当面付？(yes/no)" "no"
    if [ "$REPLY_VALUE" = "yes" ]; then
      ask "支付宝 AppID" ""; ALI_APPID="$REPLY_VALUE"
      ask_secret "支付宝应用私钥"; ALI_PRIV="$REPLY_VALUE"
      ask_secret "支付宝公钥"; ALI_PUB="$REPLY_VALUE"
      ask "支付宝回调地址 NOTIFY_URL" "https://your-domain.com/payment/alipay/webhook"; ALI_NOTIFY="$REPLY_VALUE"
    fi
    note "未接入官方支付时，可填个人收款码账号，用户转账后在管理台「充值订单」人工确认。"
    ask "微信收款账号/备注（可留空）" ""; WX_RECV="$REPLY_VALUE"
    ask "支付宝收款账号（可留空）" ""; ALI_RECV="$REPLY_VALUE"
  fi

  ENV_LINES+=(
    "REALTALK_REGION=prod"
    "TRIAL_DAYS=30"
    "BUDGET_RATIO=0.5"
    "NONMEMBER_DAILY_CHAT_TOKENS=1000"
    "NONMEMBER_DAILY_CAPTURE_TOKENS=1000"
    "NONMEMBER_DAILY_CAPTURE_SECONDS=300"
    "DAILY_TOKEN_LIMIT_FREE=8000"
    "DAILY_TOKEN_LIMIT_BASIC=120000"
    "DAILY_TOKEN_LIMIT_PREMIUM=400000"
    "UPLOAD_DATA_DIR=./data/uploads"
    "AUDIO_MAX_BYTES=314572800"
    "AUDIO_MAX_SECONDS=21600"
    "# 安全：生产默认关闭内购校验旁路（接 Apple 内购前保持 false）"
    "APPLE_IAP_DEV_BYPASS=false"
    "# 邮箱注册默认关闭，仅微信认证"
    "EMAIL_AUTH_ENABLED=false"
    "EMAIL_DEV_MODE=true"
    "PAYMENT_RECEIVER_NAME=$RECV_NAME"
    "WECHAT_RECEIVER_ACCOUNT=$WX_RECV" "ALIPAY_RECEIVER_ACCOUNT=$ALI_RECV"
    "PAYMENT_DEV_AUTO_CONFIRM=$PAY_DEV_CONFIRM"
    "WECHAT_MCHID=$WX_MCHID" "WECHAT_API_KEY=$WX_APIKEY" "WECHAT_NOTIFY_URL=$WX_NOTIFY"
    "WECHAT_CERT_SERIAL=$WX_SERIAL" "WECHAT_PLATFORM_CERT=$WX_CERT"
    "ALIPAY_APP_ID=$ALI_APPID" "ALIPAY_PRIVATE_KEY=$ALI_PRIV" "ALIPAY_PUBLIC_KEY=$ALI_PUB" "ALIPAY_NOTIFY_URL=$ALI_NOTIFY"
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
$DEPLOY_BACKEND && [ -n "$REDIS_PORT_VAL" ] && echo "  Redis 对外：  <本机IP>:${REDIS_PORT_VAL}  （内置 Redis，不建议暴露公网）"
$DEPLOY_ADMIN   && echo "  管理台：      http://<本机IP>:${ADMIN_PORT:-8001}"
$DEPLOY_WEB     && echo "  用户 Web 端： http://<本机IP>:${WEB_PORT:-8002}"

if $DEPLOY_BACKEND; then
  echo
  say "管理员登录账号：${ADMIN_USERNAME:-admin}　密码：${ADMIN_PW_VALUE:-（见 .env ADMIN_PASSWORD）}"
  note "请立即记下并妥善保管，登录管理台后尽快改密。"
  echo
  say "⚠️  代码层安全已就绪（单设备登录 / 服务端会员鉴权与到期 / 限流 / 强 JWT 密钥 / 危险旁路告警）。"
  say "    以下基础设施/平台层安全需运维在部署后另行设置（代码无法代办）："
  note "HTTPS/TLS：在 API、管理台、Web 前都挂反向代理（Nginx/Caddy）启用证书，App 只连 https。"
  note "防火墙：仅放行必要端口；数据库/Redis 不要暴露公网（用内网或 SSH 隧道）。"
  note "抗 DDoS / WAF：在 CDN 或网关层做（应用内限流只是兜底，单机粒度）。"
  note "客户端防篡改：上线后接 iOS App Attest / Android Play Integrity，在登录与付款接口校验设备完整性。"
  note "上线前确认：PAYMENT_DEV_AUTO_CONFIRM / WECHAT_AUTH_DEV_MODE / APPLE_IAP_DEV_BYPASS 均为 false。"
fi

cat <<'EOF'

 常用命令：docker compose ps / logs -f api / down
 跨机部署：在其他机器重复运行 bash setup.sh，只勾选该机的应用并填写后端地址。
EOF
