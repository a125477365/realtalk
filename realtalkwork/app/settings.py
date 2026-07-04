from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _load_dotenv() -> None:
    candidates = [
        Path.cwd() / ".env",
        Path(__file__).resolve().parents[1] / ".env",
    ]
    for path in candidates:
        if not path.exists():
            continue
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_dotenv()


def _bool_env(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _multiline_env(name: str) -> str | None:
    """多行 PEM/证书类 env：setup.sh 写入时把换行转义为字面 \\n，这里还原成真实换行。
    （管理台维护时存的是真实换行，不经过这里。）"""
    value = os.getenv(name)
    return value.replace("\\n", "\n") if value else value


_INSECURE_JWT_DEFAULT = "change-me-before-production"


@dataclass(frozen=True)
class Settings:
    database_url: str | None = os.getenv("DATABASE_URL")
    database_path: Path = Path(os.getenv("REALTALK_DB", "realtalk.sqlite3"))
    deployment_region: str = os.getenv("REALTALK_REGION") or os.getenv("REGION", "local")
    # JWT 签名密钥单一来源=共享 DB（装库时 db_init 入库：库空则播种 env JWT_SECRET、否则随机生成）。
    # 不再从 env/本地文件解析为运行期来源；env JWT_SECRET 仅作首装播种值。
    # 对话采集分块暂存：配置后用 Redis（TTL 自动过期、跨节点共享），否则回退本地文件
    redis_url: str | None = os.getenv("REDIS_URL")
    token_ttl_hours: int = int(os.getenv("TOKEN_TTL_HOURS", "720"))
    # 短效访问令牌 + 长效刷新令牌（参考成熟 App：缩小令牌被盗用的时间窗，配合刷新轮换）
    access_token_ttl_minutes: int = int(os.getenv("ACCESS_TOKEN_TTL_MINUTES", "60"))
    refresh_token_ttl_days: int = int(os.getenv("REFRESH_TOKEN_TTL_DAYS", "30"))
    # 会话「最近活跃」节流写入：超过该秒数才更新 last_seen，避免每请求一次写库
    last_seen_throttle_seconds: int = int(os.getenv("LAST_SEEN_THROTTLE_SECONDS", "120"))
    # 会话闲置超时（按端区分）：超过该时长无任何请求即需重新登录；活跃使用会自动滑动续期。
    idle_timeout_app_minutes: int = int(os.getenv("IDLE_TIMEOUT_APP_MINUTES", str(7 * 24 * 60)))  # App：闲置 7 天
    idle_timeout_web_minutes: int = int(os.getenv("IDLE_TIMEOUT_WEB_MINUTES", "30"))              # 用户 web：闲置 30 分钟
    admin_idle_timeout_minutes: int = int(os.getenv("ADMIN_IDLE_TIMEOUT_MINUTES", "10"))          # 管理端 web：闲置 10 分钟
    retention_days: int = int(os.getenv("RETENTION_DAYS", "3"))
    history_retention_days: int = int(os.getenv("HISTORY_RETENTION_DAYS", "90"))
    roleplay_accept_score: float = float(os.getenv("ROLEPLAY_ACCEPT_SCORE", "0.6"))
    monthly_price_cents: int = int(os.getenv("MONTHLY_PRICE_CENTS", "3000"))
    online_window_minutes: int = int(os.getenv("ONLINE_WINDOW_MINUTES", "5"))
    admin_username: str = os.getenv("ADMIN_USERNAME", "admin")
    admin_password: str = os.getenv("ADMIN_PASSWORD", "admin123456")
    political_filter_enabled: bool = _bool_env("POLITICAL_FILTER_ENABLED", True)
    require_pro_for_ai: bool = _bool_env("REQUIRE_PRO_FOR_AI", False)

    # 会员体系：新用户首月免费试用基础会员
    trial_days: int = int(os.getenv("TRIAL_DAYS", "30"))
    # 每日 token 限额（按生效套餐），管理台可在 app_settings 覆盖
    daily_token_limit_free: int = int(os.getenv("DAILY_TOKEN_LIMIT_FREE", "8000"))
    daily_token_limit_basic: int = int(os.getenv("DAILY_TOKEN_LIMIT_BASIC", "120000"))
    daily_token_limit_premium: int = int(os.getenv("DAILY_TOKEN_LIMIT_PREMIUM", "400000"))

    # 音频上传（高级会员）
    upload_dir: Path = Path(os.getenv("UPLOAD_DIR", "./uploads"))
    audio_max_bytes: int = int(os.getenv("AUDIO_MAX_BYTES", str(300 * 1024 * 1024)))
    audio_max_seconds: int = int(os.getenv("AUDIO_MAX_SECONDS", str(6 * 3600)))
    # 语音转写：cloud=OpenAI 兼容 API，local=服务器本地命令行工具
    asr_mode: str = os.getenv("ASR_MODE", "cloud")
    asr_base_url: str | None = os.getenv("ASR_BASE_URL")
    asr_api_key: str | None = os.getenv("ASR_API_KEY")
    asr_model: str = os.getenv("ASR_MODEL", "whisper-1")
    # 本地转写命令模板：{input}=音频路径，{dir}=可写目录；命令需把文本打到 stdout 或在 {dir} 生成同名 .txt
    # 默认即镜像自带的内置脚本(faster-whisper)，故 ASR_MODE=local 开箱即用、无需另配命令。
    asr_local_command: str | None = os.getenv("ASR_LOCAL_COMMAND", "python /app/app/asr_local.py {input}")
    # 本地 whisper 模型大小（faster-whisper：tiny/base/small/medium/large-v3）
    asr_local_model: str = os.getenv("ASR_LOCAL_MODEL", "small")
    asr_dev_mode: bool = _bool_env("ASR_DEV_MODE", False)

    # 语音合成（TTS）：cloud=OpenAI 兼容 /audio/speech，local=服务器本地命令行（Piper/Coqui 等）
    tts_mode: str = os.getenv("TTS_MODE", "cloud")
    tts_base_url: str | None = os.getenv("TTS_BASE_URL")
    tts_api_key: str | None = os.getenv("TTS_API_KEY")
    tts_model: str = os.getenv("TTS_MODEL", "tts-1")
    # 可选音色列表（逗号分隔，供用户选择）与默认音色
    tts_voices: str = os.getenv("TTS_VOICES", "alloy,echo,fable,onyx,nova,shimmer")
    tts_default_voice: str = os.getenv("TTS_DEFAULT_VOICE", "alloy")
    # 本地合成命令模板：{voice}=音色，{out}=输出音频路径，文本经 stdin 传入；命令需在 {out} 生成音频
    # 默认即镜像自带的内置脚本(Piper)，故 TTS_MODE=local 开箱即用、无需另配命令。
    tts_local_command: str | None = os.getenv("TTS_LOCAL_COMMAND", "python /app/app/tts_local.py {voice} {out}")
    tts_format: str = os.getenv("TTS_FORMAT", "mp3")  # cloud 返回与本地输出的音频格式
    tts_dev_mode: bool = _bool_env("TTS_DEV_MODE", False)  # 未配置时返回静音占位，便于联调
    # TTS 结果缓存：作为「提前生成下一句」的暂存。滑动过期——每次被取用就续期，
    # 默认 30 分钟内没再被用到就删除，下次重新合成。合成并发上限、每用户每分钟上限同段。
    tts_cache_ttl_seconds: int = int(os.getenv("TTS_CACHE_TTL_SECONDS", "1800"))
    tts_max_concurrency: int = int(os.getenv("TTS_MAX_CONCURRENCY", "8"))
    # 本地 ASR 并发上限：每请求一个独立 whisper 进程(1~2GB 内存)，超出排队，防多用户同时说话挤爆内存
    asr_max_concurrency: int = int(os.getenv("ASR_MAX_CONCURRENCY", "3"))
    tts_user_rate_per_min: int = int(os.getenv("TTS_USER_RATE_PER_MIN", "30"))
    audio_user_rate_per_min: int = int(os.getenv("AUDIO_USER_RATE_PER_MIN", "30"))

    # 语音文件服务器（高级会员上传录音）：
    # - 可处理语音文件的服务器列表「ip:port;ip:port」在【管理台】配置并存库，未配置则上传直接报错（不本地兜底）。
    # - 本机地址：本服务器在上面列表中的 ip:port，用于判断「某文件是否归我处理」。语音服务器必须在 .env 设置。
    voice_node_addr: str | None = os.getenv("VOICE_NODE_ADDR")
    # 语音文件本地存放目录（已配则用之，否则放在 upload_dir/voice 下）
    voice_dir: Path = Path(os.getenv("VOICE_DIR", str(Path(os.getenv("UPLOAD_DIR", "./uploads")) / "voice")))

    # 数据库连接池（PostgreSQL 生效）
    db_pool_size: int = int(os.getenv("DB_POOL_SIZE", "10"))
    db_max_overflow: int = int(os.getenv("DB_MAX_OVERFLOW", "20"))
    email_code_ttl_minutes: int = int(os.getenv("EMAIL_CODE_TTL_MINUTES", "10"))
    email_dev_mode: bool = _bool_env("EMAIL_DEV_MODE", True)
    smtp_host: str | None = os.getenv("SMTP_HOST")
    smtp_port: int = int(os.getenv("SMTP_PORT", "587"))
    smtp_username: str | None = os.getenv("SMTP_USERNAME")
    smtp_password: str | None = os.getenv("SMTP_PASSWORD")
    smtp_from: str = os.getenv("SMTP_FROM", "RealTalk <noreply@realtalk.local>")

    payment_receiver_name: str = os.getenv("PAYMENT_RECEIVER_NAME", "RealTalk")
    wechat_receiver_account: str | None = os.getenv("WECHAT_RECEIVER_ACCOUNT")
    alipay_receiver_account: str | None = os.getenv("ALIPAY_RECEIVER_ACCOUNT")
    wechat_pay_url: str | None = os.getenv("WECHAT_PAY_URL")
    alipay_pay_url: str | None = os.getenv("ALIPAY_PAY_URL")
    payment_dev_auto_confirm: bool = _bool_env("PAYMENT_DEV_AUTO_CONFIRM", True)
    wechat_app_id: str | None = os.getenv("WECHAT_APP_ID")
    wechat_app_secret: str | None = os.getenv("WECHAT_APP_SECRET")
    # 微信开放平台「网站应用」凭据（Web 扫码登录与移动应用是两套 appid）
    wechat_web_app_id: str | None = os.getenv("WECHAT_WEB_APP_ID")
    wechat_web_app_secret: str | None = os.getenv("WECHAT_WEB_APP_SECRET")
    wechat_auth_dev_mode: bool = _bool_env("WECHAT_AUTH_DEV_MODE", True)
    # 邮箱注册默认关闭：垃圾邮箱可被批量注册薅免费试用，统一走微信认证
    email_auth_enabled: bool = _bool_env("EMAIL_AUTH_ENABLED", False)

    ai_api_key: str | None = os.getenv("AI_API_KEY") or os.getenv("ARK_API_KEY")
    ai_base_url: str | None = os.getenv("AI_BASE_URL") or os.getenv("ARK_BASE_URL")
    ai_model: str | None = os.getenv("AI_MODEL") or os.getenv("ARK_MODEL")
    # 普通任务(对话/评分/指导)超时：口语对话要跟手；模型挂死不该让用户干等两分钟
    ai_timeout_seconds: float = float(os.getenv("AI_TIMEOUT_SECONDS") or os.getenv("ARK_TIMEOUT_SECONDS", "30"))
    # 两档任务参数（管理台可配、存 DB）：长任务=场景生成(采集文字/语音文件→场景)+学习材料；其余(对话/评分)=普通任务。
    ai_timeout_long_seconds: float = float(os.getenv("AI_TIMEOUT_LONG_SECONDS", "1800"))
    ai_max_tokens_normal: int = int(os.getenv("AI_MAX_TOKENS_NORMAL", "4096"))
    ai_max_tokens_long: int = int(os.getenv("AI_MAX_TOKENS_LONG", "16384"))
    # 成本估算：每百万 token 的价格（分）。用于管理台支出统计，可在管理台覆盖。
    ai_input_price_per_1m_cents: float = float(os.getenv("AI_INPUT_PRICE_PER_1M_CENTS", "80"))
    ai_output_price_per_1m_cents: float = float(os.getenv("AI_OUTPUT_PRICE_PER_1M_CENTS", "200"))

    # 高级会员实时语音大模型（OpenAI 兼容 Realtime API 或智谱 GLM-Realtime，按 base_url 自动识别）。
    # 后端只做转发+护栏注入+结束评分。GLM 端点如 wss://open.bigmodel.cn/api/paas/v4/realtime。
    realtime_base_url: str = os.getenv("REALTIME_BASE_URL", "wss://api.openai.com/v1/realtime")
    realtime_api_key: str | None = os.getenv("REALTIME_API_KEY")
    realtime_model: str = os.getenv("REALTIME_MODEL", "gpt-4o-realtime-preview")
    realtime_voice: str = os.getenv("REALTIME_VOICE", "alloy")
    realtime_max_response_tokens: int = int(os.getenv("REALTIME_MAX_RESPONSE_TOKENS", "1024"))  # 每次回复输出上限(GLM≤1024)
    # 按分钟计费单价（分/分钟）。>0 时该会话按【时长】计费（GLM-Realtime 等按分钟计费的模型），
    # =0 时按 token 计费（OpenAI Realtime 等）。两种都计入同一「当月费用额度」（会员月费×比例）。
    realtime_price_per_minute_cents: float = float(os.getenv("REALTIME_PRICE_PER_MINUTE_CENTS", "0"))
    # 实时语音计费：文本/音频分开两组单价（分/百万 token）。音频 token 远贵于文本。
    realtime_input_text_price_per_1m_cents: float = float(os.getenv("REALTIME_INPUT_TEXT_PRICE_PER_1M_CENTS", "400"))
    realtime_input_audio_price_per_1m_cents: float = float(os.getenv("REALTIME_INPUT_AUDIO_PRICE_PER_1M_CENTS", "2800"))
    realtime_output_text_price_per_1m_cents: float = float(os.getenv("REALTIME_OUTPUT_TEXT_PRICE_PER_1M_CENTS", "1600"))
    realtime_output_audio_price_per_1m_cents: float = float(os.getenv("REALTIME_OUTPUT_AUDIO_PRICE_PER_1M_CENTS", "5600"))
    # 调用前费用预估：文本调用按输入字符估 prompt + 该输出上限估 completion
    ai_estimate_output_tokens: int = int(os.getenv("AI_ESTIMATE_OUTPUT_TOKENS", "800"))
    ai_estimate_min_input_tokens: int = int(os.getenv("AI_ESTIMATE_MIN_INPUT_TOKENS", "400"))
    # 月度 token 费用额度 = 购买会员时档位标准月费 × 该比例（剩余为项目利润）。管理台可在线配置。
    budget_ratio: float = float(os.getenv("BUDGET_RATIO", "0.5"))
    # 非会员（免费）每日限额：文字模型对话 token、采集文字输入 token、采集时长（秒）。管理台可在线改、实时生效。
    nonmember_daily_chat_tokens: int = int(os.getenv("NONMEMBER_DAILY_CHAT_TOKENS", "1000"))
    nonmember_daily_capture_tokens: int = int(os.getenv("NONMEMBER_DAILY_CAPTURE_TOKENS", "1000"))
    nonmember_daily_capture_seconds: int = int(os.getenv("NONMEMBER_DAILY_CAPTURE_SECONDS", "300"))

    ark_api_key: str | None = os.getenv("ARK_API_KEY")
    ark_base_url: str | None = os.getenv("ARK_BASE_URL")
    ark_model: str | None = os.getenv("ARK_MODEL")
    ark_bot_id: str | None = os.getenv("ARK_BOT_ID")
    ark_timeout_seconds: float = float(os.getenv("ARK_TIMEOUT_SECONDS", "40"))

    apple_product_id: str = os.getenv("APPLE_PRODUCT_ID", "realtalk.pro.monthly")
    apple_bundle_id: str = os.getenv("APPLE_BUNDLE_ID", "com.realtalk.app")
    apple_issuer_id: str | None = os.getenv("APPLE_ISSUER_ID")
    apple_key_id: str | None = os.getenv("APPLE_KEY_ID")
    apple_private_key: str | None = _multiline_env("APPLE_PRIVATE_KEY")  # .p8 私钥 PEM（首装由 db_init 入库）
    apple_use_sandbox: bool = _bool_env("APPLE_USE_SANDBOX", True)
    apple_iap_dev_bypass: bool = _bool_env("APPLE_IAP_DEV_BYPASS", True)

    admin_frontend_url: str = os.getenv("ADMIN_FRONTEND_URL", "http://localhost:8080")

    # WeChat Pay (native payment)
    wechat_mchid: str | None = os.getenv("WECHAT_MCHID")
    wechat_api_key: str | None = os.getenv("WECHAT_API_KEY")           # APIv3 密钥（回调验签解密用）
    wechat_platform_cert: str | None = _multiline_env("WECHAT_PLATFORM_CERT")  # 微信支付平台证书 PEM（验回调签名）
    wechat_cert_serial: str | None = os.getenv("WECHAT_CERT_SERIAL")      # 平台证书序列号（与回调 Wechatpay-Serial 比对）
    # 商户「下单签名」凭据：改存 DB（多活共用、运行期只读 DB）。这里只作首装播种来源（内容，非文件路径）。
    wechat_merchant_cert: str | None = _multiline_env("WECHAT_MERCHANT_CERT")          # 商户证书 PEM（取序列号）
    wechat_merchant_private_key: str | None = _multiline_env("WECHAT_MERCHANT_KEY")    # 商户私钥 PEM（下单签名）
    wechat_notify_url: str | None = os.getenv("WECHAT_NOTIFY_URL")        # 仅首装播种；运行期只读 DB

    # Alipay (当面付)
    alipay_app_id: str | None = os.getenv("ALIPAY_APP_ID")
    alipay_merchant_private_key: str | None = _multiline_env("ALIPAY_MERCHANT_PRIVATE_KEY")  # 应用私钥 PEM（下单签名）；首装播种
    alipay_public_key: str | None = _multiline_env("ALIPAY_PUBLIC_KEY")
    alipay_sandbox: bool = _bool_env("ALIPAY_SANDBOX", False)
    alipay_notify_url: str | None = os.getenv("ALIPAY_NOTIFY_URL")        # 仅首装播种；运行期只读 DB

    # Base URL for email links
    app_base_url: str = os.getenv("APP_BASE_URL", "https://realtalk.app")


settings = Settings()
