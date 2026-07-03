from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import random
import smtplib
import time
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage

from fastapi import HTTPException, status

from .settings import settings


def normalize_email(email: str) -> str:
    return email.strip().lower()


def make_email_code() -> str:
    return f"{random.SystemRandom().randint(0, 999999):06d}"


def hash_email_code(code: str) -> str:
    return hashlib.sha256(code.encode()).hexdigest()


def send_email_code(email: str, code: str) -> None:
    if settings.email_dev_mode:   # dev 开关是每节点部署项，仍走 env
        return
    from .storage import db

    cfg = db.resolve_smtp_config()   # 单一来源：只读 DB（装库时由 db_init 入库）
    if not cfg["host"] or not cfg["username"] or not cfg["password"]:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="邮件服务未配置")

    message = EmailMessage()
    message["Subject"] = "RealTalk 邮箱验证码"
    message["From"] = cfg["from_addr"]
    message["To"] = email
    message.set_content(
        f"你的 RealTalk 验证码是：{code}\n\n"
        f"验证码 {cfg['code_ttl_minutes']} 分钟内有效。"
    )

    with smtplib.SMTP(cfg["host"], cfg["port"], timeout=15) as smtp:
        smtp.starttls()
        smtp.login(cfg["username"], cfg["password"])
        smtp.send_message(message)


def send_password_reset_email(email: str, token: str, base_url: str = "https://realtalk.app") -> None:
    if settings.email_dev_mode:
        return
    from .storage import db

    cfg = db.resolve_smtp_config()   # 单一来源：只读 DB
    if not cfg["host"] or not cfg["username"] or not cfg["password"]:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="邮件服务未配置")

    reset_url = f"{base_url}/auth/reset-password?token={token}"
    message = EmailMessage()
    message["Subject"] = "RealTalk 密码重置"
    message["From"] = cfg["from_addr"]
    message["To"] = email
    message.set_content(
        f"您请求重置 RealTalk 账号的密码。\n\n"
        f"请点击以下链接重置密码（链接 {cfg['code_ttl_minutes'] * 6} 分钟内有效）：\n"
        f"{reset_url}\n\n"
        f"如果您没有请求重置密码，请忽略此邮件。\n"
        f"此链接只能使用一次。\n"
    )
    with smtplib.SMTP(cfg["host"], cfg["port"], timeout=15) as smtp:
        smtp.starttls()
        smtp.login(cfg["username"], cfg["password"])
        smtp.send_message(message)


def hash_password(password: str, salt: bytes | None = None) -> tuple[str, str]:
    salt = salt or os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 180_000)
    return _b64(salt), _b64(digest)


def verify_password(password: str, salt_b64: str, expected_b64: str) -> bool:
    salt = _unb64(salt_b64)
    _, digest = hash_password(password, salt=salt)
    return hmac.compare_digest(digest, expected_b64)


def hash_admin_password(password: str) -> tuple[str, str]:
    return hash_password(password)


def verify_admin_password(admin: dict, password: str) -> bool:
    return verify_password(password, admin["password_salt"], admin["password_hash"])


def create_token(user_id: str, device_id: str | None = None, token_version: int = 1, surface: str = "app") -> str:
    from .storage import db

    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "did": device_id,            # 绑定登录设备唯一编号，实现「同账号单设备登录」
        "tv": int(token_version),    # 令牌版本，递增即可服务端批量吊销该用户全部令牌
        "sur": surface,              # 登录端（app/web）：用于按端区分会话闲置超时时长
        "jti": os.urandom(6).hex(),  # 每次签发唯一，保证轮换出的令牌互不相同
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=db.get_access_token_ttl_minutes())).timestamp()),
        "type": "access",
    }
    payload_b64 = _b64(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    signature = _sign(payload_b64)
    return f"{payload_b64}.{signature}"


def verify_token(token: str) -> tuple[str, str | None, int, str]:
    """返回 (user_id, device_id, token_version, surface)。device_id/tv 用于单设备与吊销校验，surface 用于按端区分会话闲置超时。"""
    payload = _decode_token(token, expected_type="access", expired_detail="登录已过期")
    user_id = payload.get("sub")
    if not isinstance(user_id, str) or not user_id:
        raise _unauthorized()
    device_id = payload.get("did")
    surface = payload.get("sur")
    return (
        user_id,
        (device_id if isinstance(device_id, str) and device_id else None),
        int(payload.get("tv", 1) or 1),
        (surface if surface in ("app", "web") else "app"),
    )


def create_refresh_token(user_id: str, device_id: str | None = None, token_version: int = 1, surface: str = "app") -> str:
    from .storage import db

    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "did": device_id,
        "tv": int(token_version),
        "sur": surface,
        "jti": os.urandom(6).hex(),
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(days=db.get_refresh_token_ttl_days())).timestamp()),
        "type": "refresh",
    }
    payload_b64 = _b64(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    signature = _sign(payload_b64)
    return f"{payload_b64}.{signature}"


def verify_refresh_token(token: str) -> tuple[str, str | None, int, str]:
    payload = _decode_token(token, expected_type="refresh", expired_detail="刷新令牌已过期")
    user_id = payload.get("sub")
    if not isinstance(user_id, str) or not user_id:
        raise _unauthorized()
    device_id = payload.get("did")
    surface = payload.get("sur")
    return (
        user_id,
        (device_id if isinstance(device_id, str) and device_id else None),
        int(payload.get("tv", 1) or 1),
        (surface if surface in ("app", "web") else "app"),
    )


def _decode_token(token: str, expected_type: str, expired_detail: str) -> dict:
    # 兼容：旧版标准 base64 令牌经 URL 查询串传输时 '+' 会被解析成空格——令牌里绝不含空格，直接还原
    token = token.strip().replace(" ", "+")
    try:
        payload_b64, signature = token.split(".", 1)
    except ValueError as exc:
        raise _unauthorized() from exc

    # 签名比较前归一字母表：新令牌 URL-safe、旧令牌标准 base64，两者等价可互验
    if hmac.compare_digest(_norm_b64(_sign(payload_b64)), _norm_b64(signature)) is False:
        raise _unauthorized()

    try:
        payload = json.loads(_unb64(payload_b64))
    except (json.JSONDecodeError, ValueError) as exc:
        raise _unauthorized() from exc

    if payload.get("type") != expected_type:
        raise _unauthorized("无效的令牌")

    if int(payload.get("exp", 0)) < int(time.time()):
        raise _unauthorized(expired_detail)
    return payload


def create_password_reset_token() -> tuple[str, str]:
    raw = os.urandom(24).hex()
    h = hashlib.sha256(raw.encode()).hexdigest()
    return raw, h


_cached_jwt_secret: str | None = None
_INSECURE_JWT_DEFAULT = "change-me-before-production"


def _jwt_secret() -> str:
    """签名密钥：单一来源=共享 DB（装库时由 db_init 入库：库空则把 env JWT_SECRET 播种、否则随机生成）。
    多活各后端共用同一把，运行期只读 DB，不再按 env/文件多处优先取值。"""
    global _cached_jwt_secret
    if _cached_jwt_secret:
        return _cached_jwt_secret
    from .storage import db

    secret = db.get_or_create_jwt_secret()
    _cached_jwt_secret = secret
    return secret


def _sign(payload_b64: str) -> str:
    digest = hmac.new(_jwt_secret().encode("utf-8"), payload_b64.encode("utf-8"), hashlib.sha256).digest()
    return _b64(digest)


def _b64(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    # URL-safe：令牌要走 WebSocket 查询串，标准 base64 的 '+' 会被解析成空格导致签名校验失败
    # （表现为 WS 一连上就被 4401 关闭、客户端无限「网络不稳，正在重连」）。
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _norm_b64(value: str) -> str:
    """把 base64 字符串归一到 URL-safe 字母表，供签名比较——兼容旧版标准 base64 签发的令牌。"""
    return value.replace("+", "-").replace("/", "_")


def _unb64(data: str) -> bytes:
    data = data.replace("_", "/").replace("-", "+")
    padding = "=" * (-len(data) % 4)
    return base64.b64decode(data + padding)


def _unauthorized(detail: str = "认证失败") -> HTTPException:
    return HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=detail)


# ---- Admin session management (delegates to storage) ----

ADMIN_SESSION_TTL_HOURS = 168  # 7 days


def verify_admin_token(token: str) -> dict | None:
    from .storage import db
    return db.admin_session_verify(token)


def create_admin_token(
    admin_id: str,
    username: str,
    ip_address: str | None = None,
    user_agent: str | None = None,
) -> str:
    from .storage import db
    return db.admin_session_create(admin_id, username, ip_address, user_agent, ADMIN_SESSION_TTL_HOURS)


def destroy_admin_token(token: str) -> None:
    from .storage import db
    db.admin_session_destroy(token)


def destroy_all_admin_tokens(admin_id: str) -> None:
    from .storage import db
    db.admin_session_destroy_all(admin_id)


def cleanup_expired_admin_sessions() -> None:
    from .storage import db
    db.admin_session_cleanup()


def seed_default_admin() -> None:
    """Seed default admin account if no admins exist."""
    from .storage import db
    existing = db.admin_list_all(limit=1)
    if existing["total"] > 0:
        return
    salt, pw_hash = hash_admin_password(settings.admin_password)
    db.admin_create(
        username=settings.admin_username,
        password_salt=salt,
        password_hash=pw_hash,
        role="superadmin",
        display_name="管理员",
        email=None,
    )
