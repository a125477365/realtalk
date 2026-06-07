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


@dataclass(frozen=True)
class Settings:
    database_url: str | None = os.getenv("DATABASE_URL")
    database_path: Path = Path(os.getenv("REALTALK_DB", "realtalk.sqlite3"))
    deployment_region: str = os.getenv("REALTALK_REGION") or os.getenv("REGION", "local")
    jwt_secret: str = os.getenv("JWT_SECRET", "change-me-before-production")
    token_ttl_hours: int = int(os.getenv("TOKEN_TTL_HOURS", "720"))
    retention_days: int = int(os.getenv("RETENTION_DAYS", "3"))
    history_retention_days: int = int(os.getenv("HISTORY_RETENTION_DAYS", "90"))
    roleplay_accept_score: float = float(os.getenv("ROLEPLAY_ACCEPT_SCORE", "0.72"))
    monthly_price_cents: int = int(os.getenv("MONTHLY_PRICE_CENTS", "3000"))
    online_window_minutes: int = int(os.getenv("ONLINE_WINDOW_MINUTES", "5"))
    admin_username: str = os.getenv("ADMIN_USERNAME", "admin")
    admin_password: str = os.getenv("ADMIN_PASSWORD", "admin123456")
    political_filter_enabled: bool = _bool_env("POLITICAL_FILTER_ENABLED", True)
    require_pro_for_ai: bool = _bool_env("REQUIRE_PRO_FOR_AI", False)
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
    wechat_auth_dev_mode: bool = _bool_env("WECHAT_AUTH_DEV_MODE", True)

    ai_api_key: str | None = os.getenv("AI_API_KEY") or os.getenv("ARK_API_KEY")
    ai_base_url: str = os.getenv("AI_BASE_URL") or os.getenv("ARK_BASE_URL", "https://ark.cn-beijing.volces.com/api/v3")
    ai_model: str = os.getenv("AI_MODEL") or os.getenv("ARK_MODEL", "doubao-seed-1-6-251015")
    ai_timeout_seconds: float = float(os.getenv("AI_TIMEOUT_SECONDS") or os.getenv("ARK_TIMEOUT_SECONDS", "40"))

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


settings = Settings()
