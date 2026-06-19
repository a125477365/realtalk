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
    if settings.email_dev_mode:
        return
    if not settings.smtp_host or not settings.smtp_username or not settings.smtp_password:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="邮件服务未配置")

    message = EmailMessage()
    message["Subject"] = "RealTalk 邮箱验证码"
    message["From"] = settings.smtp_from
    message["To"] = email
    message.set_content(
        f"你的 RealTalk 验证码是：{code}\n\n"
        f"验证码 {settings.email_code_ttl_minutes} 分钟内有效。"
    )

    with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=15) as smtp:
        smtp.starttls()
        smtp.login(settings.smtp_username, settings.smtp_password)
        smtp.send_message(message)


def send_password_reset_email(email: str, token: str, base_url: str = "https://realtalk.app") -> None:
    if settings.email_dev_mode:
        return
    if not settings.smtp_host or not settings.smtp_username or not settings.smtp_password:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="邮件服务未配置")
    
    reset_url = f"{base_url}/auth/reset-password?token={token}"
    message = EmailMessage()
    message["Subject"] = "RealTalk 密码重置"
    message["From"] = settings.smtp_from
    message["To"] = email
    message.set_content(
        f"您请求重置 RealTalk 账号的密码。\n\n"
        f"请点击以下链接重置密码（链接 {settings.email_code_ttl_minutes * 6} 分钟内有效）：\n"
        f"{reset_url}\n\n"
        f"如果您没有请求重置密码，请忽略此邮件。\n"
        f"此链接只能使用一次。\n"
    )
    with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=15) as smtp:
        smtp.starttls()
        smtp.login(settings.smtp_username, settings.smtp_password)
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


def create_token(user_id: str, device_id: str | None = None) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "did": device_id,  # 绑定登录设备唯一编号，实现「同账号单设备登录」
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(hours=settings.token_ttl_hours)).timestamp()),
        "type": "access",
    }
    payload_b64 = _b64(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    signature = _sign(payload_b64)
    return f"{payload_b64}.{signature}"


def verify_token(token: str) -> tuple[str, str | None]:
    """返回 (user_id, device_id)。device_id 用于单设备登录校验。"""
    try:
        payload_b64, signature = token.split(".", 1)
    except ValueError as exc:
        raise _unauthorized() from exc

    if hmac.compare_digest(_sign(payload_b64), signature) is False:
        raise _unauthorized()

    try:
        payload = json.loads(_unb64(payload_b64))
    except (json.JSONDecodeError, ValueError) as exc:
        raise _unauthorized() from exc

    if payload.get("type") != "access":
        raise _unauthorized("无效的访问令牌")

    if int(payload.get("exp", 0)) < int(time.time()):
        raise _unauthorized("登录已过期")

    user_id = payload.get("sub")
    if not isinstance(user_id, str) or not user_id:
        raise _unauthorized()
    device_id = payload.get("did")
    return user_id, (device_id if isinstance(device_id, str) and device_id else None)


def create_refresh_token(user_id: str, device_id: str | None = None) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "did": device_id,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(days=30)).timestamp()),
        "type": "refresh",
    }
    payload_b64 = _b64(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    signature = _sign(payload_b64)
    return f"{payload_b64}.{signature}"


def verify_refresh_token(token: str) -> tuple[str, str | None]:
    try:
        payload_b64, signature = token.split(".", 1)
    except ValueError:
        raise _unauthorized()

    if hmac.compare_digest(_sign(payload_b64), signature) is False:
        raise _unauthorized()

    try:
        payload = json.loads(_unb64(payload_b64))
    except (json.JSONDecodeError, ValueError):
        raise _unauthorized()

    if payload.get("type") != "refresh":
        raise _unauthorized("无效的刷新令牌")

    if int(payload.get("exp", 0)) < int(time.time()):
        raise _unauthorized("刷新令牌已过期")

    user_id = payload.get("sub")
    if not isinstance(user_id, str) or not user_id:
        raise _unauthorized()
    device_id = payload.get("did")
    return user_id, (device_id if isinstance(device_id, str) and device_id else None)


def create_password_reset_token() -> tuple[str, str]:
    raw = os.urandom(24).hex()
    h = hashlib.sha256(raw.encode()).hexdigest()
    return raw, h


def _sign(payload_b64: str) -> str:
    digest = hmac.new(settings.jwt_secret.encode("utf-8"), payload_b64.encode("utf-8"), hashlib.sha256).digest()
    return _b64(digest)


def _b64(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return base64.b64encode(data).rstrip(b"=").decode("ascii")


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
