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


_INSECURE_JWT_DEFAULT = "change-me-before-production"


def _resolve_jwt_secret() -> str:
    """解析 JWT 签名密钥。

    安全要点：绝不使用众所周知的弱默认值——否则任何人都能伪造登录令牌冒充用户。
    优先取 JWT_SECRET 环境变量；未配置时落到一个持久化的随机密钥文件
    （令牌跨重启仍有效），文件不可写则退化为进程内随机密钥。
    """
    import secrets as _secrets

    env = os.getenv("JWT_SECRET")
    if env and env != _INSECURE_JWT_DEFAULT:
        return env
    secret_file = Path(os.getenv("JWT_SECRET_FILE", ".jwt_secret.key"))
    try:
        if secret_file.exists():
            existing = secret_file.read_text(encoding="utf-8").strip()
            if existing:
                return existing
        generated = _secrets.token_hex(32)
        secret_file.write_text(generated, encoding="utf-8")
        try:
            os.chmod(secret_file, 0o600)
        except OSError:
            pass
        return generated
    except OSError:
        return _secrets.token_hex(32)


@dataclass(frozen=True)
class Settings:
    database_url: str | None = os.getenv("DATABASE_URL")
    database_path: Path = Path(os.getenv("REALTALK_DB", "realtalk.sqlite3"))
    deployment_region: str = os.getenv("REALTALK_REGION") or os.getenv("REGION", "local")
    jwt_secret: str = _resolve_jwt_secret()
    jwt_secret_is_default: bool = os.getenv("JWT_SECRET", _INSECURE_JWT_DEFAULT) in ("", _INSECURE_JWT_DEFAULT)
    # 对话采集分块暂存：配置后用 Redis（TTL 自动过期、跨节点共享），否则回退本地文件
    redis_url: str | None = os.getenv("REDIS_URL")
    token_ttl_hours: int = int(os.getenv("TOKEN_TTL_HOURS", "720"))
    # 短效访问令牌 + 长效刷新令牌（参考成熟 App：缩小令牌被盗用的时间窗，配合刷新轮换）
    access_token_ttl_minutes: int = int(os.getenv("ACCESS_TOKEN_TTL_MINUTES", "60"))
    refresh_token_ttl_days: int = int(os.getenv("REFRESH_TOKEN_TTL_DAYS", "30"))
    # 会话「最近活跃」节流写入：超过该秒数才更新 last_seen，避免每请求一次写库
    last_seen_throttle_seconds: int = int(os.getenv("LAST_SEEN_THROTTLE_SECONDS", "120"))
    retention_days: int = int(os.getenv("RETENTION_DAYS", "3"))
    history_retention_days: int = int(os.getenv("HISTORY_RETENTION_DAYS", "90"))
    roleplay_accept_score: float = float(os.getenv("ROLEPLAY_ACCEPT_SCORE", "0.72"))
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
    asr_local_command: str | None = os.getenv("ASR_LOCAL_COMMAND")
    # 本地 whisper 模型大小（faster-whisper：tiny/base/small/medium/large-v3）
    asr_local_model: str = os.getenv("ASR_LOCAL_MODEL", "small")
    asr_dev_mode: bool = _bool_env("ASR_DEV_MODE", False)

    # 音频分布式：入口节点把上传文件转发给某个 worker 节点处理（共享同一数据库）
    # 逗号分隔的 worker 内部地址，如 "http://10.0.0.6:8000,http://10.0.0.7:8000"；留空=本机处理
    audio_worker_nodes: str | None = os.getenv("AUDIO_WORKER_NODES")
    # 节点间内部调用令牌（入口与 worker 必须一致）
    internal_token: str | None = os.getenv("INTERNAL_TOKEN")

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
    ai_base_url: str = os.getenv("AI_BASE_URL") or os.getenv("ARK_BASE_URL", "https://ark.cn-beijing.volces.com/api/v3")
    ai_model: str = os.getenv("AI_MODEL") or os.getenv("ARK_MODEL", "doubao-seed-1-6-251015")
    ai_timeout_seconds: float = float(os.getenv("AI_TIMEOUT_SECONDS") or os.getenv("ARK_TIMEOUT_SECONDS", "40"))
    # 成本估算：每百万 token 的价格（分）。用于管理台支出统计，可在管理台覆盖。
    ai_input_price_per_1m_cents: float = float(os.getenv("AI_INPUT_PRICE_PER_1M_CENTS", "80"))
    ai_output_price_per_1m_cents: float = float(os.getenv("AI_OUTPUT_PRICE_PER_1M_CENTS", "200"))

    # 高级会员实时语音大模型（OpenAI 兼容 Realtime API，WebSocket）。后端只做转发+护栏注入+结束评分。
    realtime_base_url: str = os.getenv("REALTIME_BASE_URL", "wss://api.openai.com/v1/realtime")
    realtime_api_key: str | None = os.getenv("REALTIME_API_KEY")
    realtime_model: str = os.getenv("REALTIME_MODEL", "gpt-4o-realtime-preview")
    realtime_voice: str = os.getenv("REALTIME_VOICE", "alloy")
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

    ark_api_key: str | None = os.getenv("ARK_API_KEY")
    ark_base_url: str = os.getenv("ARK_BASE_URL", "https://ark.cn-beijing.volces.com/api/v3")
    ark_model: str = os.getenv("ARK_MODEL", "doubao-seed-1-6-251015")
    ark_bot_id: str | None = os.getenv("ARK_BOT_ID")
    ark_timeout_seconds: float = float(os.getenv("ARK_TIMEOUT_SECONDS", "40"))

    apple_product_id: str = os.getenv("APPLE_PRODUCT_ID", "realtalk.pro.monthly")
    apple_bundle_id: str = os.getenv("APPLE_BUNDLE_ID", "com.realtalk.app")
    apple_issuer_id: str | None = os.getenv("APPLE_ISSUER_ID")
    apple_key_id: str | None = os.getenv("APPLE_KEY_ID")
    apple_private_key: str | None = os.getenv("APPLE_PRIVATE_KEY")
    apple_use_sandbox: bool = _bool_env("APPLE_USE_SANDBOX", True)
    apple_iap_dev_bypass: bool = _bool_env("APPLE_IAP_DEV_BYPASS", True)

    admin_frontend_url: str = os.getenv("ADMIN_FRONTEND_URL", "http://localhost:8080")

    # WeChat Pay (native payment)
    wechat_mchid: str | None = os.getenv("WECHAT_MCHID")
    wechat_api_key: str | None = os.getenv("WECHAT_API_KEY")
    wechat_ssl_cert_path: str | None = os.getenv("WECHAT_SSL_CERT_PATH")
    wechat_ssl_key_path: str | None = os.getenv("WECHAT_SSL_KEY_PATH")
    wechat_notify_url: str | None = os.getenv("WECHAT_NOTIFY_URL")

    # Alipay (当面付)
    alipay_app_id: str | None = os.getenv("ALIPAY_APP_ID")
    alipay_private_key: str | None = os.getenv("ALIPAY_PRIVATE_KEY")
    alipay_public_key: str | None = os.getenv("ALIPAY_PUBLIC_KEY")
    alipay_sandbox: bool = _bool_env("ALIPAY_SANDBOX", False)
    alipay_notify_url: str | None = os.getenv("ALIPAY_NOTIFY_URL")

    # Base URL for email links
    app_base_url: str = os.getenv("APP_BASE_URL", "https://realtalk.app")


settings = Settings()
