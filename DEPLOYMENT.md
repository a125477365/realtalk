# RealTalk 部署指南

## 1. 服务端部署

### 1.1 环境要求
- Docker 20.10+, Docker Compose v2+
- Python >= 3.12（仅本地 venv 需要）
- 生产环境数据库: postgres:15-alpine

### 1.2 克隆仓库
```bash
git clone https://github.com/a125477365/realtalk.git
cd realtalk/realtalkwork
```

### 1.3 环境变量配置

推荐使用交互式引导（逐项解释每个后台参数并自动生成 `.env`，可直接启动）：
```bash
bash setup.sh
```

或手动配置：
```bash
cp .env.example .env
```
必填项: JWT_SECRET、ADMIN_USERNAME/ADMIN_PASSWORD。AI 模型可在 `.env` 配置（AI_BASE_URL + AI_API_KEY + AI_MODEL），也可以部署后在管理台「系统设置 → AI 模型对接」中随时配置/切换（管理台配置优先生效）。生产接入微信登录需 WECHAT_APP_ID + WECHAT_APP_SECRET。

### 1.4 部署方式 A：Docker Compose（推荐）
```bash
docker compose down 2>/dev/null || true
docker compose build
docker compose up -d
```

### 1.5 部署方式 B：本地 venv（开发）
```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### 1.6 验证
```bash
curl -s http://localhost:8000/health   # 存活
curl -s http://localhost:8000/ready    # 数据库连通
```

### 1.7 采集分块暂存 Redis（可选，多节点必配）

对话采集分块是「攒齐即删」的短命数据，用 Redis 暂存（带 TTL 自动回收、用完即删、不写主库、跨节点共享）。`setup.sh` 会询问：内置 Redis 容器 / 远程 Redis / 不用（回退本地文件）。手动配置则在 `.env` 设 `REDIS_URL`（如 `redis://redis:6379/0`）。**单机可不配（自动回退本地文件）；多节点部署务必配同一个 Redis**，否则各节点的分块无法汇总。

### 1.8 安全清单（上线前必读）

**代码层已内置（无需额外操作）：**
- 同账号单设备登录：新设备登录顶掉旧设备，旧端自动退出需重新授权。
- 会员鉴权与到期在服务端强制：未付费/过期/非会员无法使用会员功能，客户端篡改也绕不过。
- 强 JWT 密钥：未配 `JWT_SECRET` 时自动落到持久化随机密钥，杜绝弱默认值。
- 接口限流：认证类防撞库、其余防洪泛（应用内兜底，单机粒度）。
- 启动告警：检测到危险开发旁路 / 弱配置会在日志醒目提示。

**`.env` 上线前必须确认（`setup.sh` 选择"正式"时已自动设为 false）：**
```
PAYMENT_DEV_AUTO_CONFIRM=false   # 否则用户不付款也能确认到账
WECHAT_AUTH_DEV_MODE=false       # 否则任意设备可直登，未校验真实身份
APPLE_IAP_DEV_BYPASS=false       # 否则内购校验被绕过
EMAIL_DEV_MODE=false             # 若启用邮箱注册
JWT_SECRET=<长随机串>            # 多节点共享同一值
ADMIN_PASSWORD=<强密码>          # 不要用默认值
```

**基础设施 / 平台层（代码无法代办，运维必做）：**
- **HTTPS/TLS**：API、管理台、Web 前挂反向代理（Nginx/Caddy）启用证书；App 只连 `https://`，可做证书绑定（pinning）。
- **网络隔离**：数据库、Redis 不暴露公网；只放行必要端口（API/管理台/Web）。
- **抗 DDoS / WAF**：在 CDN 或网关层做（应用内限流仅兜底）。
- **客户端防篡改**：接 iOS App Attest / Android Play Integrity，在登录与付款接口校验设备完整性，防止破解版/模拟器伪造请求。
- **密钥与备份**：`.env`、`.jwt_secret.key`、数据库定期备份并妥善保管，绝不入库（已在 `.gitignore`）。

---

## 2. iOS 客户端部署

### 2.1 环境要求
- macOS 13+, Xcode 15+, iOS 17+

### 2.2 克隆仓库
```bash
git clone https://github.com/a125477365/realtalk.git
```

### 2.3 配置后端地址
打开 `realtalk/realtalk/AppConfig.swift`，修改 `apiBaseURL`:
- 模拟器: `http://127.0.0.1:8000`
- 真机: `http://<Mac局域网IP>:8000`

### 2.4 签名与运行
1. 打开 `realtalk.xcodeproj`
2. 选择 Team，点击 Run

---

## 3. Git 工作流

```bash
git add -A
git commit -m "feat: 描述"
git push origin main
```

服务端更新:
```bash
git pull origin main && docker compose build && docker compose up -d
```

> `.env` 不纳入 Git，需手动配置。
