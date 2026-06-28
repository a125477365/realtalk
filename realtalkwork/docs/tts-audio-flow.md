# TTS 语音：生成、缓存与获取流程（设计文档）

本文说明对练中 AI 台词语音（后端 TTS）**何时合成、是否进 Redis、何时获取、命中条件**，以及为什么不会取到别人的/错的语音。实时语音大模型（高级会员）的音频来自语音模型本身、不走本文路径，不在此列。

## 0. 一句话结论

- **只有一个接口既"生成"又"返回"**：没有"生成接口 + 按 id 二次拉取接口"之分。App 永远从 HTTP 响应体 / WS 帧里**直接拿到音频**，从不直接读 Redis。
- **Redis 只是后端内部的「同句去重缓存」**，键是内容哈希，命中条件是「音色+格式+文本」三者完全一致且 5 分钟内有人合成过。不可能取到别的语音。
- **手工触发式**（HTTP）走缓存；**沉浸式**（WS）完全不碰 Redis。

## 1. 两条播放路径

| 路径 | 触发接口 | 协议 | 进 Redis？ | 音频怎么到 App |
|---|---|---|---|---|
| 手工触发式 / 点读 | `GET /tts/speak` | HTTP | ✅ 查+写（`use_cache=True`） | 同一请求的响应体 |
| 试听音色 | `GET /tts/preview` | HTTP | ✅ 查+写 | 同一请求的响应体 |
| 沉浸式对练 | `WS /roleplay/stream`（内部 `_send_tts`） | WebSocket | ❌ 不查不写（`use_cache=False`） | 同一条 WS 连接的二进制帧 |

三者最终都调用同一个 `voice_io.synthesize(text, voice, use_cache=...)`，区别只在 `use_cache`。

## 2. 核心：`synthesize(text, voice, use_cache=True)`

`app/voice_io.py`。一次调用内完成"查缓存→（未命中）合成→（可选）写缓存→返回"：

```
text/voice 规整 → fmt = TTS_FORMAT（云端 mp3 / 本地 Piper wav）
            │
            ├─ dev 占位：dev_mode 且云端/本地都未配置 → 返回静音 WAV（不缓存、不限并发）
            │
            ├─ cache_key = use_cache ? "rt:tts:" + sha256("voice|fmt|text")[:40] : None
            │
            ├─ 若 cache_key 非空：_cache_get(key)
            │       命中 → 直接返回缓存音频（秒回，不再合成）          ← 「获取」就发生在这
            │
            ├─ 取并发令牌（满则抛 TTSOverloaded → 调用方 429）
            │   未命中则真正合成：
            │     · 云端：POST {TTS_BASE_URL}/audio/speech（OpenAI 兼容）
            │     · 本地：Piper 二进制（app/tts_local.py）
            │
            └─ 若 cache_key 非空且音频 ≤2MB：_cache_set(key, audio, ex=TTS_CACHE_TTL_SECONDS)
                返回 (audio, content_type)
```

- **缓存键**：`rt:tts:<sha256("voice|fmt|text") 前40位十六进制>`（`_tts_cache_key`）。
- **值**：音频字节的 base64（Redis 客户端 `decode_responses=True`）。
- **TTL**：`TTS_CACHE_TTL_SECONDS`，默认 **300 秒（5 分钟）**。
- **超 2MB 不写**（单条 TTS 很小，兜底）。
- Redis 不可用时 `_cache_get/_cache_set` 静默跳过，直接合成，不影响主流程。

## 3. 手工触发式（`GET /tts/speak`）逐步

`app/main.py: tts_speak`。**生成与获取是同一个接口、同一次请求**，没有第二个拉取接口。

```
App                         任一后端副本(HTTP 负载均衡)              Redis(共享)
 │  GET /tts/speak?text=...  │                                        │
 │ ─────────────────────────>│ voice = 该用户保存的音色               │
 │                           │ key = sha256(voice|fmt|text)           │
 │                           │ ── GET key ──────────────────────────> │
 │                           │ <── 命中:base64 音频 ───────────────── │
 │                           │   (命中→直接用)                        │
 │                           │   (未命中→合成→SET key, EX=300) ─────> │
 │ <── 200 audio/mpeg 字节 ──│                                        │
 │  立即播放                 │                                        │
```

- **音色**来自 `db.get_user_tts_voice(user.id)`（用户在「设置→对话与字幕→AI 朗读音色」选的），未设则默认音色。
- 限流：`tts_user_rate_per_min`；并发满 → 429。

### 从 Redis 命中的条件（精确）
1. `use_cache=True`（仅 `/tts/speak`、`/tts/preview`）；
2. 5 分钟内有过一次**完全相同**的合成：**同音色 + 同格式 + 同文本**（三者拼成的 SHA256 一致）；
3. Redis 可达。
满足才直接返回缓存；否则现合成并回写。

### 为什么 HTTP 路径要用 Redis（多活）
手工触发是无状态 HTTP，请求可能落到任意副本，**重试可能落到另一台**。共享 Redis 让"A 合成过、B 重试命中"成立，省一次重复合成。生成即播、取不到就忽略下一步——所以只需短暂兜底，5 分钟即过期，不让动态语音堆积。

## 4. 沉浸式（`WS /roleplay/stream`）逐步

`app/main.py: roleplay_stream` 内的 `_send_tts`。**完全不碰 Redis**：AI 出一句就现合成、就地从这条 WS 推给 App。

```
App  ── WS /roleplay/stream ──  同一台后端(连接固定在这台)
 │  上传你的语音帧 + commit      │ ASR → 评分 → 推进 → 生成 AI 下一句
 │                              │ _send_tts(aiText):
 │                              │   synthesize(aiText, voice, use_cache=False)  ← 既不查也不写 Redis
 │ <── {ai_audio_begin, ct} ────│
 │ <── 二进制帧(每 16KB) ───────│   生成的音频按 16KB 分帧直接发回本连接
 │ <── {ai_audio_end} ──────────│
 │  收齐即播                    │
```

- **生成时机**：后端在该 WS 处理循环里、当 AI 产生新台词时调用 `_send_tts`。
- **获取方式**：同一条 WS 连接的二进制帧（`ai_audio_begin`/`ai_audio_end` JSON 帧夹着音频帧），不经 Redis、不经第二个接口。
- **为什么不缓存**：沉浸式每句 AI 回复基本唯一、只随这条流推一次、不会被复用；且 WS 连接固定在同一台，断了重连续上即可，不存在 HTTP 那种"重试落到别的副本要取音频"的问题。缓存它纯属浪费 Redis。

## 5. "未来对话会不会取到别人的/错的语音？"——不会

- 键是 **`sha256(voice|fmt|text)` 内容哈希**。不同文本 → 不同键，**不可能**命中到别的音频（要命中得撞 160-bit SHA256，密码学上不可能）。
- 命中只可能是"**同音色 + 同文本**"——那本就是同一段确定性合成语音，返回它是正确的。
- 键**不含 user_id**：两个用户用同音色读同一句话会共享同一份缓存音频——但这本就是逐字节相同的语音，无隐私、无串音问题。换音色或换文本即不同键。
- TTL 5 分钟过期；沉浸式根本不入键。所以"对话变多"只会让旧键自然过期，不会越积越多，也不会错位。

## 6. 相关配置（每节点 .env / k8s ConfigMap）

| 变量 | 含义 | 默认 |
|---|---|---|
| `TTS_CACHE_TTL_SECONDS` | 手工触发缓存 TTL | `300`（5 分钟） |
| `TTS_FORMAT` | 音频格式（云端 mp3 / 本地 Piper 须 wav） | `mp3` |
| `TTS_MAX_CONCURRENCY` | 合成并发上限（满则 429） | `8` |
| `TTS_USER_RATE_PER_MIN` | 每用户每分钟合成上限 | `30` |

> 云端凭据（`tts_base_url/api_key/model`、音色清单）是**入库参数**（管理台维护）；`TTS_MODE/FORMAT/本地命令`是每节点 env。详见 [deployment.md](deployment.md)。
