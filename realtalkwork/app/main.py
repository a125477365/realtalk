from __future__ import annotations

import asyncio
import hashlib
import hmac
import json as _json
import os
import re
import secrets
import shutil
import threading
import time as _time
import uuid
from collections import defaultdict, deque
from datetime import datetime, timedelta, timezone
from difflib import SequenceMatcher
from pathlib import Path

import httpx
from fastapi import Depends, FastAPI, File, HTTPException, Query, UploadFile, WebSocket, status
from fastapi.responses import RedirectResponse, Response
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBasic, HTTPBasicCredentials, HTTPBearer

from .ark_client import (
    evaluate_roleplay_turn,
    generate_ai_chat_reply,
    generate_learning,
    generate_preset_scenario,
    generate_scenario,
    resolve_ai_config,
    test_ai_connection,
)
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
    AdminPasswordChangeRequest,
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
    CaptureQuotaResponse,
    CaptureUploadChunkRequest,
    CaptureUploadChunkResponse,
    CaptureUploadCompleteRequest,
    CaptureUploadCompleteResponse,
    CaptureUploadInitRequest,
    CaptureUploadInitResponse,
    EmailCodeRequest,
    EmailCodeResponse,
    EmailRegisterRequest,
    LearningGenerateRequest,
    LearningResponse,
    MessageResponse,
    ModelSettingsUpdateRequest,
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
    RoleplayEvaluateRequest,
    RoleplayMessageRequest,
    RoleplaySessionRecord,
    RoleplayStartRequest,
    RoleplayStateResponse,
    ScenarioGenerateRequest,
    ScenarioListResponse,
    ScenarioResponse,
    ScenarioSummary,
    SceneLine,
    TokenRefreshRequest,
    TrainingAnswerRequest,
    TrainingStartRequest,
    TrainingStateResponse,
    TranscriptItem,
    TranscriptQueryResponse,
    TranscriptUploadRequest,
    TranscriptUploadResponse,
    UserOut,
    WeChatLoginRequest,
)
from .schemas import (
    AsrSettingsRequest,
    AudioJobListResponse,
    AudioJobOut,
    AudioUploadInitRequest,
    AudioUploadInitResponse,
    AudioUploadStatusResponse,
    PlanCatalogResponse,
    PlanItem,
    PresetScenarioCatalogResponse,
    PresetScenarioGenerateRequest,
    PresetScenarioGroup,
    NonmemberLimits,
    QuotaSettingsRequest,
    SubscribeRequest,
    SupportTicketCreate,
    SupportTicketListResponse,
    SupportTicketOut,
    SupportTicketUpdateRequest,
    TokenUsageInfo,
)
from .capture_store import capture_store
from .realtime_voice import (
    build_session_instructions,
    proxy_session,
    realtime_usage_cost_cents,
    resolve_realtime_config,
    resolve_realtime_pricing,
    score_voice_session,
    test_realtime_connection,
)
from .schemas import RealtimeSettingsRequest
from .settings import settings
from .storage import DatabaseIntegrityError, InsufficientBalanceError, clean_transcript_items, db

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
        allowed = _is_localhost_af or origin == _af_url
        # 预检请求必须在路由之前直接应答，否则跨域 JSON 请求会因 405 失败
        if request.method == "OPTIONS" and allowed and origin:
            return Response(
                status_code=204,
                headers={
                    "Access-Control-Allow-Origin": origin,
                    "Access-Control-Allow-Credentials": "true",
                    "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
                    "Access-Control-Allow-Headers": request.headers.get(
                        "access-control-request-headers", "*"
                    ),
                    "Access-Control-Max-Age": "600",
                },
            )
        response = await call_next(request)
        if allowed and origin:
            response.headers["Access-Control-Allow-Origin"] = origin
            response.headers["Access-Control-Allow-Credentials"] = "true"
            response.headers["Access-Control-Expose-Headers"] = "Set-Cookie"
        return response


class RateLimitMiddleware(BaseHTTPMiddleware):
    """进程内限流：缓解暴力破解与请求洪泛（资源耗尽）。

    认证类接口限制更严（防撞库），其余接口给较宽松上限以不影响正常分块上传/轮询。
    多节点部署时为单机粒度；真正的分布式限流与抗 DDoS 建议在网关/CDN/WAF 层做。
    """

    _EXEMPT = ("/health", "/ready", "/payment/", "/audio/internal/")

    def __init__(self, app) -> None:
        super().__init__(app)
        self._hits: dict[str, deque] = defaultdict(deque)
        self._lock = threading.Lock()

    async def dispatch(self, request: Request, call_next):
        path = request.url.path
        if request.method == "OPTIONS" or any(path.startswith(p) for p in self._EXEMPT):
            return await call_next(request)
        ip = request.client.host if request.client else "unknown"
        is_auth = path.startswith("/auth/") or path.startswith("/admin/login")
        limit, window = (40, 60) if is_auth else (600, 60)
        bucket = f"{ip}:{'a' if is_auth else 'g'}"
        now = _time.monotonic()
        with self._lock:
            dq = self._hits[bucket]
            while dq and dq[0] <= now - window:
                dq.popleft()
            if len(dq) >= limit:
                return Response(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    content=_json.dumps({"detail": "请求过于频繁，请稍后再试"}),
                    media_type="application/json",
                )
            dq.append(now)
        return await call_next(request)


# 先加限流（内层），再加 CORS（外层）：429 响应也能带上 CORS 头
app.add_middleware(RateLimitMiddleware)
app.add_middleware(DynamicCORSMiddleware)


def _warn_insecure_config() -> None:
    """启动时对危险的开发旁路 / 弱配置发出醒目告警（不阻断启动）。"""
    warnings: list[str] = []
    if settings.jwt_secret_is_default:
        warnings.append("未设置 JWT_SECRET（已用持久化随机密钥兜底；生产请显式配置）")
    if settings.payment_dev_auto_confirm:
        warnings.append("PAYMENT_DEV_AUTO_CONFIRM=true（用户可不实际付款即确认到账，务必生产关闭）")
    if settings.wechat_auth_dev_mode:
        warnings.append("WECHAT_AUTH_DEV_MODE=true（微信登录走开发模拟，未校验真实身份）")
    if settings.apple_iap_dev_bypass:
        warnings.append("APPLE_IAP_DEV_BYPASS=true（内购校验被绕过）")
    if settings.admin_password == "admin123456":
        warnings.append("使用默认管理员密码 admin123456（务必修改）")
    if warnings:
        print(
            "[security] ⚠️ 上线前请处理以下开发旁路 / 弱配置：\n  - " + "\n  - ".join(warnings),
            flush=True,
        )


@app.on_event("startup")
async def startup() -> None:
    from .auth import seed_default_admin
    _warn_insecure_config()
    db.cleanup_expired()
    asyncio.create_task(_cleanup_loop())
    seed_default_admin()
    # 首装把「管理台可配置」参数从 env 落库（仅补缺）；以后以 DB 为准
    db.seed_app_settings_from_env()


def _authenticate_token(token: str) -> UserOut:
    """校验 access token（存在性/封禁/单设备/令牌版本），返回用户。供 HTTP 与 WebSocket 共用。"""
    user_id, device_id, token_version = verify_token(token)
    session = db.get_user_session(user_id)
    if session is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="用户不存在")
    user: UserOut = session["user"]
    if user.is_banned:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="账号已被禁用")
    active_device = session["active_device_id"]
    if active_device is not None and active_device != device_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="您的账号已在其他设备登录，请重新登录")
    if token_version != session["token_version"]:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="登录状态已失效，请重新登录")
    last_seen = session["last_seen_at"]
    now = datetime.now(timezone.utc)
    if last_seen is None or (now - last_seen).total_seconds() > settings.last_seen_throttle_seconds:
        db.touch_user_seen(user.id)
    return user


def current_user(credentials: HTTPAuthorizationCredentials | None = Depends(security)) -> UserOut:
    # 同步依赖：FastAPI 自动放到线程池执行，DB 查询不阻塞事件循环
    if credentials is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="缺少登录凭证")
    return _authenticate_token(credentials.credentials)


def current_admin(request: Request, credentials: HTTPBasicCredentials | None = Depends(admin_security)) -> dict:
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
        )
    admin = db.admin_get_by_username(credentials.username)
    if admin is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="管理员账号或密码错误",
        )
    if not admin["is_active"]:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="账号已被禁用",
        )
    if not verify_admin_password(admin, credentials.password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="管理员账号或密码错误",
        )
    return admin


_login_page_url = os.getenv("ADMIN_FRONTEND_URL", "http://localhost:8080").rstrip("/") + "/login"


@app.get("/admin/login-page")
async def admin_login_page() -> RedirectResponse:
    return RedirectResponse(_login_page_url, status_code=303)


@app.post("/admin/login")
async def admin_login(request: Request, response: Response) -> dict:
    content_type = request.headers.get("content-type", "").lower()
    if "application/json" in content_type:
        body = await request.json()
        username = (body.get("username") or "").strip()
        password = body.get("password") or ""
    else:
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
        samesite="lax",
        secure=False,
    )
    return {
        "ok": True,
        "id": admin["id"],
        "username": admin["username"],
        "role": admin["role"],
        "display_name": admin.get("display_name"),
    }


@app.post("/admin/logout")
async def admin_logout(request: Request, response: Response) -> dict:
    token = request.cookies.get("admin_session")
    if token:
        destroy_admin_token(token)
    response.delete_cookie(key="admin_session", path="/")
    return {"ok": True}


@app.get("/admin/api/me")
def admin_me(admin: dict = Depends(current_admin)) -> dict:
    """供管理台前端恢复登录会话。"""
    return {
        "id": admin["id"],
        "username": admin["username"],
        "role": admin["role"],
        "display_name": admin.get("display_name"),
        "email": admin.get("email"),
    }


@app.post("/admin/api/password/change", response_model=MessageResponse)
def admin_change_password(
    request: AdminPasswordChangeRequest,
    admin: dict = Depends(current_admin),
) -> MessageResponse:
    from .auth import destroy_all_admin_tokens

    if not verify_admin_password(admin, request.old_password):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="当前密码错误")
    salt, pw_hash = hash_password(request.new_password)
    db.admin_update(admin["id"], password_salt=salt, password_hash=pw_hash)
    destroy_all_admin_tokens(admin["id"])
    return MessageResponse(message="密码已修改，请重新登录")


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
def billing_prices() -> PriceResponse:
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
def admin_overview(admin: dict = Depends(current_admin)) -> dict:
    return db.admin_overview()


@app.get("/admin/api/users")
def admin_users(
    q: str | None = Query(default=None, max_length=120),
    limit: int = Query(default=100, ge=1, le=500),
    admin: dict = Depends(current_admin),
) -> dict:
    return {"items": db.admin_list_users(limit=limit, query=q)}


@app.get("/admin/api/users/{user_id}")
def admin_user_detail(user_id: str, admin: dict = Depends(current_admin)) -> dict:
    detail = db.admin_get_user_detail(user_id)
    if detail is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="用户不存在")
    return detail


@app.patch("/admin/api/users/{user_id}")
def admin_update_user(
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
def admin_update_price(
    request: AdminPriceUpdateRequest,
    admin: dict = Depends(current_admin),
) -> PriceResponse:
    db.set_app_setting("monthly_price_cents", str(request.monthly_price_cents))
    return billing_prices()


# ---- 模型配置（管理员可对接任意 OpenAI 兼容模型服务）----

def _masked_key(key: str | None) -> str | None:
    if not key:
        return None
    if len(key) <= 8:
        return "****"
    return key[:4] + "****" + key[-4:]


@app.get("/admin/api/settings/model")
async def admin_get_model_settings(admin: dict = Depends(current_admin)) -> dict:
    config = resolve_ai_config()
    return {
        "provider": config.provider,
        "base_url": config.base_url,
        "api_key_masked": _masked_key(config.api_key),
        "api_key_configured": config.enabled,
        "model": config.model,
        "bot_id": config.bot_id,
        "timeout_seconds": config.timeout_seconds,
        "input_price_per_1m_cents": config.input_price_per_1m_cents,
        "output_price_per_1m_cents": config.output_price_per_1m_cents,
    }


@app.post("/admin/api/settings/model")
async def admin_update_model_settings(
    request: ModelSettingsUpdateRequest,
    admin: dict = Depends(current_admin),
) -> dict:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    updates: dict[str, str] = {}
    if request.provider is not None:
        updates["ai_provider"] = request.provider.strip()
    if request.base_url is not None:
        updates["ai_base_url"] = request.base_url.strip().rstrip("/")
    if request.api_key is not None:
        updates["ai_api_key"] = request.api_key.strip()
    if request.model is not None:
        updates["ai_model"] = request.model.strip()
    if request.bot_id is not None:
        updates["ai_bot_id"] = request.bot_id.strip()
    if request.timeout_seconds is not None:
        updates["ai_timeout_seconds"] = str(request.timeout_seconds)
    if request.input_price_per_1m_cents is not None:
        updates["ai_input_price_per_1m_cents"] = str(request.input_price_per_1m_cents)
    if request.output_price_per_1m_cents is not None:
        updates["ai_output_price_per_1m_cents"] = str(request.output_price_per_1m_cents)
    for key, value in updates.items():
        db.set_app_setting(key, value)
    return await admin_get_model_settings(admin)


@app.post("/admin/api/settings/model/test")
async def admin_test_model_settings(admin: dict = Depends(current_admin)) -> dict:
    return await test_ai_connection()


# ---- 高级会员实时语音大模型配置 ----

@app.get("/admin/api/settings/realtime")
async def admin_get_realtime_settings(admin: dict = Depends(current_admin)) -> dict:
    config = resolve_realtime_config()
    pricing = resolve_realtime_pricing()
    return {
        "base_url": config.base_url,
        "model": config.model,
        "voice": config.voice,
        "api_key_masked": _masked_key(config.api_key),
        "api_key_configured": config.enabled,
        "input_text_price_per_1m_cents": pricing.input_text,
        "input_audio_price_per_1m_cents": pricing.input_audio,
        "output_text_price_per_1m_cents": pricing.output_text,
        "output_audio_price_per_1m_cents": pricing.output_audio,
    }


@app.post("/admin/api/settings/realtime")
async def admin_set_realtime_settings(
    request: RealtimeSettingsRequest,
    admin: dict = Depends(current_admin),
) -> dict:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    if request.base_url is not None:
        db.set_app_setting("realtime_base_url", request.base_url.strip())
    if request.api_key is not None:
        db.set_app_setting("realtime_api_key", request.api_key.strip())
    if request.model is not None:
        db.set_app_setting("realtime_model", request.model.strip())
    if request.voice is not None:
        db.set_app_setting("realtime_voice", request.voice.strip())
    for field, key in (
        ("input_text_price_per_1m_cents", "realtime_input_text_price_per_1m_cents"),
        ("input_audio_price_per_1m_cents", "realtime_input_audio_price_per_1m_cents"),
        ("output_text_price_per_1m_cents", "realtime_output_text_price_per_1m_cents"),
        ("output_audio_price_per_1m_cents", "realtime_output_audio_price_per_1m_cents"),
    ):
        value = getattr(request, field)
        if value is not None:
            db.set_app_setting(key, str(value))
    return await admin_get_realtime_settings(admin)


@app.post("/admin/api/settings/realtime/test")
async def admin_test_realtime_settings(admin: dict = Depends(current_admin)) -> dict:
    return await test_realtime_connection()


@app.get("/admin/api/settings/plans", response_model=PlanCatalogResponse)
def admin_get_plans(admin: dict = Depends(current_admin)) -> PlanCatalogResponse:
    return PlanCatalogResponse(
        items=[PlanItem(**item) for item in db.get_plan_catalog()],
        trial_days=0,  # 已取消试用，保留字段兼容旧客户端
    )


@app.post("/admin/api/settings/plans", response_model=PlanCatalogResponse)
def admin_set_plans(
    items: list[PlanItem],
    admin: dict = Depends(current_admin),
) -> PlanCatalogResponse:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    if not items:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="套餐目录不能为空")
    ids = [item.id for item in items]
    if len(ids) != len(set(ids)):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="套餐 ID 重复")
    db.set_plan_catalog([item.model_dump() for item in items])
    return admin_get_plans(admin)


@app.get("/admin/api/settings/presets", response_model=PresetScenarioCatalogResponse)
def admin_get_presets(admin: dict = Depends(current_admin)) -> PresetScenarioCatalogResponse:
    return PresetScenarioCatalogResponse(
        items=[PresetScenarioGroup(**item) for item in db.get_preset_scenarios()]
    )


@app.post("/admin/api/settings/presets", response_model=PresetScenarioCatalogResponse)
def admin_set_presets(
    items: list[PresetScenarioGroup],
    admin: dict = Depends(current_admin),
) -> PresetScenarioCatalogResponse:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    group_ids = [group.id for group in items]
    if len(group_ids) != len(set(group_ids)):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="主场景 ID 重复")
    for group in items:
        sub_ids = [sub.id for sub in group.subs]
        if len(sub_ids) != len(set(sub_ids)):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"「{group.title}」下子场景 ID 重复",
            )
    db.set_preset_scenarios([group.model_dump() for group in items])
    return admin_get_presets(admin)


@app.get("/admin/api/settings/quota")
def admin_get_quota(admin: dict = Depends(current_admin)) -> dict:
    return {
        "daily_token_limit_free": db.get_daily_token_limit("free"),
        "daily_token_limit_basic": db.get_daily_token_limit("basic"),
        "daily_token_limit_premium": db.get_daily_token_limit("premium"),
        "budget_ratio": db.get_budget_ratio(),
        "nonmember_daily_chat_tokens": db.get_nonmember_daily_chat_tokens(),
        "nonmember_daily_capture_tokens": db.get_nonmember_daily_capture_tokens(),
        "nonmember_daily_capture_seconds": db.get_app_setting_int(
            "nonmember_daily_capture_seconds", settings.nonmember_daily_capture_seconds
        ),
    }


@app.post("/admin/api/settings/quota")
def admin_set_quota(
    request: QuotaSettingsRequest,
    admin: dict = Depends(current_admin),
) -> dict:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    for key in ("daily_token_limit_free", "daily_token_limit_basic", "daily_token_limit_premium"):
        value = getattr(request, key)
        if value is not None:
            db.set_app_setting(key, str(value))
    if request.budget_ratio is not None:
        db.set_app_setting("budget_ratio", str(request.budget_ratio))
    for key in (
        "nonmember_daily_chat_tokens",
        "nonmember_daily_capture_tokens",
        "nonmember_daily_capture_seconds",
    ):
        value = getattr(request, key)
        if value is not None:
            db.set_app_setting(key, str(value))
    return admin_get_quota(admin)


# ==================== 客服工单 ====================

@app.post("/support/tickets", response_model=SupportTicketOut)
def create_support_ticket(
    request: SupportTicketCreate,
    user: UserOut = Depends(current_user),
) -> SupportTicketOut:
    ticket = db.create_support_ticket(
        user_id=user.id,
        category=request.category,
        subject=request.subject.strip(),
        body=request.body.strip(),
    )
    return SupportTicketOut(**ticket)


@app.get("/support/tickets", response_model=SupportTicketListResponse)
def list_my_support_tickets(user: UserOut = Depends(current_user)) -> SupportTicketListResponse:
    items = db.list_user_tickets(user.id)
    return SupportTicketListResponse(items=[SupportTicketOut(**t) for t in items])


@app.get("/admin/api/support/tickets")
def admin_list_support_tickets(
    status_filter: str | None = Query(default=None, alias="status"),
    admin: dict = Depends(current_admin),
) -> dict:
    return {"items": db.list_support_tickets(status=status_filter)}


@app.post("/admin/api/support/tickets/{ticket_id}", response_model=SupportTicketOut)
def admin_update_support_ticket(
    ticket_id: str,
    request: SupportTicketUpdateRequest,
    admin: dict = Depends(current_admin),
) -> SupportTicketOut:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    ticket = db.update_support_ticket(
        ticket_id,
        status=request.status,
        admin_reply=request.admin_reply.strip() if request.admin_reply is not None else None,
    )
    if ticket is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="工单不存在")
    return SupportTicketOut(**ticket)


@app.get("/admin/api/settings/asr")
def admin_get_asr(admin: dict = Depends(current_admin)) -> dict:
    from .audio_pipeline import resolve_asr_config

    config = resolve_asr_config()
    return {
        "mode": config["mode"],
        "base_url": config["base_url"],
        "model": config["model"],
        "local_command": config["local_command"],
        "api_key_masked": _masked_key(config["api_key"]),
        "api_key_configured": bool(config["api_key"]),
        "dev_mode": config["dev_mode"],
    }


@app.post("/admin/api/settings/asr")
def admin_set_asr(
    request: AsrSettingsRequest,
    admin: dict = Depends(current_admin),
) -> dict:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    # 转写方式（cloud/local）与本地命令由部署脚本控制，管理台只配置云端服务参数
    if request.base_url is not None:
        db.set_app_setting("asr_base_url", request.base_url.strip().rstrip("/"))
    if request.api_key is not None:
        db.set_app_setting("asr_api_key", request.api_key.strip())
    if request.model is not None:
        db.set_app_setting("asr_model", request.model.strip())
    return admin_get_asr(admin)


@app.get("/admin/api/usage/users")
def admin_usage_users(
    days: int = Query(default=30, ge=1, le=120),
    limit: int = Query(default=100, ge=1, le=500),
    admin: dict = Depends(current_admin),
) -> dict:
    return {"items": db.admin_usage_users(days=days, limit=limit), "days": days}


@app.get("/admin/api/stats/timeseries")
def admin_stats_timeseries(
    days: int = Query(default=30, ge=7, le=120),
    admin: dict = Depends(current_admin),
) -> dict:
    return db.admin_stats_timeseries(days)


@app.get("/admin/api/orders")
def admin_orders(
    order_status: str | None = Query(default=None, alias="status"),
    method: str | None = None,
    q: str | None = Query(default=None, max_length=120),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    admin: dict = Depends(current_admin),
) -> dict:
    return db.admin_list_orders(limit=limit, offset=offset, status=order_status, method=method, query=q)


@app.post("/admin/api/orders/{order_id}/mark-paid")
def admin_mark_order_paid(
    order_id: str,
    admin: dict = Depends(current_admin),
) -> dict:
    """人工对账：管理员确认线下/转账到账后手动入账。"""
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    try:
        order, user = db.mark_recharge_paid_by_order_id(order_id, 0)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="订单不存在") from exc
    return {"order": order.model_dump(), "user_balance_cents": user.balance_cents}


# ---- Admin CRUD ----

@app.get("/admin/api/admins", response_model=AdminListResponse)
def admin_list_admins(
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
def admin_create_admin(
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
def admin_update_target(
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
def admin_delete_target(
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


@app.post("/auth/register", response_model=AuthResponse)
async def register(request: EmailRegisterRequest) -> AuthResponse:
    raise HTTPException(status_code=status.HTTP_410_GONE, detail="仅支持微信快速授权登录")


@app.post("/auth/login", response_model=AuthResponse)
async def login(request: AuthRequest) -> AuthResponse:
    raise HTTPException(status_code=status.HTTP_410_GONE, detail="仅支持微信快速授权登录")


@app.get("/auth/wechat/web-config")
def wechat_web_config(redirect: str = Query(default="", max_length=500)) -> dict:
    """Web 端微信登录配置：开发模式直登；生产返回开放平台扫码授权 URL。"""
    if settings.wechat_auth_dev_mode:
        return {"dev_mode": True, "auth_url": None}
    if not settings.wechat_web_app_id:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="网站微信登录未配置（WECHAT_WEB_APP_ID）")
    from urllib.parse import quote

    auth_url = (
        "https://open.weixin.qq.com/connect/qrconnect"
        f"?appid={settings.wechat_web_app_id}"
        f"&redirect_uri={quote(redirect, safe='')}"
        "&response_type=code&scope=snsapi_login#wechat_redirect"
    )
    return {"dev_mode": False, "auth_url": auth_url}


def _issue_token_pair(user_id: str, device_id: str | None) -> tuple[str, str]:
    """按用户当前令牌版本签发 access + refresh 令牌对。"""
    tv = db.get_token_version(user_id)
    return create_token(user_id, device_id, tv), create_refresh_token(user_id, device_id, tv)


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
    # 单设备登录：把本次登录的设备编号设为该账号唯一有效设备（顶掉其它设备）
    device_id = (request.device_id or uuid.uuid4().hex)[:128]
    db.set_active_device(user.id, device_id)
    access_token, refresh = _issue_token_pair(user.id, device_id)
    return AuthResponse(token=access_token, refresh_token=refresh, user=user)


# ---- Email/Password Auth for App Users ----

@app.post("/auth/password/register", response_model=AuthTokenResponse)
def register_password(
    request: PasswordRegisterRequest,
) -> AuthTokenResponse:
    if not settings.email_auth_enabled:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="邮箱注册未开放，请使用微信登录")
    normalized = normalize_email(request.email)
    existing = db.get_user_by_login_identifier(normalized)
    if existing:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="该邮箱已注册")
    
    if not db.consume_email_code(normalized, hash_email_code(request.code)):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="验证码无效或已过期")
    
    salt, pw_hash = hash_password(request.password)
    user = db.create_user(normalized, salt, pw_hash)
    device_id = uuid.uuid4().hex
    db.set_active_device(user.id, device_id)
    access_token, refresh = _issue_token_pair(user.id, device_id)
    return AuthTokenResponse(
        access_token=access_token,
        refresh_token=refresh,
        expires_in=settings.access_token_ttl_minutes * 60,
    )


@app.post("/auth/password/login", response_model=AuthTokenResponse)
def login_password(
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
    device_id = (request.device_id or uuid.uuid4().hex)[:128]
    db.set_active_device(user.id, device_id)
    access_token, refresh = _issue_token_pair(user.id, device_id)
    return AuthTokenResponse(
        access_token=access_token,
        refresh_token=refresh,
        expires_in=settings.access_token_ttl_minutes * 60,
    )


@app.post("/auth/password/change", response_model=AuthTokenResponse)
def change_password(
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
    # 改密即吊销此前签发的所有令牌（其它设备/旧会话立即失效），再给当前设备发新令牌
    db.bump_token_version(user.id)
    device_id = db.get_active_device(user.id)  # 保留当前设备绑定
    access_token, refresh = _issue_token_pair(user.id, device_id)
    return AuthTokenResponse(
        access_token=access_token,
        refresh_token=refresh,
        expires_in=settings.access_token_ttl_minutes * 60,
    )


@app.post("/auth/password/reset/send")
def send_password_reset(
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
def confirm_password_reset(
    request: PasswordResetConfirmRequest,
) -> AuthTokenResponse:
    raw_hash = hashlib.sha256(request.token.encode()).hexdigest()
    result = db.consume_email_reset_token(raw_hash)
    if result is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="重置链接无效或已过期")
    
    salt, pw_hash = hash_password(request.new_password)
    db.user_password_reset(result["user_id"], salt, pw_hash)
    # 重置密码即吊销旧令牌并在当前设备重建会话，顶掉其它设备
    db.bump_token_version(result["user_id"])
    device_id = uuid.uuid4().hex
    db.set_active_device(result["user_id"], device_id)
    access_token, refresh = _issue_token_pair(result["user_id"], device_id)
    return AuthTokenResponse(
        access_token=access_token,
        refresh_token=refresh,
        expires_in=settings.access_token_ttl_minutes * 60,
    )


@app.post("/auth/token/refresh", response_model=AuthTokenResponse)
def refresh_token(
    request: TokenRefreshRequest,
) -> AuthTokenResponse:
    user_id, device_id, token_version = verify_refresh_token(request.refresh_token)
    session = db.get_user_session(user_id)
    if session is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="用户不存在")
    user: UserOut = session["user"]
    if user.is_banned:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="账号已被禁用")
    # 刷新令牌也必须来自当前绑定设备、且令牌版本未被吊销，否则旧设备/已注销令牌不能续命
    active_device = session["active_device_id"]
    if active_device is not None and active_device != device_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="您的账号已在其他设备登录，请重新登录",
        )
    if token_version != session["token_version"]:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="登录状态已失效，请重新登录",
        )
    db.touch_user_seen(user.id)
    # 轮换：每次刷新都发新的 access + refresh
    access_token, refresh = _issue_token_pair(user.id, device_id)
    return AuthTokenResponse(
        access_token=access_token,
        refresh_token=refresh,
        expires_in=settings.access_token_ttl_minutes * 60,
    )


@app.post("/auth/logout", response_model=MessageResponse)
def logout(user: UserOut = Depends(current_user)) -> MessageResponse:
    """登出（注销全部设备）：递增令牌版本，使该账号此前所有 access/refresh 立即失效。"""
    db.bump_token_version(user.id)
    db.set_active_device(user.id, None)
    return MessageResponse(message="已退出登录")


@app.post("/auth/email/code")
def send_register_code(
    request: EmailCodeRequest,
) -> EmailCodeResponse:
    if not settings.email_auth_enabled:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="邮箱注册未开放，请使用微信登录")
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
def me(user: UserOut = Depends(current_user)) -> UserOut:
    return user


@app.post("/ai/chat", response_model=AIChatResponse)
async def ai_chat(request: AIChatRequest, user: UserOut = Depends(current_user)) -> AIChatResponse:
    require_ai_access(user, estimated_cents=estimate_text_cost_cents(len(request.message or "")))
    if is_political_sensitive(request.message):
        # 涉政话题不进入模型，直接引导回口语练习
        return AIChatResponse(reply="这个话题我们就不展开了。我们继续练英语吧，你想还原哪段真实对话？")
    scenario = db.get_scenario(user.id, request.scene_id) if request.scene_id else None
    reply = await generate_ai_chat_reply(request.message.strip(), request.messages, scenario, user_id=user.id)
    return AIChatResponse(reply=reply)


@app.get("/billing/account", response_model=BillingAccountResponse)
def billing_account(user: UserOut = Depends(current_user)) -> BillingAccountResponse:
    updated = db.get_user(user.id) or user
    return BillingAccountResponse(
        user=updated,
        ledger=db.list_billing_ledger(user.id),
        usage=token_usage_info(updated),
        nonmember_limits=nonmember_limits_info(),
    )


@app.get("/billing/plans", response_model=PlanCatalogResponse)
def billing_plans() -> PlanCatalogResponse:
    return PlanCatalogResponse(
        items=[PlanItem(**item) for item in db.get_plan_catalog()],
        trial_days=0,  # 已取消试用，保留字段兼容旧客户端
    )


@app.post("/billing/subscribe", response_model=BillingAccountResponse)
def billing_subscribe(
    request: SubscribeRequest,
    user: UserOut = Depends(current_user),
) -> BillingAccountResponse:
    plan = next((item for item in db.get_plan_catalog() if item.get("id") == request.plan_id), None)
    if plan is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="套餐不存在")
    try:
        updated = db.subscribe_plan(user.id, plan)
    except InsufficientBalanceError as exc:
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail=f"余额不足，还差 ¥{exc.missing_cents / 100:.2f}，请先充值",
        ) from exc
    return BillingAccountResponse(
        user=updated,
        ledger=db.list_billing_ledger(updated.id),
        usage=token_usage_info(updated),
    )


@app.post("/billing/recharge", response_model=RechargeOrderResponse)
async def create_recharge(
    request: RechargeCreateRequest,
    http_request: Request,
    user: UserOut = Depends(current_user),
) -> RechargeOrderResponse:
    if request.method == "admin":
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="无效支付方式")

    # 会员套餐订单：金额取套餐价、带 plan_id（支付成功后激活会员而非加余额）
    plan_id = request.plan_id
    if plan_id:
        plan = next((p for p in db.get_plan_catalog() if p.get("id") == plan_id), None)
        if plan is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="套餐不存在")
        amount_cents = int(plan["price_cents"])
        order_desc = f"开通{plan.get('title', '会员')}"
    else:
        amount_cents = request.amount_cents
        order_desc = f"RealTalk充值{amount_cents / 100:.0f}元"
        if amount_cents < 100:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="充值金额不能小于 1 元")

    # 三种到账方式（按优先级）：官方支付（商户号）→ 收款码人工确认 → 开发模式自动确认。
    wechat_official = bool(settings.wechat_mchid and settings.wechat_notify_url)
    alipay_official = bool(settings.alipay_app_id and settings.alipay_notify_url)
    manual_fallback = settings.payment_dev_auto_confirm or bool(
        settings.wechat_receiver_account
        or settings.alipay_receiver_account
        or settings.wechat_pay_url
        or settings.alipay_pay_url
    )
    if request.method == "wechat" and not wechat_official and not manual_fallback:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="微信支付暂不可用，请联系管理员配置收款方式")
    if request.method == "alipay" and not alipay_official and not manual_fallback:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="支付宝暂不可用，请联系管理员配置收款方式")

    client_ip = http_request.client.host if http_request.client else "127.0.0.1"

    if request.method == "wechat" and wechat_official:
        try:
            result = await wechat_pay.create_unified_order(
                out_trade_no=str(uuid.uuid4()),
                total_fee=amount_cents,
                description=order_desc,
                notify_url=settings.wechat_notify_url,
                client_ip=client_ip,
            )
            
            order = db.create_recharge_order(
                user.id,
                request.method,
                amount_cents,
                payment_url=result.get("code_url"),
                qr_code_text=result.get("code_url"),
                receiver_name=settings.payment_receiver_name,
                receiver_account=settings.wechat_receiver_account,
                plan_id=plan_id,
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
    
    if request.method == "alipay" and alipay_official:
        try:
            result = await alipay.create_trade_precreate(
                out_trade_no=str(uuid.uuid4()),
                total_amount=amount_cents / 100.0,
                subject=order_desc,
                notify_url=settings.alipay_notify_url,
            )
            
            order = db.create_recharge_order(
                user.id,
                request.method,
                amount_cents,
                payment_url=result.get("qr_code"),
                qr_code_text=result.get("qr_code"),
                receiver_name=settings.payment_receiver_name,
                receiver_account=settings.alipay_receiver_account,
                plan_id=plan_id,
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
        amount_cents,
        payment_url=method_settings["payment_url"],
        qr_code_text=method_settings["qr_code_text"],
        receiver_name=settings.payment_receiver_name,
        receiver_account=method_settings["receiver_account"],
        plan_id=plan_id,
    )
    order.message = ("请使用" + method_settings["title"] + "支付 " + money_text(amount_cents)
                     + ("（" + order_desc + "）" if plan_id else "") + "，付款备注订单号。")
    return order


@app.post("/billing/recharge/confirm", response_model=BillingAccountResponse)
def confirm_recharge(
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
    order_status = row[1]

    provider_status = "unknown"
    if order_status == "pending" and method in ("wechat", "alipay"):
        try:
            if method == "wechat" and settings.wechat_mchid:
                result = await wechat_pay.query_order(order_id)
                provider_status = result.get("trade_state", "unknown")
                if provider_status == "SUCCESS":
                    amount = int(result.get("amount", {}).get("total", 0))
                    if amount > 0:
                        _, _ = db.mark_recharge_paid_by_order_id(order_id, amount)
                        order_status = "paid"
            elif method == "alipay" and settings.alipay_app_id:
                result = await alipay.query_trade(order_id)
                provider_status = result.get("trade_status", "unknown")
                if provider_status in ("TRADE_SUCCESS", "TRADE_FINISHED"):
                    total = float(result.get("total_amount", 0))
                    if total > 0:
                        _, _ = db.mark_recharge_paid_by_order_id(order_id, int(total * 100))
                        order_status = "paid"
        except HTTPException:
            pass

    return {"order_id": order_id, "status": order_status, "provider_status": provider_status}


_CAPTURE_MAX_ITEMS_PER_CHUNK = 80
_CAPTURE_BATCH_MAX_ITEMS = 80
_CAPTURE_BATCH_MAX_CHARS = 18000


def _scenario_batches(items: list[TranscriptItem]) -> list[list[TranscriptItem]]:
    batches: list[list[TranscriptItem]] = []
    current: list[TranscriptItem] = []
    current_chars = 0
    for item in items:
        item_chars = len(item.text)
        if current and (
            len(current) >= _CAPTURE_BATCH_MAX_ITEMS
            or current_chars + item_chars > _CAPTURE_BATCH_MAX_CHARS
        ):
            batches.append(current)
            current = []
            current_chars = 0
        current.append(item)
        current_chars += item_chars
    if current:
        batches.append(current)
    return batches


async def _generate_and_save_capture_scenarios(user_id: str, items: list[TranscriptItem]) -> list[ScenarioResponse]:
    saved: list[ScenarioResponse] = []
    for batch in _scenario_batches(items):
        # 内容哈希幂等：相同采集内容若已生成过未过期的场景，直接复用，避免重复上传产生重复场景
        digest = hashlib.sha256(
            "\n".join((item.text or "").strip() for item in batch).encode("utf-8")
        ).hexdigest()
        existing = db.find_scenario_by_source_hash(user_id, digest)
        if existing is not None:
            saved.append(existing)
            continue
        scenario = await generate_scenario(batch, user_id=user_id)
        saved.append(
            db.create_scenario(user_id, batch[0].timestamp, batch[-1].timestamp, scenario, source_hash=digest)
        )
    return saved


@app.get("/capture/quota", response_model=CaptureQuotaResponse)
def capture_quota(user: UserOut = Depends(current_user)) -> CaptureQuotaResponse:
    """采集前/采集中查询剩余额度（按 token 估算），供客户端提示或自动停止。"""
    return capture_quota_info(user)


@app.post("/capture/upload/init", response_model=CaptureUploadInitResponse)
def capture_upload_init(
    request: CaptureUploadInitRequest,
    user: UserOut = Depends(current_user),
) -> CaptureUploadInitResponse:
    require_ai_access(user)
    upload_id = uuid.uuid4().hex
    capture_store.init_session(
        upload_id=upload_id,
        user_id=user.id,
        meta={
            "start": request.start.isoformat() if request.start else None,
            "end": request.end.isoformat() if request.end else None,
            "estimated_items": request.estimated_items,
            "created_at": datetime.now(timezone.utc).isoformat(),
        },
    )
    return CaptureUploadInitResponse(
        upload_id=upload_id,
        received_chunks=[],
        max_items_per_chunk=_CAPTURE_MAX_ITEMS_PER_CHUNK,
    )


@app.post("/capture/upload/chunk", response_model=CaptureUploadChunkResponse)
def capture_upload_chunk(
    request: CaptureUploadChunkRequest,
    user: UserOut = Depends(current_user),
) -> CaptureUploadChunkResponse:
    require_ai_access(user)
    items = clean_transcript_items(request.items)
    count = capture_store.append_chunk(
        upload_id=request.upload_id,
        user_id=user.id,
        chunk_index=request.chunk_index,
        items=[item.model_dump(mode="json") for item in items],
    )
    if count < 0:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="上传会话不存在或已过期，请重新开始")
    return CaptureUploadChunkResponse(
        upload_id=request.upload_id,
        chunk_index=request.chunk_index,
        accepted_items=len(items),
        received_chunks=capture_store.received_chunks(request.upload_id, user.id),
    )


@app.post("/capture/upload/complete", response_model=CaptureUploadCompleteResponse)
async def capture_upload_complete(
    request: CaptureUploadCompleteRequest,
    user: UserOut = Depends(current_user),
) -> CaptureUploadCompleteResponse:
    require_ai_access(user)
    items = await asyncio.to_thread(capture_store.load_items, request.upload_id, user.id)
    if items is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="上传会话不存在或已过期，请重新开始")
    if not items:
        await asyncio.to_thread(capture_store.delete_session, request.upload_id, user.id)
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="本次采集没有可生成场景的对话")
    enforce_capture_quota(user, items)  # 非会员每日采集上限
    scenarios = await _generate_and_save_capture_scenarios(user.id, items)
    await asyncio.to_thread(capture_store.delete_session, request.upload_id, user.id)
    return CaptureUploadCompleteResponse(
        accepted_items=len(items),
        generated=len(scenarios),
        scenario_ids=[scenario.scene_id for scenario in scenarios],
        scenarios=scenarios,
    )


@app.post("/transcript/upload", response_model=TranscriptUploadResponse)
async def upload_transcripts(
    request: TranscriptUploadRequest,
    user: UserOut = Depends(current_user),
) -> TranscriptUploadResponse:
    """兼容旧客户端：不再写 transcripts 表，清洗后直接生成场景。"""
    require_ai_access(user)
    items = sorted(clean_transcript_items(request.items), key=lambda item: item.timestamp)
    if not items:
        return TranscriptUploadResponse(uploaded=0, retention_days=0, generated=0, scenario_ids=[])
    scenarios = await _generate_and_save_capture_scenarios(user.id, items)
    return TranscriptUploadResponse(
        uploaded=len(items),
        retention_days=0,
        generated=len(scenarios),
        scenario_ids=[scenario.scene_id for scenario in scenarios],
    )


# ---- 高级会员：录音文件上传 → 转写 → 生成场景 ----

_ALLOWED_AUDIO_SUFFIXES = {".mp3", ".wav", ".m4a"}


def _require_audio_ready(user: UserOut) -> None:
    require_premium(user)
    require_ai_access(user)
    from .audio_pipeline import asr_configured

    if not asr_configured():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="语音转写服务未配置，请联系管理员在管理台「系统设置」中配置 ASR",
        )


def _audio_suffix(filename: str | None) -> str:
    suffix = os.path.splitext(filename or "")[1].lower()
    if suffix not in _ALLOWED_AUDIO_SUFFIXES:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="仅支持 mp3 / wav / m4a 格式")
    return suffix


def _file_sha256(path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


async def _start_audio_job(user_id: str, filename: str, dest, size: int, file_hash: str | None = None) -> dict:
    from .audio_pipeline import dispatch_or_process

    job = db.create_audio_job(user_id, filename, size, file_hash=file_hash)
    asyncio.create_task(dispatch_or_process(job["id"], user_id, dest))
    return job


@app.post("/audio/upload", response_model=AudioJobOut)
async def audio_upload(
    file: UploadFile = File(...),
    user: UserOut = Depends(current_user),
) -> AudioJobOut:
    """一次性上传（适合较小文件或不需要断点续传的客户端）。"""
    _require_audio_ready(user)
    suffix = _audio_suffix(file.filename)

    settings.upload_dir.mkdir(parents=True, exist_ok=True)
    dest = settings.upload_dir / f"{uuid.uuid4()}{suffix}"
    size = 0
    try:
        with dest.open("wb") as out:
            while chunk := await file.read(1024 * 1024):
                size += len(chunk)
                if size > settings.audio_max_bytes:
                    raise HTTPException(
                        status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                        detail=f"文件超过 {settings.audio_max_bytes // (1024 * 1024)}MB 上限",
                    )
                out.write(chunk)
    except HTTPException:
        dest.unlink(missing_ok=True)
        raise
    if size == 0:
        dest.unlink(missing_ok=True)
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="文件为空")

    job = await _start_audio_job(user.id, file.filename or dest.name, dest, size)
    return AudioJobOut(**job)


# ---- 断点续传：init → chunk(可重试/续传) → complete ----

def _upload_session_path(user_id: str, upload_id: str):
    safe = "".join(c for c in upload_id if c.isalnum() or c in "-_")
    return settings.upload_dir / "incomplete" / f"{user_id}__{safe}.part"


@app.post("/audio/upload/init", response_model=AudioUploadInitResponse)
def audio_upload_init(
    request: AudioUploadInitRequest,
    user: UserOut = Depends(current_user),
) -> AudioUploadInitResponse:
    _require_audio_ready(user)
    _audio_suffix(request.filename)
    if request.size_bytes > settings.audio_max_bytes:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"文件超过 {settings.audio_max_bytes // (1024 * 1024)}MB 上限",
        )
    upload_id = f"{uuid.uuid4().hex}{os.path.splitext(request.filename)[1].lower()}"
    part = _upload_session_path(user.id, upload_id)
    part.parent.mkdir(parents=True, exist_ok=True)
    part.touch()
    return AudioUploadInitResponse(upload_id=upload_id, received_bytes=0)


@app.get("/audio/upload/status", response_model=AudioUploadStatusResponse)
def audio_upload_status(
    upload_id: str = Query(...),
    size_bytes: int = Query(default=0, ge=0),
    user: UserOut = Depends(current_user),
) -> AudioUploadStatusResponse:
    part = _upload_session_path(user.id, upload_id)
    received = part.stat().st_size if part.exists() else 0
    return AudioUploadStatusResponse(
        upload_id=upload_id,
        received_bytes=received,
        size_bytes=size_bytes,
        completed=size_bytes > 0 and received >= size_bytes,
    )


@app.put("/audio/upload/chunk")
async def audio_upload_chunk(
    request: Request,
    upload_id: str = Query(...),
    offset: int = Query(..., ge=0),
    user: UserOut = Depends(current_user),
) -> dict:
    """从 offset 写入一段数据；客户端断线后用 /status 查到 received_bytes 再续传。"""
    _require_audio_ready(user)
    part = _upload_session_path(user.id, upload_id)
    if not part.exists():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="上传会话不存在或已过期，请重新发起")
    current = part.stat().st_size
    if offset > current:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=f"偏移不连续，当前已接收 {current} 字节")

    # 用 r+b 定位到 offset 覆盖写（幂等：重发同一段不会损坏文件）
    with part.open("r+b") as fh:
        fh.seek(offset)
        async for chunk in request.stream():
            if not chunk:
                continue
            fh.seek(offset)
            fh.write(chunk)
            offset += len(chunk)
            if offset > settings.audio_max_bytes:
                fh.truncate(settings.audio_max_bytes)
                raise HTTPException(
                    status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                    detail=f"文件超过 {settings.audio_max_bytes // (1024 * 1024)}MB 上限",
                )
    return {"upload_id": upload_id, "received_bytes": part.stat().st_size}


@app.get("/audio/precheck")
def audio_precheck(file_hash: str = Query(...), user: UserOut = Depends(current_user)) -> dict:
    """上传前去重预检：客户端先算文件哈希，若同用户同文件已成功生成过场景则直接复用，省去整段上传。"""
    _require_audio_ready(user)
    existing = db.find_audio_job_by_hash(user.id, file_hash)
    return {"duplicate": existing is not None, "job": AudioJobOut(**existing).model_dump() if existing else None}


@app.post("/audio/upload/complete", response_model=AudioJobOut)
async def audio_upload_complete(
    upload_id: str = Query(...),
    filename: str = Query(default=""),
    user: UserOut = Depends(current_user),
) -> AudioJobOut:
    _require_audio_ready(user)
    part = _upload_session_path(user.id, upload_id)
    if not part.exists() or part.stat().st_size == 0:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="上传未完成或文件为空")
    suffix = os.path.splitext(upload_id)[1].lower() or ".mp3"
    dest = settings.upload_dir / f"{uuid.uuid4()}{suffix}"
    part.rename(dest)
    size = dest.stat().st_size
    # 文件内容哈希幂等：同一用户同一文件已成功生成过场景，直接复用，不重复转写/重复生成
    file_hash = await asyncio.to_thread(_file_sha256, dest)
    existing = db.find_audio_job_by_hash(user.id, file_hash)
    if existing is not None:
        dest.unlink(missing_ok=True)
        return AudioJobOut(**existing)
    job = await _start_audio_job(user.id, filename or dest.name, dest, size, file_hash=file_hash)
    return AudioJobOut(**job)


# ---- 节点间内部接口：入口转发来的文件由本 worker 处理 ----

@app.post("/audio/internal/ingest")
async def audio_internal_ingest(
    request: Request,
    job_id: str = Query(...),
    user_id: str = Query(...),
    file: UploadFile = File(...),
) -> dict:
    expected = settings.internal_token or ""
    if not expected or request.headers.get("x-internal-token") != expected:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="内部令牌无效")

    from .audio_pipeline import process_audio_job

    settings.upload_dir.mkdir(parents=True, exist_ok=True)
    suffix = os.path.splitext(file.filename or "")[1].lower() or ".mp3"
    dest = settings.upload_dir / f"{uuid.uuid4()}{suffix}"
    with dest.open("wb") as out:
        while chunk := await file.read(1024 * 1024):
            out.write(chunk)
    asyncio.create_task(process_audio_job(job_id, user_id, dest))
    return {"accepted": True, "job_id": job_id}


@app.get("/audio/jobs", response_model=AudioJobListResponse)
def audio_jobs_list(
    limit: int = Query(default=20, ge=1, le=100),
    user: UserOut = Depends(current_user),
) -> AudioJobListResponse:
    return AudioJobListResponse(items=[AudioJobOut(**item) for item in db.list_audio_jobs(user.id, limit=limit)])


@app.get("/transcript/query", response_model=TranscriptQueryResponse, deprecated=True)
def query_transcripts(
    start: datetime | None = Query(default=None),
    end: datetime | None = Query(default=None),
    user: UserOut = Depends(current_user),
) -> TranscriptQueryResponse:
    """[已废弃] 原始对话不再入库（采集结束直接生成场景，见 /capture/upload/*）。

    transcripts 表与本端点仅为兼容旧客户端保留，正常情况下会返回空列表。
    """
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
    return await generate_learning(items, user_id=user.id)


@app.post("/scenario/generate", response_model=ScenarioResponse)
async def scenario_generate(
    request: ScenarioGenerateRequest,
    user: UserOut = Depends(current_user),
) -> ScenarioResponse:
    require_ai_access(user)
    items = materialize_items(user.id, request.start, request.end, request.items)
    if not items:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="当前时间范围没有对话")
    scenario = await generate_scenario(items, user_id=user.id)
    return db.create_scenario(user.id, request.start, request.end, scenario)


@app.get("/scenario/list", response_model=ScenarioListResponse)
def scenario_list(
    start: datetime | None = Query(default=None),
    end: datetime | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=100),
    user: UserOut = Depends(current_user),
) -> ScenarioListResponse:
    items = db.list_scenarios(user.id, start, end, limit=limit)
    return ScenarioListResponse(items=[ScenarioSummary(**item) for item in items])


@app.get("/scenario/today", response_model=ScenarioListResponse)
def scenario_today(
    auto_generate: bool = Query(default=True),
    user: UserOut = Depends(current_user),
) -> ScenarioListResponse:
    """返回今天的场景列表。

    真实对话采集结束时会通过 /capture/upload/complete 直接生成场景；
    打开列表只读取已经生成的场景，不再触发模型调用。
    """
    now = datetime.now(timezone.utc)
    day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    existing = db.list_scenarios(user.id, day_start, now + timedelta(minutes=1))
    return ScenarioListResponse(
        items=[ScenarioSummary(**item) for item in existing],
        generated=False,
    )


@app.get("/scenario/presets/catalog", response_model=PresetScenarioCatalogResponse)
def scenario_presets_catalog(
    user: UserOut = Depends(current_user),
) -> PresetScenarioCatalogResponse:
    """通用场景目录（主场景 + 子场景标题），供没有录音时直接选场景练口语。"""
    return PresetScenarioCatalogResponse(
        items=[PresetScenarioGroup(**item) for item in db.get_preset_scenarios()]
    )


@app.post("/scenario/presets/generate", response_model=ScenarioResponse)
async def scenario_presets_generate(
    request: PresetScenarioGenerateRequest,
    user: UserOut = Depends(current_user),
) -> ScenarioResponse:
    """用户选中某个通用子场景后，让 AI 即时生成约 40 句中英双语对话并落库，随后即可进入对练。"""
    require_ai_access(user)
    catalog = db.get_preset_scenarios()
    group = next((g for g in catalog if g.get("id") == request.group_id), None)
    if group is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="主场景不存在")
    sub = next((s for s in group.get("subs", []) if s.get("id") == request.sub_id), None)
    if sub is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="子场景不存在")
    scenario = await generate_preset_scenario(
        str(group.get("title", "")),
        str(sub.get("title", "")),
        user_id=user.id,
    )
    now = datetime.now(timezone.utc)
    return db.create_scenario(user.id, now, now, scenario)


@app.get("/scenario/{scene_id}", response_model=ScenarioResponse)
def scenario_detail(
    scene_id: str,
    user: UserOut = Depends(current_user),
) -> ScenarioResponse:
    scenario = db.get_scenario(user.id, scene_id)
    if scenario is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="场景不存在")
    return scenario


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
        scenario = db.create_scenario(user.id, request.start, request.end, await generate_scenario(items, user_id=user.id))

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
    require_ai_access(user, estimated_cents=estimate_text_cost_cents(len(request.message or "")))
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
        user_id=user.id,
    )
    score = evaluation.score
    final_guidance = request.guidance_mode == "final"
    accepted = True if final_guidance else evaluation.accepted and score >= settings.roleplay_accept_score
    had_rejected_attempt = db.has_rejected_practice_attempt(
        user.id,
        session.session_id,
        target_line.index,
        settings.roleplay_accept_score,
    )
    feedback = "" if final_guidance else format_roleplay_feedback(
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
        feedback=(stored_feedback if final_guidance else feedback or None),
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
    latest_feedback = feedback or None
    if final_guidance and session.status == "completed":
        latest_feedback = format_final_roleplay_review(
            session,
            db.list_roleplay_messages(user.id, session.session_id),
        )
    return roleplay_state_response(
        user.id,
        session,
        scenario,
        latest_feedback=latest_feedback,
        latest_accepted=accepted,
    )


@app.post("/roleplay/evaluate", response_model=RoleplayStateResponse)
async def roleplay_evaluate(
    request: RoleplayEvaluateRequest,
    user: UserOut = Depends(current_user),
) -> RoleplayStateResponse:
    """按需对当前对练给出最终评分与建议。

    与 /roleplay/message 不同，本接口不推进对话，只汇总到目前为止的表现，
    因此用户中途退出（未走到最后一句）也能拿到评估结果。
    """
    require_ai_access(user)
    session = db.get_roleplay_session(user.id, request.session_id)
    if session is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="场景练习不存在")
    scenario = db.get_scenario(user.id, session.scene_id)
    if scenario is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="场景不存在")
    messages = db.list_roleplay_messages(user.id, session.session_id)
    review = format_final_roleplay_review(session, messages)
    return roleplay_state_response(user.id, session, scenario, latest_feedback=review)


def _ws_reason(text: object, max_bytes: int = 120) -> str:
    """WebSocket close reason 上限约 123 字节；按字节安全截断（避免中文超限报错）。"""
    raw = str(text).encode("utf-8")[:max_bytes]
    return raw.decode("utf-8", "ignore")


@app.websocket("/roleplay/voice")
async def roleplay_voice(
    websocket: WebSocket,
    token: str = Query(...),
    session_id: str = Query(...),
) -> None:
    """高级会员实时语音对练：后端在客户端与语音大模型之间转发音频，注入场景与护栏，结束给评分。

    鉴权走 query 里的 access token（WebSocket 不便带 Authorization 头）。
    """
    # 先 accept 再校验：握手后用 close(code, reason) 才能把原因（如超额需升级）干净地回传给客户端
    await websocket.accept()
    try:
        user = _authenticate_token(token)
        require_premium(user)
        # 语音对练开始时只校验「当月已用是否已超额」（流式无法预知本次时长，按用户选择不预扣）
        require_ai_access(user, estimated_cents=0.0)
    except HTTPException as exc:
        await websocket.close(code=4401, reason=_ws_reason(exc.detail))
        return
    session = db.get_roleplay_session(user.id, session_id)
    scenario = db.get_scenario(user.id, session.scene_id) if session else None
    if session is None or scenario is None:
        await websocket.close(code=4404, reason="场景练习不存在")
        return
    config = resolve_realtime_config()
    if not config.enabled:
        await websocket.close(code=4503, reason="语音大模型未配置，请联系管理员")
        return

    instructions = build_session_instructions(scenario, session.selected_role)
    usage: dict = {}
    try:
        transcript, usage = await proxy_session(websocket, instructions, config)
    except Exception:  # noqa: BLE001 — 转发期间任一端异常即结束并评分
        transcript = []
    # 实时语音用量计费：按文本/音频分开的单价折算费用并入账（与文字模型同一张 ai_usage 表）
    if usage and any(usage.values()):
        pricing = resolve_realtime_pricing()
        cost = realtime_usage_cost_cents(usage, pricing)
        input_tokens = int(usage.get("input_text", 0)) + int(usage.get("input_audio", 0))
        output_tokens = int(usage.get("output_text", 0)) + int(usage.get("output_audio", 0))
        try:
            db.record_ai_usage(
                user_id=user.id,
                kind="voice_realtime",
                model=config.model,
                prompt_tokens=input_tokens,
                completion_tokens=output_tokens,
                cost_cents=cost,
                latency_ms=0,
            )
        except Exception:  # noqa: BLE001 — 计费失败不影响主流程
            pass
    review = await score_voice_session(transcript, scenario, user.id)
    try:
        await websocket.send_text(_json.dumps({"type": "realtalk.review", **review}, ensure_ascii=False))
    except Exception:  # noqa: BLE001
        pass
    session.status = "completed"
    db.update_roleplay_session(session)
    try:
        await websocket.close()
    except Exception:  # noqa: BLE001
        pass


@app.get("/practice/history", response_model=PracticeHistoryResponse)
def practice_history(
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
    learning = await generate_learning(items, user_id=user.id)
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


def monthly_budget_cents(user: UserOut) -> float:
    """该用户当月可用的大模型费用额度（分）= 购买会员时锁定的档位标准月费 × 可配置比例（默认 50%）。

    旧用户即使后台调价，仍按其购买会员时的月费计算额度；会员到期后重新购买才用新价。
    """
    return db.user_monthly_budget_cents(user.id, user.plan_tier)


def estimate_text_cost_cents(input_chars: int = 0) -> float:
    """文本模型「调用前」费用预估（分）：按输入字符估 prompt + 该输出上限估 completion。

    预估参数实时读取 app_settings（管理台改后即时生效），缺失回退 env 默认。
    """
    from .ark_client import resolve_ai_config

    cfg = resolve_ai_config()
    min_input = db.get_app_setting_int("ai_estimate_min_input_tokens", settings.ai_estimate_min_input_tokens)
    output_tokens = db.get_app_setting_int("ai_estimate_output_tokens", settings.ai_estimate_output_tokens)
    # 中文约 1 token/字符，英文更少；取较保守的 max(下限, 字符数) 作为输入 token 估计
    input_tokens = max(min_input, int(input_chars))
    return round(
        input_tokens / 1_000_000 * cfg.input_price_per_1m_cents
        + output_tokens / 1_000_000 * cfg.output_price_per_1m_cents,
        4,
    )


def require_ai_access(user: UserOut, estimated_cents: float | None = None) -> None:
    """模型功能门禁：会员（或试用期）+ 当月费用额度（会员月费的 50%）。

    每次调模型前：检查「当月已用(文字+语音)费用 + 本次预估费用 > 额度」则拦截，
    并停止生成场景/对话；只拦截需要大模型的功能，采集/回看历史等不受影响。
    免费档（试用结束）→ 提示订阅；额度用尽→ 基础提示升级高级、高级暂时禁止（充值功能后续上线）。
    """
    if user.plan_tier == "free":
        # 非会员：每日固定 token 的文字模型用量（管理台可配置），用尽提示升级
        limit = db.get_nonmember_daily_chat_tokens()
        used_tokens = db.tokens_used_today(user.id)
        if limit > 0 and used_tokens >= limit:
            raise HTTPException(
                status_code=status.HTTP_402_PAYMENT_REQUIRED,
                detail=f"非会员每日 AI 用量已用完（每天 {limit} tokens），升级会员可解锁更多用量，或明天再来。",
            )
        return
    budget = monthly_budget_cents(user)
    used = db.cost_used_this_cycle(user.id)
    estimate = estimate_text_cost_cents() if estimated_cents is None else max(0.0, estimated_cents)
    if budget > 0 and used + estimate > budget:
        budget_yuan = budget / 100
        used_yuan = used / 100
        if user.plan_tier == "premium":
            detail = (
                f"本月语音/文字大模型用量已达额度上限（约 ¥{used_yuan:.2f} / ¥{budget_yuan:.2f}），"
                "高级会员额度充值功能即将上线，本月暂无法继续调用模型，下月自动恢复。"
            )
        else:
            detail = (
                f"本月 AI 用量已达额度上限（约 ¥{used_yuan:.2f} / ¥{budget_yuan:.2f}），"
                "升级高级会员可获得更高额度；本月额度下月自动恢复。"
            )
        raise HTTPException(status_code=status.HTTP_402_PAYMENT_REQUIRED, detail=detail)


def require_premium(user: UserOut) -> None:
    if user.plan_tier != "premium":
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail="上传录音文件生成场景是高级会员功能，请升级高级会员",
        )


def enforce_capture_quota(user: UserOut, items: list[TranscriptItem]) -> None:
    """非会员每日采集文字输入上限（token≈字符，管理台可配置）；会员不限。通过则记账。"""
    if user.plan_tier != "free":
        return
    char_count = sum(len((item.text or "").strip()) for item in items)
    if char_count <= 0:
        return
    limit = db.get_nonmember_daily_capture_tokens()
    used = db.capture_tokens_used_today(user.id)
    if limit > 0 and used + char_count > limit:
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail=f"非会员每日可采集的对话有限（每天约 {limit} 字），升级会员可解锁更多，或明天再来。",
        )
    db.record_capture_input(user.id, char_count)


def capture_quota_info(user: UserOut) -> CaptureQuotaResponse:
    """估算用户还能用于采集→生成场景的 token 余量（采集会调文本模型生成场景）。"""
    from .ark_client import resolve_ai_config

    sentence_tokens = 30  # 估算：平均每句对话约 30 token
    if user.plan_tier == "free":
        chat_left = max(0, db.get_nonmember_daily_chat_tokens() - db.tokens_used_today(user.id))
        cap_left = max(0, db.get_nonmember_daily_capture_tokens() - db.capture_tokens_used_today(user.id))
        remaining = min(chat_left, cap_left)
        is_member = False
    else:
        remaining_cents = max(0.0, monthly_budget_cents(user) - db.cost_used_this_cycle(user.id))
        price = resolve_ai_config().input_price_per_1m_cents or 80.0
        remaining = int(remaining_cents / price * 1_000_000) if price > 0 else 0
        is_member = True
    can = remaining > 0
    approx = remaining // sentence_tokens
    if not can:
        message = (
            "已超过当月可用额度，暂时无法采集；本月额度下月恢复，或升级会员获得更多额度。"
            if is_member else "今日免费额度已用尽，明天恢复，或升级会员获得更多额度。"
        )
    elif remaining < 1000:
        message = f"额度不足，大约还能采集 {approx} 句，请尽快升级会员或留意用量。"
    else:
        message = ""
    return CaptureQuotaResponse(
        remaining_tokens=remaining,
        can_capture=can,
        approx_sentences=approx,
        is_member=is_member,
        message=message,
    )


def nonmember_limits_info() -> NonmemberLimits:
    """非会员每日限额（供客户端登录后本地控制采集 token / 录音时长）。"""
    return NonmemberLimits(
        daily_chat_tokens=db.get_nonmember_daily_chat_tokens(),
        daily_capture_tokens=db.get_nonmember_daily_capture_tokens(),
        daily_capture_seconds=db.get_app_setting_int(
            "nonmember_daily_capture_seconds", settings.nonmember_daily_capture_seconds
        ),
    )


def token_usage_info(user: UserOut) -> TokenUsageInfo:
    used_tokens = db.tokens_used_today(user.id)
    # 客户端只展示「已用百分比」，不暴露具体金额（避免用户对「月费一半」的疑惑，金额属内部口径）
    if user.plan_tier == "free":
        # 非会员：每日 token 用量百分比
        limit = db.get_nonmember_daily_chat_tokens()
        pct = round(used_tokens / limit * 100, 1) if limit > 0 else 0.0
        over = limit > 0 and used_tokens >= limit
        return TokenUsageInfo(
            today_tokens=used_tokens,
            daily_limit=limit,
            remaining_tokens=max(0, limit - used_tokens),
            over_limit=over,
            over_budget=over,
            usage_percent=min(100.0, pct),
            is_member=False,
        )
    budget = monthly_budget_cents(user)
    cycle_cost = db.cost_used_this_cycle(user.id)
    over_budget = budget > 0 and cycle_cost >= budget
    pct = round(cycle_cost / budget * 100, 1) if budget > 0 else 0.0
    return TokenUsageInfo(
        today_tokens=used_tokens,
        daily_limit=0,
        remaining_tokens=0,
        over_limit=over_budget,
        over_budget=over_budget,
        usage_percent=min(100.0, pct),
        is_member=True,
        month_cost_cents=round(cycle_cost, 2),
        month_budget_cents=round(budget, 2),
        month_remaining_cents=round(max(0.0, budget - cycle_cost), 2),
    )


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

    if request.client == "web":
        app_id, app_secret = settings.wechat_web_app_id, settings.wechat_web_app_secret
    else:
        app_id, app_secret = settings.wechat_app_id, settings.wechat_app_secret
    if not app_id or not app_secret:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="微信登录未配置")

    try:
        async with httpx.AsyncClient(timeout=15) as client:
            token_response = await client.get(
                "https://api.weixin.qq.com/sns/oauth2/access_token",
                params={
                    "appid": app_id,
                    "secret": app_secret,
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
    except HTTPException:
        raise
    except httpx.HTTPError as exc:
        # 服务器连不上微信（无外网/DNS/被墙）等：返回清晰错误而非 500
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="无法连接微信服务器，请检查服务器外网访问；如未接入正式微信，请将 WECHAT_AUTH_DEV_MODE 设为 true",
        ) from exc

    return {
        "openid": openid,
        "nickname": user_payload.get("nickname") or request.nickname or "微信用户",
        "avatar_url": user_payload.get("headimgurl") or request.avatar_url,
    }


def materialize_items(user_id: str, start: datetime, end: datetime, request_items: list) -> list:
    if request_items:
        items = clean_transcript_items(request_items)
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


def format_final_roleplay_review(
    session: RoleplaySessionRecord,
    messages: list,
) -> str:
    score = round((session.score_total / session.turns) * 100) if session.turns else 0
    user_messages = [message for message in messages if getattr(message, "speaker", "") == "user"]
    weak_points = [
        getattr(message, "feedback", "")
        for message in user_messages
        if getattr(message, "feedback", "") and "正确，已继续" not in getattr(message, "feedback", "")
    ][:3]
    if not weak_points:
        return f"最终评分 {score}/100。整体表达能完成交流，接下来重点练自然停顿和更口语的连接词。"
    joined = "\n".join(f"- {point}" for point in weak_points)
    return f"最终评分 {score}/100。本轮优先改这几处：\n{joined}"


async def _cleanup_loop() -> None:
    while True:
        await asyncio.sleep(60 * 60)
        db.cleanup_expired(force=True)


# ---- 用户 Web 端（同源静态站点，登录后管理账号/充值/订阅/场景/上传录音）----
from pathlib import Path as _Path

from fastapi.staticfiles import StaticFiles

_web_dir = _Path(__file__).resolve().parents[1] / "web-frontend" / "public"
if _web_dir.is_dir():
    app.mount("/web", StaticFiles(directory=str(_web_dir), html=True), name="web")
