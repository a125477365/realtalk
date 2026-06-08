from __future__ import annotations

import asyncio
import hashlib
import hmac
import html
from datetime import datetime, timedelta, timezone
from difflib import SequenceMatcher

import httpx
from fastapi import Depends, FastAPI, HTTPException, Query, status
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBasic, HTTPBasicCredentials, HTTPBearer

from .ark_client import evaluate_roleplay_turn, generate_ai_chat_reply, generate_learning, generate_scenario
from .auth import create_admin_session, create_token, destroy_admin_session, hash_password, make_email_code, normalize_email, send_email_code, verify_password, verify_admin_session, verify_token
from .billing import apple_billing
from .content_policy import is_political_sensitive
from .schemas import (
    AdminPriceUpdateRequest,
    AdminUserUpdateRequest,
    ApplePurchaseVerifyRequest,
    AuthRequest,
    AuthResponse,
    AIChatRequest,
    AIChatResponse,
    BillingAccountResponse,
    BillingResponse,
    EmailCodeRequest,
    EmailCodeResponse,
    EmailRegisterRequest,
    LearningGenerateRequest,
    LearningResponse,
    PracticeHistoryResponse,
    PriceResponse,
    RechargeConfirmRequest,
    RechargeCreateRequest,
    RechargeOrderResponse,
    RoleplayMessageRequest,
    RoleplaySessionRecord,
    RoleplayStartRequest,
    RoleplayStateResponse,
    ScenarioGenerateRequest,
    ScenarioResponse,
    SceneLine,
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
import secrets as _secrets
from .storage import DatabaseIntegrityError, clean_transcript_items, db

app = FastAPI(title="RealTalk API", version="1.0.0")
security = HTTPBearer(auto_error=False)
admin_security = HTTPBasic(auto_error=False)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def startup() -> None:
    db.cleanup_expired()
    asyncio.create_task(_cleanup_loop())


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


async def current_admin(request: Request, credentials: HTTPBasicCredentials | None = Depends(admin_security)) -> str:
    session_token = request.cookies.get("admin_session")
    if session_token:
        username = verify_admin_session(session_token)
        if username:
            return username
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        token = auth.split(" ", 1)[1].strip()
        payload_b64, signature = token.split(".", 1)
        if hmac.compare_digest(_sign(payload_b64), signature):
            payload = json.loads(_unb64(payload_b64))
            if int(payload.get("exp", 0)) >= int(time.time()):
                if payload.get("role") == "admin":
                    return payload.get("sub", "admin")
    if credentials is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="需要管理员登录")
    username_ok = hmac.compare_digest(credentials.username, settings.admin_username)
    password_ok = hmac.compare_digest(credentials.password, settings.admin_password)
    if not username_ok or not password_ok:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="管理员账号或密码错误")
    return credentials.username


def _admin_login_page(bad_session: bool = False) -> str:
    err = "<p style='color:#ff3b30'>Session 已过期，请重新登录</p>" if bad_session else ""
    return (
        "<!doctype html><html><head><meta charset='utf-8'/><title>RealTalk 管理台 - 登录</title>"
        "<style>"
        "body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;background:#f5f5f7;color:#1d1d1f;margin:0;padding:24px}"
        ".container{max-width:420px;margin:80px auto;background:#fff;border-radius:18px;padding:32px;box-shadow:0 1px 2px rgba(0,0,0,0.06)}"
        "h1{font-size:20px;margin:0 0 18px}input{display:block;width:100%;padding:10px;margin:8px 0;border:1px solid #d1d1d6;border-radius:12px;font:inherit}"
        "button{width:100%;padding:11px;border:0;border-radius:12px;background:#0071e3;color:#fff;font-weight:600;cursor:pointer}"
        "a{color:#0071e3;text-decoration:none}small{color:#86868b}"
        "</style></head><body><div class='container'><h1>RealTalk 管理台</h1>"
        + err +
        "<form method='post' action='/admin/login' autocomplete='off'>"
        "<input name='username' placeholder='用户名' autofocus/>"
        "<input name='password' type='password' placeholder='密码'/>"
        "<button type='submit'>登 录</button></form>"
        "<p style='text-align:center;margin-top:18px'><small>默认账号：admin / admin123456</small></p>"
        "<p style='text-align:center;margin-top:8px'><a href='/'>返回首页</a></p>"
        "</div></body></html>"
    )


    def _admin_logged_in_page() -> str:
        return (
            "<!doctype html><html><head><meta charset='utf-8'/><title>RealTalk 管理台</title>"
            "<style>"
            "body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;background:#f5f5f7;color:#1d1d1f;margin:0;padding:24px}"
            ".container{max-width:960px;margin:0 auto}header{display:flex;align-items:center;justify-content:space-between;margin-bottom:24px}"
            "h1{font-size:22px;margin:0}.badge{font-size:12px;padding:4px 10px;border-radius:999px;background:#e5e5ea;color:#555}"
            ".card{background:#fff;border-radius:14px;padding:18px 20px;box-shadow:0 1px 2px rgba(0,0,0,0.04);margin-bottom:16px}"
            "a{color:#0071e3}button{padding:7px 12px;border:0;border-radius:10px;background:#ff3b30;color:#fff;cursor:pointer}"
            "</style></head><body><div class='container'><header><h1>RealTalk 管理台</h1><span class='badge'>已登录</span></header>"
            "<form method='post' action='/admin/logout' style='display:inline'><button type='submit'>退出登录</button></form>"
            "<div class='card'><h2>数据概览</h2><p>请从下方接口获取实时数据：</p><ul>"
            "<li><a href='/admin/api/overview' target='_blank'>/admin/api/overview</a></li>"
            "<li><a href='/admin/api/users' target='_blank'>/admin/api/users</a></li>"
            "</ul></div>"
            "<div class='card'><h2>健康检查</h2><ul>"
            "<li><a href='/health' target='_blank'>/health</a></li>"
            "<li><a href='/ready' target='_blank'>/ready</a></li>"
            "</ul></div></div></body></html>"
        )


    def admin_html(*, bad_session: bool = False) -> str:
        return _admin_login_page(bad_session=bad_session)


    def admin_logged_in_html() -> str:
        return _admin_logged_in_page()
    <style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;background:#f5f5f7;color:#1d1d1f;margin:0;padding:24px}.container{max-width:960px;margin:0 auto}header{display:flex;align-items:center;justify-content:space-between;margin-bottom:24px}h1{font-size:22px;margin:0}.badge{font-size:12px;padding:4px 10px;border-radius:999px;background:#e5e5ea;color:#555}.card{background:#fff;border-radius:14px;padding:18px 20px;box-shadow:0 1px 2px rgba(0,0,0,0.04);margin-bottom:16px}a{color:#0071e3}</style></head><body><div class="container"><header><h1>RealTalk 管理台</h1><span class="badge">local</span></header><div class="card"><h2>数据概览</h2><p>请从上方 API 接口获取实时数据：</p><ul><li><a href="/admin/api/overview" target="_blank">/admin/api/overview</a></li><li><a href="/admin/api/users" target="_blank">/admin/api/users</a></li></ul></div><div class="card"><h2>健康检查</h2><ul><li><a href="/health" target="_blank">/health</a></li><li><a href="/ready" target="_blank">/ready</a></li></ul></div></div></body></html>"""

@app.post("/admin/login")
async def admin_login(request: Request, response: Response) -> Response:
    form = await request.form()
    username = form.get("username", "")
    password = form.get("password", "")
    username_ok = hmac.compare_digest(username, settings.admin_username)
    password_ok = hmac.compare_digest(password, settings.admin_password)
    if not username_ok or not password_ok:
        return HTMLResponse(
            "<h1>管理员登录</h1><p style='color:#ff3b30'>账号或密码错误</p><a href='/admin'>返回</a>",
            status_code=401,
        )
    token = create_admin_session(username)
    response = RedirectResponse("/admin", status_code=303)
    secure = ";" if request.url.scheme != "https" else "; Secure"
    response.set_cookie(
        key="admin_session",
        value=token,
        httponly=True,
        max_age=60 * 60 * 24 * 7,
        path="/admin",
        samesite="lax",
    )
    return response


@app.post("/admin/logout")
async def admin_logout(response: Response) -> Response:
    response.delete_cookie(key="admin_session", path="/admin")
    return RedirectResponse("/admin", status_code=303)

def _session_store():
    if not hasattr(_session_store, "_data"):
        _session_store._data = {}
        _session_store._next = int(time.time())
    return _session_store._data


def _new_session_id() -> str:
    store = _session_store()
    ts = _new_session_id._next
    _new_session_id._next = ts + 1
    return f"{ts:012x}"


async def _current_admin(request: Request) -> str:
    session_id = request.cookies.get("admin_session")
    if not session_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="需要管理员登录")
    username = _session_store().get(session_id)
    if not username:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="需要管理员登录")
    return username


def _admin_login_page() -> str:
    return (
        "<!doctype html><html><head><meta charset='utf-8'/><title>RealTalk 管理台 - 登录</title>"
        "<style>"
        "body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;background:#f5f5f7;color:#1d1d1f;margin:0;padding:24px}"
        ".box{max-width:420px;margin:80px auto;background:#fff;border-radius:18px;padding:32px;box-shadow:0 1px 2px rgba(0,0,0,0.06)}"
        "h1{font-size:20px;margin:0 0 18px}"
        "input{display:block;width:100%;padding:10px;margin:8px 0;border:1px solid #d1d1d6;border-radius:12px;font:inherit}"
        "button{width:100%;padding:11px;border:0;border-radius:12px;background:#0071e3;color:#fff;font-weight:600;cursor:pointer}"
        "small{color:#86868b}"
        "</style></head><body><div class='box'><h1>RealTalk 管理台</h1>"
        "<form method='post' action='/admin/login' autocomplete='off'>"
        "<input name='username' placeholder='用户名' autofocus/>"
        "<input name='password' type='password' placeholder='密码'/>"
        "<button type='submit'>登 录</button></form>"
        "<p style='text-align:center;margin-top:18px'><small>默认账号：admin / admin123456</small></p>"
        "<p style='text-align:center;margin-top:8px'><a href='/'>返回首页</a></p>"
        "</div></body></html>"
    )


def _admin_dashboard_html() -> str:
    return (
        "<!doctype html><html><head><meta charset='utf-8'/><title>RealTalk 管理台</title>"
        "<style>"
        "body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;background:#f5f5f7;color:#1d1d1f;margin:0;padding:24px}"
        ".container{max-width:960px;margin:0 auto}header{display:flex;align-items:center;justify-content:space-between;margin-bottom:24px}"
        "h1{font-size:22px;margin:0}.badge{font-size:12px;padding:4px 10px;border-radius:999px;background:#e5e5ea;color:#555}"
        ".card{background:#fff;border-radius:14px;padding:18px 20px;box-shadow:0 1px 2px rgba(0,0,0,0.04);margin-bottom:16px}"
        "a{color:#0071e3}button{padding:7px 12px;border:0;border-radius:10px;background:#ff3b30;color:#fff;cursor:pointer}"
        "</style></head><body><div class='container'><header><h1>RealTalk 管理台</h1><span class='badge'>已登录</span></header>"
        "<form method='post' action='/admin/logout' style='display:inline'><button type='submit'>退出登录</button></form>"
        "<div class='card'><h2>数据概览</h2><p>请从下方接口获取实时数据：</p><ul>"
        "<li><a href='/admin/api/overview' target='_blank'>/admin/api/overview</a></li>"
        "<li><a href='/admin/api/users' target='_blank'>/admin/api/users</a></li>"
        "</ul></div>"
        "<div class='card'><h2>健康检查</h2><ul>"
        "<li><a href='/health' target='_blank'>/health</a></li>"
        "<li><a href='/ready' target='_blank'>/ready</a></li>"
        "</ul></div></div></body></html>"
    )


@app.get("/admin", response_class=HTMLResponse)
async def admin_console(request: Request) -> HTMLResponse:
    try:
        await _current_admin(request)
        return HTMLResponse(_admin_dashboard_html())
    except HTTPException:
        return HTMLResponse(_admin_login_page())


@app.post("/admin/login")
async def admin_login(request: Request, response: Response) -> Response:
    form = await request.form()
    username = form.get("username", "")
    password = form.get("password", "")
    username_ok = hmac.compare_digest(username, settings.admin_username)
    password_ok = hmac.compare_digest(password, settings.admin_password)
    if not username_ok or not password_ok:
        return HTMLResponse(
            "<h1>管理员登录</h1><p style='color:#ff3b30'>账号或密码错误</p><a href='/admin'>返回</a>",
            status_code=401,
        )
    session_id = _new_session_id()
    _session_store()[session_id] = username
    redirect = RedirectResponse("/admin", status_code=303)
    redirect.set_cookie(
        key="admin_session",
        value=session_id,
        httponly=True,
        max_age=60 * 60 * 24 * 7,
        path="/admin",
        samesite="lax",
    )
    return redirect


@app.post("/admin/logout")
async def admin_logout(response: Response, request: Request) -> Response:
    session_id = request.cookies.get("admin_session")
    if session_id:
        _session_store().pop(session_id, None)
    redirect = RedirectResponse("/admin", status_code=303)
    redirect.delete_cookie(key="admin_session", path="/admin")
    return redirect

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


@app.get("/admin", response_class=HTMLResponse)
async def admin_console(request: Request) -> HTMLResponse:
    try:
        _ = await current_admin(request)
        return HTMLResponse(admin_logged_in_html())
    except HTTPException:
        if request.cookies.get("admin_session"):
            return HTMLResponse(admin_html(bad_session=True))
        return HTMLResponse(admin_html())


@app.get("/admin/api/overview")
async def admin_overview(_: str = Depends(_current_admin)) -> dict:
    return db.admin_overview()


@app.get("/admin/api/users")
async def admin_users(
    q: str | None = Query(default=None, max_length=120),
    limit: int = Query(default=100, ge=1, le=500),
    _: str = Depends(_current_admin),
) -> dict:
    return {"items": db.admin_list_users(limit=limit, query=q)}


@app.get("/admin/api/users/{user_id}")
async def admin_user_detail(user_id: str, _: str = Depends(_current_admin)) -> dict:
    detail = db.admin_get_user_detail(user_id)
    if detail is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="用户不存在")
    return detail


@app.patch("/admin/api/users/{user_id}")
async def admin_update_user(
    user_id: str,
    request: AdminUserUpdateRequest,
    _: str = Depends(_current_admin),
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
    _: str = Depends(current_admin),
) -> PriceResponse:
    db.set_app_setting("monthly_price_cents", str(request.monthly_price_cents))
    return await billing_prices()


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
    user: UserOut = Depends(current_user),
) -> RechargeOrderResponse:
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
    order.message = f"请使用{method_settings['title']}向收款账号支付 {money_text(request.amount_cents)}，付款备注订单号。"
    return order


@app.post("/billing/recharge/confirm", response_model=BillingAccountResponse)
async def confirm_recharge(
    request: RechargeConfirmRequest,
    user: UserOut = Depends(current_user),
) -> BillingAccountResponse:
    if not settings.payment_dev_auto_confirm:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="生产环境请通过微信/支付宝支付回调确认到账")
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
        correction = f"参考答案：{current.answer}"

    if session.index >= len(session.items):
        session.status = "completed"
        feedback = f"训练完成，得分 {session.score}/{len(session.items)}。"

    db.update_session(session)
    return state_response(session, feedback=feedback, correction=correction)


def require_ai_access(user: UserOut) -> None:
    if settings.require_pro_for_ai and user.plan != "pro":
        raise HTTPException(status_code=status.HTTP_402_PAYMENT_REQUIRED, detail="请订阅 RealTalk Pro 后使用 AI 学习和训练")


def email_code_hash(email: str, code: str) -> str:
    payload = f"{email}:{code}:{settings.jwt_secret}".encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


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
    return f"¥{amount_cents / 100:.2f}"


async def resolve_wechat_profile(request: WeChatLoginRequest) -> dict[str, str | None]:
    if settings.wechat_auth_dev_mode:
        digest = hashlib.sha256(request.code.encode("utf-8")).hexdigest()[:24]
        return {
            "openid": f"dev-{digest}",
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
    return f"先按参考句练熟：{expected}"


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
    feedback = f"{prefix}{feedback}"
    if correction and correction not in feedback:
        return f"{feedback}\n更自然：{correction}"
    return feedback


async def _cleanup_loop() -> None:
    while True:
        await asyncio.sleep(60 * 60)
        db.cleanup_expired()

def _sign(payload_b64: str) -> str:
    import hashlib
    import base64
    digest = hashlib.new(
        "sha256",
        settings.jwt_secret.encode("utf-8") + payload_b64.encode("utf-8"),
    ).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")

def _unb64(data: str) -> bytes:
    import base64
    padding = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + padding)
