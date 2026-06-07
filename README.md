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

- 真实对话转英语场景（逐句还原 + 自由对话）
- AI 实时纠错 + 发音反馈
- 角色扮演 / 场景生成 / 填空题训练
- 微信登录 + 内购订阅
- Docker 一键部署（API + PostgreSQL）

