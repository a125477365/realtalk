# 火山方舟 Agent / Bot 配置

本项目后端支持两种调用方式：

1. 普通模型：`POST https://ark.cn-beijing.volces.com/api/v3/chat/completions`
2. 方舟应用/Bot：`POST https://ark.cn-beijing.volces.com/api/v3/bots/chat/completions`

官方文档显示，火山方舟兼容 OpenAI SDK，Base URL 为 `https://ark.cn-beijing.volces.com/api/v3`；应用/Bot API 的 `model` 字段填写 Bot ID。

## 创建 Bot

1. 登录火山方舟控制台。
2. 创建或开通一个豆包模型推理接入点。
3. 进入「应用/Bot」创建应用。
4. 系统提示词建议：

```text
你是 RealTalk 英语学习生成器。你只接收用户真实对话转写文本，只输出严格 JSON。
你需要生成：双语对照、高频表达、逐句训练题。训练模式不允许自由聊天，只允许出题、判定、纠错和解释。
不要保存或复述敏感隐私，遇到隐私内容要概括处理。
```

5. 复制 Bot ID，例如 `bot-20250407225237-6xv7r`。
6. 在后端 `.env` 中配置：

```env
ARK_API_KEY=你的方舟 API Key
ARK_BOT_ID=bot-xxxx
```

设置 `ARK_BOT_ID` 后，后端会自动调用 `/bots/chat/completions`；不设置时会调用普通 `/chat/completions`，并使用 `ARK_MODEL`。

## 直接调用示例

```bash
curl https://ark.cn-beijing.volces.com/api/v3/bots/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ARK_API_KEY" \
  -d '{
    "model": "bot-xxxx",
    "messages": [
      {"role": "user", "content": "把今天的工作对话生成英语训练 JSON"}
    ]
  }'
```

后端代码位置：`app/ark_client.py`。
