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

# 再配置时读取旧 .env 的字面值作为默认值；只解析 KEY=VALUE，绝不 source/执行旧配置。
declare -A PREVIOUS_ENV=()
load_previous_env() {
  local path="$1" line key value
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    key="${line%%=*}"; value="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && PREVIOUS_ENV["$key"]="$value"
  done < "$path"
}

old_default() { # KEY FALLBACK
  if [[ -n ${PREVIOUS_ENV[$1]+present} ]]; then
    printf '%s' "${PREVIOUS_ENV[$1]}"
  elif [ "$1" = "DEPLOYMENT_MODE" ] && [[ -n ${PREVIOUS_ENV[REALTALK_ENV]+present} ]]; then
    # 旧命名 development/production 无缝迁移到新界面同名选项 dev/prod。
    case "${PREVIOUS_ENV[REALTALK_ENV]}" in development|dev) printf 'dev' ;; *) printf 'prod' ;; esac
  else
    printf '%s' "$2"
  fi
}
old_yes_if_set() { [[ -n "${PREVIOUS_ENV[$1]:-}" ]] && printf 'yes' || printf 'no'; }
old_app_selection() {
  local profiles=",${PREVIOUS_ENV[COMPOSE_PROFILES]:-}," out=""
  [[ "$profiles" == *",backend,"* ]] && out="${out}1,"
  [[ "$profiles" == *",admin,"* ]] && out="${out}2,"
  [[ "$profiles" == *",web,"* ]] && out="${out}3,"
  [[ "$profiles" == *",speech,"* ]] && out="${out}4,"
  [[ "$profiles" == *",backend-redis,"* ]] && out="${out}5,"
  [[ "$profiles" == *",backend-db,"* ]] && out="${out}6,"
  printf '%s' "${out%,}"
}

ask_config() { # KEY PROMPT FALLBACK
  ask "$2" "$(old_default "$1" "$3")"
}

ask_secret_config() { # KEY PROMPT；旧值不回显，回车保留，输入 - 清空
  local input
  if [[ -n ${PREVIOUS_ENV[$1]+present} ]]; then
    read -r -s -p "$2 [已保存，回车保留，-=清空]: " input; echo
    if [ -z "$input" ]; then REPLY_VALUE="${PREVIOUS_ENV[$1]}";
    elif [ "$input" = "-" ]; then REPLY_VALUE="";
    else REPLY_VALUE="$input"; fi
  else
    ask_secret "$2"
  fi
}

ask_generated_secret_config() { # KEY PROMPT FALLBACK；新配置仍显示可记录的自动值，旧配置不回显
  if [[ -n ${PREVIOUS_ENV[$1]+present} ]]; then ask_secret_config "$1" "$2"; else ask "$2" "$3"; fi
}
ask_secret_default_config() { # KEY PROMPT FALLBACK；旧值不回显，新配置用默认值
  if [[ -n ${PREVIOUS_ENV[$1]+present} ]]; then ask_secret_config "$1" "$2"; else ask "$2" "$3"; fi
}

rand() { LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "${1:-32}"; }

check_local_postgres_auth() {
  # libpq 的错误会打印 postgres 服务名解析后的容器内网 IP（旧网络可能是 192.168.64.x，
  # 当前默认是 172.28.x），这不是 setup.sh 写入的外部数据库地址。这里在 db_init 之前用
  # .env 中的新密码做一次真实认证，避免密码不一致时仍继续启动其余组件。
  if ! grep -qE '^COMPOSE_PROFILES=.*backend-db' .env; then
    return 0
  fi
  # 库在容器内监听的端口：bridge 固定 5432；host 模式直接绑对外端口（.env 的 POSTGRES_PORT）
  local pg_port=5432
  if grep -qE '^COMPOSE_FILE=.*docker-compose\.host\.yml' .env; then
    pg_port="$(sed -n 's/^POSTGRES_PORT=//p' .env | tail -n 1 | tr -d '[:space:]')"
    pg_port="${pg_port:-5433}"
  fi
  say "校验内置 PostgreSQL 连接与密码…"
  for _ in $(seq 1 60); do
    docker compose exec -T postgres \
      pg_isready -U "${POSTGRES_USER:-realtalk}" -p "$pg_port" >/dev/null 2>&1 && break
    sleep 1
  done
  if docker compose exec -T postgres \
    sh -c "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -h 127.0.0.1 -p $pg_port -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -Atqc 'SELECT 1'" \
    2>/dev/null | grep -qx '1'; then
    say "${GREEN}✔ 内置 PostgreSQL 密码验证通过${RESET}"
    return 0
  fi
  echo
  say "⚠️  内置 PostgreSQL 密码验证失败，已停止后续初始化。"
  note "日志显示的是 postgres 服务名解析后的容器内部 IP，不是外部数据库配置。"
  note "最常见原因：数据目录已初始化，修改 POSTGRES_PASSWORD 不会修改库内旧密码。"
  note "请重新运行 setup.sh 并覆盖 .env；检测到旧数据目录时选择 keep 后填写原密码，"
  note "或确认不保留旧数据后选择 reset 重新初始化。"
  return 1
}

say "=============================================="
say " RealTalk 部署引导（可分布式拆机部署）"
say "=============================================="
echo

if [ -f .env ]; then
  load_previous_env .env
  ask "检测到已有 .env，是否覆盖重新生成？(yes/no)" "no"
  if [ "$REPLY_VALUE" != "yes" ]; then
    # 保留 .env 也要把完整部署跑完——尤其是【数据库供给(db_init)】这一步，
    # 否则只 docker compose up 起来的 API 会因「库未供给」fail-fast 退出。
    say "已保留现有 .env，按它重新部署…"
    CURRENT_MODE="$(sed -n 's/^DEPLOYMENT_MODE=//p' .env | tail -n 1 | tr -d '[:space:]')"
    # 兼容旧版本生成的 .env；新版本只写 DEPLOYMENT_MODE。
    [ -n "$CURRENT_MODE" ] || CURRENT_MODE="$(sed -n 's/^REALTALK_ENV=//p' .env | tail -n 1 | tr -d '[:space:]')"
    CURRENT_MODE="${CURRENT_MODE:-dev}"
    note "当前 .env 的部署模式：${CURRENT_MODE}（选择 no 不会重新询问或改写 prod/dev）。"
    command -v docker >/dev/null 2>&1 || { say "未检测到 docker，请安装后执行：docker compose up -d --build"; exit 1; }
    # 所有服务在主 compose 文件；起哪些服务由 .env 的 COMPOSE_PROFILES 决定。
    docker compose up -d --build --remove-orphans
    check_local_postgres_auth || exit 1
    if grep -qE '^COMPOSE_PROFILES=.*backend' .env; then
      say "供给数据库（建表 + 系统参数入库；幂等，可重复跑）…"
      if docker compose run --rm api python -m app.db_init; then
        say "${GREEN}✔ 数据库已供给${RESET}"
      else
        say "数据库供给失败，请重试：docker compose run --rm api python -m app.db_init"
      fi
    fi
    say "完成。常用命令：docker compose ps / logs -f api / down"
    exit 0
  fi
  cp .env ".env.bak.$(date +%Y%m%d%H%M%S)"
  note "旧配置已备份。"
fi

# ============ 第 1 步：选择本机要部署的应用 ============
say "[1] 选择本机要部署的应用（逗号分隔可多选；各应用可拆机独立部署）"
echo "    1) 后端 API"
echo "    2) 管理台（运营/财务/模型配置）"
echo "    3) 用户 Web 端（充值/会员/场景/录音上传）"
echo "    4) 本地实时语音模型服务器（ASR+TTS+LLM，OpenAI 兼容接口）"
echo "    5) Redis（采集暂存/缓存/实时上下文）"
echo "    6) PostgreSQL 数据库"
OLD_APPS="$(old_app_selection)"
ask "要部署哪些应用？" "${OLD_APPS:-1,2,3,5,6}"
SEL=",$REPLY_VALUE,"
DEPLOY_BACKEND=false; DEPLOY_ADMIN=false; DEPLOY_WEB=false; DEPLOY_SPEECH=false; DEPLOY_REDIS=false; DEPLOY_PG=false
[[ "$SEL" == *",1,"* ]] && DEPLOY_BACKEND=true
[[ "$SEL" == *",2,"* ]] && DEPLOY_ADMIN=true
[[ "$SEL" == *",3,"* ]] && DEPLOY_WEB=true
[[ "$SEL" == *",4,"* ]] && DEPLOY_SPEECH=true
[[ "$SEL" == *",5,"* ]] && DEPLOY_REDIS=true
[[ "$SEL" == *",6,"* ]] && DEPLOY_PG=true
$DEPLOY_BACKEND || $DEPLOY_ADMIN || $DEPLOY_WEB || $DEPLOY_SPEECH || $DEPLOY_REDIS || $DEPLOY_PG || { say "未选择任何应用，退出。"; exit 1; }

PROFILES=()
ENV_LINES=("# ===== 由 setup.sh 生成（$(date '+%Y-%m-%d %H:%M:%S')）=====")
ENV_LINES+=("COMPOSE_NETWORK_NAME=realtalk" "COMPOSE_SUBNET=172.28.0.0/16")

# ---- 网络模式（单一决策点）----
# 这里的选择决定后面各步写进 .env 的「本机服务」连接串形态：
#   bridge → 服务名（postgres:5432 / redis:6379 / api:8000，容器 DNS 解析）
#   host   → 127.0.0.1:对外端口（host 模式没有容器 DNS 与端口映射）
# 远程服务的连接串两种模式通用（本就填真实 IP，不受影响）。
# docker-compose.host.yml 只负责 network_mode 与端口绑定，不改写任何地址。
HOST_NET=false
HOST_NET_OLD="no"
[[ "${PREVIOUS_ENV[COMPOSE_FILE]:-}" == *docker-compose.host.yml* ]] && HOST_NET_OLD="yes"
echo
note "网络模式：bridge=默认（容器私网+端口映射）；host=容器直接用宿主网络栈。"
note "软路由/OpenWrt(iStoreOS) 常拦「docker→lan」转发——容器上得了外网、却到不了局域网"
note "其它主机（如局域网里的语音服务器）。这种环境请选 host 绕过转发限制。"
ask "使用 host 网络模式？(yes/no)" "$HOST_NET_OLD"
if [ "$REPLY_VALUE" = "yes" ]; then
  HOST_NET=true
  ENV_LINES+=("COMPOSE_FILE=docker-compose.yml:docker-compose.host.yml" "COMPOSE_PATH_SEPARATOR=:")
  note "host 模式：各服务直接绑定各自对外端口，同机服务间走 127.0.0.1。"
else
  note "容器内部网络固定为 172.28.0.0/16；对外服务仍通过宿主机端口映射访问。"
fi
# COMPOSE_FILE 由本步全权管理：切回 bridge 时不得从旧 .env 残留 host 配置
unset "PREVIOUS_ENV[COMPOSE_FILE]" "PREVIOUS_ENV[COMPOSE_PATH_SEPARATOR]" 2>/dev/null || true

API_UPSTREAM_DEFAULT="http://api:8000"

# ============ 第 2 步：PostgreSQL 数据库（菜单选 6：本机内置库，可独立部署） ============
# 数据库的“物理部署参数”（数据目录/密码/初始化）归属本步；
# 后端步只消费由此派生的 DATABASE_URL（本机同机→内部地址，未选→填远程）。
FRESH_DB=false          # 是否新建库：新库才需把模型/语音等参数首次入库（后端步用到）
PG_DEPLOYED_LOCAL=false
if $DEPLOY_PG; then
  echo; say "[2] PostgreSQL 数据库参数（本机内置库）"
  PROFILES+=("backend-db")
  PG_DEPLOYED_LOCAL=true
  ask_config POSTGRES_DATA_DIR "PostgreSQL 数据目录" "./data/postgres"
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
        # 必须先 down：仅 stop postgres 仍可能有 API 重连、挂载占用或孤儿容器。
        if command -v docker >/dev/null 2>&1; then
          note "正在 docker compose down，释放数据库挂载与全部相关容器…"
          docker compose down --remove-orphans
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
    ask_secret_default_config POSTGRES_PASSWORD "原 PostgreSQL 密码" "realtalk"
    PG_PW="$REPLY_VALUE"
  else
    ask_generated_secret_config POSTGRES_PASSWORD "PostgreSQL 密码（回车自动生成）" "$(rand 20)"
    PG_PW="$REPLY_VALUE"
    FRESH_DB=true   # 新初始化的内置库 → 需要把模型/语音等参数写入并落库
  fi

  note "内置 PostgreSQL 容器对外端口（拆机部署时供远程后端连接），默认不使用 5432（避免与宿主机已有库冲突）。"
  ask_config POSTGRES_PORT "PostgreSQL 对外端口" "5433"
  PG_PORT_VAL="$REPLY_VALUE"
  ENV_LINES+=("POSTGRES_PORT=$PG_PORT_VAL")

  # 写入完整连接串（compose 不支持嵌套变量插值，且需与内置库密码一致）；
  # 地址形态由前面的网络模式决定：bridge=服务名 postgres:5432，host=127.0.0.1:对外端口。
  if $HOST_NET; then
    PG_ADDR="127.0.0.1:${PG_PORT_VAL}"
  else
    PG_ADDR="postgres:5432"
  fi
  ENV_LINES+=(
    "POSTGRES_USER=realtalk"
    "POSTGRES_PASSWORD=$PG_PW"
    "POSTGRES_DB=realtalk"
    "DATABASE_URL=postgresql+psycopg://realtalk:${PG_PW}@${PG_ADDR}/realtalk?sslmode=disable"
  )
  if $HOST_NET; then
    note "host 模式：同机后端连接 ${PG_ADDR}（数据库直接绑定该宿主端口）。"
  else
    note "同机后端始终连接 postgres:5432；日志会显示其解析后的 172.28.x 容器内网 IP，这是正常现象。"
  fi
fi

# ============ 第 3 步：Redis（菜单选 5：本机内置 Redis，可独立部署） ============
# Redis 的“物理部署参数”（数据目录/对外端口）归属本步；后端步只消费 REDIS_URL。
REDIS_PORT_VAL=""
REDIS_DEPLOYED_LOCAL=false
if $DEPLOY_REDIS; then
  echo; say "[3] Redis 参数（本机内置）"
  PROFILES+=("backend-redis")
  REDIS_DEPLOYED_LOCAL=true
  note "对话采集分块暂存 / 实时语音上下文用 Redis（多活部署下本地文件会导致 chunk 落在不同机器上无法汇总）。"
  ask_config REDIS_DATA_DIR "Redis 数据目录" "./data/redis"
  ENV_LINES+=("REDIS_DATA_DIR=$REPLY_VALUE")
  note "内置 Redis 容器对外端口，默认不使用 6379（避免与宿主机已有 Redis 冲突）。"
  ask_config REDIS_PORT "Redis 对外端口" "6380"
  REDIS_PORT_VAL="$REPLY_VALUE"
  ENV_LINES+=("REDIS_PORT=$REDIS_PORT_VAL")
  # 地址形态由网络模式决定：bridge=服务名 redis:6379，host=127.0.0.1:对外端口
  if $HOST_NET; then
    ENV_LINES+=("REDIS_URL=redis://127.0.0.1:${REDIS_PORT_VAL}/0")
  else
    ENV_LINES+=("REDIS_URL=redis://redis:6379/0")   # 同机后端走内部 service 名 redis:6379
  fi
fi

# ============ 第 4 步：后端参数 ============
if $DEPLOY_BACKEND; then
  echo; say "[4] 后端 API 参数"
  PROFILES+=("backend")

  ask_config API_PORT "API 对外端口" "8000"
  ENV_LINES+=("API_PORT=$REPLY_VALUE")
  API_PORT="$REPLY_VALUE"
  # host 模式下同机前端走 127.0.0.1:API_PORT（无容器 DNS）；bridge 保持服务名 api:8000
  if $HOST_NET; then
    API_UPSTREAM_DEFAULT="http://127.0.0.1:${API_PORT}"
  fi

  # 数据库连接：本机装了 PostgreSQL(菜单6) 则连接串已由第2步写好；否则填远程库地址。
  if $PG_DEPLOYED_LOCAL; then
    note "数据库随菜单 6 在本机部署，连接串已按网络模式配置（bridge=postgres:5432 / host=127.0.0.1:对外端口）。"
  else
    echo
    note "本机未部署 PostgreSQL(菜单 6)：填写远程数据库连接串。"
    note "示例：postgresql+psycopg://user:pass@db.example.com:5432/realtalk?sslmode=require"
    ask_config DATABASE_URL "数据库连接串 DATABASE_URL" ""
    [ -n "$REPLY_VALUE" ] || { say "外部数据库必须填写连接串"; exit 1; }
    ENV_LINES+=("DATABASE_URL=$REPLY_VALUE")
  fi

  # Redis 连接：本机装了 Redis(菜单5) 则连接串已由第3步写好；否则填远程 Redis 地址。
  if $REDIS_DEPLOYED_LOCAL; then
    note "Redis 随菜单 5 在本机部署，连接串已按网络模式配置（bridge=redis:6379 / host=127.0.0.1:对外端口）。"
  else
    echo
    note "对话采集分块暂存必须使用 Redis（多活部署下本地文件会导致 chunk 落在不同机器上无法汇总）。"
    note "本机未部署 Redis(菜单 5)：填写远程 Redis 连接串。"
    note "示例：redis://:你的密码@redis.example.com:6379/0（走 TLS 用 rediss://）"
    ask_config REDIS_URL "Redis 连接串 REDIS_URL" ""
    [ -n "$REPLY_VALUE" ] || { say "Redis 是必选项，必须填写连接串"; exit 1; }
    ENV_LINES+=("REDIS_URL=$REPLY_VALUE")
  fi

  ask_generated_secret_config JWT_SECRET "JWT 密钥（回车自动生成强随机密钥）" "$(rand 48)"
  ENV_LINES+=("JWT_SECRET=$REPLY_VALUE")

  ask_config ADMIN_USERNAME "管理员用户名" "admin"
  ENV_LINES+=("ADMIN_USERNAME=$REPLY_VALUE")
  note "管理员初始密码默认自动生成强随机值（请记下，登录后可在管理台改密）。"
  ask_generated_secret_config ADMIN_PASSWORD "管理员初始密码（回车=自动生成）" "$(rand 16)"
  ADMIN_PW_VALUE="$REPLY_VALUE"
  ENV_LINES+=("ADMIN_PASSWORD=$ADMIN_PW_VALUE")

  # ---- 部署模式：一键决定所有「联调旁路」开关 ----
  echo
  note "部署模式（决定下列每节点联调开关，运行期只读 .env）："
  note "  prod 生产：关闭全部旁路——微信需真实登录、支付须验签到账、Apple 内购真校验(走正式端点)、"
  note "             ASR/TTS 未配置即报错、邮件按 SMTP 真发。正式上线必须 prod。"
  note "  dev 联调：任意设备直接登录、支付下单自动到账、内购校验旁路、ASR/TTS 未配置返回占位、"
  note "             邮件不外发、Apple/支付宝走沙箱。便于本地联调，切勿用于线上。"
  ask_config DEPLOYMENT_MODE "部署模式 (prod / dev)" "prod"
  DEPLOYMENT_MODE="$REPLY_VALUE"
  DEV=false; [ "$DEPLOYMENT_MODE" = "dev" ] && DEV=true

  # 以下「AI 模型 / 实时语音」属于保存在数据库（app_settings）的参数：
  # 仅在新建数据库时询问并写入（首次启动会落库）；连接已有库时库里已有，跳过询问，可在管理台改。
  if $FRESH_DB; then
    note "AI 模型可跳过，部署后在管理台「系统设置 → AI 模型对接」配置（推荐）。"
    ask_config AI_BASE_URL "AI Base URL（回车跳过）" ""
    AI_BASE_URL="$REPLY_VALUE"
    if [ -n "$AI_BASE_URL" ]; then
      ask_secret_config AI_API_KEY "AI API Key"; AI_KEY="$REPLY_VALUE"
      ask_config AI_MODEL "模型名称" "doubao-seed-1-6-251015"
      ENV_LINES+=("AI_BASE_URL=$AI_BASE_URL" "AI_API_KEY=$AI_KEY" "AI_MODEL=$REPLY_VALUE")
    else
      ENV_LINES+=("AI_BASE_URL=" "AI_API_KEY=" "AI_MODEL=")
    fi

    # 注：原「高级会员实时语音」独立配置（REALTIME_*）已下线——所有实时语音（含 GPT-Live 式全双工）
    # 统一走下面的 B 类对话语音模型一张卡，本地或 OpenAI 由地址决定，无需单独配置。

    # ==== 按功能归属分开配置模型（A/B 类，入库、管理台可改、现读生效） ====
    # A 场景生成（高级会员上传音频文件→场景）：ASR + 文字模型（文字模型槽位在管理台「模型」卡，可留空跟随对话模型）
    echo
    note "A · 场景生成 — 语音转写 ASR（上传音频文件→场景；可指本地语音服务器 http://<IP>:9100/v1 或云端）："
    ask_config SCENARIO_ASR_BASE_URL "A·ASR Base URL（留空=之后在管理台配）" ""; SASR_BASE="$REPLY_VALUE"
    SASR_KEY=""; SASR_MODEL="whisper-1"
    if [ -n "$SASR_BASE" ]; then
      ask_secret_config SCENARIO_ASR_API_KEY "A·ASR API Key（本地语音服务器可填 local）"; SASR_KEY="$REPLY_VALUE"
      ask_config SCENARIO_ASR_MODEL "A·ASR 模型名称" "whisper-1"; SASR_MODEL="$REPLY_VALUE"
    fi
    ENV_LINES+=("SCENARIO_ASR_BASE_URL=$SASR_BASE" "SCENARIO_ASR_API_KEY=$SASR_KEY" "SCENARIO_ASR_MODEL=$SASR_MODEL")
    # api 后端不内置任何语音引擎：全部走 A/B 配置的模型地址（本地语音服务器或云端）
    ENV_LINES+=("ASR_BASE_URL=" "ASR_API_KEY=" "ASR_MODEL=whisper-1" "ASR_DEV_MODE=$DEV")

    # B 对话（手动/沉浸式/私教）语音模型【一张卡】：一个地址派生 ASR/TTS/LLM/实时通道四个端点
    echo
    note "B · 对话语音模型（手动/沉浸式/私教）：本地语音服务器填 http://<IP>:9100/v1（Key=local），"
    note "或 OpenAI 填 https://api.openai.com/v1；转写/合成/对话/实时通道自动派生，无需分别配置。"
    ask_config CONV_VOICE_BASE_URL "B·语音模型 Base URL（留空=之后在管理台配）" ""; CV_BASE="$REPLY_VALUE"
    CV_KEY=""; CV_MODEL=""; CV_VOICE=""
    TTS_VOICES_VAL="alloy,ash,ballad,coral,echo,sage,shimmer,verse,marin,cedar"; TTS_DEFAULT_VOICE_VAL="marin"
    if [ -n "$CV_BASE" ]; then
      ask_secret_config CONV_VOICE_API_KEY "B·语音模型 API Key（本地填 local）"; CV_KEY="$REPLY_VALUE"
      ask_config CONV_VOICE_MODEL "B·实时模型名（OpenAI 如 gpt-realtime；本地留空）" ""; CV_MODEL="$REPLY_VALUE"
      case "$CV_BASE" in
        *openai*) ask_config CONV_VOICE_VOICE "B·默认音色" "marin"; CV_VOICE="$REPLY_VALUE" ;;
        *) note "本地 Qwen3-TTS 音色由后面的本地模型步骤统一选择，这里无需重复填写。"
           CV_VOICE=""
           TTS_VOICES_VAL="Aiden,Vivian,Serena,Uncle_Fu,Dylan,Eric,Ryan,Ono_Anna,Sohee"
           TTS_DEFAULT_VOICE_VAL="Aiden" ;;
      esac
    fi
    ENV_LINES+=("CONV_VOICE_BASE_URL=$CV_BASE" "CONV_VOICE_API_KEY=$CV_KEY" "CONV_VOICE_MODEL=$CV_MODEL" "CONV_VOICE_VOICE=$CV_VOICE")
    # 分端点计费单价（a=转写分/分钟、b=合成分/百万字符、d=实时通道分/分钟；c=token 单价在模型卡）
    ask_config ASR_PRICE_PER_MINUTE_CENTS "a·语音转写单价（分/分钟，0=不计费）" "0"; ENV_LINES+=("ASR_PRICE_PER_MINUTE_CENTS=$REPLY_VALUE")
    ask_config TTS_PRICE_PER_1M_CHARS_CENTS "b·语音合成单价（分/百万字符，0=不计费）" "0"; ENV_LINES+=("TTS_PRICE_PER_1M_CHARS_CENTS=$REPLY_VALUE")
    ask_config CONV_VOICE_PRICE_PER_MINUTE_CENTS "d·实时通道单价（分/分钟，0=不计费）" "0"; ENV_LINES+=("CONV_VOICE_PRICE_PER_MINUTE_CENTS=$REPLY_VALUE")
    # 通用旧键兜底（B 留空时回退；api 后端无内置引擎）
    ENV_LINES+=(
      "TTS_FORMAT=mp3" "TTS_DEV_MODE=$DEV"
      "TTS_BASE_URL=" "TTS_API_KEY=" "TTS_MODEL=tts-1"
      "TTS_VOICES=$TTS_VOICES_VAL" "TTS_DEFAULT_VOICE=$TTS_DEFAULT_VOICE_VAL"
    )

    note "额度参数已设为默认值（非会员每天 1000 token / 5 分钟录音，基础 12 万 / 高级 40 万），可在管理台「系统设置 → 额度」调整。"
  else
    note "连接已有数据库：AI 模型 / 实时语音 / ASR / TTS 等配置沿用库中已有值（如需修改请到管理台「系统设置」）。"
    # 已有库：A/B 模型配置沿用库中值（管理台可改）；这里只写通用兜底 env（api 后端无内置引擎）
    ENV_LINES+=(
      "ASR_BASE_URL=" "ASR_API_KEY=" "ASR_MODEL=whisper-1" "ASR_DEV_MODE=false"
      "TTS_FORMAT=mp3" "TTS_DEV_MODE=$DEV"
      "TTS_BASE_URL=" "TTS_API_KEY=" "TTS_MODEL=tts-1"
      "TTS_VOICES=alloy,ash,ballad,coral,echo,sage,shimmer,verse,marin,cedar" "TTS_DEFAULT_VOICE=marin"
    )
  fi

  ask_config WEB_CONCURRENCY "worker 进程数（建议=CPU核数）" "4"
  ENV_LINES+=("WEB_CONCURRENCY=$REPLY_VALUE")

  # ---- 语音文件服务器（高级会员上传录音）----
  note "高级会员上传的录音文件，会按【文件 MD5】路由到「可处理语音的服务器」，由其每小时定时任务转写并生成场景。"
  note "可处理语音的【服务器列表】在【管理台 → 系统设置 → 语音文件服务器】中配置（格式 ip:port;ip:port），未配置则语音上传直接报错。"
  ask "本机是否作为语音文件服务器（处理上传的录音文件）？(yes/no)" "$(old_yes_if_set VOICE_NODE_ADDR)"
  VOICE_NODE_ADDR_VAL=""
  if [ "$REPLY_VALUE" = "yes" ]; then
    note "请填【本机在语音服务器列表中的地址 ip:port】，其它服务器须能通过它访问本机；服务据此判断某文件是否归本机处理。"
    note "首次启动时本机地址会自动加入【管理台 → 系统设置 → 语音文件服务器】列表，之后可在管理台删除（删除后重启不会再自动加回）。"
    ask_config VOICE_NODE_ADDR "本机语音服务地址 VOICE_NODE_ADDR（如 192.168.6.3:8000；必填）" ""
    VOICE_NODE_ADDR_VAL="$REPLY_VALUE"
    [ -z "$VOICE_NODE_ADDR_VAL" ] && note "未填本机地址 → 本机不会注册为语音服务器，也不会自动加入列表。"
  fi
  ENV_LINES+=("VOICE_NODE_ADDR=$VOICE_NODE_ADDR_VAL")

  # ---- 采集功能：上传的真实对话录音存放目录（映射到容器 /app/uploads）----
  note "【采集】高级会员上传的真实对话录音存这里（转写后生成练习场景，3 天自动清理）；语音服务器尤其占空间，建议放数据盘。"
  note "注：场景对练时说的话不存这里——内存即时转写评分后立即丢弃，无需配置目录。"
  ask_config UPLOAD_DATA_DIR "采集录音上传目录" "./data/uploads"
  ENV_LINES+=("UPLOAD_DATA_DIR=$REPLY_VALUE")


  # ---- 微信登录（高级，可选）----
  echo
  note "微信登录：默认开发模拟模式（任意设备直接登录，便于联调）。"
  if $DEV; then REPLY_VALUE="no"; else ask "现在配置正式微信登录凭据吗？(yes/no)" "no"; fi
  if [ "$REPLY_VALUE" = "yes" ]; then
    ask_config WECHAT_APP_ID "移动应用 AppID（微信开放平台 · 移动应用）" ""
    WX_APPID="$REPLY_VALUE"
    ask_secret_config WECHAT_APP_SECRET "移动应用 AppSecret"; WX_SECRET="$REPLY_VALUE"
    ask_config WECHAT_WEB_APP_ID "网站应用 AppID（用于 Web 扫码登录，可留空）" ""
    WX_WEB_APPID="$REPLY_VALUE"
    WX_WEB_SECRET=""
    [ -n "$WX_WEB_APPID" ] && { ask_secret_config WECHAT_WEB_APP_SECRET "网站应用 AppSecret"; WX_WEB_SECRET="$REPLY_VALUE"; }
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
  if $DEV; then REPLY_VALUE="no"; else ask "现在配置正式支付参数吗？(yes/no)" "no"; fi
  PAY_DEV_CONFIRM=true
  WX_MCHID=""; WX_APIKEY=""; WX_NOTIFY=""; WX_SERIAL=""; WX_CERT=""; WX_MERCH_CERT=""; WX_MERCH_KEY=""
  ALI_APPID=""; ALI_PRIV=""; ALI_PUB=""; ALI_NOTIFY=""
  RECV_NAME="RealTalk"; WX_RECV=""; ALI_RECV=""
  if [ "$REPLY_VALUE" = "yes" ]; then
    PAY_DEV_CONFIRM=false
    ask_config PAYMENT_RECEIVER_NAME "收款主体名称（显示给用户）" "RealTalk"
    RECV_NAME="$REPLY_VALUE"
    note "支付回调必须验签后才入账（防伪造通知白嫖会员）。这些凭证也可稍后在管理台「支付验签配置」维护。"
    ask "配置微信支付商户？(yes/no)" "$(old_yes_if_set WECHAT_MCHID)"
    if [ "$REPLY_VALUE" = "yes" ]; then
      ask_config WECHAT_MCHID "微信支付商户号 MCHID" ""; WX_MCHID="$REPLY_VALUE"
      ask_secret_config WECHAT_API_KEY "微信支付 APIv3 密钥（回调验签解密用）"; WX_APIKEY="$REPLY_VALUE"
      ask_config WECHAT_CERT_SERIAL "微信平台证书序列号（回调验签用，可留空稍后在管理台填）" ""; WX_SERIAL="$REPLY_VALUE"
      ask "微信平台证书 PEM 文件路径（回调验签用，可留空稍后在管理台粘贴）" ""; WX_CERT_PATH="$REPLY_VALUE"
      if [ -n "$WX_CERT_PATH" ] && [ -f "$WX_CERT_PATH" ]; then
        # 多行 PEM → 字面 \n 单行写入 .env（后端 _multiline_env 还原）
        WX_CERT="$(sed ':a;N;$!ba;s/\n/\\n/g' "$WX_CERT_PATH")"
      fi
      ask "微信商户证书 apiclient_cert.pem 路径（下单签名用，可留空稍后在管理台粘贴）" ""; WX_MERCH_CERT_PATH="$REPLY_VALUE"
      if [ -n "$WX_MERCH_CERT_PATH" ] && [ -f "$WX_MERCH_CERT_PATH" ]; then
        WX_MERCH_CERT="$(sed ':a;N;$!ba;s/\n/\\n/g' "$WX_MERCH_CERT_PATH")"
      fi
      ask "微信商户私钥 apiclient_key.pem 路径（下单签名用，可留空稍后在管理台粘贴）" ""; WX_MERCH_KEY_PATH="$REPLY_VALUE"
      if [ -n "$WX_MERCH_KEY_PATH" ] && [ -f "$WX_MERCH_KEY_PATH" ]; then
        WX_MERCH_KEY="$(sed ':a;N;$!ba;s/\n/\\n/g' "$WX_MERCH_KEY_PATH")"
      fi
      ask "微信支付回调地址 NOTIFY_URL" "https://your-domain.com/payment/wechat/webhook"; WX_NOTIFY="$REPLY_VALUE"
    fi
    ask "配置支付宝当面付？(yes/no)" "$(old_yes_if_set ALIPAY_APP_ID)"
    if [ "$REPLY_VALUE" = "yes" ]; then
      ask_config ALIPAY_APP_ID "支付宝 AppID" ""; ALI_APPID="$REPLY_VALUE"
      ask "支付宝应用私钥 PEM 文件路径（下单签名用，可留空稍后在管理台粘贴）" ""; ALI_PRIV_PATH="$REPLY_VALUE"
      if [ -n "$ALI_PRIV_PATH" ] && [ -f "$ALI_PRIV_PATH" ]; then
        ALI_PRIV="$(sed ':a;N;$!ba;s/\n/\\n/g' "$ALI_PRIV_PATH")"
      fi
      ask_secret_config ALIPAY_PUBLIC_KEY "支付宝公钥"; ALI_PUB="$REPLY_VALUE"
      ask "支付宝回调地址 NOTIFY_URL" "https://your-domain.com/payment/alipay/webhook"; ALI_NOTIFY="$REPLY_VALUE"
    fi
    note "未接入官方支付时，可填个人收款码账号，用户转账后在管理台「充值订单」人工确认。"
    ask_config WECHAT_RECEIVER_ACCOUNT "微信收款账号/备注（可留空）" ""; WX_RECV="$REPLY_VALUE"
    ask_config ALIPAY_RECEIVER_ACCOUNT "支付宝收款账号（可留空）" ""; ALI_RECV="$REPLY_VALUE"
  fi

  # ---- 集成凭据：邮件 SMTP / Apple 内购（多活后端共用，入库；微信登录在上面已单独配过）----
  echo
  note "以下凭据多活后端共用，装库时入库（DB 为唯一来源）。可全部留空，稍后在管理台「集成凭据」填。"
  SMTP_HOST=""; SMTP_USER=""; SMTP_PW=""; SMTP_FROM_VAL="RealTalk <noreply@realtalk.local>"
  AP_PRODUCT="realtalk.pro.monthly"; AP_BUNDLE="com.realtalk.app"; AP_ISSUER=""; AP_KEYID=""; AP_PRIV=""
  if $DEV; then REPLY_VALUE="no"; else ask "现在配置集成凭据（邮件 SMTP / Apple 内购）吗？(yes/no)" "no"; fi
  if [ "$REPLY_VALUE" = "yes" ]; then
    ask "配置邮件 SMTP？(yes/no)" "$(old_yes_if_set SMTP_HOST)"
    if [ "$REPLY_VALUE" = "yes" ]; then
      ask_config SMTP_HOST "SMTP 主机" ""; SMTP_HOST="$REPLY_VALUE"
      ask_config SMTP_USERNAME "SMTP 用户名" ""; SMTP_USER="$REPLY_VALUE"
      ask_secret_config SMTP_PASSWORD "SMTP 密码"; SMTP_PW="$REPLY_VALUE"
      ask_config SMTP_FROM "发件人" "RealTalk <noreply@realtalk.local>"; SMTP_FROM_VAL="$REPLY_VALUE"
    fi
    ask "配置 Apple 内购服务端校验？(yes/no)" "$(old_yes_if_set APPLE_ISSUER_ID)"
    if [ "$REPLY_VALUE" = "yes" ]; then
      ask_config APPLE_PRODUCT_ID "product_id" "realtalk.pro.monthly"; AP_PRODUCT="$REPLY_VALUE"
      ask_config APPLE_BUNDLE_ID "bundle_id" "com.realtalk.app"; AP_BUNDLE="$REPLY_VALUE"
      ask_config APPLE_ISSUER_ID "issuer_id" ""; AP_ISSUER="$REPLY_VALUE"
      ask_config APPLE_KEY_ID "key_id" ""; AP_KEYID="$REPLY_VALUE"
      ask "私钥 .p8 文件路径（可留空稍后在管理台粘贴）" ""; AP_PRIV_PATH="$REPLY_VALUE"
      if [ -n "$AP_PRIV_PATH" ] && [ -f "$AP_PRIV_PATH" ]; then
        AP_PRIV="$(sed ':a;N;$!ba;s/\n/\\n/g' "$AP_PRIV_PATH")"
      fi
    fi
  fi

  # 仅开发环境、且未配 SMTP 时才返回联调验证码；生产环境绝不返回验证码。
  EMAIL_DEV="false"; [ "$DEV" = true ] && [ -z "$SMTP_HOST" ] && EMAIL_DEV="true"
  ENV_LINES+=(
    "REALTALK_REGION=prod"
    "DEPLOYMENT_MODE=$DEPLOYMENT_MODE"
    "AUDIO_MAX_BYTES=314572800"
    "AUDIO_MAX_SECONDS=21600"
    "# —— 每节点开关（按部署自标识 dev/prod；运行期只读 .env，不入库）——"
    "# —— 联调旁路开关：随上面「部署模式」prod=false / dev=true（运行期只读 .env）——"
    "APPLE_IAP_DEV_BYPASS=$DEV"
    "APPLE_USE_SANDBOX=$DEV"
    "ALIPAY_SANDBOX=$DEV"
    "# 邮箱注册默认关闭，仅微信认证；配了 SMTP 自动关开发模式以真正发信"
    "EMAIL_AUTH_ENABLED=false"
    "EMAIL_DEV_MODE=$EMAIL_DEV"
    "PAYMENT_DEV_AUTO_CONFIRM=$PAY_DEV_CONFIRM"
    "# —— 多活共用值（装库时入库，DB 为唯一来源；运行期只读 DB，可在管理台维护）——"
    "PAYMENT_RECEIVER_NAME=$RECV_NAME"
    "WECHAT_RECEIVER_ACCOUNT=$WX_RECV" "ALIPAY_RECEIVER_ACCOUNT=$ALI_RECV"
    "WECHAT_MCHID=$WX_MCHID" "WECHAT_API_KEY=$WX_APIKEY" "WECHAT_NOTIFY_URL=$WX_NOTIFY"
    "WECHAT_CERT_SERIAL=$WX_SERIAL" "WECHAT_PLATFORM_CERT=$WX_CERT"
    "WECHAT_MERCHANT_CERT=$WX_MERCH_CERT" "WECHAT_MERCHANT_KEY=$WX_MERCH_KEY"
    "ALIPAY_APP_ID=$ALI_APPID" "ALIPAY_MERCHANT_PRIVATE_KEY=$ALI_PRIV" "ALIPAY_PUBLIC_KEY=$ALI_PUB" "ALIPAY_NOTIFY_URL=$ALI_NOTIFY"
    "SMTP_HOST=$SMTP_HOST" "SMTP_USERNAME=$SMTP_USER" "SMTP_PASSWORD=$SMTP_PW" "SMTP_FROM=$SMTP_FROM_VAL"
    "APPLE_PRODUCT_ID=$AP_PRODUCT" "APPLE_BUNDLE_ID=$AP_BUNDLE"
    "APPLE_ISSUER_ID=$AP_ISSUER" "APPLE_KEY_ID=$AP_KEYID" "APPLE_PRIVATE_KEY=$AP_PRIV"
  )
fi

# ============ 第 5 步：管理台参数 ============
if $DEPLOY_ADMIN; then
  echo; say "[5] 管理台参数"
  PROFILES+=("admin")
  ask_config ADMIN_PORT "管理台对外端口" "8001"
  ADMIN_PORT="$REPLY_VALUE"
  ENV_LINES+=("ADMIN_PORT=$ADMIN_PORT")
  if $DEPLOY_BACKEND; then
    note "后端在同机部署，管理台自动走内部网络 $API_UPSTREAM_DEFAULT"
  else
    ask_config API_UPSTREAM "后端 API 地址（另一台机器）" "http://192.168.1.10:8000"
    API_UPSTREAM_DEFAULT="$REPLY_VALUE"
  fi
fi

# ============ 第 6 步：用户 Web 端参数 ============
if $DEPLOY_WEB; then
  echo; say "[6] 用户 Web 端参数"
  PROFILES+=("web")
  ask_config WEB_PORT "用户 Web 端对外端口" "8002"
  WEB_PORT="$REPLY_VALUE"
  ENV_LINES+=("WEB_PORT=$WEB_PORT")
  if ! $DEPLOY_BACKEND && ! $DEPLOY_ADMIN; then
    ask_config API_UPSTREAM "后端 API 地址（另一台机器）" "http://192.168.1.10:8000"
    API_UPSTREAM_DEFAULT="$REPLY_VALUE"
  fi
fi

# ============ 第 7 步：本地实时语音模型服务器（菜单选 4：ASR+TTS+LLM，OpenAI 兼容 API） ============
if $DEPLOY_SPEECH; then
  echo; say "[7] 本地实时语音模型服务器参数"
  PROFILES+=("speech")
  note "对外 4 个 OpenAI 兼容端点：/audio/transcriptions、/audio/speech、/chat/completions、WS /realtime；"
  note "api 后端在 A/B 配置里填本服务地址即可全量切换到本地模型。"
  note "REST（字幕/上传生成场景/手动朗读）：faster-whisper(ASR) + 同一 Qwen GGUF(LLM) + Qwen3-TTS。"
  note "实时 WS（沉浸/私教）：speech-to-speech 原生编排 Silero VAD → faster-whisper → 同一 Qwen GGUF → Qwen3-TTS。"
  note "无需 venv：全部依赖在一个 speech 容器内，9100 是唯一对外端口；S2S 内部端口不对外。"
  ask_config SPEECH_DEVICE "计算设备 (cpu/cuda)" "cpu";                      ENV_LINES+=("SPEECH_DEVICE=$REPLY_VALUE")
  ENV_LINES+=("SPEECH_LLAMA_CPU_PORTABLE=true")
  note "CPU 模式默认源码构建最保守 llama.cpp（关闭 AVX/F16C/AVX2/FMA），兼容旧 Xeon/NAS；构建会慢一些，但避免首次推理 exit 132。"
  ask_config SPEECH_ASR_MODEL "共享 faster-whisper ASR 模型大小（REST 与 S2S 使用同一份模型文件）(tiny/base/small/medium/large-v3)" "small"; ENV_LINES+=("SPEECH_ASR_MODEL=$REPLY_VALUE")
  note "LLM 用 GGUF 量化模型（默认 Qwen2.5-1.5B-Instruct Q4：CPU 可跑、指令遵循明显好于 0.5B；"
  note "机器很弱可换 0.5b 求快，机器强可换 3B/7B 求质量）。"
  ask_config SPEECH_LLM_REPO "共享 LLM GGUF 仓库（REST 与 S2S 共用同一 llama.cpp 实例）" "Qwen/Qwen2.5-1.5B-Instruct-GGUF"; ENV_LINES+=("SPEECH_LLM_REPO=$REPLY_VALUE")
  ask_config SPEECH_LLM_FILE "共享 LLM GGUF 文件名(或绝对路径)" "qwen2.5-1.5b-instruct-q4_k_m.gguf"; ENV_LINES+=("SPEECH_LLM_FILE=$REPLY_VALUE")
  ask_config SPEECH_REALTIME_ENGINE "实时 WS 引擎 (s2s=原生 speech-to-speech / legacy=旧实现回退)" "s2s"; SPEECH_RT_ENGINE="$REPLY_VALUE"; ENV_LINES+=("SPEECH_REALTIME_ENGINE=$REPLY_VALUE")
  note "CPU 推荐 0.6B Qwen3-TTS：比 1.7B 更省内存、首包更快；需要更细腻音色可改 1.7B（CPU 会更慢）。"
  ask_config SPEECH_TTS_MODEL "统一 Qwen3-TTS 模型（REST 与 realtime 共用配置）" "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"; ENV_LINES+=("SPEECH_TTS_MODEL=$REPLY_VALUE")
  ask_config SPEECH_TTS_SPEAKER "统一 Qwen3-TTS 默认音色（中文推荐 Vivian，英文推荐 Aiden）" "Aiden"; ENV_LINES+=("SPEECH_TTS_SPEAKER=$REPLY_VALUE")
  ask_config SPEECH_TTS_QUANT "Qwen3-TTS GGUF 量化（CPU 推荐 Q4_K_M）" "Q4_K_M"; ENV_LINES+=("SPEECH_TTS_QUANT=$REPLY_VALUE")
  note "下方目录统一保存 faster-whisper、GGUF LLM、Qwen3-TTS 和 HuggingFace 缓存。"
  ask_config SPEECH_MODELS_DIR "全部语音/文字模型保存目录（宿主机，建议大盘）" "./speech-models"; ENV_LINES+=("SPEECH_MODELS_DIR=$REPLY_VALUE")
  ask_config SPEECH_PORT "对外端口" "9100";                                  ENV_LINES+=("SPEECH_PORT=$REPLY_VALUE")
  SPEECH_PORT_VAL="$REPLY_VALUE"
  ask "用 HuggingFace 镜像站下模型？(yes=hf-mirror.com / no=官方直连)" "$( [ "${PREVIOUS_ENV[HF_ENDPOINT]:-}" = "https://hf-mirror.com" ] && echo yes || echo no )"
  if [ "$REPLY_VALUE" = "yes" ]; then
    ENV_LINES+=("HF_ENDPOINT=https://hf-mirror.com")
  else
    ENV_LINES+=("HF_ENDPOINT=")
  fi
  # legacy 实现才把短期实时上下文放 Redis；s2s 每次连接由 API 后端从数据库重新播种，
  # 不要求为了语音服务额外部署 Redis（项目的采集分块/后端 Redis 需求仍按前面菜单处理）。
  if [ "$SPEECH_RT_ENGINE" = "legacy" ]; then
    if $DEPLOY_REDIS; then
      if $HOST_NET; then
        note "legacy 实时上下文走本机 Redis 127.0.0.1:${REDIS_PORT_VAL}/1（与后端 /0 库隔离）。"
        ENV_LINES+=("SPEECH_REDIS_URL=redis://127.0.0.1:${REDIS_PORT_VAL}/1")
      else
        note "legacy 实时上下文走内部 Redis redis:6379/1（与后端 /0 库隔离）。"
        ENV_LINES+=("SPEECH_REDIS_URL=redis://redis:6379/1")
      fi
    else
      note "legacy 模式需远程 Redis（建议 /1 库与后端 /0 隔离）。"
      ask_config SPEECH_REDIS_URL "语音服务器 Redis 连接串 SPEECH_REDIS_URL" ""
      [ -n "$REPLY_VALUE" ] || { say "legacy 实时上下文需要 Redis，必须填写连接串"; exit 1; }
      ENV_LINES+=("SPEECH_REDIS_URL=$REPLY_VALUE")
    fi
  else
    note "s2s 实时模式不要求语音服务 Redis：断线后 API 后端会从数据库历史重新播种上下文。"
  fi
fi

ENV_LINES+=("API_UPSTREAM=$API_UPSTREAM_DEFAULT")
IFS=,; ENV_LINES+=("COMPOSE_PROFILES=${PROFILES[*]}"); unset IFS

# ============ 写入 .env 并部署 ============
echo; say "[8] 生成 .env（应用: ${PROFILES[*]}）"
# 对于因组件/模式选择而未再次询问的旧键，原样保留；本轮确认或生成的键优先。
declare -A GENERATED_ENV_KEYS=()
for line in "${ENV_LINES[@]}"; do
  [[ "$line" == \#* || "$line" != *=* ]] && continue
  GENERATED_ENV_KEYS["${line%%=*}"]=1
done
for key in "${!PREVIOUS_ENV[@]}"; do
  [[ "$key" = "REALTALK_ENV" || -n ${GENERATED_ENV_KEYS[$key]+present} ]] && continue
  ENV_LINES+=("$key=${PREVIOUS_ENV[$key]}")
done
printf '%s\n' "${ENV_LINES[@]}" > .env
say ".env 已生成。"

echo
ask "是否立即构建并启动？(yes/no)" "yes"
if [ "$REPLY_VALUE" = "yes" ]; then
  command -v docker >/dev/null 2>&1 || { say "未检测到 docker，请安装后执行：docker compose up -d --build"; exit 1; }
  # 所有服务在主 compose 文件，起哪些服务由 COMPOSE_PROFILES 决定（speech 服务带 profile）。
  docker compose up -d --build --remove-orphans
  check_local_postgres_auth || exit 1
  if $DEPLOY_BACKEND; then
    # 数据库「供给」一次：建表 + 把系统参数入库（API 启动只读已供给的库，不自己建表/播种，多后端安全）。
    # 系统参数初始值取自本次 .env，入库后即以 DB 为唯一来源；之后可从 .env 删除这些 DB 参数行（运行期不再读）。
    say "初始化数据库（建表 + 系统参数入库，仅一次）…"
    if docker compose run --rm api python -m app.db_init; then
      say "${GREEN}✔ 数据库已初始化${RESET}"
    else
      say "数据库初始化失败，请检查后重试：docker compose run --rm api python -m app.db_init"
    fi
    say "等待 API 就绪…（选了本地 ASR/TTS 时，首次启动会预拉模型，可能需要几分钟）"
    for _ in $(seq 1 90); do   # 最长约 3 分钟，给首次预拉本地模型留时间
      curl -fs "http://127.0.0.1:${API_PORT:-8000}/health" >/dev/null 2>&1 && break
      sleep 2
    done
    curl -fs "http://127.0.0.1:${API_PORT:-8000}/health" >/dev/null 2>&1 \
      && say "${GREEN}✔ API 已就绪${RESET}" \
      || say "API 尚未就绪（可能仍在下载本地模型）：docker compose logs -f api 查看进度"
  fi
  if $DEPLOY_SPEECH; then
    say "等待统一语音模型容器就绪…（首次启动会下载 Whisper/GGUF/Qwen3-TTS）"
    for _ in $(seq 1 600); do
      curl -fs "http://127.0.0.1:${SPEECH_PORT_VAL:-9100}/health" >/dev/null 2>&1 && break
      sleep 2
    done
    if curl -fs "http://127.0.0.1:${SPEECH_PORT_VAL:-9100}/health" >/dev/null 2>&1; then
      say "${GREEN}✔ 统一 speech 容器及原生 /v1/realtime 已就绪，正在验证共享 LLM 首次推理…${RESET}"
      if curl -fsS --max-time 300 -H 'Content-Type: application/json' \
        -d '{"model":"local","messages":[{"role":"user","content":"Reply OK"}],"max_tokens":8}' \
        "http://127.0.0.1:${SPEECH_PORT_VAL:-9100}/v1/chat/completions" >/dev/null; then
        say "${GREEN}✔ Whisper / Qwen LLM / Qwen3-TTS 服务及 LLM 推理验证通过${RESET}"
      else
        say "本地 LLM 推理验证失败：docker compose logs --tail=200 speech"
      fi
    else
      say "本地语音模型尚未就绪：docker compose logs -f speech"
    fi
  fi
fi

echo
say "=============================================="
say " 部署完成，本机入口："
say "=============================================="
$DEPLOY_BACKEND && echo "  后端 API：    http://<本机IP>:${API_PORT:-8000}  （App 服务地址指向这里）"
if $DEPLOY_SPEECH; then
  echo "  本地语音模型：http://<本机IP>:${SPEECH_PORT_VAL:-9100}/v1  （OpenAI 兼容 API）"
  echo
  say "本地语音模型 API 调用方式："
  note "语音→文字:  curl -F file=@a.wav -F language=en http://<IP>:${SPEECH_PORT_VAL:-9100}/v1/audio/transcriptions"
  note "文字→语音:  POST /v1/audio/speech  {\"input\":\"Hello 你好\"}  → WAV（中英混读）"
  note "文字对话:   POST /v1/chat/completions  （OpenAI 消息格式）"
  note "实时通道:   WS /v1/realtime?session=<id>  speech-to-speech 原生流式 VAD/ASR/LLM/Qwen3-TTS（LLM 与 REST 共用 GGUF）"
  say "管理台「系统设置 → 模型中心」本地模型填写（同一服务地址按文字/ASR/语音三个子区保存）："
  note "AI 模型对接：服务商=自定义（OpenAI 兼容）；Base URL=http://<IP>:${SPEECH_PORT_VAL:-9100}/v1（不要追加 /chat/completions）；模型名称=local；API Key=local。"
  note "AI 参数：CPU 普通超时建议 120 秒（GPU 可 30 秒），长任务 1800 秒；max_tokens 可先用 4096/16384；本地运行的输入/输出价格填 0。"
  note "场景生成 Base URL / 模型 / API Key：留空即跟随上方 local；如本地小模型生成场景质量不足，再单独填云端强模型。"
  note "A·场景生成 ASR：Base URL=http://<IP>:${SPEECH_PORT_VAL:-9100}/v1；模型=whisper-1；API Key=local；转写单价=0。"
  note "B·对话语音模型：Base URL=http://<IP>:${SPEECH_PORT_VAL:-9100}/v1；实时模型名留空；API Key=local；默认音色填上面选择的 Qwen3 音色；合成/实时单价=0。"
  note "A 是上传音频生成场景所用 ASR，B 是 App 手动/沉浸/私教的语音通道，文字模型是文字推理；职责不同，但本地部署时都指向同一 9100 服务。"
  note "资源复用：单个 speech 容器、单个模型卷、同一 GGUF LLM；REST 与实时统一 Qwen3-TTS 模型和音色配置。"
  note "详细文档：speechserver/README.md；首次启动会下载模型（受限网络在 .env 加 HF_ENDPOINT=https://hf-mirror.com）"
fi
if $DEPLOY_PG; then
  echo "  PostgreSQL：  <本机IP>:${PG_PORT_VAL:-5433}  （内置库，不建议暴露公网）"
  note "远程机器连接串（后端 API 拆机部署时填 DATABASE_URL）："
  note "  postgresql+psycopg://realtalk:${PG_PW}@<本机IP>:${PG_PORT_VAL:-5433}/realtalk?sslmode=disable"
fi
if $DEPLOY_REDIS; then
  echo "  Redis 对外：  <本机IP>:${REDIS_PORT_VAL:-6380}  （内置 Redis，不建议暴露公网）"
  note "远程机器连接串：后端 API 填 REDIS_URL=redis://<本机IP>:${REDIS_PORT_VAL:-6380}/0；"
  note "  语音服务器实时上下文填 SPEECH_REDIS_URL=redis://<本机IP>:${REDIS_PORT_VAL:-6380}/1"
fi
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
