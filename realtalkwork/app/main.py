from __future__ import annotations

import asyncio
import hashlib
import hmac
import json as _json
import secrets
import os
import uuid
from datetime import datetime, timedelta, timezone
from difflib import SequenceMatcher

import httpx
from fastapi import Depends, FastAPI, HTTPException, Query, status
from fastapi.responses import RedirectResponse, Response
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBasic, HTTPBasicCredentials, HTTPBearer

from .ark_client import evaluate_roleplay_turn, generate_ai_chat_reply, generate_learning, generate_scenario
from .auth import (
    create_admin_token, create_token, create_refresh_token,
    destroy_admin_token, hash_password, hash_email_code,
    make_email_code, normalize_email, send_email_code,
    send_password_reset_email, verify_password, verify_admin_token,
    verify_admin_password, verify_token, verify_refresh_token,
    create_password_reset_token, seed_default_admin,
)
from .billing import apple_billing, wechat_pay, alipay
from .content_policy import is_political_sensitive
from .schemas import (
    AdminCreateRequest,
    AdminListResponse,
    AdminOut,
    AdminPriceUpdateRequest,
    AdminUpdateRequest,
    AdminUserUpdateRequest,
    ApplePurchaseVerifyRequest,
    AuthRequest,
    AuthResponse,
    AuthTokenResponse,
    AIChatRequest,
    AIChatResponse,
    BillingAccountResponse,
    BillingResponse,
    EmailCodeRequest,
    EmailCodeResponse,
    EmailRegisterRequest,
    LearningGenerateRequest,
    LearningResponse,
    MessageResponse,
    PasswordChangeRequest,
    PasswordLoginRequest,
    PasswordRegisterRequest,
    PasswordResetConfirmRequest,
    PasswordResetSendRequest,
    PracticeHistoryResponse,
    PriceResponse,
    RechargeConfirmRequest,
    RechargeCreateRequest,
    RechargeQueryRequest,
    RechargeOrderResponse,
    RoleplayMessageRequest,
    RoleplaySessionRecord,
    RoleplayStartRequest,
    RoleplayStateResponse,
    ScenarioGenerateRequest,
    ScenarioResponse,
    SceneLine,
    TokenRefreshRequest,
    TrainingAnswerRequest,
    TrainingStartRequest,
    TrainingStateResponse,
    TranscriptQueryResponse,
    TranscriptUploadRequest,
    TranscriptUploadResponse,
    UserOut,
    WeChatLoginRequest,
)
from .settings import settings
from .storage import DatabaseIntegrityError, clean_transcript_items, db

app = FastAPI(title="RealTalk API", version="1.0.0")
security = HTTPBearer(auto_error=False)
admin_security = HTTPBasic(auto_error=False)

_af_url = os.getenv("ADMIN_FRONTEND_URL", "http://localhost:8080")
_is_localhost_af = (
    _af_url.startswith("http://localhost")
    or _af_url.startswith("http://127.0.0.1")
)


class DynamicCORSMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        origin = request.headers.get("origin", "")
        response = await call_next(request)
        if _is_localhost_af or origin == _af_url:
            response.headers["Access-Control-Allow-Origin"] = origin or "*"
            response.headers["Access-Control-Allow-Credentials"] = "true"
            response.headers["Access-Control-Allow-Methods"] = "*"
            response.headers["Access-Control-Allow-Headers"] = "*"
            response.headers["Access-Control-Expose-Headers"] = "Set-Cookie"
        return response


app.add_middleware(DynamicCORSMiddleware)


@app.on_event("startup")
async def startup() -> None:
    from .auth import seed_default_admin
    db.cleanup_expired()
    asyncio.create_task(_cleanup_loop())
    seed_default_admin()


async def current_user(credentials: HTTPAuthorizationCredentials | None = Depends(security)) -> UserOut:
    if credentials is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="缺少登录凭证")
    user_id = verify_token(credentials.credentials)
    user = db.get_user(user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="用户不存在")
    if user.is_banned:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="账号已被禁用")
    db.touch_user_seen(user.id)
    return user


async def current_admin(request: Request, credentials: HTTPBasicCredentials | None = Depends(admin_security)) -> dict:
    """Authenticate admin via session cookie or HTTP Basic. Returns admin dict."""
    session_token = request.cookies.get("admin_session")
    if session_token:
        admin = verify_admin_token(session_token)
        if admin:
            return admin
    if credentials is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="需要管理员登录",
            headers={"WWW-Authenticate": "Basic"},
        )
    admin = db.admin_get_by_username(credentials.username)
    if admin is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="管理员账号或密码错误",
            headers={"WWW-Authenticate": "Basic"},
        )
    if not admin["is_active"]:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="账号已被禁用",
            headers={"WWW-Authenticate": "Basic"},
        )
    if not verify_admin_password(admin, credentials.password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="管理员账号或密码错误",
            headers={"WWW-Authenticate": "Basic"},
        )
    return admin


_login_page_url = os.getenv("ADMIN_FRONTEND_URL", "http://localhost:8080").rstrip("/") + "/login"


@app.get("/admin/login-page")
async def admin_login_page() -> RedirectResponse:
    return RedirectResponse(_login_page_url, status_code=303)


@app.post("/admin/login")
async def admin_login(request: Request, response: Response) -> dict:
    form = await request.form()
    username = (form.get("username") or "").strip()
    password = form.get("password") or ""
    
    admin = db.admin_get_by_username(username)
    if admin is None:
        raise HTTPException(status_code=401, detail="用户名或密码错误")
    if not admin["is_active"]:
        raise HTTPException(status_code=403, detail="账号已被禁用")
    if not verify_admin_password(admin, password):
        raise HTTPException(status_code=401, detail="用户名或密码错误")
    
    client_ip = request.client.host if request.client else None
    user_agent = request.headers.get("user-agent")
    token = create_admin_token(admin["id"], admin["username"], client_ip, user_agent)
    
    db.admin_touch_login(admin["id"], client_ip)
    
    response.set_cookie(
        key="admin_session",
        value=token,
        httponly=True,
        max_age=60 * 60 * 24 * 7,
        path="/",
        samesite="none",
        secure=False,
    )
    return {"ok": True, "username": admin["username"], "role": admin["role"]}


@app.post("/admin/logout")
async def admin_logout(request: Request, response: Response) -> dict:
    token = request.cookies.get("admin_session")
    if token:
        destroy_admin_token(token)
    response.delete_cookie(key="admin_session", path="/")
    return {"ok": True}


@app.get("/health")
async def health() -> dict[str, str | int]:
    return {
        "status": "ok",
        "retention_days": settings.retention_days,
        "history_retention_days": settings.history_retention_days,
        "database": db.backend,
        "region": settings.deployment_region,
    }


@app.get("/ready")
async def ready() -> dict[str, str]:
    db.ping()
    return {"status": "ready", "database": db.backend, "region": settings.deployment_region}


@app.get("/billing/prices", response_model=PriceResponse)
async def billing_prices() -> PriceResponse:
    monthly_price_cents = db.get_monthly_price_cents()
    return PriceResponse(
        monthly_price_cents=monthly_price_cents,
        monthly_price_yuan=monthly_price_cents / 100,
        product_id=settings.apple_product_id,
    )


@app.get("/admin")
async def admin_console() -> RedirectResponse:
    return RedirectResponse("/admin/login", status_code=303)


@app.get("/admin/api/overview")
async def admin_overview(admin: dict = Depends(current_admin)) -> dict:
    return db.admin_overview()


@app.get("/admin/api/users")
async def admin_users(
    q: str | None = Query(default=None, max_length=120),
    limit: int = Query(default=100, ge=1, le=500),
    admin: dict = Depends(current_admin),
) -> dict:
    return {"items": db.admin_list_users(limit=limit, query=q)}


@app.get("/admin/api/users/{user_id}")
async def admin_user_detail(user_id: str, admin: dict = Depends(current_admin)) -> dict:
    detail = db.admin_get_user_detail(user_id)
    if detail is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="用户不存在")
    return detail


@app.patch("/admin/api/users/{user_id}")
async def admin_update_user(
    user_id: str,
    request: AdminUserUpdateRequest,
    admin: dict = Depends(current_admin),
) -> dict:
    detail = db.admin_update_user(
        user_id,
        display_name=request.display_name,
        plan=request.plan,
        balance_cents=request.balance_cents,
        balance_delta_cents=request.balance_delta_cents,
        is_banned=request.is_banned,
        admin_notes=request.admin_notes,
    )
    if detail is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="用户不存在")
    return detail


@app.post("/admin/api/settings/price")
async def admin_update_price(
    request: AdminPriceUpdateRequest,
    admin: dict = Depends(current_admin),
) -> PriceResponse:
    db.set_app_setting("monthly_price_cents", str(request.monthly_price_cents))
    return await billing_prices()


# ---- Admin CRUD ----

@app.get("/admin/api/admins", response_model=AdminListResponse)
async def admin_list_admins(
    q: str | None = Query(default=None, max_length=120),
    role: str | None = None,
    is_active: bool | None = None,
    limit: int = Query(default=20, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    _: dict = Depends(current_admin),
) -> AdminListResponse:
    result = db.admin_list_all(limit=limit, offset=offset, query=q, role=role, is_active=is_active)
    return AdminListResponse(
        items=[AdminOut(**item) for item in result["items"]],
        total=result["total"],
        limit=result["limit"],
        offset=result["offset"],
    )


@app.post("/admin/api/admins", response_model=AdminOut)
async def admin_create_admin(
    request: AdminCreateRequest,
    admin: dict = Depends(current_admin),
) -> AdminOut:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    
    existing = db.admin_get_by_username(request.username)
    if existing:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="用户名已存在")
    
    salt, pw_hash = hash_password(request.password)
    result = db.admin_create(
        username=request.username,
        password_salt=salt,
        password_hash=pw_hash,
        role=request.role,
        display_name=request.display_name,
        email=request.email,
    )
    return AdminOut(**result)


@app.patch("/admin/api/admins/{target_id}", response_model=AdminOut)
async def admin_update_target(
    target_id: str,
    request: AdminUpdateRequest,
    admin: dict = Depends(current_admin),
) -> AdminOut:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    
    # Prevent self-deactivation
    if target_id == admin["id"] and request.is_active is False:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="不能禁用自己的账号")
    
    update_kwargs: dict = {}
    if request.password is not None:
        salt, pw_hash = hash_password(request.password)
        update_kwargs["password_salt"] = salt
        update_kwargs["password_hash"] = pw_hash
    if request.role is not None:
        if admin["role"] != "superadmin" and request.role == "superadmin":
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
        update_kwargs["role"] = request.role
    if request.display_name is not None:
        update_kwargs["display_name"] = request.display_name
    if request.email is not None:
        update_kwargs["email"] = request.email
    if request.is_active is not None:
        update_kwargs["is_active"] = request.is_active
    
    result = db.admin_update(target_id, **update_kwargs)
    if result is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="管理员不存在")
    return AdminOut(**result)


@app.delete("/admin/api/admins/{target_id}")
async def admin_delete_target(
    target_id: str,
    admin: dict = Depends(current_admin),
) -> MessageResponse:
    if admin["role"] != "superadmin":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="仅超级管理员可删除账号")
    if target_id == admin["id"]:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="不能删除自己的账号")
    
    success = db.admin_delete(target_id)
    if not success:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="管理员不存在")
    return MessageResponse(message="管理员已删除")


@app.post("/auth/email/code", response_model=EmailCodeResponse)
async def send_register_email_code(request: EmailCodeRequest) -> EmailCodeResponse:
    raise HTTPException(status_code=status.HTTP_410_GONE, detail="仅支持微信快速授权登录")


@app.post("/auth/register", response_model=AuthResponse)
async def register(request: EmailRegisterRequest) -> AuthResponse:
    raise HTTPException(status_code=status.HTTP_410_GONE, detail="仅支持微信快速授权登录")


@app.post("/auth/login", response_model=AuthResponse)
async def login(request: AuthRequest) -> AuthResponse:
    raise HTTPException(status_code=status.HTTP_410_GONE, detail="仅支持微信快速授权登录")


@app.post("/auth/wechat/login", response_model=AuthResponse)
async def wechat_login(request: WeChatLoginRequest) -> AuthResponse:
    profile = await resolve_wechat_profile(request)
    salt, password_hash = hash_password(profile["openid"])
    try:
        user = db.get_or_create_wechat_user(
            profile["openid"],
            profile.get("nickname"),
            profile.get("avatar_url"),
            salt,
            password_hash,
        )
    except DatabaseIntegrityError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="微信账号已存在") from exc
    if user.is_banned:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="账号已被禁用")
    return AuthResponse(token=create_token(user.id), user=user)


# ---- Email/Password Auth for App Users ----

@app.post("/auth/password/register", response_model=AuthTokenResponse)
async def register_password(
    request: PasswordRegisterRequest,
) -> AuthTokenResponse:
    normalized = normalize_email(request.email)
    existing = db.get_user_by_login_identifier(normalized)
    if existing:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="该邮箱已注册")
    
    if not db.consume_email_code(normalized, hash_email_code(request.code)):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="验证码无效或已过期")
    
    salt, pw_hash = hash_password(request.password)
    user = db.create_user(normalized, salt, pw_hash)
    return AuthTokenResponse(
        access_token=create_token(user.id),
        refresh_token=create_refresh_token(user.id),
        expires_in=int(settings.token_ttl_hours * 3600),
    )


@app.post("/auth/password/login", response_model=AuthTokenResponse)
async def login_password(
    request: PasswordLoginRequest,
) -> AuthTokenResponse:
    normalized = normalize_email(request.email)
    row = db.get_user_by_login_identifier(normalized)
    if row is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="邮箱或密码错误")
    if row.get("wechat_openid"):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="该账号使用微信登录，请使用微信授权")
    
    if not verify_password(request.password, row["password_salt"], row["password_hash"]):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="邮箱或密码错误")
    
    user = db.get_user(row["id"])
    if user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="用户不存在")
    if user.is_banned:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="账号已被禁用")
    
    db.touch_user_seen(user.id)
    return AuthTokenResponse(
        access_token=create_token(user.id),
        refresh_token=create_refresh_token(user.id),
        expires_in=int(settings.token_ttl_hours * 3600),
    )


@app.post("/auth/password/change", response_model=AuthTokenResponse)
async def change_password(
    request: PasswordChangeRequest,
    user: UserOut = Depends(current_user),
) -> AuthTokenResponse:
    row = db.get_user_row(user.id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="用户不存在")
    if not verify_password(request.old_password, row["password_salt"], row["password_hash"]):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="原密码错误")
    
    salt, pw_hash = hash_password(request.new_password)
    db.update_user_password(user.id, salt, pw_hash)
    return AuthTokenResponse(
        access_token=create_token(user.id),
        refresh_token=create_refresh_token(user.id),
        expires_in=int(settings.token_ttl_hours * 3600),
    )


@app.post("/auth/password/reset/send")
async def send_password_reset(
    request: PasswordResetSendRequest,
) -> MessageResponse:
    normalized = normalize_email(request.email)
    user = db.get_user_by_login_identifier(normalized)
    if user is not None:
        raw_token, token_hash = create_password_reset_token()
        ttl_minutes = settings.email_code_ttl_minutes
        expires_at = datetime.now(timezone.utc) + timedelta(minutes=ttl_minutes * 6)
        db.create_email_reset_token(user.id, normalized, token_hash, expires_at)
        send_password_reset_email(normalized, raw_token, settings.app_base_url)
    
    return MessageResponse(message="如果该邮箱已注册，重置邮件已发送")


@app.post("/auth/password/reset/confirm", response_model=AuthTokenResponse)
async def confirm_password_reset(
    request: PasswordResetConfirmRequest,
) -> AuthTokenResponse:
    raw_hash = hashlib.sha256(request.token.encode()).hexdigest()
    result = db.consume_email_reset_token(raw_hash)
    if result is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="重置链接无效或已过期")
    
    salt, pw_hash = hash_password(request.new_password)
    db.user_password_reset(result["user_id"], salt, pw_hash)
    
    return AuthTokenResponse(
        access_token=create_token(result["user_id"]),
        refresh_token=create_refresh_token(result["user_id"]),
        expires_in=int(settings.token_ttl_hours * 3600),
    )


@app.post("/auth/token/refresh", response_model=AuthTokenResponse)
async def refresh_token(
    request: TokenRefreshRequest,
) -> AuthTokenResponse:
    user_id = verify_refresh_token(request.refresh_token)
    user = db.get_user(user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="用户不存在")
    if user.is_banned:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="账号已被禁用")
    
    db.touch_user_seen(user.id)
    return AuthTokenResponse(
        access_token=create_token(user.id),
        refresh_token=create_refresh_token(user.id),
        expires_in=int(settings.token_ttl_hours * 3600),
    )


@app.post("/auth/email/code")
async def send_register_code(
    request: EmailCodeRequest,
) -> EmailCodeResponse:
    email = normalize_email(request.email)
    existing = db.get_user_by_login_identifier(email)
    if existing:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="该邮箱已注册，请直接登录或使用找回密码")
    
    code = make_email_code()
    send_email_code(email, code)
    
    ttl_seconds = settings.email_code_ttl_minutes * 60
    expires_at = datetime.now(timezone.utc) + timedelta(minutes=settings.email_code_ttl_minutes)
    db.store_email_code(email, hash_email_code(code), expires_at)
    
    if settings.email_dev_mode:
        return EmailCodeResponse(sent=True, expires_in_seconds=ttl_seconds, dev_code=code)
    return EmailCodeResponse(sent=True, expires_in_seconds=ttl_seconds)


@app.get("/auth/me", response_model=UserOut)
async def me(user: UserOut = Depends(current_user)) -> UserOut:
    return user


@app.post("/ai/chat", response_model=AIChatResponse)
async def ai_chat(request: AIChatRequest, user: UserOut = Depends(current_user)) -> AIChatResponse:
    require_ai_access(user)
    if is_political_sensitive(request.message):
        return AIChatResponse(reply="")
    scenario = db.get_scenario(user.id, request.scene_id) if request.scene_id else None
    reply = await generate_ai_chat_reply(request.message.strip(), request.messages, scenario)
    return AIChatResponse(reply=reply)


@app.get("/billing/account", response_model=BillingAccountResponse)
async def billing_account(user: UserOut = Depends(current_user)) -> BillingAccountResponse:
    updated = db.get_user(user.id) or user
    return BillingAccountResponse(user=updated, ledger=db.list_billing_ledger(user.id))


@app.post("/billing/recharge", response_model=RechargeOrderResponse)
async def create_recharge(
    request: RechargeCreateRequest,
    http_request: Request,
    user: UserOut = Depends(current_user),
) -> RechargeOrderResponse:
    if request.method == "admin":
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="无效支付方式")
    
    if request.method == "wechat" and not settings.wechat_mchid:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="微信支付暂不可用")
    if request.method == "alipay" and not settings.alipay_app_id:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="支付宝暂不可用")
    
    client_ip = http_request.client.host if http_request.client else "127.0.0.1"
    
    if request.method == "wechat" and settings.wechat_notify_url:
        try:
            result = await wechat_pay.create_unified_order(
                out_trade_no=str(uuid.uuid4()),
                total_fee=request.amount_cents,
                description=f"RealTalk充值{request.amount_cents / 100:.0f}元",
                notify_url=settings.wechat_notify_url,
                client_ip=client_ip,
            )
            
            order = db.create_recharge_order(
                user.id,
                request.method,
                request.amount_cents,
                payment_url=result.get("code_url"),
                qr_code_text=result.get("code_url"),
                receiver_name=settings.payment_receiver_name,
                receiver_account=settings.wechat_receiver_account,
            )
            return RechargeOrderResponse(
                order_id=order.order_id,
                method=order.method,
                amount_cents=order.amount_cents,
                status=order.status,
                qr_code_text=result.get("code_url"),
                qr_code_url=f"https://api.qrserver.com/v1/create-qr-code/?size=200x200&data={_json.dumps(result.get('code_url', ''))}",
                message="请使用微信扫描二维码支付",
                created_at=order.created_at,
                expires_at=datetime.now(timezone.utc) + timedelta(minutes=30),
            )
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=f"微信支付创建失败: {str(e)[:100]}")
    
    if request.method == "alipay" and settings.alipay_notify_url:
        try:
            result = await alipay.create_trade_precreate(
                out_trade_no=str(uuid.uuid4()),
                total_amount=request.amount_cents / 100.0,
                subject=f"RealTalk充值{request.amount_cents / 100:.0f}元",
                notify_url=settings.alipay_notify_url,
            )
            
            order = db.create_recharge_order(
                user.id,
                request.method,
                request.amount_cents,
                payment_url=result.get("qr_code"),
                qr_code_text=result.get("qr_code"),
                receiver_name=settings.payment_receiver_name,
                receiver_account=settings.alipay_receiver_account,
            )
            return RechargeOrderResponse(
                order_id=order.order_id,
                method=order.method,
                amount_cents=order.amount_cents,
                status=order.status,
                qr_code_text=result.get("qr_code"),
                qr_code_url=f"https://api.qrserver.com/v1/create-qr-code/?size=200x200&data={_json.dumps(result.get('qr_code', ''))}",
                message="请使用支付宝扫描二维码支付",
                created_at=order.created_at,
                expires_at=datetime.now(timezone.utc) + timedelta(minutes=30),
            )
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=f"支付宝创建失败: {str(e)[:100]}")
    
    # Fallback: manual payment (fake QR for dev)
    method_settings = payment_method_settings(request.method)
    order = db.create_recharge_order(
        user.id,
        request.method,
        request.amount_cents,
        payment_url=method_settings["payment_url"],
        qr_code_text=method_settings["qr_code_text"],
        receiver_name=settings.payment_receiver_name,
        receiver_account=method_settings["receiver_account"],
    )
    order.message = "请使用" + method_settings["title"] + "向收款账号支付 " + money_text(request.amount_cents) + "，付款备注订单号。"
    return order


@app.post("/billing/recharge/confirm", response_model=BillingAccountResponse)
async def confirm_recharge(
    request: RechargeConfirmRequest,
    user: UserOut = Depends(current_user),
) -> BillingAccountResponse:
    # In production (real payment), this is only called via webhook
    # For dev mode, allow manual confirmation
    if not settings.payment_dev_auto_confirm:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="生产环境请通过微信/支付宝支付回调确认到账",
        )
    
    try:
        _, updated_user = db.mark_recharge_paid(user.id, request.order_id)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="充值订单不存在") from exc
    
    return BillingAccountResponse(user=updated_user, ledger=db.list_billing_ledger(user.id))


@app.post("/billing/apple/verify", response_model=BillingResponse)
async def verify_apple_purchase(
    request: ApplePurchaseVerifyRequest,
    user: UserOut = Depends(current_user),
) -> BillingResponse:
    verified, expires_at, message = await apple_billing.verify(request)
    updated_user = db.update_subscription(user.id, request.original_transaction_id, expires_at)
    return BillingResponse(user=updated_user, verified=verified, message=message)


# ---- Payment Webhooks ----

@app.post("/payment/wechat/webhook")
async def wechat_payment_webhook(request: Request) -> dict:
    """WeChat Pay v3 async notification handler."""
    body = await request.body()
    headers = dict(request.headers)
    
    if not settings.wechat_mchid:
        return {"code": "FAIL", "message": "not configured"}
    
    try:
        payload = _json.loads(body)
    except Exception:
        return {"code": "FAIL", "message": "invalid json"}
    
    event_type = payload.get("event_type", "")
    resource = payload.get("resource", {})
    out_trade_no = resource.get("out_trade_no", "")
    
    if not out_trade_no:
        return {"code": "FAIL", "message": "no order id"}
    
    payload_json = _json.dumps(payload)
    webhook_id = db.store_payment_webhook(out_trade_no, "wechat", event_type, payload_json)
    
    if event_type == "TRANSACTION.SUCCESS":
        trade_state = resource.get("trade_state", "")
        if trade_state == "SUCCESS":
            trade_data = resource.get("amount", {})
            paid_amount = int(trade_data.get("total", 0))
            
            if paid_amount > 0:
                try:
                    _, _ = db.mark_recharge_paid_by_order_id(out_trade_no, paid_amount)
                    db.mark_webhook_processed(webhook_id)
                except Exception as e:
                    db.mark_webhook_failed(webhook_id, str(e)[:200])
                    return {"code": "FAIL", "message": str(e)[:100]}
    
    db.mark_webhook_processed(webhook_id)
    return {"code": "SUCCESS", "message": "OK"}


@app.post("/payment/alipay/webhook")
async def alipay_payment_webhook(request: Request) -> str:
    """Alipay async notification handler. Returns 'success' plain text."""
    form = await request.form()
    
    if not settings.alipay_app_id:
        return "fail"
    
    try:
        params = dict(form)
        out_trade_no = params.get("out_trade_no", "")
        trade_status = params.get("trade_status", "")
        
        if not out_trade_no:
            return "fail"
        
        payload_json = _json.dumps(params)
        webhook_id = db.store_payment_webhook(out_trade_no, "alipay", trade_status, payload_json)
        
        if trade_status in ("TRADE_SUCCESS", "TRADE_FINISHED"):
            total_amount = float(params.get("total_amount", 0))
            paid_cents = int(total_amount * 100)
            
            if paid_cents > 0:
                try:
                    _, _ = db.mark_recharge_paid_by_order_id(out_trade_no, paid_cents)
                    db.mark_webhook_processed(webhook_id)
                except Exception as e:
                    db.mark_webhook_failed(webhook_id, str(e)[:200])
                    return "fail"
        
        db.mark_webhook_processed(webhook_id)
    except Exception as e:
        return "fail"
    
    return "success"


@app.post("/payment/query")
async def query_payment_status(
    order_id: str = Query(...),
    user: UserOut = Depends(current_user),
) -> dict:
    """Query payment order status from provider."""
    with db.engine.connect() as conn:
        from sqlalchemy import select, text
        row = conn.execute(
            text("SELECT method, status, amount_cents FROM payment_orders WHERE order_id = :oid AND user_id = :uid"),
            {"oid": order_id, "uid": user.id}
        ).fetchone()
    
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="订单不存在")
    
    method = row[0]
    status = row[1]
    
    provider_status = "unknown"
    if status == "pending" and method in ("wechat", "alipay"):
        try:
            if method == "wechat" and settings.wechat_mchid:
                result = await wechat_pay.query_order(order_id)
                provider_status = result.get("trade_state", "unknown")
                if provider_status == "SUCCESS":
                    amount = int(result.get("amount", {}).get("total", 0))
                    if amount > 0:
                        _, _ = db.mark_recharge_paid_by_order_id(order_id, amount)
                        status = "paid"
            elif method == "alipay" and settings.alipay_app_id:
                result = await alipay.query_trade(order_id)
                provider_status = result.get("trade_status", "unknown")
                if provider_status in ("TRADE_SUCCESS", "TRADE_FINISHED"):
                    total = float(result.get("total_amount", 0))
                    if total > 0:
                        _, _ = db.mark_recharge_paid_by_order_id(order_id, int(total * 100))
                        status = "paid"
        except HTTPException:
            pass
    
    return {"order_id": order_id, "status": status, "provider_status": provider_status}


@app.post("/transcript/upload", response_model=TranscriptUploadResponse)
async def upload_transcripts(
    request: TranscriptUploadRequest,
    user: UserOut = Depends(current_user),
) -> TranscriptUploadResponse:
    db.cleanup_expired()
    uploaded = db.insert_transcripts(user.id, request.items)
    return TranscriptUploadResponse(uploaded=uploaded, retention_days=settings.retention_days)


@app.get("/transcript/query", response_model=TranscriptQueryResponse)
async def query_transcripts(
    start: datetime | None = Query(default=None),
    end: datetime | None = Query(default=None),
    user: UserOut = Depends(current_user),
) -> TranscriptQueryResponse:
    now = datetime.now(timezone.utc)
    start = start or (now - timedelta(hours=1))
    end = end or now
    return TranscriptQueryResponse(items=db.query_transcripts(user.id, start, end))


@app.post("/learning/generate", response_model=LearningResponse)
async def learning_generate(
    request: LearningGenerateRequest,
    user: UserOut = Depends(current_user),
) -> LearningResponse:
    require_ai_access(user)
    items = materialize_items(user.id, request.start, request.end, request.items)
    if not items:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="当前时间范围没有对话")
    return await generate_learning(items)


@app.post("/scenario/generate", response_model=ScenarioResponse)
async def scenario_generate(
    request: ScenarioGenerateRequest,
    user: UserOut = Depends(current_user),
) -> ScenarioResponse:
    require_ai_access(user)
    items = materialize_items(user.id, request.start, request.end, request.items)
    if not items:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="当前时间范围没有对话")
    scenario = await generate_scenario(items)
    return db.create_scenario(user.id, request.start, request.end, scenario)


@app.post("/roleplay/start", response_model=RoleplayStateResponse)
async def roleplay_start(
    request: RoleplayStartRequest,
    user: UserOut = Depends(current_user),
) -> RoleplayStateResponse:
    require_ai_access(user)
    if request.scene_id:
        scenario = db.get_scenario(user.id, request.scene_id)
        if scenario is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="场景不存在")
    else:
        items = materialize_items(user.id, request.start, request.end, request.items)
        if not items:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="当前时间范围没有对话")
        scenario = db.create_scenario(user.id, request.start, request.end, await generate_scenario(items))

    role_ids = {role.id for role in scenario.roles if role.is_user_candidate}
    if request.selected_role not in role_ids:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="请选择可扮演的角色")

    ai_role = next((role.id for role in scenario.roles if role.id != request.selected_role), request.selected_role)
    session = db.create_roleplay_session(user.id, scenario.scene_id, request.selected_role, ai_role)
    session = push_ai_lines_until_user_turn(user.id, session, scenario)
    db.update_roleplay_session(session)
    return roleplay_state_response(user.id, session, scenario)


@app.post("/roleplay/message", response_model=RoleplayStateResponse)
async def roleplay_message(
    request: RoleplayMessageRequest,
    user: UserOut = Depends(current_user),
) -> RoleplayStateResponse:
    require_ai_access(user)
    session = db.get_roleplay_session(user.id, request.session_id)
    if session is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="场景练习不存在")
    scenario = db.get_scenario(user.id, session.scene_id)
    if scenario is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="场景不存在")
    if session.status == "completed":
        return roleplay_state_response(user.id, session, scenario, latest_feedback="这轮练习已完成")

    target_line = next_user_line(session, scenario)
    if target_line is None:
        session.status = "completed"
        db.update_roleplay_session(session)
        return roleplay_state_response(user.id, session, scenario, latest_feedback="这轮练习已完成")

    evaluation = await evaluate_roleplay_turn(
        request.message.strip(),
        target_line,
        scenario,
        db.list_roleplay_messages(user.id, session.session_id),
    )
    score = evaluation.score
    accepted = evaluation.accepted and score >= settings.roleplay_accept_score
    had_rejected_attempt = db.has_rejected_practice_attempt(
        user.id,
        session.session_id,
        target_line.index,
        settings.roleplay_accept_score,
    )
    feedback = format_roleplay_feedback(
        evaluation.feedback,
        evaluation.correction,
        accepted,
        had_rejected_attempt,
    )
    stored_feedback = feedback or evaluation.feedback.strip() or "回答正确，已继续下一句。"
    db.add_roleplay_message(
        user.id,
        session.session_id,
        speaker="user",
        role=session.selected_role,
        content=request.message.strip(),
        translation=target_line.source_text,
        feedback=feedback or None,
    )
    db.add_practice_result(
        user.id,
        session.session_id,
        scenario.scene_id,
        target_line.index,
        evaluation.correction,
        request.message.strip(),
        score,
        stored_feedback,
    )

    if accepted:
        session.turns += 1
        session.score_total += score
        session.target_index = target_line.index + 1
        session = push_ai_lines_until_user_turn(user.id, session, scenario)
        if next_user_line(session, scenario) is None:
            session.status = "completed"
    db.update_roleplay_session(session)
    return roleplay_state_response(
        user.id,
        session,
        scenario,
        latest_feedback=feedback or None,
        latest_accepted=accepted,
    )


@app.get("/practice/history", response_model=PracticeHistoryResponse)
async def practice_history(
    limit: int = Query(default=20, ge=1, le=100),
    user: UserOut = Depends(current_user),
) -> PracticeHistoryResponse:
    return PracticeHistoryResponse(items=db.list_practice_history(user.id, limit=limit))


@app.post("/training/start", response_model=TrainingStateResponse)
async def training_start(
    request: TrainingStartRequest,
    user: UserOut = Depends(current_user),
) -> TrainingStateResponse:
    require_ai_access(user)
    items = materialize_items(user.id, request.start, request.end, request.items)
    if not items:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="当前时间范围没有对话")
    learning = await generate_learning(items)
    drills = learning.drills[:8]
    if not drills:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="没有可训练的句子")
    session = db.create_session(user.id, drills)
    return state_response(session)


@app.post("/training/answer", response_model=TrainingStateResponse)
async def training_answer(
    request: TrainingAnswerRequest,
    user: UserOut = Depends(current_user),
) -> TrainingStateResponse:
    require_ai_access(user)
    session = db.get_session(user.id, request.session_id)
    if session is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="训练会话不存在")
    if session.status == "completed" or session.index >= len(session.items):
        session.status = "completed"
        db.update_session(session)
        return state_response(session, feedback="训练已完成")

    current = session.items[session.index]
    similarity = SequenceMatcher(None, normalize(request.answer), normalize(current.answer)).ratio()
    correct = similarity >= 0.72

    if correct:
        session.index += 1
        session.score += 1
        feedback = "通过，进入下一句。"
        correction = current.answer
    else:
        feedback = "还没有通过，请完成当前句后再进入下一句。"
        correction = "参考答案：" + current.answer

    if session.index >= len(session.items):
        session.status = "completed"
        feedback = "训练完成，得分 " + str(session.score) + "/" + str(len(session.items)) + "。"

    db.update_session(session)
    return state_response(session, feedback=feedback, correction=correction)


def require_ai_access(user: UserOut) -> None:
    if settings.require_pro_for_ai and user.plan != "pro":
        raise HTTPException(status_code=status.HTTP_402_PAYMENT_REQUIRED, detail="请订阅 RealTalk Pro 后使用 AI 学习和训练")


def payment_method_settings(method: str) -> dict[str, str | None]:
    if method == "wechat":
        return {
            "title": "微信",
            "payment_url": settings.wechat_pay_url,
            "qr_code_text": settings.wechat_pay_url,
            "receiver_account": settings.wechat_receiver_account,
        }
    if method == "alipay":
        return {
            "title": "支付宝",
            "payment_url": settings.alipay_pay_url,
            "qr_code_text": settings.alipay_pay_url,
            "receiver_account": settings.alipay_receiver_account,
        }
    raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="不支持的支付方式")


def money_text(amount_cents: int) -> str:
    return "¥" + f"{amount_cents / 100:.2f}"


async def resolve_wechat_profile(request: WeChatLoginRequest) -> dict[str, str | None]:
    if settings.wechat_auth_dev_mode:
        digest = hashlib.sha256(request.code.encode("utf-8")).hexdigest()[:24]
        return {
            "openid": "dev-" + digest,
            "nickname": request.nickname or "微信用户",
            "avatar_url": request.avatar_url,
        }

    if not settings.wechat_app_id or not settings.wechat_app_secret:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="微信登录未配置")

    async with httpx.AsyncClient(timeout=15) as client:
        token_response = await client.get(
            "https://api.weixin.qq.com/sns/oauth2/access_token",
            params={
                "appid": settings.wechat_app_id,
                "secret": settings.wechat_app_secret,
                "code": request.code,
                "grant_type": "authorization_code",
            },
        )
        token_response.raise_for_status()
        token_payload = token_response.json()
        if "errcode" in token_payload:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="微信授权失败")
        access_token = token_payload["access_token"]
        openid = token_payload["openid"]

        user_response = await client.get(
            "https://api.weixin.qq.com/sns/userinfo",
            params={
                "access_token": access_token,
                "openid": openid,
                "lang": "zh_CN",
            },
        )
        user_response.raise_for_status()
        user_payload = user_response.json()
        if "errcode" in user_payload:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="微信用户信息获取失败")

    return {
        "openid": openid,
        "nickname": user_payload.get("nickname") or request.nickname or "微信用户",
        "avatar_url": user_payload.get("headimgurl") or request.avatar_url,
    }


def materialize_items(user_id: str, start: datetime, end: datetime, request_items: list) -> list:
    if request_items:
        items = clean_transcript_items(request_items)
        db.insert_transcripts(user_id, items)
    else:
        items = db.query_transcripts(user_id, start, end)
    return sorted(clean_transcript_items(items), key=lambda item: item.timestamp)


def state_response(session, feedback: str | None = None, correction: str | None = None) -> TrainingStateResponse:
    completed = session.status == "completed" or session.index >= len(session.items)
    if completed:
        return TrainingStateResponse(
            session_id=session.session_id,
            prompt="",
            expected_answer="",
            index=len(session.items),
            total=len(session.items),
            completed=True,
            feedback=feedback,
            correction=correction,
        )

    item = session.items[session.index]
    return TrainingStateResponse(
        session_id=session.session_id,
        prompt=item.prompt,
        expected_answer=item.answer,
        index=session.index,
        total=len(session.items),
        completed=False,
        feedback=feedback,
        correction=correction,
    )


def normalize(value: str) -> str:
    return " ".join(value.lower().replace(".", "").replace(",", "").split())


def push_ai_lines_until_user_turn(
    user_id: str,
    session: RoleplaySessionRecord,
    scenario: ScenarioResponse,
) -> RoleplaySessionRecord:
    while session.target_index < len(scenario.lines):
        line = scenario.lines[session.target_index]
        if line.target_role == session.selected_role:
            break
        db.add_roleplay_message(
            user_id,
            session.session_id,
            speaker="ai",
            role=line.target_role,
            content=line.english,
            translation=line.source_text,
            feedback=line.intent,
        )
        session.target_index += 1
    if session.target_index >= len(scenario.lines):
        session.status = "completed"
    return session


def next_user_line(session: RoleplaySessionRecord, scenario: ScenarioResponse) -> SceneLine | None:
    for line in scenario.lines[session.target_index:]:
        if line.target_role == session.selected_role:
            return line
    return None


def roleplay_state_response(
    user_id: str,
    session: RoleplaySessionRecord,
    scenario: ScenarioResponse,
    latest_feedback: str | None = None,
    latest_accepted: bool | None = None,
) -> RoleplayStateResponse:
    total = sum(1 for line in scenario.lines if line.target_role == session.selected_role)
    completed = session.status == "completed"
    score = round(session.score_total / session.turns, 3) if session.turns else 0
    return RoleplayStateResponse(
        session_id=session.session_id,
        scenario=scenario,
        selected_role=session.selected_role,
        ai_role=session.ai_role,
        next_line=next_user_line(session, scenario),
        progress=session.turns,
        total=total,
        score=score,
        completed=completed,
        messages=db.list_roleplay_messages(user_id, session.session_id),
        latest_feedback=latest_feedback,
        latest_accepted=latest_accepted,
    )


def feedback_for_score(score: float, expected: str) -> str:
    if score >= 0.9:
        return "很自然，基本还原了这句真实对话。"
    if score >= 0.72:
        return "意思到位，可以继续；再注意语序和固定搭配。"
    return "先按参考句练熟：" + expected


def format_roleplay_feedback(
    feedback: str,
    correction: str,
    accepted: bool,
    had_rejected_attempt: bool = False,
) -> str:
    feedback = feedback.strip()
    correction = correction.strip()
    if accepted:
        return "正确，那我们继续下一句开始交流吧。" if had_rejected_attempt else ""
    prefix = "先别急，我们把这一句说准。"
    feedback = prefix + feedback
    if correction and correction not in feedback:
        return feedback + "\n更自然：" + correction
    return feedback


async def _cleanup_loop() -> None:
    while True:
        await asyncio.sleep(60 * 60)
        db.cleanup_expired()
