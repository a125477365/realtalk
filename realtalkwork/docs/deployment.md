# RealTalk 容器化和多中心部署

## 字段检查结论

接口字段采用 snake_case，iOS 端通过 `CodingKeys` 映射到 Swift 的 camelCase，当前主链路字段已对齐：

- 登录：`token`、`user.id`、`user.login_identifier`、`display_name`、`avatar_url`、`plan`、`balance_cents`、`created_at`
- 转写：`items[].id`、`timestamp`、`text`，后端只保存文字，不保存音频
- 场景：`scene_id`、`roles[].is_user_candidate`、`lines[].target_role`、`source_text`、`english`
- 角色扮演：`session_id`、`selected_role`、`ai_role`、`next_line`、`latest_feedback`
- 账单：`amount_cents`、`balance_after_cents`、`payment_url`、`qr_code_text`

表字段也已覆盖当前业务。用户登录标识字段是 `users.login_identifier`，微信用户格式为 `wechat:<openid>`。真实微信身份字段是 `users.wechat_openid`。

## 后台容器化

后端是无状态 FastAPI 服务，可以横向扩容。构建镜像：

```bash
cd /Volumes/istore/Public/code/realtalk/realtalkwork
docker build -t realtalk-api:latest .
```

本地带 CockroachDB 启动：

```bash
docker compose up --build
```

健康检查：

```bash
curl http://127.0.0.1:8000/health
curl http://127.0.0.1:8000/ready
```

`/health` 用于进程存活检查；`/ready` 会连接数据库，适合负载均衡健康探测。

## 分布式数据库

开发默认 SQLite：

```env
REALTALK_DB=./realtalk.sqlite3
```

生产使用 `DATABASE_URL` 连接 PostgreSQL 协议数据库。推荐两类成熟方案：

- CockroachDB：分布式 SQL、多副本 Raft 同步、跨区域 survivability，适合多中心强一致写入。
- YugabyteDB：PostgreSQL 协议、多副本同步复制、跨区域部署，适合云原生分布式数据库场景。

示例：

```env
DATABASE_URL=postgresql+psycopg://app_user:password@db.example.com:26257/realtalk?sslmode=require
REALTALK_REGION=cn-shanghai-1
```

实时同步由数据库集群负责，API 容器不在本地保存状态。多中心部署时，每个区域运行同一镜像，并连接同一个多区域数据库集群或就近网关。

## Kubernetes

示例清单在 `deploy/k8s/`，包含两部分：

- `realtalk-api.yaml`：API Deployment（3 副本）+ Service
- `redis.yaml`：Redis StatefulSet（1 Master + 2 Replica）+ 3 个 Service
- `admin-frontend.yaml`：管理台 Deployment（1 副本）+ Service
- `web-frontend.yaml`：用户 Web 端 Deployment（1 副本）+ Service

### Redis 主从架构

```
redis-0 (Master)  ← 读写，API 容器通过 redis-master Service 连接
redis-1 (Replica) ← 只读，自动从 Master 同步
redis-2 (Replica) ← 只读，自动从 Master 同步
```

StatefulSet 按序号分配角色：`redis-0` 为 Master，其余为 Replica（通过 initContainer 写入 `replicaof` 配置）。数据持久化到 PVC（每 Pod 1Gi）。Master 故障时需手动提升 Replica 或部署 Redis Sentinel 自动故障转移。

### 部署步骤

```bash
# 1. 先部署 Redis
kubectl apply -f deploy/k8s/redis.yaml
kubectl rollout status statefulset/redis

# 2. 创建 Secret（敏感配置）和 ConfigMap（非敏感配置）
#    ⚠️ 替换所有 replace-with-* 占位符，否则对应功能不可用
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: realtalk-api-secret
type: Opaque
stringData:
  # ── 基础设施 ──
  DATABASE_URL: postgresql+psycopg://app_user:password@db.example.com:5432/realtalk?sslmode=require
  JWT_SECRET: replace-with-a-long-random-secret
  REDIS_URL: redis://redis-master:6379/0

  # ── 管理台 ──
  ADMIN_USERNAME: admin
  ADMIN_PASSWORD: replace-with-strong-password

  # ── 微信登录（必须填写，否则 WECHAT_AUTH_DEV_MODE=false 时无人能登录）──
  WECHAT_APP_ID: replace-with-wechat-mobile-appid
  WECHAT_APP_SECRET: replace-with-wechat-mobile-secret
  WECHAT_WEB_APP_ID: replace-with-wechat-web-appid
  WECHAT_WEB_APP_SECRET: replace-with-wechat-web-secret

  # ── AI 模型（不填则走离线兜底，可在管理台后续配置）──
  AI_BASE_URL: https://ark.cn-beijing.volces.com/api/v3
  AI_API_KEY: replace-with-ai-api-key
  AI_MODEL: doubao-seed-1-6-251015

  # ── 微信支付（不填则微信支付返回 503）──
  WECHAT_MCHID: ""
  WECHAT_API_KEY: ""
  WECHAT_NOTIFY_URL: https://your-domain.com/payment/wechat/webhook

  # ── 支付宝（不填则支付宝返回 503）──
  ALIPAY_APP_ID: ""
  ALIPAY_PRIVATE_KEY: ""
  ALIPAY_PUBLIC_KEY: ""
  ALIPAY_NOTIFY_URL: https://your-domain.com/payment/alipay/webhook
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: realtalk-api-config
data:
  # ── 基础 ──
  REALTALK_REGION: cn-shanghai-1
  API_UPSTREAM: http://realtalk-api:80

  # ── 功能开关（生产务必关闭 dev 模式）──
  WECHAT_AUTH_DEV_MODE: "false"
  PAYMENT_DEV_AUTO_CONFIRM: "false"
  APPLE_IAP_DEV_BYPASS: "false"
  EMAIL_AUTH_ENABLED: "false"
  EMAIL_DEV_MODE: "false"

  # ── 业务参数 ──
  TRIAL_DAYS: "30"
  DAILY_TOKEN_LIMIT_FREE: "8000"
  DAILY_TOKEN_LIMIT_BASIC: "120000"
  DAILY_TOKEN_LIMIT_PREMIUM: "400000"
  UPLOAD_DATA_DIR: ./data/uploads
  PAYMENT_RECEIVER_NAME: RealTalk
EOF

# 3. 部署 API
kubectl apply -f deploy/k8s/realtalk-api.yaml
kubectl rollout status deployment/realtalk-api

# 4. 部署管理台和用户 Web 端（可选）
kubectl apply -f deploy/k8s/admin-frontend.yaml
kubectl apply -f deploy/k8s/web-frontend.yaml
kubectl rollout status deployment/realtalk-admin
kubectl rollout status deployment/realtalk-web
```

`REDIS_URL` 指向 `redis-master` Service（Master Pod），采集上传的分块暂存通过 Redis 在 3 个 API 副本间共享。`API_UPSTREAM` 指向 API Service，管理台和 Web 端 Nginx 通过它反向代理后端接口。

