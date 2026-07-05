# RealTalk 本地实时语音模型服务器

独立容器：**ASR（faster-whisper）+ TTS（Piper 中英混读）+ LLM（llama.cpp GGUF）**，
对外暴露 **OpenAI 兼容 API** —— RealTalk api 后端与管理台无需任何代码改动，把对应 Base URL 指过来即可全量切换到本地模型。

## 安装

```bash
# setup.sh 里选择「安装本地实时语音模型」即可；或手动：
docker compose -f docker-compose.yml -f docker-compose.speech.yml up -d --build speech
```

参数全部走 `.env`（每节点部署项，不入库、不进管理台）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `SPEECH_DEVICE` | `cpu` | `cpu` / `cuda`（GPU 需 nvidia-container-toolkit） |
| `SPEECH_ASR_MODEL` | `small` | whisper 尺寸：tiny/base/small/medium/large-v3 |
| `SPEECH_LLM_REPO` / `SPEECH_LLM_FILE` | Qwen2.5-1.5B-Instruct Q4 | GGUF 模型仓库/文件（FILE 也可填绝对路径） |
| `SPEECH_TTS_VOICE_EN` / `_ZH` | lessac / huayan | Piper 英文/中文音色（混合文本自动分段双音色拼接） |
| `SPEECH_MODELS_DIR` | `./speech-models` | 宿主机模型目录（启动预拉，多副本可共享只读） |
| `HF_ENDPOINT` | 空 | 受限网络填 `https://hf-mirror.com` |
| `SPEECH_*_CONCURRENCY` | ASR 3 / LLM 2 / TTS 6 | 各引擎并发上限，超出排队 |

## API 调用方式（OpenAI 兼容）

```bash
BASE=http://<服务器>:9100/v1

# 1) 语音→文字
curl -F file=@clip.wav -F language=en $BASE/audio/transcriptions        # {"text":"..."}

# 2) 文字→语音（WAV；中英混合自动双音色）
curl -X POST $BASE/audio/speech -H 'Content-Type: application/json' \
     -d '{"input":"Hello 你好","voice":"en_US-lessac-medium"}' -o out.wav

# 3) 文字对话
curl -X POST $BASE/chat/completions -H 'Content-Type: application/json' \
     -d '{"messages":[{"role":"user","content":"Say hi"}]}'

# 4) 实时通道（WS，OpenAI Realtime 事件子集）：同时上传语音流和文字上下文，
#    返回 用户转写 + 文本流 + 语音流；?session= 相同即可跨副本续聊（上下文在 Redis）
wscat -c "$BASE/realtime?session=abc&language=en"
> {"type":"session.update","session":{"instructions":"You are..."}}
> {"type":"conversation.item.create","item":{"role":"user","content":[{"type":"input_text","text":"场景台词..."}]}}
> {"type":"input_audio_buffer.append","audio":"<base64 音频>"}
> {"type":"input_audio_buffer.commit"}
< {"type":"conversation.item.input_audio_transcription.completed","transcript":"..."}
< {"type":"response.text.delta","delta":"..."} ... {"type":"response.audio.delta","delta":"<b64 pcm16>","sample_rate":22050}
```

## 在 RealTalk 中启用（管理台 → 系统设置，按 A/B/C 分类分开设置）

| 分类 | 卡片 | 填什么 | 用在哪 |
|---|---|---|---|
| A 场景生成 | A·场景生成-语音转写 | `http://<IP>:9100/v1` 或云端 | 上传音频文件→场景 的转写 |
| A 场景生成 | 模型卡「场景生成」槽位 | 本地或云端（留空=跟随对话模型） | 场景/学习材料生成 LLM |
| B 对话 | B·对话-语音转写 | `http://<IP>:9100/v1`（留空=跟随 A） | 手动/沉浸式/私教逐句转写 |
| B 对话 | B·对话-语音合成 | `http://<IP>:9100/v1`，格式 wav | 手动/沉浸式/私教朗读 |
| B 对话 | B·对话-实时通道 | `ws://<IP>:9100/v1/realtime` | 私教流式（音频边说边传，上下文在本服 Redis，5 分钟滑动、退出即清） |
| B 对话 | 模型卡（对话文字模型） | `http://<IP>:9100/v1` | 对话回复/评分/指导 LLM |
| C 高级实时语音 | C·高级会员实时语音 | 保持 OpenAI/GLM（独立预留） | 本地异常不影响高级会员 |

接口与功能对应：`/audio/transcriptions`+`/chat/completions` → 上传音频生成场景、手动触发式；
`/audio/speech` → 手动触发式朗读；`WS /realtime` → 沉浸式/私教流式（沉浸式因逐句评分/进度判断，当前仍走分步管线+可选流式转写，后续切换）。

## 多活 / 高并发 / k8s

- 引擎无进程间共享状态；实时会话上下文存 **Redis**（`spx:ctx:<session>`，30 分钟滑动 TTL）→ 任意副本可接管；
- ASR/LLM/TTS 各自并发信号量排队，防止把节点打挂；模型目录可多副本共享（只读加载）；
- k8s：`deploy/k8s/speech-server.yaml`（Deployment+Service+PVC），探针已带 `start-period`（首启要下载模型）。
