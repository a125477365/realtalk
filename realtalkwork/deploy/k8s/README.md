# RealTalk on Kubernetes（完整安装步骤）

多活（多副本）部署。核心原则与 `setup.sh` 一致：

- **建表/迁移/系统参数入库 = 一次性 `db-init` Job 完成**（单一执行者）。
- **API 副本只读已供给的库**，不建表、不播种；未供给会 fail-fast。Pod 用 initContainer 阻塞等待 Job 供给完成。
- **每节点参数走 Secret/ConfigMap（env）**；**多活共用参数（凭据/策略）入数据库**，由 `db-init` 首次播种、之后在管理台维护。

---

## 0. 构建并推送镜像

4 个 manifest 都用预构建镜像 `your-registry/realtalk-api:latest`，所以先在 `realtalkwork/` 目录构建并推到你的仓库。

**默认构建（推荐）—— 本地 ASR(faster-whisper) + TTS(Piper) 随镜像装好,与 API 同容器：**
```bash
cd realtalkwork
docker build -t your-registry/realtalk-api:latest .
docker push your-registry/realtalk-api:latest
```
这样云端付费模型和本地开源模型都已就绪,运维之后切换只改 `ASR_MODE/TTS_MODE` 配置即可,**不必重建镜像**。

**只想要更小的「纯云端」镜像**（确定不用本地引擎）时,构建时关掉即可：
```bash
docker build \
  --build-arg WITH_LOCAL_ASR=false \
  --build-arg WITH_LOCAL_TTS=false \
  -t your-registry/realtalk-api:latest .
docker push your-registry/realtalk-api:latest
```

构建后把 4 个 manifest 里的 `your-registry/realtalk-api:latest` 替换成你的镜像地址（API Deployment、db-init Job、以及 initContainer 三处都在 `realtalk-api.yaml` / `db-init.yaml`）。

> **建议**：k8s 多副本若用**云端 ASR/TTS** Pod 完全无状态、可随意扩缩；用**本地引擎**要额外处理模型持久化（见第 4 节）。
> 镜像默认带本地引擎只是让你能随时切换,用不用是运行期的 `ASR_MODE/TTS_MODE` 决定的。

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
  --from-literal=ASR_MODE='cloud' --from-literal=TTS_MODE='cloud' \
  `# —— 8 个联调旁路开关(对应 setup.sh「部署模式」)：生产全 false；本地联调可全 true ——` \
  --from-literal=WECHAT_AUTH_DEV_MODE='false' \
  --from-literal=PAYMENT_DEV_AUTO_CONFIRM='false' \
  --from-literal=EMAIL_DEV_MODE='false' \
  --from-literal=APPLE_IAP_DEV_BYPASS='false' \
  --from-literal=APPLE_USE_SANDBOX='false' \
  --from-literal=ALIPAY_SANDBOX='false' \
  --from-literal=ASR_DEV_MODE='false' \
  --from-literal=TTS_DEV_MODE='false'
```
> 这 8 个就是全部「联调旁路」开关，与 docker-compose 的 `setup.sh「部署模式 prod/dev」`等价：
> **生产全 `false`**（真实登录/验签/内购校验、正式端点、未配置即报错）；本地联调全 `true`（任意登录、自动到账、内购旁路、沙箱、ASR/TTS 占位）。

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

镜像**默认已带本地引擎**（第 0 步），用本地只需把 `realtalk-api-config` 的 mode 改为 local 加命令；
**模型首次使用时自动下载**到容器内 `/app/models`（无需手动下载）。受限网络走镜像站：
`HF_ENDPOINT=https://hf-mirror.com`（whisper）、`PIPER_VOICES_BASE=https://hf-mirror.com/rhasspy/piper-voices/resolve/main`（Piper），加到 `realtalk-api-config` 即可。

```bash
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

## 5. （采集功能）/app/uploads 录音目录

仅当本集群启用「采集」（用户上传真实对话录音→转写生成场景）时需要。采集文件按 MD5 路由到处理它的节点，
多副本下要让处理节点都能读到同一份 → 给 `/app/uploads` 挂一个 `ReadWriteMany` PVC（同 `/app/models` 的写法，
`mountPath: /app/uploads`）。**对练语音不落盘**（内存即转即弃），无需为它配卷。
> 容器入口脚本会自动把 `/app/uploads`、`/app/models` 属主修正给运行用户，PVC 不必预设属主。

## 为什么这样多副本才安全
3 个 API 副本共享同一个已供给的数据库：JWT 密钥、AI/支付/微信/SMTP 凭据、会话策略全在库里，
所以 A 副本签的令牌 B 副本认、任一副本在管理台改配置全体即时生效——不存在各副本各建表/各取值的竞争。
