# RealTalk

RealTalk 是一个基于真实对话的英语口语练习系统。它把日常中文对话自动还原为英语场景，配合 AI 纠错和语音交互，帮助用户在真实语境中练习口语。

## 项目结构

- `realtalk/` — iOS SwiftUI 客户端（语音识别 / TTS / 场景练习）
- `realtalkwork/` — FastAPI 后端 + Docker 部署

## 快速开始

- **服务端部署**：见 [`DEPLOYMENT.md`](./DEPLOYMENT.md)
- **接口列表**：见 [`realtalkwork/README.md`](./realtalkwork/README.md)
- **后端安装**：见 [`realtalkwork/INSTALL.md`](./realtalkwork/INSTALL.md)

## 特性

**App（iOS）**
- 真实对话采集（点按录音 / 设定时间窗自动采集）并转写上传
- 今日场景列表：每天自动把真实对话还原成英语练习场景，选场景、选角色直接开练
- 逐句对练：双语字幕（AI 句中英同显，用户句先中文提示后英文+纠错标注）、答错暂停指导、超时主动提示
- 账户：余额 / 账单 / 微信与支付宝充值 / 设置

**管理台**
- 多维数据看板：收入、AI 支出、毛利、新增/在线用户、练习量及趋势图
- 用户管理、充值订单（含人工确认到账）、多管理员与角色
- AI 模型在线配置：任意 OpenAI 兼容服务（方舟/DeepSeek/通义/Kimi/智谱/自定义），保存即生效，可测试连接

**部署**
- `bash realtalkwork/setup.sh` 交互式引导生成配置并一键启动（API + PostgreSQL + 管理台）

