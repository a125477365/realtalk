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
