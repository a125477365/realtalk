# RealTalk 后端

FastAPI 服务位于 `E:\code\realtalk\realtalkwork`，负责微信快速授权登录、账户余额和账单、微信/支付宝充值订单、文本对话留存、英语场景逐句生成、AI 咨询、逐轮语音角色扮演状态、逐轮纠错和练习历史。后端支持 Docker 容器化部署，生产环境可通过 `DATABASE_URL` 接入 PostgreSQL 协议的分布式数据库集群。

## 启动

```powershell
cd E:\code\realtalk\realtalkwork
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
copy .env.example .env
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

iOS 默认访问 `http://127.0.0.1:8000`。真机调试时，把 `RealTalk/AppConfig.swift` 里的 `apiBaseURL` 改成电脑局域网 IP，并在防火墙放行 8000 端口。

## 数据保存

- 本地开发默认 SQLite 文件：`E:\code\realtalk\realtalkwork\realtalk.sqlite3`
- 生产环境设置 `DATABASE_URL` 后使用 PostgreSQL 协议数据库；可连接 CockroachDB、YugabyteDB 或托管 PostgreSQL
- `users`：`login_identifier`、微信 openid、密码哈希、套餐、余额、Apple 原始交易号
- `transcripts`：只保存文本，不保存音频；`expires_at = timestamp + 3 天`
- `sessions`：训练题目、当前状态和得分；同样按 3 天清理
- `scenarios`：从用户选择的当天或某个时间段真实转写逐句生成英语场景
- `roleplay_sessions` / `roleplay_messages` / `practice_results`：保存角色扮演过程、每句口语识别结果、纠错反馈和练习得分

## 语音还原练习

- iOS 采集端使用系统语音识别把真实世界对话转成文字，上传 `/transcript/upload` 的是文字，不上传音频。
- `/scenario/generate` 会把所选时间段的真实文本逐句拆成英语口语场景；空白文本会被拒绝，不会凭空生成场景。
- `/roleplay/start` 根据用户选择的角色开始同一场景；用户可在 App 内对换角色并重开。
- `/roleplay/message` 接收 iOS 英文语音识别后的文字；后端会把中文原句、目标英文、用户回答和场景上下文交给大模型做受控纠错评分，未配置模型时回退到规则相似度。
- `/ai/chat` 用于用户在练习中咨询“怎么说”、请求提示或总结纠错，后端会携带当前场景上下文调用大模型。
- `/practice/history` 返回每个用户的历史练习结果。

## 低成本语音链路

当前版本采用稳定低成本的一轮一轮语音练习，不走实时音频流：

```text
真实对话收集：iOS 麦克风 -> iOS 中文语音识别 -> 中文文字 -> 后台保存
英语练习：iOS 英文语音识别 -> 英文文字 -> 后台大模型纠错/推进剧情 -> iOS TTS 播放 AI 英文回复
```

后台和大模型之间传输的是文本和结构化场景，不传用户练习音频。这样便于保存每句话、纠错、计费和更换任意 OpenAI 风格模型；后续如果要做到 ChatGPT Voice / Gemini Live 那种低延迟打断式对话，再新增 WebSocket/WebRTC 实时音频通道。

## 容器和多中心部署

```bash
docker build -t realtalk-api:latest .
docker compose up --build
```

多中心部署时，API 容器保持无状态，每个区域设置自己的 `REALTALK_REGION`，并共同连接分布式数据库集群。`/health` 用于存活检查，`/ready` 会 ping 数据库用于就绪检查。详细说明见 `docs/deployment.md`。

## 模型配置

后端优先读取 `AI_API_KEY` / `AI_BASE_URL` / `AI_MODEL`，兼容任意 OpenAI 风格 `/chat/completions` 服务。未配置 `AI_*` 时自动使用 `ARK_*`；如果配置了 `ARK_BOT_ID`，会调用火山方舟 Bot 的 `/bots/chat/completions`。

## 收费开关

开发时 `APPLE_IAP_DEV_BYPASS=true`，后端收到 iOS 的 StoreKit 交易后直接把用户标为 `pro`。生产环境请改为：

```env
APPLE_IAP_DEV_BYPASS=false
APPLE_USE_SANDBOX=false
REQUIRE_PRO_FOR_AI=true
APPLE_ISSUER_ID=...
APPLE_KEY_ID=...
APPLE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
```

`/learning/generate`、`/training/start`、`/scenario/generate` 和 `/roleplay/*` 会在 `REQUIRE_PRO_FOR_AI=true` 时要求用户套餐为 `pro`。

## 微信登录和充值

登录只支持微信授权。开发环境默认 `WECHAT_AUTH_DEV_MODE=true`，iOS 会用本机开发授权码换取测试账号；生产环境请配置 `WECHAT_APP_ID`、`WECHAT_APP_SECRET`，并在 iOS 接入微信 OpenSDK 后把真实授权 `code` 传给 `/auth/wechat/login`。

微信/支付宝充值接口会创建订单并记录账单。开发环境默认 `PAYMENT_DEV_AUTO_CONFIRM=true`，用户点“我已付款”即可入账；生产环境应关闭该开关，并接入微信/支付宝官方支付回调后再调用入账逻辑。
