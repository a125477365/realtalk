# RealTalk on Kubernetes（完整安装步骤）

多活（多副本）部署。核心原则与 `setup.sh` 一致：

- **建表/迁移/系统参数入库 = 一次性 `db-init` Job 完成**（单一执行者）。
- **API 副本只读已供给的库**，不建表、不播种；未供给会 fail-fast。Pod 用 initContainer 阻塞等待 Job 供给完成。
- **每节点参数走 Secret/ConfigMap（env）**；**多活共用参数（凭据/策略）入数据库**，由 `db-init` 首次播种、之后在管理台维护。

---

## 0. 构建并推送镜像

4 个 manifest 都用预构建镜像 `your-registry/realtalk-api:latest`，所以先在 `realtalkwork/` 目录构建并推到你的仓库。

**纯云端 ASR/TTS（推荐，Pod 完全无状态）：**
```bash
cd realtalkwork
docker build -t your-registry/realtalk-api:latest .
docker push your-registry/realtalk-api:latest
```

**要服务器本地 ASR(faster-whisper) / 本地 TTS(Piper) —— 是的，和 docker-compose 一样靠 build-arg，但 k8s 用预构建镜像，所以要在【构建镜像时】传：**
```bash
docker build \
  --build-arg WITH_LOCAL_ASR=true \   # 装 faster-whisper
  --build-arg WITH_LOCAL_TTS=true \   # 装 piper-tts
  -t your-registry/realtalk-api:latest .
docker push your-registry/realtalk-api:latest
```
（云端方式不传即可，默认 false，镜像不背这些依赖。）

构建后把 4 个 manifest 里的 `your-registry/realtalk-api:latest` 替换成你的镜像地址（API Deployment、db-init Job、以及 initContainer 三处都在 `realtalk-api.yaml` / `db-init.yaml`）。

> **建议**：k8s 多副本优先用**云端 ASR/TTS** —— Pod 无状态、可随意扩缩、无模型存储问题。
> 本地引擎更适合单机 docker-compose；在 k8s 用本地引擎要额外处理模型持久化（见第 4 节）。

## 1. 外部依赖
- **PostgreSQL**：自建或托管，拿到连接串（不在本目录管理）。
- **Redis**：`kubectl apply -f redis.yaml`（1 Master + 2 Replica）。

## 2. 创建 Secret 与 ConfigMap

`realtalk-api-secret`（敏感）——**每节点引导项** + **首次装库要入库的凭据初值**：
```bash
kubectl create secret generic realtalk-api-secret \
  --from-literal=DATABASE_URL='postgresql+psycopg://user:pass@pg-host:5432/realtalk?sslmode=require' \
  --from-literal=REDIS_URL='redis://redis-master:6379/0' \
  --from-literal=JWT_SECRET='<强随机；仅供 db-init 播种入库>' \
  --from-literal=ADMIN_USERNAME='admin' \
  --from-literal=ADMIN_PASSWORD='<强随机>' \
  `# —— 以下为首次装库要入库的凭据初值（之后在管理台改，API 运行期不再读）——` \
  --from-literal=AI_BASE_URL='...' --from-literal=AI_API_KEY='...' --from-literal=AI_MODEL='...' \
  --from-literal=WECHAT_APP_ID='...' --from-literal=WECHAT_APP_SECRET='...' \
  --from-literal=WECHAT_MCHID='...' --from-literal=WECHAT_API_KEY='...'
  # 云端 ASR/TTS 凭据、支付证书、SMTP、Apple 等同理；留空可稍后在管理台填
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

> 凭据初值放 Secret 还是只在管理台填，二选一即可；无论哪种，运行期都只读数据库（单一来源）。

## 3. 供给数据库并部署
```bash
kubectl apply -f db-init.yaml          # 一次性建库 + 入库（幂等，可重跑）
kubectl wait --for=condition=complete job/realtalk-db-init --timeout=300s
kubectl apply -f realtalk-api.yaml     # 3 副本 API（initContainer 会等待供给完成）
kubectl apply -f admin-frontend.yaml -f web-frontend.yaml
```
升级（已有库）：`db-init` 的播种有「只播种一次」标记，重跑只补建新表/列，不会覆盖管理台改过的值。

## 4. （可选）本地 ASR / TTS：env 与模型持久化

仅当第 0 步构建镜像带了 `WITH_LOCAL_ASR/TTS=true` 时才用本地。把 `realtalk-api-config` 的 mode 改为 local 并加命令：
```bash
# 本地 ASR（faster-whisper）
ASR_MODE=local
ASR_LOCAL_COMMAND=python /app/app/asr_local.py {input}
ASR_LOCAL_MODEL=small               # tiny/base/small/medium
# 本地 TTS（Piper，输出 WAV，英文音色）
TTS_MODE=local
TTS_FORMAT=wav
TTS_LOCAL_COMMAND=python /app/app/tts_local.py {voice} {out}
```
TTS 音色清单是**入库参数**，放 db-init 的 Secret/ConfigMap 里播种（Piper 音色名）：
```bash
TTS_VOICES=en_US-lessac-medium,en_US-amy-medium,en_GB-alan-medium
TTS_DEFAULT_VOICE=en_US-lessac-medium
```

**模型持久化**（本地引擎的模型默认下载到容器内 `/app/models`）。多副本下三选一：
- **接受每 Pod 首次下载**：不挂卷，小模型（whisper small / piper medium）影响有限，重启会重下。
- **共享 PVC（推荐持久）**：建一个 `ReadWriteMany` 的 PVC（需 NFS 等 RWX storageclass），在 `realtalk-api.yaml` 的 Pod 上挂到 `/app/models`，多副本共享一份：
  ```yaml
  # realtalk-api.yaml 的 spec.template.spec 里加：
  volumes:
    - name: models
      persistentVolumeClaim:
        claimName: realtalk-models      # 你自建的 RWX PVC
  # 并在 api 容器（以及本地引擎用到的 initContainer，如有）加：
  volumeMounts:
    - name: models
      mountPath: /app/models
  ```
- **最稳：把模型烤进镜像**：自定义 Dockerfile 在构建期预下载模型，Pod 启动即用、无需联网、无需挂卷。

## 为什么这样多副本才安全
3 个 API 副本共享同一个已供给的数据库：JWT 密钥、AI/支付/微信/SMTP 凭据、会话策略全在库里，
所以 A 副本签的令牌 B 副本认、任一副本在管理台改配置全体即时生效——不存在各副本各建表/各取值的竞争。
