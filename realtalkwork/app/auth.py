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


def hash_password(password: str, salt: bytes | None = None) -> tuple[str, str]:
    salt = salt or os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 180_000)
    return _b64(salt), _b64(digest)


def verify_password(password: str, salt_b64: str, expected_b64: str) -> bool:
    salt = _unb64(salt_b64)
    _, digest = hash_password(password, salt=salt)
    return hmac.compare_digest(digest, expected_b64)


def create_token(user_id: str) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(hours=settings.token_ttl_hours)).timestamp()),
    }
    payload_b64 = _b64(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    signature = _sign(payload_b64)
    return f"{payload_b64}.{signature}"


def verify_token(token: str) -> str:
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

    if int(payload.get("exp", 0)) < int(time.time()):
        raise _unauthorized("登录已过期")

    user_id = payload.get("sub")
    if not isinstance(user_id, str) or not user_id:
        raise _unauthorized()
    return user_id


def _sign(payload_b64: str) -> str:
    digest = hmac.new(settings.jwt_secret.encode("utf-8"), payload_b64.encode("utf-8"), hashlib.sha256).digest()
    return _b64(digest)


def _b64(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _unb64(data: str) -> bytes:
    padding = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + padding)


def _unauthorized(detail: str = "认证失败") -> HTTPException:
    return HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=detail)
