# RealTalk on Kubernetes

多活（多副本）部署。核心原则与 `setup.sh` 一致：

- **建表/迁移/系统参数入库 = 一次性 `db-init` Job 完成**（单一执行者）。
- **API 副本只读已供给的库**，不建表、不播种；未供给会 fail-fast。Pod 用 initContainer 阻塞等待 Job 供给完成。
- **每节点参数走 Secret/ConfigMap（env）**；**多活共用参数（凭据/策略）入数据库**，由 `db-init` 首次播种、之后在管理台维护。

## 1. 先准备外部依赖
- **PostgreSQL**：自建或托管，拿到连接串（不在本目录管理）。
- **Redis**：`kubectl apply -f redis.yaml`（1 Master + 2 Replica）。

## 2. 创建 Secret 与 ConfigMap

`realtalk-api-secret`（敏感）——只放**每节点引导项** + **首次装库要入库的凭据初值**：

```bash
kubectl create secret generic realtalk-api-secret \
  --from-literal=DATABASE_URL='postgresql+psycopg://user:pass@pg-host:5432/realtalk?sslmode=require' \
  --from-literal=REDIS_URL='redis://redis-master:6379/0' \
  --from-literal=JWT_SECRET='<强随机；仅供 db-init 播种入库>' \
  --from-literal=ADMIN_USERNAME='admin' \
  --from-literal=ADMIN_PASSWORD='<强随机>' \
  # —— 以下为首次装库要入库的凭据初值（之后在管理台改，API 运行期不再读）——
  --from-literal=AI_BASE_URL='...' --from-literal=AI_API_KEY='...' --from-literal=AI_MODEL='...' \
  --from-literal=ASR_BASE_URL='...' --from-literal=ASR_API_KEY='...' --from-literal=ASR_MODEL='whisper-1' \
  --from-literal=TTS_BASE_URL='...' --from-literal=TTS_API_KEY='...' --from-literal=TTS_MODEL='tts-1' \
  --from-literal=WECHAT_APP_ID='...' --from-literal=WECHAT_APP_SECRET='...' \
  --from-literal=WECHAT_MCHID='...' --from-literal=WECHAT_API_KEY='...' \
  # 支付平台/商户证书、SMTP、Apple 等同理，留空可稍后在管理台填
```

`realtalk-api-config`（非敏感）——**每节点 dev/prod 开关 + 区域 + 运行期 env**：

```bash
kubectl create configmap realtalk-api-config \
  --from-literal=REALTALK_REGION='prod' \
  --from-literal=WECHAT_AUTH_DEV_MODE='false' \
  --from-literal=PAYMENT_DEV_AUTO_CONFIRM='false' \
  --from-literal=APPLE_IAP_DEV_BYPASS='false' \
  --from-literal=EMAIL_DEV_MODE='false' \
  --from-literal=ASR_MODE='cloud' --from-literal=TTS_MODE='cloud'
```

> 凭据初值放 Secret 还是只在管理台填，二选一即可：留空 Secret，部署后到管理台「系统设置」逐项填也行。
> 无论哪种，运行期都只读数据库（单一来源）。

## 3. 供给数据库并部署

```bash
kubectl apply -f db-init.yaml          # 一次性建库 + 入库（幂等，可重跑）
kubectl wait --for=condition=complete job/realtalk-db-init --timeout=300s
kubectl apply -f realtalk-api.yaml     # 3 副本 API（initContainer 已会等待供给完成）
kubectl apply -f admin-frontend.yaml -f web-frontend.yaml
```

升级（已有库）：`db-init` 的播种有「只播种一次」标记，重跑只补建新表/列，不会覆盖管理台改过的值。

## 为什么这样多副本才安全
3 个 API 副本共享同一个已供给的数据库：JWT 密钥、AI/支付/微信/SMTP 凭据、会话策略全在库里，
所以 A 副本签的令牌 B 副本认、任一副本在管理台改配置全体即时生效——不存在各副本各建表/各取值的竞争。
