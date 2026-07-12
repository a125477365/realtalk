# TTS 语音：生成、缓存与获取流程（设计文档）

本文说明对练中 AI 台词语音（后端 TTS）**何时合成、是否进 Redis、何时获取、命中条件**，以及为什么不会取到别人的/错的语音。实时语音大模型（高级会员）的音频来自语音模型本身、不走本文路径，不在此列。

## 0. 一句话结论

- **所有播放路径都「缓存优先」**：取语音时先查 Redis，命中直接用、不再合成；未命中才现合成并写回缓存。
- **Redis 的作用是「提前生成下一句」**：每推进一轮对话，后端就把「本轮 + 下一轮」的 AI 台词在后台异步预先合成进 Redis，于是轮到播时基本都已命中、秒回，解决"字幕已显示但等 TTS 半天才出声"。
- **键是内容哈希**（音色|格式|文本），命中条件是三者完全一致；**TTL 30 分钟滑动**（被取用就续期，30 分钟没再用到才删）。不可能取到别人的/错的语音。
- 唯一不入 Redis 的是**实时语音大模型**（音频来自模型本身，不走本文路径）。

## 1. 两条播放路径

| 路径 | 触发接口 | 协议 | 进 Redis？ | 音频怎么到 App |
|---|---|---|---|---|
| 手工触发式 / 点读 | `GET /tts/speak` | HTTP | ✅ 查+写（`use_cache=True`） | 同一请求的响应体 |
| 试听音色 | `GET /tts/preview` | HTTP | ✅ 查+写 | 同一请求的响应体 |
| 沉浸式对练 | `WS /roleplay/stream`（内部 `_send_tts`） | WebSocket | ✅ 查+写（`use_cache=True`） | 同一条 WS 连接的二进制帧 |

三者最终都调用同一个 `voice_io.synthesize(text, voice, use_cache=...)`。

## 1.5 提前生成（核心优化）

对练台词是**剧本化**的（`scenario.lines` + 会话 `target_index`），所以"下一句 AI 说什么"是确定的、可提前算出。

- `roleplay_start`：建会话后，把**开场 AI 段** + **用户说完第一句后的 AI 段**丢后台异步合成进 Redis。
- `roleplay_message`（手工 `/roleplay/message`、语音 `/roleplay/message/audio`、以及沉浸式 WS 内部都走它）：每接受一轮，就把**本轮刚推送的 AI 段** + **用户下一句之后的 AI 段**异步预生成。
- 用的是该用户当前选定音色，缓存键与取用时一致 → 取用即命中。
- 预生成是 `asyncio.create_task` 后台跑，**不阻塞**本次响应；失败静默（取用时顶多现合成一次）。
- **最后一句**之后没有 AI 段（`_ai_line_run` 返回空）→ 不再预生成。

辅助函数：`_ai_line_run(scenario, selected_role, start)` 取"从 start 起一整段连续 AI 台词"；`_prewarm_tts(user_id, texts)` 后台合成入缓存。

## 2. 核心：`synthesize(text, voice, use_cache=True)`

`app/voice_io.py`。一次调用内完成"查缓存→（未命中）合成→（可选）写缓存→返回"：

```
text/voice 规整 → fmt = TTS_FORMAT（云端 mp3 / 本地 Qwen3-TTS wav）
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
            │     · 本地：speechserver 的 OpenAI 兼容 Qwen3-TTS
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
 │                           │   (未命中→合成→SET key, EX=1800滑动) ─> │
 │ <── 200 audio/mpeg 字节 ──│                                        │
 │  立即播放                 │                                        │
```

- **音色**来自 `db.get_user_tts_voice(user.id)`（用户在「设置→对话与字幕→AI 朗读音色」选的），未设则默认音色。
- 限流：`tts_user_rate_per_min`；并发满 → 429。

### 从 Redis 命中的条件（精确）
1. `use_cache=True`（`/tts/speak`、`/tts/preview`、沉浸式 `_send_tts` 都是 True）；
2. 当前有过一次**完全相同**的合成：**同音色 + 同格式 + 同文本**（三者拼成的 SHA256 一致），且距上次取用未超过 30 分钟（滑动）；通常是被「提前生成」预热进去的；
3. Redis 可达。
满足才直接返回缓存；否则现合成并回写。因为每轮都会提前生成下一段，正常对话里取用时基本都命中。

## 4. 沉浸式（`WS /roleplay/stream`）逐步

`app/main.py: roleplay_stream`。每轮内部调用 `roleplay_message`（与手工回合同一函数 → 同样触发「提前生成」），再由 `_send_tts` **先查 Redis 命中即秒回、未命中现合成并写回**，把音频推回这条 WS。

```
App  ── WS /roleplay/stream ──  后端
 │  上传你的语音帧 + commit      │ roleplay_message(): ASR→评分→推进→【异步提前生成 本轮+下一轮 AI 段】
 │                              │ _send_tts(aiText):
 │                              │   synthesize(aiText, voice, use_cache=True)  ← 先查 Redis(多半已预热)→命中秒回
 │ <── {ai_audio_begin, ct} ────│                                              未命中→合成→写回→推流
 │ <── 二进制帧(每 16KB) ───────│   音频按 16KB 分帧发回本连接
 │ <── {ai_audio_end} ──────────│
 │  收齐即播                    │
```

- **生成时机**：开场由 `roleplay_start` 预热；每轮由 `roleplay_message` 预热下一段；真正取用在 `_send_tts`。
- **获取方式**：同一条 WS 连接的二进制帧；不经第二个接口。
- 与手工触发的区别：手工是 App 用 `GET /tts/speak` 拉音频；沉浸式是后端在 WS 里直接推。**但两者都先查同一个 Redis、且都受同一套「提前生成」预热**，所以延迟体验一致。

## 5. "未来对话会不会取到别人的/错的语音？"——不会

- 键是 **`sha256(voice|fmt|text)` 内容哈希**。不同文本 → 不同键，**不可能**命中到别的音频（要命中得撞 160-bit SHA256，密码学上不可能）。
- 命中只可能是"**同音色 + 同文本**"——那本就是同一段确定性合成语音，返回它是正确的。
- 键**不含 user_id**：两个用户用同音色读同一句话会共享同一份缓存音频——但这本就是逐字节相同的语音，无隐私、无串音问题。换音色或换文本即不同键。
- **30 分钟滑动过期**：被取用就续期，30 分钟没再用到才删、下次重新合成。所以"对话变多"只会让没用到的旧键自然过期，不会越积越多，也不会错位。

## 6. 相关配置（每节点 .env / k8s ConfigMap）

| 变量 | 含义 | 默认 |
|---|---|---|
| `TTS_CACHE_TTL_SECONDS` | TTS 缓存 TTL（**滑动**：被取用就续期） | `1800`（30 分钟） |
| `TTS_FORMAT` | 音频格式（云端 mp3 / 本地 Qwen3-TTS 为 wav） | `mp3` |
| `TTS_MAX_CONCURRENCY` | 合成并发上限（满则 429） | `8` |
| `TTS_USER_RATE_PER_MIN` | 每用户每分钟合成上限 | `30` |

> 云端凭据（`tts_base_url/api_key/model`、音色清单）是**入库参数**（管理台维护）；`TTS_MODE/FORMAT/本地命令`是每节点 env。详见 [deployment.md](deployment.md)。
