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

`/health` 用于进程存活检查；`/ready` 会连接数据库，适合负载均衡或 Kubernetes readiness probe。

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

示例清单在 `deploy/k8s/realtalk-api.yaml`。每个区域应分别创建：

- `realtalk-api-config`：`REALTALK_REGION`、`REQUIRE_PRO_FOR_AI`、模型基础配置等非密钥配置
- `realtalk-api-secret`：`DATABASE_URL`、`JWT_SECRET`、模型 API Key、微信/支付密钥

最小 Secret 示例：

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: realtalk-api-secret
type: Opaque
stringData:
  DATABASE_URL: postgresql+psycopg://app_user:password@db.example.com:26257/realtalk?sslmode=require
  JWT_SECRET: replace-with-a-long-random-secret
```

最小 ConfigMap 示例：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: realtalk-api-config
data:
  REALTALK_REGION: cn-shanghai-1
  REQUIRE_PRO_FOR_AI: "false"
  WECHAT_AUTH_DEV_MODE: "false"
  PAYMENT_DEV_AUTO_CONFIRM: "false"
```
