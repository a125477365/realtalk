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
from fastapi import Depends, FastAPI, File, HTTPException, Query, UploadFile, WebSocket, WebSocketDisconnect, status
from fastapi.responses import RedirectResponse, Response
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBasic, HTTPBasicCredentials, HTTPBearer

from .ark_client import (
    ai_timeout_policy,
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
    ScenarioRole,
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
    AudioUploadCompleteResponse,
    PlanCatalogResponse,
    PlanItem,
    PresetScenarioCatalogResponse,
    PresetSceneItem,
    PresetSceneGroup,
    PresetSceneAdminItem,
    PresetSceneListResponse,
    PresetSceneSaveRequest,
    PresetSceneGenerateRequest,
    NonmemberLimits,
    QuotaSettingsRequest,
    SubscribeRequest,
    SupportTicketCreate,
    SupportTicketListResponse,
    SupportTicketOut,
    SupportTicketUpdateRequest,
    TokenUsageInfo,
    PaymentSettingsRequest,
    IntegrationSettingsRequest,
    SessionPolicyRequest,
    PronunciationWord,
    TtsSettingsRequest,
    TtsVoiceRequest,
    TtsVoicesResponse,
    VoiceServersRequest,
)
from .capture_store import capture_store
from . import voice_pipeline
from . import voice_io
from . import payments
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
    # JWT 密钥已单一来源化（共享 DB；装库时入库、多活共用），不再有「弱默认/各节点各自一把」的风险，故无需告警。
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
    # 数据库必须已「供给」（建表+系统参数入库）。API 后端只读，绝不自己建表/播种。
    # 未供给 → 明确报错退出，提示去装库节点运行 db_init（避免多后端并发建表/播种竞争）。
    if not db.is_provisioned():
        raise RuntimeError(
            "数据库未初始化：请在安装数据库的节点运行 `python -m app.db_init` 完成建表与系统参数入库后再启动 API。"
        )
    _warn_insecure_config()
    db.cleanup_expired()
    asyncio.create_task(_cleanup_loop())
    asyncio.create_task(_capture_worker_loop())  # 采集场景生成消费者（多活：每节点一个）
    asyncio.create_task(_voice_cron_loop())       # 语音文件转写/生成场景/清理（每台语音服务器处理本地文件）
    _register_self_as_voice_node()  # 语音服务器首次启动自动把本机加入列表（之后可在管理台删除）


def _idle_ttl_seconds(surface: str | None) -> int:
    """按登录端返回会话闲置超时秒数：web 较短、app 较长。"""
    if surface == "web":
        return db.get_idle_timeout_web_minutes() * 60
    return db.get_idle_timeout_app_minutes() * 60


def _authenticate_token(token: str) -> UserOut:
    """校验 access token（存在性/封禁/单设备/令牌版本/闲置超时），返回用户。供 HTTP 与 WebSocket 共用。"""
    user_id, device_id, token_version, surface = verify_token(token)
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
    # 闲置超时：太久没有任何请求即需重新登录（活跃使用会在下方滑动续期 last_seen）
    if last_seen is not None and (now - last_seen).total_seconds() > _idle_ttl_seconds(surface):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="登录已超时，请重新登录")
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
        "retention_days": db.get_retention_days(),
        "history_retention_days": db.get_history_retention_days(),
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
        product_id=db.resolve_apple_iap_config()["product_id"],
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
        "api_key_configured": bool(config.api_key),
        "model": config.model,
        "bot_id": config.bot_id,
        "timeout_seconds": config.timeout_seconds,
        "timeout_long_seconds": config.timeout_long_seconds,
        "max_tokens_normal": config.max_tokens_normal,
        "max_tokens_long": config.max_tokens_long,
        "effective_timeouts": ai_timeout_policy(config),
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
    if request.timeout_long_seconds is not None:
        updates["ai_timeout_long_seconds"] = str(request.timeout_long_seconds)
    if request.max_tokens_normal is not None:
        updates["ai_max_tokens_normal"] = str(request.max_tokens_normal)
    if request.max_tokens_long is not None:
        updates["ai_max_tokens_long"] = str(request.max_tokens_long)
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


def _default_scene_roles() -> list[ScenarioRole]:
    return [
        ScenarioRole(id="self", name="我", description="用户可扮演的角色", is_user_candidate=True),
        ScenarioRole(id="counterpart", name="对方", description="另一位对话角色", is_user_candidate=True),
    ]


def _reindex_lines(lines: list[SceneLine]) -> list[SceneLine]:
    return [line.model_copy(update={"index": i}) for i, line in enumerate(lines)]


@app.get("/admin/api/presets", response_model=PresetSceneListResponse)
def admin_list_presets(admin: dict = Depends(current_admin)) -> PresetSceneListResponse:
    return PresetSceneListResponse(items=[PresetSceneAdminItem(**item) for item in db.list_preset_scenarios()])


@app.post("/admin/api/presets", response_model=PresetSceneAdminItem)
def admin_save_preset(
    request: PresetSceneSaveRequest,
    admin: dict = Depends(current_admin),
) -> PresetSceneAdminItem:
    """新增或编辑一条预置场景（含完整对话内容）。运维可随时修改补充。"""
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    if not request.lines:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="对话内容不能为空")
    scenario = ScenarioResponse(
        scene_id=request.scene_id or "",
        title=request.title,
        summary=request.summary,
        roles=request.roles or _default_scene_roles(),
        lines=_reindex_lines(request.lines),
        expressions=request.expressions,
    )
    if request.scene_id:
        if not db.update_preset_scenario(request.scene_id, request.group, request.title, scenario, request.sort):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="预置场景不存在")
        scene_id = request.scene_id
    else:
        saved = db.create_preset_scenario(request.group, request.title, scenario, request.sort)
        scene_id = saved.scene_id
    return PresetSceneAdminItem(
        scene_id=scene_id,
        group=request.group,
        title=request.title,
        summary=request.summary,
        roles=scenario.roles,
        lines=scenario.lines,
        expressions=scenario.expressions,
        line_count=len(scenario.lines),
        sort=request.sort,
    )


@app.delete("/admin/api/presets/{scene_id}")
def admin_delete_preset(scene_id: str, admin: dict = Depends(current_admin)) -> dict:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    if not db.delete_preset_scenario(scene_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="预置场景不存在")
    return {"ok": True}


@app.post("/admin/api/presets/generate", response_model=ScenarioResponse)
async def admin_generate_preset_draft(
    request: PresetSceneGenerateRequest,
    admin: dict = Depends(current_admin),
) -> ScenarioResponse:
    """用 AI 按主题生成一份对话草稿，返回给运维编辑后再保存（不落库）。

    生成失败/模型未配置时返回明确错误原因（而不是静默给一段与主题无关的固定占位草稿）。
    """
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    try:
        return await generate_preset_scenario(request.group, request.title, user_id=None)
    except HTTPException:
        raise
    except httpx.TimeoutException:
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="AI 生成草稿超时：大模型生成较慢，请重试；如反复超时，请在「系统设置 · 模型」调大超时时间。",
        )
    except httpx.HTTPStatusError as exc:
        body = ""
        try:
            body = exc.response.text[:160]
        except Exception:  # noqa: BLE001
            pass
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"AI 生成草稿失败：模型服务返回 {exc.response.status_code}。{body}",
        )
    except Exception as exc:  # noqa: BLE001 — 把真实原因反馈给运维
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"AI 生成草稿失败：{str(exc)[:200]}",
        )


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
    # 截图为 base64 data URL：限制数量与总大小，避免超大请求
    images = [img for img in request.images if isinstance(img, str) and img.startswith("data:image")][:4]
    if sum(len(img) for img in images) > 8 * 1024 * 1024:  # base64 总长约 8MB（≈6MB 原图）
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="截图过大，请压缩后再上传（最多 4 张、合计约 6MB）")
    ticket = db.create_support_ticket(
        user_id=user.id,
        category=request.category,
        subject=request.subject.strip(),
        body=request.body.strip(),
        images=images,
    )
    return SupportTicketOut(**ticket)


@app.get("/support/tickets", response_model=SupportTicketListResponse)
def list_my_support_tickets(user: UserOut = Depends(current_user)) -> SupportTicketListResponse:
    items = db.list_user_tickets(user.id)
    return SupportTicketListResponse(items=[SupportTicketOut(**t) for t in items])


@app.get("/admin/api/support/tickets")
def admin_list_support_tickets(
    status_filter: str | None = Query(default=None, alias="status"),
    category: str | None = Query(default=None),
    start: datetime | None = Query(default=None),
    end: datetime | None = Query(default=None),
    admin: dict = Depends(current_admin),
) -> dict:
    # 进工单界面默认只看待处理（open）；传 status=all 看全部
    effective_status = None if status_filter in (None, "", "all") else status_filter
    return {"items": db.list_support_tickets(status=effective_status, category=category, start=start, end=end)}


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


@app.get("/admin/api/settings/tts")
def admin_get_tts(admin: dict = Depends(current_admin)) -> dict:
    config = voice_io.resolve_tts_config()
    return {
        "mode": config["mode"],
        "base_url": config["base_url"],
        "model": config["model"],
        "voices": config["voices"],
        "default_voice": voice_io.default_voice(),
        "api_key_masked": _masked_key(config["api_key"]),
        "api_key_configured": bool(config["api_key"]),
        "configured": voice_io.tts_configured(),
        "dev_mode": config["dev_mode"],
    }


@app.post("/admin/api/settings/tts")
def admin_set_tts(
    request: TtsSettingsRequest,
    admin: dict = Depends(current_admin),
) -> dict:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    # mode / 本地命令由部署控制；管理台只配置云端 base_url/api_key/model 与可选音色
    if request.base_url is not None:
        db.set_app_setting("tts_base_url", request.base_url.strip().rstrip("/"))
    if request.api_key is not None:
        db.set_app_setting("tts_api_key", request.api_key.strip())
    if request.model is not None:
        db.set_app_setting("tts_model", request.model.strip())
    if request.voices is not None:
        db.set_app_setting("tts_voices", request.voices.strip())
    if request.default_voice is not None:
        db.set_app_setting("tts_default_voice", request.default_voice.strip())
    return admin_get_tts(admin)


@app.get("/tts/voices", response_model=TtsVoicesResponse)
def tts_voices(user: UserOut = Depends(current_user)) -> TtsVoicesResponse:
    """可选 AI 音色 + 当前用户已选音色（用于练习时朗读 AI 台词）。"""
    current = db.get_user_tts_voice(user.id) or voice_io.default_voice()
    return TtsVoicesResponse(
        voices=voice_io.available_voices(),
        current=voice_io.normalize_voice(current),
        configured=voice_io.tts_configured(),
    )


@app.post("/tts/voice", response_model=TtsVoicesResponse)
def tts_set_voice(request: TtsVoiceRequest, user: UserOut = Depends(current_user)) -> TtsVoicesResponse:
    voice = voice_io.normalize_voice(request.voice)
    db.set_user_tts_voice(user.id, voice)
    return TtsVoicesResponse(voices=voice_io.available_voices(), current=voice, configured=voice_io.tts_configured())


def _enforce_user_rate(user_id: str, name: str, limit: int, window: int = 60) -> None:
    """每用户每窗口分布式限流（Redis 固定窗口计数，跨节点）。比按 IP 的进程内限流更贴近防滥用。
    Redis 异常时放行——不因缓存抖动锁死正常用户（按 IP 的进程内限流仍兜底）。"""
    if limit <= 0:
        return
    r = getattr(capture_store, "r", None)
    if r is None:
        return
    n = 0
    try:
        key = f"rt:rl:{name}:{user_id}:{int(_time.time()) // window}"
        n = r.incr(key)
        if n == 1:
            r.expire(key, window)
    except Exception:  # noqa: BLE001
        return
    if n > limit:
        raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail="操作过于频繁，请稍后再试")


@app.get("/tts/speak")
async def tts_speak(
    text: str = Query(..., min_length=1, max_length=600),
    cache: bool = Query(default=True),  # 指导性内容传 cache=false（不入 Redis，太杂且不复用）
    user: UserOut = Depends(current_user),
) -> Response:
    """用用户选定的音色朗读一段文本（练习时播放 AI 台词）。"""
    _enforce_user_rate(user.id, "tts", settings.tts_user_rate_per_min)
    voice = db.get_user_tts_voice(user.id) or voice_io.default_voice()
    try:
        audio, content_type = await voice_io.synthesize(text, voice, use_cache=cache)
    except voice_io.TTSOverloaded as exc:
        raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail=str(exc)) from exc
    return Response(content=audio, media_type=content_type)


@app.get("/tts/preview")
async def tts_preview(
    voice: str = Query(default=""),
    text: str = Query(default="Hello, this is how I sound."),
    user: UserOut = Depends(current_user),
) -> Response:
    """试听某个音色（音色选择界面用）。返回音频字节。"""
    _enforce_user_rate(user.id, "tts", settings.tts_user_rate_per_min)
    try:
        audio, content_type = await voice_io.synthesize(text[:200], voice or None)
    except voice_io.TTSOverloaded as exc:
        raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail=str(exc)) from exc
    return Response(content=audio, media_type=content_type)


@app.get("/admin/api/settings/voice-servers")
def admin_get_voice_servers(admin: dict = Depends(current_admin)) -> dict:
    """语音文件服务器列表（可处理语音上传的服务器 ip:port）。"""
    return {
        "servers_text": db.get_app_setting_str("voice_servers") or "",
        "servers": voice_pipeline.voice_servers(),
    }


@app.post("/admin/api/settings/voice-servers")
def admin_set_voice_servers(
    request: VoiceServersRequest,
    admin: dict = Depends(current_admin),
) -> dict:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    # 规范化后存库：统一成 `ip:port;ip:port`；非法项忽略
    cleaned = [voice_pipeline.normalize_addr(p) for p in (request.servers or "").replace(",", ";").replace("\n", ";").split(";")]
    cleaned = [a for a in cleaned if a]
    db.set_app_setting("voice_servers", ";".join(cleaned))
    return admin_get_voice_servers(admin)


@app.get("/admin/api/settings/payment")
def admin_get_payment(admin: dict = Depends(current_admin)) -> dict:
    """支付验签凭证（敏感项只回是否已配置/掩码，不回明文）。"""
    c = payments.resolve_payment_config()
    return {
        "wechat_mchid": c["wechat_mchid"] or "",
        "wechat_cert_serial": c["wechat_cert_serial"] or "",
        "wechat_notify_url": c["wechat_notify_url"] or "",
        "wechat_apiv3_key_configured": bool(c["wechat_apiv3_key"]),
        "wechat_platform_cert_configured": bool(c["wechat_platform_cert"]),
        "wechat_merchant_cert_configured": bool(c["wechat_merchant_cert"]),
        "wechat_merchant_key_configured": bool(c["wechat_merchant_private_key"]),
        "wechat_verify_ready": payments.wechat_configured(c),
        "alipay_app_id": c["alipay_app_id"] or "",
        "alipay_notify_url": c["alipay_notify_url"] or "",
        "alipay_public_key_configured": bool(c["alipay_public_key"]),
        "alipay_merchant_key_configured": bool(c["alipay_merchant_private_key"]),
        "alipay_verify_ready": payments.alipay_configured(c),
        "payment_receiver_name": c["payment_receiver_name"] or "",
        "wechat_receiver_account": c["wechat_receiver_account"] or "",
        "alipay_receiver_account": c["alipay_receiver_account"] or "",
        "wechat_pay_url": c["wechat_pay_url"] or "",
        "alipay_pay_url": c["alipay_pay_url"] or "",
    }


@app.post("/admin/api/settings/payment")
def admin_set_payment(
    request: PaymentSettingsRequest,
    admin: dict = Depends(current_admin),
) -> dict:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    # 非敏感项空串也允许清空；敏感项（密钥/证书/公钥）留空=保持不变
    if request.wechat_mchid is not None:
        db.set_app_setting("wechat_mchid", request.wechat_mchid.strip())
    if request.wechat_cert_serial is not None:
        db.set_app_setting("wechat_cert_serial", request.wechat_cert_serial.strip())
    if request.wechat_notify_url is not None:
        db.set_app_setting("wechat_notify_url", request.wechat_notify_url.strip())
    if request.wechat_apiv3_key:
        db.set_app_setting("wechat_apiv3_key", request.wechat_apiv3_key.strip())
    if request.wechat_platform_cert:
        db.set_app_setting("wechat_platform_cert", request.wechat_platform_cert.strip())
    if request.wechat_merchant_cert:
        db.set_app_setting("wechat_merchant_cert", request.wechat_merchant_cert.strip())
    if request.wechat_merchant_private_key:
        db.set_app_setting("wechat_merchant_private_key", request.wechat_merchant_private_key.strip())
    if request.alipay_app_id is not None:
        db.set_app_setting("alipay_app_id", request.alipay_app_id.strip())
    if request.alipay_notify_url is not None:
        db.set_app_setting("alipay_notify_url", request.alipay_notify_url.strip())
    if request.alipay_public_key:
        db.set_app_setting("alipay_public_key", request.alipay_public_key.strip())
    if request.alipay_merchant_private_key:
        db.set_app_setting("alipay_merchant_private_key", request.alipay_merchant_private_key.strip())
    if request.payment_receiver_name is not None:
        db.set_app_setting("payment_receiver_name", request.payment_receiver_name.strip())
    if request.wechat_receiver_account is not None:
        db.set_app_setting("wechat_receiver_account", request.wechat_receiver_account.strip())
    if request.alipay_receiver_account is not None:
        db.set_app_setting("alipay_receiver_account", request.alipay_receiver_account.strip())
    if request.wechat_pay_url is not None:
        db.set_app_setting("wechat_pay_url", request.wechat_pay_url.strip())
    if request.alipay_pay_url is not None:
        db.set_app_setting("alipay_pay_url", request.alipay_pay_url.strip())
    return admin_get_payment(admin)


@app.get("/admin/api/settings/integrations")
def admin_get_integrations(admin: dict = Depends(current_admin)) -> dict:
    """多活共用凭据：SMTP / 微信登录 / Apple IAP（密钥类只回是否已配置，不回明文）。"""
    smtp = db.resolve_smtp_config()
    wx = db.resolve_wechat_login_config()
    ap = db.resolve_apple_iap_config()
    return {
        "smtp_host": smtp["host"] or "",
        "smtp_port": smtp["port"],
        "smtp_username": smtp["username"] or "",
        "smtp_password_configured": bool(smtp["password"]),
        "smtp_from": smtp["from_addr"],
        "email_code_ttl_minutes": smtp["code_ttl_minutes"],
        "smtp_ready": db.smtp_configured(),
        "wechat_app_id": wx["app_id"] or "",
        "wechat_app_secret_configured": bool(wx["app_secret"]),
        "wechat_web_app_id": wx["web_app_id"] or "",
        "wechat_web_app_secret_configured": bool(wx["web_app_secret"]),
        "apple_product_id": ap["product_id"] or "",
        "apple_bundle_id": ap["bundle_id"] or "",
        "apple_issuer_id": ap["issuer_id"] or "",
        "apple_key_id": ap["key_id"] or "",
        "apple_private_key_configured": bool(ap["private_key"]),
    }


@app.post("/admin/api/settings/integrations")
def admin_set_integrations(
    request: IntegrationSettingsRequest,
    admin: dict = Depends(current_admin),
) -> dict:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    # 非敏感项空串=清空；密钥/私钥类（password/secret/private_key）留空=保持不变
    if request.smtp_host is not None:
        db.set_app_setting("smtp_host", request.smtp_host.strip())
    if request.smtp_port is not None:
        db.set_app_setting("smtp_port", str(request.smtp_port))
    if request.smtp_username is not None:
        db.set_app_setting("smtp_username", request.smtp_username.strip())
    if request.smtp_password:
        db.set_app_setting("smtp_password", request.smtp_password.strip())
    if request.smtp_from is not None:
        db.set_app_setting("smtp_from", request.smtp_from.strip())
    if request.email_code_ttl_minutes is not None:
        db.set_app_setting("email_code_ttl_minutes", str(request.email_code_ttl_minutes))
    if request.wechat_app_id is not None:
        db.set_app_setting("wechat_app_id", request.wechat_app_id.strip())
    if request.wechat_app_secret:
        db.set_app_setting("wechat_app_secret", request.wechat_app_secret.strip())
    if request.wechat_web_app_id is not None:
        db.set_app_setting("wechat_web_app_id", request.wechat_web_app_id.strip())
    if request.wechat_web_app_secret:
        db.set_app_setting("wechat_web_app_secret", request.wechat_web_app_secret.strip())
    if request.apple_product_id is not None:
        db.set_app_setting("apple_product_id", request.apple_product_id.strip())
    if request.apple_bundle_id is not None:
        db.set_app_setting("apple_bundle_id", request.apple_bundle_id.strip())
    if request.apple_issuer_id is not None:
        db.set_app_setting("apple_issuer_id", request.apple_issuer_id.strip())
    if request.apple_key_id is not None:
        db.set_app_setting("apple_key_id", request.apple_key_id.strip())
    if request.apple_private_key:
        db.set_app_setting("apple_private_key", request.apple_private_key.strip())
    return admin_get_integrations(admin)


@app.get("/admin/api/settings/session")
def admin_get_session_policy(admin: dict = Depends(current_admin)) -> dict:
    """会话/留存策略（多活共用，DB 为唯一运行期来源）。"""
    return {
        "access_token_ttl_minutes": db.get_access_token_ttl_minutes(),
        "refresh_token_ttl_days": db.get_refresh_token_ttl_days(),
        "idle_timeout_app_minutes": db.get_idle_timeout_app_minutes(),
        "idle_timeout_web_minutes": db.get_idle_timeout_web_minutes(),
        "admin_idle_timeout_minutes": db.get_admin_idle_timeout_minutes(),
        "retention_days": db.get_retention_days(),
        "history_retention_days": db.get_history_retention_days(),
        "online_window_minutes": db.get_online_window_minutes(),
        "roleplay_accept_score": db.get_roleplay_accept_score(),
        "political_filter_enabled": db.get_political_filter_enabled(),
    }


@app.post("/admin/api/settings/session")
def admin_set_session_policy(
    request: SessionPolicyRequest,
    admin: dict = Depends(current_admin),
) -> dict:
    if admin["role"] not in ("superadmin", "admin"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="权限不足")
    for key in (
        "access_token_ttl_minutes", "refresh_token_ttl_days",
        "idle_timeout_app_minutes", "idle_timeout_web_minutes", "admin_idle_timeout_minutes",
        "retention_days", "history_retention_days", "online_window_minutes",
    ):
        val = getattr(request, key)
        if val is not None:
            db.set_app_setting(key, str(int(val)))
    if request.roleplay_accept_score is not None:
        db.set_app_setting("roleplay_accept_score", str(float(request.roleplay_accept_score)))
    if request.political_filter_enabled is not None:
        db.set_app_setting("political_filter_enabled", "1" if request.political_filter_enabled else "0")
    return admin_get_session_policy(admin)


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
    web_app_id = db.resolve_wechat_login_config()["web_app_id"]   # 单一来源：只读 DB
    if not web_app_id:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="网站微信登录未配置（wechat_web_app_id）")
    from urllib.parse import quote

    auth_url = (
        "https://open.weixin.qq.com/connect/qrconnect"
        f"?appid={web_app_id}"
        f"&redirect_uri={quote(redirect, safe='')}"
        "&response_type=code&scope=snsapi_login#wechat_redirect"
    )
    return {"dev_mode": False, "auth_url": auth_url}


def _issue_token_pair(user_id: str, device_id: str | None, surface: str = "app") -> tuple[str, str]:
    """按用户当前令牌版本签发 access + refresh 令牌对；surface 决定该会话的闲置超时时长。"""
    tv = db.get_token_version(user_id)
    return create_token(user_id, device_id, tv, surface), create_refresh_token(user_id, device_id, tv, surface)


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
    # request.client 区分 app / 用户 web：用户 web 闲置 30 分钟、app 闲置 7 天需重新登录
    access_token, refresh = _issue_token_pair(user.id, device_id, request.client)
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
        expires_in=db.get_access_token_ttl_minutes() * 60,
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
        expires_in=db.get_access_token_ttl_minutes() * 60,
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
        expires_in=db.get_access_token_ttl_minutes() * 60,
    )


@app.post("/auth/password/reset/send")
def send_password_reset(
    request: PasswordResetSendRequest,
) -> MessageResponse:
    normalized = normalize_email(request.email)
    user = db.get_user_by_login_identifier(normalized)
    if user is not None:
        raw_token, token_hash = create_password_reset_token()
        ttl_minutes = db.get_app_setting_int("email_code_ttl_minutes", settings.email_code_ttl_minutes)
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
        expires_in=db.get_access_token_ttl_minutes() * 60,
    )


@app.post("/auth/token/refresh", response_model=AuthTokenResponse)
def refresh_token(
    request: TokenRefreshRequest,
) -> AuthTokenResponse:
    user_id, device_id, token_version, surface = verify_refresh_token(request.refresh_token)
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
    # 闲置超时：太久没活动则刷新也不能续命，需重新登录（与 _authenticate_token 一致）
    last_seen = session["last_seen_at"]
    now = datetime.now(timezone.utc)
    if last_seen is not None and (now - last_seen).total_seconds() > _idle_ttl_seconds(surface):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="登录已超时，请重新登录")
    db.touch_user_seen(user.id)
    # 轮换：每次刷新都发新的 access + refresh，并保持原登录端的超时策略
    access_token, refresh = _issue_token_pair(user.id, device_id, surface)
    return AuthTokenResponse(
        access_token=access_token,
        refresh_token=refresh,
        expires_in=db.get_access_token_ttl_minutes() * 60,
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
    
    code_ttl_minutes = db.get_app_setting_int("email_code_ttl_minutes", settings.email_code_ttl_minutes)
    ttl_seconds = code_ttl_minutes * 60
    expires_at = datetime.now(timezone.utc) + timedelta(minutes=code_ttl_minutes)
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
    _pay_cfg = payments.resolve_payment_config()   # 单一来源：商户号/支付宝 appid 只读 DB
    wechat_official = bool(_pay_cfg["wechat_mchid"] and _pay_cfg["wechat_notify_url"])
    alipay_official = bool(_pay_cfg["alipay_app_id"] and _pay_cfg["alipay_notify_url"])
    manual_fallback = settings.payment_dev_auto_confirm or bool(
        _pay_cfg["wechat_receiver_account"]
        or _pay_cfg["alipay_receiver_account"]
        or _pay_cfg["wechat_pay_url"]
        or _pay_cfg["alipay_pay_url"]
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
                notify_url=_pay_cfg["wechat_notify_url"],
                client_ip=client_ip,
            )
            
            order = db.create_recharge_order(
                user.id,
                request.method,
                amount_cents,
                payment_url=result.get("code_url"),
                qr_code_text=result.get("code_url"),
                receiver_name=_pay_cfg["payment_receiver_name"],
                receiver_account=_pay_cfg["wechat_receiver_account"],
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
                notify_url=_pay_cfg["alipay_notify_url"],
            )
            
            order = db.create_recharge_order(
                user.id,
                request.method,
                amount_cents,
                payment_url=result.get("qr_code"),
                qr_code_text=result.get("qr_code"),
                receiver_name=_pay_cfg["payment_receiver_name"],
                receiver_account=_pay_cfg["alipay_receiver_account"],
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
        receiver_name=_pay_cfg["payment_receiver_name"],
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
    """WeChat Pay v3 异步回调：必须验签 + 解密，绝不信任明文（防伪造通知白嫖会员）。"""
    body = await request.body()
    headers = {k.lower(): v for k, v in request.headers.items()}

    config = payments.resolve_payment_config()
    if not payments.wechat_configured(config):
        return {"code": "FAIL", "message": "not configured"}   # 未配 APIv3 密钥/平台证书 → 拒绝，不处理
    # 1) 验签（平台证书 RSA-SHA256 + 时间窗防重放）：失败直接拒绝
    if not payments.verify_wechat_signature(headers, body, config):
        return {"code": "FAIL", "message": "invalid signature"}

    try:
        payload = _json.loads(body)
    except Exception:
        return {"code": "FAIL", "message": "invalid json"}

    event_type = payload.get("event_type", "")
    # 2) 解密 resource（真实金额/状态在密文里，明文不可信）
    try:
        resource = payments.decrypt_wechat_resource(payload.get("resource", {}), config["wechat_apiv3_key"])
    except Exception:
        return {"code": "FAIL", "message": "decrypt failed"}
    out_trade_no = resource.get("out_trade_no", "")

    if not out_trade_no:
        return {"code": "FAIL", "message": "no order id"}

    payload_json = _json.dumps(resource)
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
    """支付宝异步回调：必须 RSA2 验签后才处理（防伪造通知白嫖会员）。返回 'success' 纯文本。"""
    form = await request.form()

    config = payments.resolve_payment_config()
    if not payments.alipay_configured(config):
        return "fail"   # 未配支付宝公钥 → 无法验签 → 拒绝
    try:
        params = {k: str(v) for k, v in form.items()}
        # 验签：失败直接拒绝
        if not payments.verify_alipay_signature(params, config["alipay_public_key"]):
            return "fail"
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
            if method == "wechat" and payments.resolve_payment_config()["wechat_mchid"]:
                result = await wechat_pay.query_order(order_id)
                provider_status = result.get("trade_state", "unknown")
                if provider_status == "SUCCESS":
                    amount = int(result.get("amount", {}).get("total", 0))
                    if amount > 0:
                        _, _ = db.mark_recharge_paid_by_order_id(order_id, amount)
                        order_status = "paid"
            elif method == "alipay" and payments.resolve_payment_config()["alipay_app_id"]:
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
    """采集分块上传收尾。改为异步：快速校验+配额后把生成任务推入 Redis 队列即返回，
    App 收到「上传成功」即可删除本地文件，不必等待大模型生成；场景生成完会出现在场景列表。"""
    require_ai_access(user)
    items = await asyncio.to_thread(capture_store.load_items, request.upload_id, user.id)
    if items is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="上传会话不存在或已过期，请重新开始")
    if not items:
        await asyncio.to_thread(capture_store.delete_session, request.upload_id, user.id)
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="本次采集没有可生成场景的对话")
    enforce_capture_quota(user, items)  # 非会员每日采集上限（快速校验，仍同步）
    # 入队由「任意 API 节点的消费者」领取生成（多活）；会话数据已在共享 Redis，处理完由消费者清理。
    await asyncio.to_thread(capture_store.enqueue_generation, user.id, request.upload_id)
    return CaptureUploadCompleteResponse(
        accepted_items=len(items),
        generated=0,
        scenario_ids=[],
        scenarios=[],
        status="processing",
    )


async def _process_capture_job(user_id: str, upload_id: str) -> None:
    """后台消费一个采集生成任务：从 Redis 读取 → 生成场景落库 → 清理会话与锁。失败不重试（按需求）。"""
    try:
        items = await asyncio.to_thread(capture_store.load_items, upload_id, user_id)
        if not items:
            return
        await _generate_and_save_capture_scenarios(user_id, items)
    except Exception as exc:  # noqa: BLE001 — 生成失败按需求不再处理，仅记录日志
        print(f"[capture] 场景生成失败 user={user_id} upload={upload_id}: {str(exc)[:200]}", flush=True)
    finally:
        await asyncio.to_thread(capture_store.delete_session, upload_id, user_id)
        await asyncio.to_thread(capture_store.clear_generation_lock, user_id, upload_id)


async def _capture_worker_loop() -> None:
    """采集场景生成消费者：每个 API 节点常驻一个，Redis 队列把任务分发给某个节点处理（多活、无状态）。"""
    while True:
        try:
            job = await asyncio.to_thread(capture_store.dequeue_generation, 2)
            if not job:
                continue
            user_id = job.get("user_id")
            upload_id = job.get("upload_id")
            if user_id and upload_id:
                await _process_capture_job(user_id, upload_id)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 — 消费循环必须不死
            print(f"[capture] 采集生成消费循环异常：{str(exc)[:200]}", flush=True)
            await asyncio.sleep(1)


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


# ---- 语音文件上传：按 MD5 路由到指定语音服务器 + 断点续传 + 文件名去重 ----
# 处理改为「接收存盘 → 每小时定时任务转写+生成场景」。上传端点只负责把文件可靠地落到
# 「该 md5 应归属的那台语音服务器」；命中本机则本地存盘，否则把整请求转发给目标服务器。

async def _route_or_forward(request: Request, md5: str) -> Response | None:
    """按 md5 选语音服务器：命中本机返回 None（本地处理）；否则把整请求转发到目标 ip:port 并返回其响应。"""
    if not voice_pipeline.valid_md5(md5):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="缺少或非法的文件 MD5")
    servers = voice_pipeline.voice_servers()
    if not servers:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="未配置语音文件服务器，请联系管理员在管理台「系统设置」中配置可处理语音的服务器列表",
        )
    if request.headers.get("x-voice-routed") == "1":
        return None  # 已是被转发来的请求 → 本机直接处理，避免二次转发
    target = voice_pipeline.route_target(md5, servers)
    if voice_pipeline.is_self(target):
        return None
    body = await request.body()
    headers = {k: v for k, v in request.headers.items() if k.lower() not in ("host", "content-length")}
    headers["x-voice-routed"] = "1"
    url = f"http://{target}{request.url.path}"
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(1800, connect=15)) as client:
            resp = await client.request(
                request.method, url, params=dict(request.query_params), content=body, headers=headers
            )
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"转发到语音服务器 {target} 失败：{str(exc)[:160]}",
        ) from exc
    return Response(content=resp.content, status_code=resp.status_code, media_type=resp.headers.get("content-type"))


@app.post("/audio/upload/init", response_model=AudioUploadInitResponse)
async def audio_upload_init(
    request: Request,
    body: AudioUploadInitRequest,
    user: UserOut = Depends(current_user),
) -> AudioUploadInitResponse:
    _require_audio_ready(user)
    fwd = await _route_or_forward(request, body.md5)
    if fwd is not None:
        return fwd
    ext = _audio_suffix(body.filename)
    if body.size_bytes > settings.audio_max_bytes:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"文件超过 {settings.audio_max_bytes // (1024 * 1024)}MB 上限",
        )
    # 去重：已转写(.txt)或已传完(.ready) → 直接视为成功；半截文件 → 返回已收字节支持续传
    if voice_pipeline.txt_path(user.id, body.md5).exists():
        return AudioUploadInitResponse(upload_id=body.md5, received_bytes=body.size_bytes, done=True)
    existing = voice_pipeline.find_audio(user.id, body.md5)
    if existing is not None:
        done = voice_pipeline.ready_marker(existing).exists()
        return AudioUploadInitResponse(upload_id=body.md5, received_bytes=existing.stat().st_size, done=done)
    dest = voice_pipeline.audio_path(user.id, body.md5, ext)
    dest.touch()
    return AudioUploadInitResponse(upload_id=body.md5, received_bytes=0, done=False)


@app.get("/audio/upload/status", response_model=AudioUploadStatusResponse)
async def audio_upload_status(
    request: Request,
    md5: str = Query(...),
    size_bytes: int = Query(default=0, ge=0),
    user: UserOut = Depends(current_user),
) -> AudioUploadStatusResponse:
    fwd = await _route_or_forward(request, md5)
    if fwd is not None:
        return fwd
    existing = voice_pipeline.find_audio(user.id, md5)
    txt_done = voice_pipeline.txt_path(user.id, md5).exists()
    received = existing.stat().st_size if existing else (size_bytes if txt_done else 0)
    completed = txt_done or (existing is not None and voice_pipeline.ready_marker(existing).exists()) or (
        size_bytes > 0 and received >= size_bytes
    )
    return AudioUploadStatusResponse(upload_id=md5, received_bytes=received, size_bytes=size_bytes, completed=completed)


@app.put("/audio/upload/chunk")
async def audio_upload_chunk(
    request: Request,
    md5: str = Query(...),
    offset: int = Query(..., ge=0),
    user: UserOut = Depends(current_user),
) -> dict:
    """从 offset 写入一段数据；客户端断线后用 /status 查到 received_bytes 再续传。"""
    _require_audio_ready(user)
    fwd = await _route_or_forward(request, md5)
    if fwd is not None:
        return fwd
    part = voice_pipeline.find_audio(user.id, md5)
    if part is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="上传会话不存在，请先 init")
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
    return {"upload_id": md5, "received_bytes": part.stat().st_size}


@app.post("/audio/upload/complete", response_model=AudioUploadCompleteResponse)
async def audio_upload_complete(
    request: Request,
    md5: str = Query(...),
    filename: str = Query(default=""),
    size_bytes: int = Query(default=0, ge=0),
    user: UserOut = Depends(current_user),
) -> AudioUploadCompleteResponse:
    _require_audio_ready(user)
    fwd = await _route_or_forward(request, md5)
    if fwd is not None:
        return fwd
    if voice_pipeline.txt_path(user.id, md5).exists():
        return AudioUploadCompleteResponse(upload_id=md5, status="done")
    part = voice_pipeline.find_audio(user.id, md5)
    if part is None or part.stat().st_size == 0:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="上传未完成或文件为空")
    if size_bytes > 0 and part.stat().st_size < size_bytes:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"文件不完整（已收 {part.stat().st_size}/{size_bytes} 字节），请继续上传",
        )
    # 打 .ready 标记：定时任务据此识别「已传完，可转写」
    voice_pipeline.ready_marker(part).touch()
    return AudioUploadCompleteResponse(upload_id=md5, status="uploaded")


# ---- 语音服务器定时任务：转写 → 生成场景 → 清理（每台只处理本地文件）----

async def _voice_transcribe_pending() -> None:
    """任务1：把「已传完」音频转写为 {user_id}_{md5}.txt，并删除音频。"""
    from .audio_pipeline import transcribe_file

    for audio in await asyncio.to_thread(voice_pipeline.list_ready_audio):
        user_id, md5, _ = voice_pipeline.parse_audio_name(audio)
        try:
            text = await transcribe_file(audio)
            await asyncio.to_thread(voice_pipeline.txt_path(user_id, md5).write_text, text or "", "utf-8")
            voice_pipeline.ready_marker(audio).unlink(missing_ok=True)
            audio.unlink(missing_ok=True)
        except Exception as exc:  # noqa: BLE001 — 单条失败不影响其它
            print(f"[voice] 转写失败 {audio.name}: {str(exc)[:160]}", flush=True)


async def _voice_generate_pending() -> None:
    """任务2：把 {user_id}_{md5}.txt 内容走与采集相同的大模型流程生成场景，完成后打 .done 标记。"""
    from .audio_pipeline import _text_to_items

    now = datetime.now(timezone.utc)
    for txt in await asyncio.to_thread(voice_pipeline.list_pending_txt):
        user_id, md5, _ = voice_pipeline.parse_audio_name(txt)
        try:
            text = await asyncio.to_thread(txt.read_text, "utf-8")
            items = clean_transcript_items(_text_to_items(text, now))
            if items:
                await _generate_and_save_capture_scenarios(user_id, items)
            voice_pipeline.done_marker(user_id, md5).touch()  # 已生成，待 3 天后清理
        except Exception as exc:  # noqa: BLE001
            print(f"[voice] 场景生成失败 {txt.name}: {str(exc)[:160]}", flush=True)


def _register_self_as_voice_node() -> None:
    """首次启动：若本机配置了 VOICE_NODE_ADDR，自动把本机地址加入管理台「语音文件服务器」列表。
    仅第一次加（用 marker 记录），之后运维可在管理台删除该 ip，重启也不会再自动加回。"""
    addr = voice_pipeline.normalize_addr(settings.voice_node_addr)
    if not addr:
        return
    marker = f"voice_node_registered:{addr}"
    if db.get_app_setting_str(marker):
        return  # 已自动注册过一次 → 尊重运维之后的删除，不再加回
    servers = voice_pipeline.voice_servers()
    if addr not in servers:
        servers.append(addr)
        db.set_app_setting("voice_servers", ";".join(servers))
    db.set_app_setting(marker, "1")
    print(f"[voice] 首次启动：已把本机 {addr} 加入语音文件服务器列表（之后可在管理台删除）", flush=True)


async def _voice_cron_loop() -> None:
    """语音服务器三件定时任务（每台只处理本地 voice_dir）：每小时一轮——转写、生成场景、清理 3 天前文件。"""
    while True:
        try:
            await _voice_transcribe_pending()                       # 任务1：转写
            await _voice_generate_pending()                         # 任务2：生成场景
            await asyncio.to_thread(voice_pipeline.cleanup_old, 3)  # 任务3：清理 3 天前文件
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 — 循环必须不死
            print(f"[voice] 定时任务异常：{str(exc)[:160]}", flush=True)
        await asyncio.sleep(3600)


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


def _summaries_with_last_score(user_id: str, items: list[dict]) -> list[ScenarioSummary]:
    """给场景摘要补上「上一次对练得分」，供场景卡展示历史成绩。"""
    last = db.last_practice_scores(user_id, [it["scene_id"] for it in items])
    out: list[ScenarioSummary] = []
    for it in items:
        info = last.get(it["scene_id"]) or {}
        out.append(ScenarioSummary(
            **it,
            last_score=info.get("score"),
            last_practiced_at=info.get("at"),
            in_progress=bool(info.get("in_progress")),
            resume_session_id=info.get("resume_session_id"),
            resume_progress=int(info.get("resume_progress") or 0),
        ))
    return out


# 各档位「全部场景」可见的历史天数：非会员 2 天、基础会员 2 周、高级会员 1 个月
HISTORY_WINDOW_DAYS = {"free": 2, "basic": 14, "premium": 30}


def history_window_days(tier: str) -> int:
    return HISTORY_WINDOW_DAYS.get(tier, 2)


@app.get("/scenario/list", response_model=ScenarioListResponse)
def scenario_list(
    start: datetime | None = Query(default=None),
    end: datetime | None = Query(default=None),
    limit: int = Query(default=100, ge=1, le=200),
    user: UserOut = Depends(current_user),
) -> ScenarioListResponse:
    # 按会员档位限制可见历史窗口（非会员2天/基础2周/高级1月）
    window_start = datetime.now(timezone.utc) - timedelta(days=history_window_days(user.plan_tier))
    if start is None or start < window_start:
        start = window_start
    items = db.list_scenarios(user.id, start, end, limit=limit)
    return ScenarioListResponse(items=_summaries_with_last_score(user.id, items))


@app.delete("/scenario/{scene_id}")
def scenario_delete(scene_id: str, user: UserOut = Depends(current_user)) -> dict:
    """删除用户自己的场景（预置通用场景不可删）。"""
    if not db.delete_scenario(user.id, scene_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="场景不存在或不可删除")
    return {"ok": True}


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
        items=_summaries_with_last_score(user.id, existing),
        generated=False,
    )


@app.get("/scenario/presets/catalog", response_model=PresetScenarioCatalogResponse)
def scenario_presets_catalog(
    user: UserOut = Depends(current_user),
) -> PresetScenarioCatalogResponse:
    """通用场景目录：运维预置的全局场景，按主场景分组；每个子场景已含完整对话，可直接进入对练。
    同时带上该用户上一次练这场景的得分。"""
    presets = db.list_preset_scenarios()
    last = db.last_practice_scores(user.id, [p["scene_id"] for p in presets])
    grouped: dict[str, list[PresetSceneItem]] = {}
    order: list[str] = []
    for p in presets:
        group = p["group"] or "通用场景"
        if group not in grouped:
            grouped[group] = []
            order.append(group)
        info = last.get(p["scene_id"]) or {}
        grouped[group].append(
            PresetSceneItem(
                scene_id=p["scene_id"],
                title=p["title"],
                line_count=p["line_count"],
                roles=[ScenarioRole(**r) for r in p["roles"]],
                last_score=info.get("score"),
                last_practiced_at=info.get("at"),
            )
        )
    return PresetScenarioCatalogResponse(
        items=[PresetSceneGroup(group=g, scenes=grouped[g]) for g in order]
    )


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

    # 继续上次进度：找该场景+角色最近一个未完成会话，直接回放其历史与进度（不新建、不重复推送 AI 台词）。
    if request.resume:
        existing = db.get_resumable_roleplay_session(user.id, scenario.scene_id, request.selected_role)
        if existing is not None:
            # 继续上次：提前生成"用户说完当前句后 AI 的下一段"语音
            _prewarm_tts(user.id, _ai_line_run(scenario, existing.selected_role, existing.target_index + 1))
            return roleplay_state_response(user.id, existing, scenario)
        # 没有可继续的会话则退化为从头开始（首次进入或上次已完成）。

    # 从头重新开始：作废该场景+角色旧的未完成会话，保证「可继续」只指向这次新建的。
    db.abandon_active_roleplay_sessions(user.id, scenario.scene_id, request.selected_role)
    ai_role = next((role.id for role in scenario.roles if role.id != request.selected_role), request.selected_role)
    session = db.create_roleplay_session(user.id, scenario.scene_id, request.selected_role, ai_role)
    session = push_ai_lines_until_user_turn(user.id, session, scenario)
    db.update_roleplay_session(session)
    # 提前生成：开场 AI 台词 + 用户说完第一句后 AI 的下一段
    _prewarm_tts(
        user.id,
        _ai_line_run(scenario, session.selected_role, 0)
        + _ai_line_run(scenario, session.selected_role, session.target_index + 1),
    )
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
        review = format_final_roleplay_review(session, db.list_roleplay_messages(user.id, session.session_id))
        return roleplay_state_response(user.id, session, scenario, latest_feedback=review)

    target_line = next_user_line(session, scenario)
    if target_line is None:
        session.status = "completed"
        db.update_roleplay_session(session)
        review = format_final_roleplay_review(session, db.list_roleplay_messages(user.id, session.session_id))
        return roleplay_state_response(user.id, session, scenario, latest_feedback=review)

    evaluation = await evaluate_roleplay_turn(
        request.message.strip(),
        target_line,
        scenario,
        db.list_roleplay_messages(user.id, session.session_id),
        user_id=user.id,
    )
    score = evaluation.score
    final_guidance = request.guidance_mode == "final"
    # 更宽松、更看重「意思是否表达到位」：模型判定通过(意思对)即通过；
    # 或字符相似度达阈值(近乎原句)也通过。不再要求逐字/标点完全一致。
    accept_score = db.get_roleplay_accept_score()
    accepted = True if final_guidance else (evaluation.accepted or score >= accept_score)
    had_rejected_attempt = db.has_rejected_practice_attempt(
        user.id,
        session.session_id,
        target_line.index,
        accept_score,
    )
    feedback = "" if final_guidance else format_roleplay_feedback(
        evaluation.feedback,
        evaluation.correction,
        accepted,
        had_rejected_attempt,
    )
    stored_feedback = feedback or evaluation.feedback.strip() or ""
    # 实时指导：只有说对了（accepted）才把用户这句计入字幕；说错的不进字幕，
    # 仅在指导区给出中文纠正、让用户重新尝试。事后指导 accepted 恒为真，所以照常进字幕并继续。
    if accepted:
        db.add_roleplay_message(
            user.id,
            session.session_id,
            speaker="user",
            role=session.selected_role,
            # 字幕显示「用户实际想表达」的整理版英文（去口头语/重复后），而非场景正确答案；
            # 正确答案只在指导区(correction/feedback)展示。中文仍用本句意图(场景原句)。
            content=(evaluation.user_said or request.message).strip() or target_line.english,
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
        # 提前生成：本轮刚推送的 AI 台词 + 用户下一句之后 AI 的下一段（下次取用即命中）
        _prewarm_tts(
            user.id,
            _ai_line_run(scenario, session.selected_role, target_line.index + 1)
            + _ai_line_run(scenario, session.selected_role, session.target_index + 1),
        )
    db.update_roleplay_session(session)
    latest_feedback = feedback or None
    # 对话完成时无论实时/事后指导都给出最终评分与建议（本地计算、无额外模型调用）
    if session.status == "completed":
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


@app.post("/roleplay/message/audio", response_model=RoleplayStateResponse)
async def roleplay_message_audio(
    session_id: str = Query(...),
    guidance_mode: str = Query(default="realtime"),
    file: UploadFile = File(...),
    user: UserOut = Depends(current_user),
) -> RoleplayStateResponse:
    """方式1/2 后端语音：上传一句录音 → ASR（参考句偏置容错）→ 复用文字评分 → 词级发音纠正。
    操作步骤与文字版完全一致，只是把端侧识别换成后端识别。"""
    require_ai_access(user)
    _enforce_user_rate(user.id, "rp_audio", settings.audio_user_rate_per_min)
    session = db.get_roleplay_session(user.id, session_id)
    if session is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="场景练习不存在")
    scenario = db.get_scenario(user.id, session.scene_id)
    if scenario is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="场景不存在")
    target_line = next_user_line(session, scenario)
    reference = target_line.english if target_line else None
    suffix = os.path.splitext(file.filename or "")[1].lower() or ".m4a"
    audio = await file.read()
    if not audio:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="录音为空")
    try:
        recognized = (await voice_io.transcribe(audio, suffix=suffix, reference_text=reference)).strip()
    except Exception as exc:  # noqa: BLE001 — ASR 故障(如本地模型未就绪)返回可读 503，不要 500
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"语音识别暂时不可用：{str(exc)[-160:]}",
        ) from exc
    if not recognized:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="没听清，请再说一次")
    gm = "final" if guidance_mode == "final" else "realtime"
    resp = await roleplay_message(
        RoleplayMessageRequest(session_id=session_id, message=recognized[:2000], guidance_mode=gm),
        user,
    )
    resp.recognized_text = recognized
    if reference:
        resp.pronunciation = [PronunciationWord(**w) for w in voice_io.pronunciation_diff(recognized, reference)]
    return resp


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


@app.websocket("/roleplay/stream")
async def roleplay_stream(
    websocket: WebSocket,
    token: str = Query(...),
    session_id: str = Query(...),
) -> None:
    """方式2 沉浸式后端语音：客户端流式上传音频帧 + 客户端 VAD 在一句结束时发 commit；
    后端转写(参考句偏置)→复用文字评分→把推进的 AI 台词流式 TTS 推回；客户端抢话发 interrupt 即停 AI 朗读。
    操作步骤与原沉浸式一致，只是识别/朗读搬到后端，并支持抢话打断。"""
    await websocket.accept()
    try:
        user = _authenticate_token(token)
        require_ai_access(user, estimated_cents=0.0)
    except HTTPException as exc:
        await websocket.close(code=4401, reason=_ws_reason(exc.detail))
        return
    session = db.get_roleplay_session(user.id, session_id)
    scenario = db.get_scenario(user.id, session.scene_id) if session else None
    if session is None or scenario is None:
        await websocket.close(code=4404, reason=_ws_reason("场景练习不存在"))
        return

    voice = db.get_user_tts_voice(user.id) or voice_io.default_voice()
    send_lock = asyncio.Lock()          # 串行化发送，避免「朗读音频帧」与「结果 JSON」并发写 WS 冲突
    utterance = bytearray()
    spoken_count = 0
    tts_task: asyncio.Task | None = None

    async def _sj(obj: dict) -> None:
        async with send_lock:
            await websocket.send_json(obj)

    async def _sb(data: bytes) -> None:
        async with send_lock:
            await websocket.send_bytes(data)

    async def _send_tts(text: str) -> None:
        try:
            # 先查 Redis（多半已被 roleplay_start/roleplay_message 的「提前生成」预热过）→ 命中秒回；
            # 未命中则现合成并写回缓存，再推流给 App。下一段在每轮 roleplay_message 里已提前生成。
            audio, ct = await voice_io.synthesize(text, voice, use_cache=True)
        except Exception as exc:  # noqa: BLE001 — TTS 失败不致命：客户端仍能看文字
            await _sj({"type": "ai_audio_error", "detail": str(exc)[:120]})
            return
        await _sj({"type": "ai_audio_begin", "content_type": ct})
        for i in range(0, len(audio), 16384):
            await _sb(audio[i:i + 16384])
        await _sj({"type": "ai_audio_end"})

    async def _speak_new(messages) -> None:
        nonlocal spoken_count
        for msg in messages[spoken_count:]:
            if getattr(msg, "speaker", "") == "ai":
                await _sj({"type": "ai_line", "role": msg.role, "text": msg.content, "translation": msg.translation})
                await _send_tts(msg.content)
        spoken_count = len(messages)

    def _cancel_tts() -> None:
        nonlocal tts_task
        if tts_task and not tts_task.done():
            tts_task.cancel()
        tts_task = None

    # 开场/重连：回完整状态（客户端据此恢复字幕/进度/评分），并只朗读「当前待回应的那段 AI 台词」。
    # 把已朗读游标设到「最后一条用户消息之后」：首次进入=朗读开场 AI 台词；断线重连=只补当前待回应这句，
    # 既不会把整段历史重念一遍，又能把断线时漏掉的那句语音补给客户端。
    state0 = roleplay_state_response(user.id, session, scenario)
    for _i, _m in enumerate(state0.messages):
        if getattr(_m, "speaker", "") == "user":
            spoken_count = _i + 1
    await _sj({
        "type": "state",
        "next_line": state0.next_line.english if state0.next_line else None,
        "completed": state0.completed,
        "state": state0.model_dump(mode="json"),
    })
    tts_task = asyncio.create_task(_speak_new(state0.messages))

    try:
        while True:
            event = await websocket.receive()
            if event.get("type") == "websocket.disconnect":
                break
            if event.get("bytes") is not None:
                utterance.extend(event["bytes"])
                continue
            text = event.get("text")
            if not text:
                continue
            try:
                data = _json.loads(text)
            except (ValueError, TypeError):
                continue
            mtype = data.get("type")
            if mtype == "interrupt":          # 抢话：用户开始说话 → 立刻停 AI 朗读
                _cancel_tts()
                continue
            if mtype == "bye":
                break
            if mtype != "commit":
                continue
            # 一句话结束：拿累计音频去识别+评分
            _cancel_tts()
            audio = bytes(utterance)
            utterance.clear()
            if not audio:
                continue
            session = db.get_roleplay_session(user.id, session_id)
            if session is None:
                break
            target = next_user_line(session, scenario)
            reference = target.english if target else None
            try:
                recognized = (await voice_io.transcribe(
                    audio, suffix=data.get("format", ".m4a"), reference_text=reference
                )).strip()
            except Exception as exc:  # noqa: BLE001
                await _sj({"type": "error", "detail": f"识别失败：{str(exc)[-200:]}"})
                continue
            if not recognized:
                await _sj({"type": "result", "accepted": False, "recognized_text": "",
                           "feedback": "没听清，请再说一次", "pronunciation": []})
                continue
            gm = "final" if data.get("guidance_mode") == "final" else "realtime"
            resp = await roleplay_message(
                RoleplayMessageRequest(session_id=session_id, message=recognized[:2000], guidance_mode=gm),
                user,
            )
            resp.recognized_text = recognized
            if reference:
                resp.pronunciation = [PronunciationWord(**w) for w in voice_io.pronunciation_diff(recognized, reference)]
            # 整轮完整状态回客户端：客户端据此直接刷新字幕/进度/评分（与 HTTP 回合同构）
            await _sj({"type": "result", "state": resp.model_dump(mode="json")})
            tts_task = asyncio.create_task(_speak_new(resp.messages))
            if resp.completed:
                await _sj({"type": "completed"})
    except WebSocketDisconnect:
        pass
    except Exception as exc:  # noqa: BLE001 — 任一异常结束会话
        try:
            await _sj({"type": "error", "detail": str(exc)[:160]})
        except Exception:  # noqa: BLE001
            pass
    finally:
        _cancel_tts()
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
    cfg = payments.resolve_payment_config()   # 单一来源：收款码/收款账号只读 DB
    if method == "wechat":
        return {
            "title": "微信",
            "payment_url": cfg["wechat_pay_url"],
            "qr_code_text": cfg["wechat_pay_url"],
            "receiver_account": cfg["wechat_receiver_account"],
        }
    if method == "alipay":
        return {
            "title": "支付宝",
            "payment_url": cfg["alipay_pay_url"],
            "qr_code_text": cfg["alipay_pay_url"],
            "receiver_account": cfg["alipay_receiver_account"],
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

    wx = db.resolve_wechat_login_config()   # 单一来源：只读 DB
    if request.client == "web":
        app_id, app_secret = wx["web_app_id"], wx["web_app_secret"]
    else:
        app_id, app_secret = wx["app_id"], wx["app_secret"]
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


def _ai_line_run(scenario: ScenarioResponse, selected_role: str, start: int) -> list[str]:
    """从 start 起一整段连续 AI 台词的英文（遇到用户角色的台词或结尾即止）= 一次"轮到 AI 说"的内容。"""
    out: list[str] = []
    i = start
    while 0 <= i < len(scenario.lines):
        line = scenario.lines[i]
        if line.target_role == selected_role:
            break
        if line.english and line.english.strip():
            out.append(line.english)
        i += 1
    return out


def _prewarm_tts(user_id: str, texts: list[str]) -> None:
    """后台异步把这些 AI 台词提前合成进 Redis（提前生成下一句语音）。失败不影响主流程。

    用用户当前选定音色合成，与 /tts/speak 取用时的缓存键一致 → 取用即命中、秒回。
    """
    texts = [t for t in dict.fromkeys(t for t in texts if t and t.strip())]  # 去重保序
    if not texts:
        return
    voice = db.get_user_tts_voice(user_id) or voice_io.default_voice()

    async def _run() -> None:
        for t in texts:
            try:
                await voice_io.synthesize(t, voice, use_cache=True)
            except Exception:  # noqa: BLE001 — 预热失败静默
                pass

    try:
        asyncio.get_running_loop().create_task(_run())
    except RuntimeError:  # 无运行中的事件循环（理论上不会）
        pass


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
        # 说对了：不回头展示上一句的参考，直接推进到下一句的「请用英文说」提示。
        # (要不要在开口前看到参考英文，由客户端「参考提示」开关控制；说错了才纠正。)
        return ""
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

    def _is_positive_ack(text: str) -> bool:
        # 正向确认（说对了）不是「待改进点」，不应进入「优先改」清单
        t = text.strip()
        # 包含纠正/改进关键词的是真正的反馈，不算纯正向确认
        correction_signals = ("但", "注意", "建议", "改成", "应该是", "试试", "可以更",
                              "but", "however", "try", "instead", "better", "suggest",
                              "consider", "注意", "改进", "更自然")
        has_correction = any(sig in t.lower() for sig in correction_signals)
        if has_correction:
            return False
        # 纯正向确认模式（中/英文）
        positive_starts = ("正确", "回答正确", "很好", "非常好", "不错", "说得好",
                           "good", "great", "nice", "well done", "perfect", "excellent")
        positive_contains = ("已继续", "继续保持")
        return t.startswith(positive_starts) or any(p in t for p in positive_contains)

    # 结束后一次性汇总【全部】待改进点（不再截断到 3 条），逐句去重保序
    weak_points = list(dict.fromkeys(
        fb
        for message in user_messages
        if (fb := getattr(message, "feedback", "") or "") and not _is_positive_ack(fb)
    ))
    if not weak_points:
        return f"最终评分 {score}/100。整体表达能完成交流，接下来重点练自然停顿和更口语的连接词。"
    joined = "\n".join(f"- {point}" for point in weak_points)
    return f"最终评分 {score}/100。本轮共 {len(weak_points)} 处可改进：\n{joined}"


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
