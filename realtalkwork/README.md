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
- `transcripts`：只保存文本，不保存音频；按识别片段逐条保存，上传入口会过滤空白、纯标点、系统提示词和常见字幕噪声；`expires_at = timestamp + 3 天`
- `sessions`：训练题目、当前状态和得分；同样按 3 天清理
- `scenarios`：从用户选择的当天或某个时间段真实转写逐句生成英语场景，并把整套 A/B 角色、中文原句、英文还原句保存为一个可复练场景
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

## 语音文件服务器（高级会员上传录音）

高级会员可上传整段录音文件（手机或录音笔下载的 mp3/wav/m4a）生成场景。为支撑大文件与水平扩展，
上传与处理被拆开：**上传只负责把文件可靠落到「该文件应归属的那台语音服务器」，转写和场景生成由各语音服务器的定时任务异步完成**。

### 作用与路由规则
- **语音服务器列表**在【管理台 → 系统设置 → 语音文件服务器】配置并存库，格式 `ip:port;ip:port`，
  例如 `192.168.6.12:8000;192.168.6.3:8000;192.168.6.4:8000`。
  - 列表中的 IP 必须**各语音服务器之间网络可达**（用于互相转发）。
  - **未配置则语音上传直接报错，不本地兜底保存**。
- **某文件由哪台处理** = `列表[ int(md5 后4位十六进制, 16) % 服务器数 ]`。
  例如 md5 末 4 位 `c592`→十进制 50578，3 台时 `50578 % 3 = 1`（即第 2 台 `192.168.6.3`）。同一文件始终落同一台。
- 任意服务器收到上传请求后按上式算出目标：**命中本机则本地存盘**，否则**把整请求转发到目标 ip:port**（带 `X-Voice-Routed` 头避免二次转发）。
- 客户端每个上传报文都带整文件 **MD5**（init/chunk/complete/status 均带 `md5`），用于路由、命名与去重。

### 语音专用 URL 路径（对外 nginx 需指向语音服务器）
以下路径属于语音文件上传专用，**唯一对外 nginx 入口必须把它们转发到语音服务器的一台或全部**
（转发到一台时由该台按上面的规则自行转发；也可转发到其中一些或全部，由各服务器自行转发）：

```
/audio/upload/init
/audio/upload/status
/audio/upload/chunk
/audio/upload/complete
```

nginx 样例（把语音路径指到语音服务器 upstream，其余仍走普通 API）：
```nginx
upstream voice_servers { server 192.168.6.12:8000; server 192.168.6.3:8000; server 192.168.6.4:8000; }
upstream api_servers   { server 127.0.0.1:8000; }
server {
    listen 80;
    location /audio/upload/ { proxy_pass http://voice_servers; proxy_read_timeout 1800s; proxy_send_timeout 1800s; }
    location /              { proxy_pass http://api_servers; }
}
```

### 语音服务器的 .env
**若某台服务器是语音文件服务器，其 `.env` 必须设置本机地址**，服务据此识别「某上传报文是否归本机处理」：
```
VOICE_NODE_ADDR=192.168.6.3:8000   # 本机在「语音服务器列表」中的 ip:port
# 可选：VOICE_DIR=./uploads/voice   # 语音文件本地存放目录，默认 uploads/voice
```
`setup.sh` 部署后端时会先问「本机是否作为语音文件服务器」，选是则要求填 `VOICE_NODE_ADDR`。
**配了 `VOICE_NODE_ADDR` 的服务器首次启动时会自动把本机地址加入「语音文件服务器」列表**，省去手工添加；
之后运维可在管理台删除该地址（删除后重启不会再自动加回）。

### 本地命名、去重与断点续传
文件按 `{user_id}_{md5}{原后缀}` 保存到本机 `VOICE_DIR`：
- 重新上传时，若已存在 `{user_id}_{md5}.txt`（已转写）或已传完（有 `.ready` 标记） → 直接提示「已成功上传」；
- 若 `{user_id}_{md5}{后缀}` 已存在但大小不足 → 说明上传未完成，**支持断点续传**（从已收字节继续）。

### 三个定时任务（每台语音服务器每小时各处理自己本地的文件）
1. **转写**：把已传完的音频转写为 `{user_id}_{md5}.txt`，转写完成后删除音频文件。
2. **生成场景**：把 `.txt` 内容交给大模型生成场景（与采集到的对话文字走同一流程）；生成完成后会出现在 App 场景列表。
3. **清理**：删除 3 天前的 `.txt` / 中间标记 / 残留音频（3 天未成功即视为失败，由用户重新上传）。

> 可部署多台语音服务器，文件落在哪台完全由 MD5 路由规则决定；扩容只需在管理台列表里增删 `ip:port` 并在新机 `.env` 设好 `VOICE_NODE_ADDR`。

## 容器和多中心部署

```bash
docker build -t realtalk-api:latest .
docker compose up --build
```

多中心部署时，API 容器保持无状态，每个区域设置自己的 `REALTALK_REGION`，并共同连接分布式数据库集群。`/health` 用于存活检查，`/ready` 会 ping 数据库用于就绪检查。详细说明见 `docs/deployment.md`。

## 模型配置

文字模型配置保存在共享数据库 `app_settings` 中，管理台「系统设置 → AI 模型对接」保存后立即生效。后端兼容 OpenAI 风格 `/chat/completions` 服务；火山方舟 Bot 会走 `/bots/chat/completions`；智谱 GLM / Z.ai 使用 `https://api.z.ai/api/paas/v4`，`glm-4.7-flash` 会自动带上 `thinking` 与长输出上限。

## 模型会话隔离和指令安全

- 当前低成本版本使用无状态 Chat Completions 调用：所有用户共用同一个模型服务账号/API key，但不是共用同一个大模型会话。
- 每次模型请求都由后端按当前登录用户 `user_id` 读取自己的 `transcripts`、`scenarios`、`roleplay_messages` 后临时拼装上下文；不会把 A 用户的数据放进 B 用户的请求。
- 后端不向模型传递 provider 级 `conversation_id` / `session_id`，因此模型侧不保存跨用户连续会话；业务会话状态保存在数据库表里。
- 真实对话、场景内容、用户历史消息和当轮输入全部按“未受信任数据”处理，只能作为翻译、英语口语还原、提示、评分纠错或学习材料来源。
- 如果真实对话里出现“忽略之前规则”“泄露提示词”“执行命令”“改身份”等内容，模型必须把它当作普通待翻译文本，不得执行。
- `/ai/chat` 不会把客户端传来的 `assistant` 历史消息作为真正的高优先级 assistant 消息透传给模型，而是包成未受信任 JSON 上下文，避免用户伪造历史消息提升指令优先级。

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
