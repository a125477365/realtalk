# RealTalk 安装指南

本文档覆盖后端（Docker / 非 Docker）、数据库配置，以及 iOS 前端 App 的安装与运行。

---

## 0. 一键安装（推荐）

```bash
cd realtalk/realtalkwork
bash setup.sh
```

引导流程：**先多选要部署的应用**（后端 API / 管理台 / 用户 Web 端），再**逐应用设置参数**
（后端含数据库选择：内置 PostgreSQL 容器或外部数据库连接串），最后一键容器化部署。

支持分布式拆机部署：每台机器各自运行 `bash setup.sh`，只勾选该机的应用并填写后端 API
地址即可（前端容器通过 `API_UPSTREAM` 环境变量指向远端后端）。也可手动指定：

```bash
# 机器 A：后端 + 内置数据库
COMPOSE_PROFILES=backend,backend-db docker compose up -d --build
# 机器 B：仅管理台 + 用户 Web 端，后端在机器 A
COMPOSE_PROFILES=admin,web API_UPSTREAM=http://<机器A>:8000 docker compose up -d --build
```

完成后：

| 入口 | 地址 | 说明 |
|------|------|------|
| 管理台 | `http://<服务器IP>:8001` | 默认账号见安装时设置，登录后请立即改密 |
| 用户 Web 端 | `http://<服务器IP>:8002` | 微信登录（与 App 同账号）、充值、买会员、看场景、高级会员上传录音 |
| API | `http://<服务器IP>:8000` | iOS / Android App 的服务地址指向这里 |

管理台功能速览：
- **数据概览**：收入 / AI 支出 / 毛利 / 新增用户 / 在线用户 / 练习量多维统计与近 14/30/90 天趋势图
- **用户管理**：搜索、查看明细（用量/账单/订单）、调余额、封禁
- **充值订单**：全部订单查询；个人收款码模式下在此「确认到账」人工入账
- **管理员管理**：多管理员 + 角色（超管/管理员/运维）
- **Token 用量**：按用户排序的当日/周期 token 用量，超量/接近上限自动标红标黄
- **系统设置**：AI 模型对接（保存即生效，可测试连接）、会员套餐价格（6 档）、每日 token 限额、ASR 语音转写配置

会员体系：新用户注册自动获得 30 天基础会员试用；基础会员可用全部 App 功能，高级会员
额外支持在 App/Web 上传最长 6 小时（300MB）录音文件自动转写生成场景；所有会员受每日
token 限额约束，超限当天暂停 AI 功能（非 AI 功能不受影响）。

---

## 1. 环境要求

- Python >= 3.12（后端）
- Docker & Docker Compose（容器化部署）
- Xcode 15+（iOS 前端，macOS 宿主）
- macOS（用于真机调试和 iOS 构建）

---

## 2. 后端：非 Docker 安装

适用场景：本地开发、直接运行 FastAPI 服务。

### 2.1 克隆仓库

```bash
git clone https://github.com/a125477365/realtalk.git
cd realtalk/realtalkwork
```

### 2.2 创建虚拟环境

```bash
python3 -m venv .venv
source .venv/bin/activate  # macOS / Linux
# .venv\Scripts\activate   # Windows
```

### 2.3 安装依赖

```bash
pip install -r requirements.txt
```

依赖说明（`requirements.txt`）：
- `fastapi` + `uvicorn[standard]`：Web 服务
- `httpx`：HTTP 客户端（微信、模型调用）
- `PyJWT[crypto]`：JWT 认证
- `SQLAlchemy`：ORM
- `psycopg[binary]`：PostgreSQL 驱动（生产可选）

### 2.4 配置环境变量

```bash
cp .env.example .env
```

编辑 `.env`，必填项：

```env
# 数据库（非 Docker 本地开发默认 SQLite）
REALTALK_DB=./realtalk.sqlite3

# JWT
JWT_SECRET=替换为一个长随机字符串
TOKEN_TTL_HOURS=720

# 数据保留
RETENTION_DAYS=3
HISTORY_RETENTION_DAYS=90

# 开发开关
REQUIRE_PRO_FOR_AI=false
EMAIL_DEV_MODE=true
PAYMENT_DEV_AUTO_CONFIRM=true
WECHAT_AUTH_DEV_MODE=true
APPLE_IAP_DEV_BYPASS=true

# 生产环境 Apple IAP 验证（上线前必须配置）
# APPLE_ISSUER_ID=...
# APPLE_KEY_ID=...
# APPLE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
```

可选模型配置（任一即可）：

```env
# 方式 A：任意 OpenAI 兼容服务
AI_API_KEY=sk-...
AI_BASE_URL=https://api.openai.com/v1
AI_MODEL=gpt-4o-mini

# 方式 B：火山方舟（优先级低于 AI_*，未配置 AI_* 时生效）
# ARK_API_KEY=...
# ARK_BASE_URL=https://ark.cn-beijing.volces.com/api/v3
# ARK_MODEL=doubao-seed-1-6-251015
```

生产环境若使用 PostgreSQL 协议数据库，改 `DATABASE_URL`：

```env
DATABASE_URL=postgresql+psycopg://app_user:password@db.example.com:5432/realtalk?sslmode=require
```

此时 `REALTALK_DB` 会被忽略。

### 2.5 启动服务

```bash
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

验证：

```bash
curl http://127.0.0.1:8000/health
# 返回 {"status":"ok", "database":"sqlite", "region":"local", ...}
```

### 2.6 数据目录

- 默认 SQLite 文件：`realtalkwork/realtalk.sqlite3`（自动创建）
- 生产环境使用 PostgreSQL，数据存在远端数据库集群

---

## 3. 后端：Docker 安装

适用场景：生产部署、多中心部署、与数据库一起拉起。

### 3.1 构建镜像

```bash
cd realtalk/realtalkwork
docker build -t realtalk-api:latest .
```

Dockerfile 基础镜像：`python:3.12-slim`

### 3.2 快速启动（含 PostgreSQL 与管理台）

项目已提供 `docker-compose.yml`，一键启动 API + PostgreSQL + 管理台：

```bash
cp .env.example .env   # 或运行 bash setup.sh 交互式生成
docker compose up -d --build
```

服务说明：

| 服务 | 端口（可在 .env 改） | 说明 |
|------|------|------|
| api | 8000 | FastAPI 服务 |
| admin-frontend | 8001 | 管理台（nginx 同源代理 API，无跨域问题） |
| postgres | 内部 | 数据持久化在 `POSTGRES_DATA_DIR`（默认 `./data/postgres`） |

健康检查：
- `GET http://localhost:8000/health`：存活检查
- `GET http://localhost:8000/ready`：数据库连通检查

### 3.3 环境变量配置

Compose 从 `.env` 读取配置，常用项：

```env
API_PORT=8000            # API 对外端口
ADMIN_PORT=8001          # 管理台对外端口
POSTGRES_PASSWORD=...    # 数据库密码
POSTGRES_DATA_DIR=./data/postgres
JWT_SECRET=...           # 强随机字符串
ADMIN_USERNAME=admin     # 首次启动自动创建的超级管理员
ADMIN_PASSWORD=...
```

如需使用外部 PostgreSQL / YugabyteDB / 托管数据库，直接给 `api` 服务设置 `DATABASE_URL` 并删除 Compose 中的 `postgres` 服务。

### 3.4 多中心部署

- 每个区域启动一个 API 容器，设置不同 `REALTALK_REGION`
- 所有容器连接同一个分布式数据库集群
- 前端通过负载均衡或 DNS 轮询访问不同区域的 API

### 3.5 查看日志

```bash
docker compose logs -f api
```

### 3.6 停止服务

```bash
docker compose down
# 数据库数据在宿主机目录（默认 ./data/postgres），down 不会删除
```

---

## 4. 数据库配置

### 4.1 开发环境：SQLite（默认）

无需额外安装。启动后自动创建 `realtalk.sqlite3` 文件，包含以下表：

- `users`：用户信息、套餐、余额
- `transcripts`：对话文本（3 天自动过期）
- `sessions`：训练会话
- `scenarios`：英语场景
- `roleplay_sessions` / `roleplay_messages`：角色扮演
- `practice_results`：练习结果
- `email_verification_codes`：邮箱验证码（当前禁用）
- `billing_ledger`：账单流水
- `payment_orders`：充值订单

### 4.2 生产环境：PostgreSQL 协议数据库

支持任意兼容 PostgreSQL 协议的数据库，包括：
- PostgreSQL
- CockroachDB
- YugabyteDB
- 托管 PostgreSQL（如 AWS RDS、Supabase、Neon 等）

配置方式：

```env
DATABASE_URL=postgresql+psycopg://user:password@host:port/realtalk?sslmode=require
```

参数说明：
- `user` / `password`：数据库账号
- `host` / `port`：数据库地址
- `realtalk`：数据库名（需预先创建）
- `sslmode`：生产环境建议 `require` 或 `verify-full`

首次启动后，ORM 会自动执行建表（`metadata.create_all`）。

---

## 5. iOS 前端 App 安装与运行

### 5.1 环境要求

- macOS 13+
- Xcode 15+
- iOS 17+ 模拟器或真机

### 5.2 打开项目

```bash
open realtalk/realtalk.xcodeproj
```

或在 Xcode 中通过 File → Open 选择 `realtalk.xcodeproj`。

### 5.3 配置后端地址

打开 `realtalk/realtalk/AppConfig.swift`，修改 `apiBaseURL`：

```swift
enum AppConfig {
    // 本地开发（模拟器）
    static let apiBaseURL = URL(string: "http://127.0.0.1:8000")!

    // 局域网真机调试（示例）
    // static let apiBaseURL = URL(string: "http://192.168.1.100:8000")!

    static let subscriptionProductID = "realtalk.pro.monthly"
    static let localRetentionDays = 3
}
```

真机调试时：
1. 确保 Mac 与 iPhone 在同一 Wi-Fi
2. 将 `apiBaseURL` 改为 Mac 的局域网 IP
3. 在 macOS 防火墙中放行 8000 端口（或关闭防火墙调试）

### 5.4 签名与运行

1. 在 Xcode 中选择目标设备（模拟器或真机）
2. 点击 Signing & Capabilities，选择你的 Team
3. 点击 Run（或 Cmd + R）

### 5.5 功能验证

App 启动后：
- 登录页会自动使用微信授权（开发模式为模拟登录）
- 主页可上传/查询对话文本
- 训练、场景生成、角色扮演功能需要后端模型配置，且用户为 `pro` 套餐

---

## 6. 常见问题

### 6.1 后端启动报错 `No module named 'app'`

确保在 `realtalkwork` 目录下运行：

```bash
cd realtalk/realtalkwork
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### 6.2 iOS 真机访问不到后端

- 检查 Mac 防火墙设置
- 确认 `AppConfig.swift` 中的 IP 是 Mac 的局域网 IP，不是 `127.0.0.1`
- 在终端运行 `ifconfig | grep "inet "` 查看 IP

### 6.3 Docker 下数据库连接失败

- 确认 `postgres` 服务已 healthy：
  ```bash
  docker compose ps
  docker compose logs postgres
  ```
- 检查 `DATABASE_URL` 中的主机名是否为服务名 `postgres`

### 6.4 用户认证说明（防薅羊毛）

- 用户端（App + Web）统一**微信认证**，新用户首次登录自动注册并发放试用；一个微信
  openid 只能领取一次试用，杜绝垃圾邮箱批量注册薅取免费额度。
- Web 扫码登录需在微信开放平台创建「网站应用」，将 `WECHAT_WEB_APP_ID/SECRET` 写入
  `.env`（与移动应用的 `WECHAT_APP_ID/SECRET` 是两套凭据）。
- 如确需邮箱注册，设 `EMAIL_AUTH_ENABLED=true`（默认关闭）。

### 6.5 生产环境微信 / 支付不生效

- 开发环境默认 `WECHAT_AUTH_DEV_MODE=true` 和 `PAYMENT_DEV_AUTO_CONFIRM=true`，不会真正调用微信/支付宝接口
- 生产环境必须关闭这两个开关，并填写真实的 `WECHAT_APP_ID`、`WECHAT_APP_SECRET`、支付 URL

---

## 7. 目录结构

```
realtalk/
├── realtalk/                 # iOS 前端（SwiftUI）
│   ├── realtalk/
│   │   ├── AppConfig.swift
│   │   ├── Models/
│   │   ├── Services/
│   │   ├── ViewModels/
│   │   └── Views/
│   └── realtalk.xcodeproj/
└── realtalkwork/             # 后端（FastAPI）
    ├── app/
    │   ├── main.py
    │   ├── auth.py
    │   ├── billing.py
    │   ├── storage.py
    │   ├── ark_client.py
    │   └── settings.py
    ├── docs/
    ├── Dockerfile
    ├── docker-compose.yml
    ├── requirements.txt
    └── INSTALL.md            # 本文档
```
