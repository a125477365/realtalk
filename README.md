# RealTalk

RealTalk 是一个基于真实对话的英语口语练习系统。它把日常中文对话自动还原为英语场景，配合 AI 纠错和语音交互，帮助用户在真实语境中练习口语。

## 项目结构

- `realtalk/` — iOS SwiftUI 客户端（Claude 风格界面）
- `realtalkad/` — Android Jetpack Compose 客户端（与 iOS 功能对等）
- `realtalkwork/` — FastAPI 后端 + 管理台 + 用户 Web 端 + Docker 部署
- `esp32-recorder/` — ESP32 录音笔固件（BLE 文件列表 + 分块下载，对接两端 App）

## 快速开始

- **服务端部署**：见 [`DEPLOYMENT.md`](./DEPLOYMENT.md)
- **接口列表**：见 [`realtalkwork/README.md`](./realtalkwork/README.md)
- **后端安装**：见 [`realtalkwork/INSTALL.md`](./realtalkwork/INSTALL.md)
- **本地 speech / OpenAI 模型地址填写**：见 [`realtalkwork/speechserver/README.md`](./realtalkwork/speechserver/README.md#在-realtalk-中启用管理台--系统设置--模型中心)
- **邮箱注册（默认，免企业资质）**：见 [`docs/email-login.md`](./docs/email-login.md)
- **微信一键登录（可选，需企业号）**：见 [`docs/wechat-app-login.md`](./docs/wechat-app-login.md)

## 特性

**App（iOS / Android）**
- 真实对话采集（点按录音 / 设定时间窗自动采集）并转写上传
- 今日场景列表：每天自动把真实对话还原成英语练习场景，选场景、选角色直接开练
- 逐句对练：双语字幕（AI 句中英同显，用户句先中文提示后英文+纠错标注）、答错暂停指导、超时主动提示
- 账户：余额 / 账单 / 微信与支付宝充值 / 设置

**会员与计费**
- 新用户注册送 30 天基础会员试用
- 基础（¥30/月、季付 ¥25/月、年付 ¥20/月）/ 高级（¥50/月、季付 ¥40/月、年付 ¥30/月），价格管理台可改
- 高级会员：App/Web 上传录音文件（≤6 小时/300MB）→ 服务端 ffmpeg 分段 + ASR 转写 → 内容清洗过滤 → 生成场景后删除音频
- 每日 token 限额（按套餐），超限当天暂停 AI 功能，非 AI 功能不受影响

**用户 Web 端**（`http://<服务器>:8000/web/`）
- 注册登录、余额与用量、充值、会员购买、场景浏览、高级会员录音上传

**管理台**
- 多维数据看板：收入、AI 支出、毛利、新增/在线用户、练习量及趋势图
- 用户管理、充值订单（含人工确认到账）、多管理员与角色
- Token 用量页：按用户排序、超量/接近上限标记；套餐价格 / 每日限额 / ASR 在线配置
- AI 模型在线配置：任意 OpenAI 兼容服务（方舟/DeepSeek/通义/Kimi/智谱/自定义），保存即生效，可测试连接

**部署**
- `bash realtalkwork/setup.sh` 交互式引导生成配置并一键启动（API + PostgreSQL + 管理台）
