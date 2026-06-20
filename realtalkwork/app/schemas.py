from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class UserOut(BaseModel):
    id: str
    login_identifier: str
    display_name: str | None = None
    avatar_url: str | None = None
    plan: str
    plan_tier: str = "free"  # 生效套餐：free / basic / premium（按到期时间折算）
    plan_expires_at: datetime | None = None
    balance_cents: int = 0
    is_banned: bool = False
    admin_notes: str | None = None
    last_seen_at: datetime | None = None
    created_at: datetime


class AuthRequest(BaseModel):
    email: str = Field(min_length=5, max_length=120, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    password: str = Field(min_length=6, max_length=128)


class EmailCodeRequest(BaseModel):
    email: str = Field(min_length=5, max_length=120, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class EmailCodeResponse(BaseModel):
    sent: bool
    expires_in_seconds: int
    dev_code: str | None = None  # Only set when email_dev_mode=True


class EmailRegisterRequest(AuthRequest):
    code: str = Field(min_length=4, max_length=12)


class AuthResponse(BaseModel):
    token: str  # access token（短效，过期用 refresh_token 续）
    refresh_token: str | None = None
    user: UserOut


class WeChatLoginRequest(BaseModel):
    code: str = Field(min_length=1, max_length=512)
    nickname: str | None = Field(default=None, max_length=80)
    avatar_url: str | None = Field(default=None, max_length=1000)
    client: Literal["app", "web"] = "app"  # 网站应用与移动应用是两套微信凭据
    # 设备唯一安全编号：用于「同一账号同一时间只允许一台设备登录」。新设备登录会顶掉旧设备。
    device_id: str | None = Field(default=None, max_length=128)


class TranscriptItem(BaseModel):
    id: str
    timestamp: datetime
    text: str = Field(min_length=1, max_length=4000)


class AIChatMessage(BaseModel):
    role: Literal["user", "assistant", "system"]
    content: str = Field(min_length=1, max_length=4000)


class AIChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=4000)
    messages: list[AIChatMessage] = Field(default_factory=list, max_length=30)
    scene_id: str | None = None
    session_id: str | None = None


class AIChatResponse(BaseModel):
    reply: str


class TranscriptUploadRequest(BaseModel):
    items: list[TranscriptItem]


class TranscriptUploadResponse(BaseModel):
    uploaded: int
    retention_days: int
    generated: int = 0
    scenario_ids: list[str] = Field(default_factory=list)


class CaptureUploadInitRequest(BaseModel):
    start: datetime | None = None
    end: datetime | None = None
    estimated_items: int = Field(default=0, ge=0, le=200000)


class CaptureUploadInitResponse(BaseModel):
    upload_id: str
    received_chunks: list[int] = Field(default_factory=list)
    max_items_per_chunk: int = 80


class CaptureUploadChunkRequest(BaseModel):
    upload_id: str = Field(min_length=1, max_length=120)
    chunk_index: int = Field(ge=0, le=100000)
    items: list[TranscriptItem] = Field(default_factory=list, max_length=200)


class CaptureUploadChunkResponse(BaseModel):
    upload_id: str
    chunk_index: int
    accepted_items: int
    received_chunks: list[int]


class CaptureUploadCompleteRequest(BaseModel):
    upload_id: str = Field(min_length=1, max_length=120)
    start: datetime | None = None
    end: datetime | None = None


class TranscriptQueryResponse(BaseModel):
    items: list[TranscriptItem]


class LearningGenerateRequest(BaseModel):
    start: datetime
    end: datetime
    items: list[TranscriptItem] = Field(default_factory=list)


class DialogueLine(BaseModel):
    role: str
    zh: str
    en: str


class ExpressionCard(BaseModel):
    phrase: str
    meaning: str
    example: str


class DrillPrompt(BaseModel):
    prompt: str
    answer: str


class LearningResponse(BaseModel):
    summary: str
    dialogue: list[DialogueLine]
    expressions: list[ExpressionCard]
    drills: list[DrillPrompt]


class TrainingStartRequest(BaseModel):
    start: datetime
    end: datetime
    items: list[TranscriptItem] = Field(default_factory=list)


class TrainingAnswerRequest(BaseModel):
    session_id: str
    answer: str = Field(min_length=1, max_length=2000)


class TrainingStateResponse(BaseModel):
    session_id: str
    prompt: str
    expected_answer: str
    index: int
    total: int
    completed: bool
    feedback: str | None = None
    correction: str | None = None


class ScenarioRole(BaseModel):
    id: str
    name: str
    description: str
    is_user_candidate: bool = True


class SceneLine(BaseModel):
    index: int
    speaker: str
    target_role: str
    source_text: str
    english: str
    intent: str


class ScenarioGenerateRequest(BaseModel):
    start: datetime
    end: datetime
    items: list[TranscriptItem] = Field(default_factory=list)


class ScenarioResponse(BaseModel):
    scene_id: str
    title: str
    summary: str
    roles: list[ScenarioRole]
    lines: list[SceneLine]
    expressions: list[ExpressionCard] = Field(default_factory=list)


class CaptureUploadCompleteResponse(BaseModel):
    accepted_items: int
    generated: int
    scenario_ids: list[str]
    scenarios: list[ScenarioResponse] = Field(default_factory=list)


class RoleplayStartRequest(BaseModel):
    start: datetime
    end: datetime
    selected_role: str
    scene_id: str | None = None
    items: list[TranscriptItem] = Field(default_factory=list)


class RoleplayMessageRequest(BaseModel):
    session_id: str
    message: str = Field(min_length=1, max_length=2000)
    guidance_mode: Literal["realtime", "final"] = "realtime"


class RoleplayEvaluateRequest(BaseModel):
    """按需触发最终评估（用户中途退出也能拿到评分与建议）。"""
    session_id: str


class RoleplayEvaluation(BaseModel):
    score: float = Field(ge=0, le=1)
    feedback: str
    correction: str
    accepted: bool = True


class RoleplayMessageOut(BaseModel):
    id: str
    speaker: Literal["user", "ai"]
    role: str
    content: str
    translation: str | None = None
    feedback: str | None = None
    created_at: datetime


class RoleplayStateResponse(BaseModel):
    session_id: str
    scenario: ScenarioResponse
    selected_role: str
    ai_role: str
    next_line: SceneLine | None = None
    progress: int
    total: int
    score: float
    completed: bool
    messages: list[RoleplayMessageOut]
    latest_feedback: str | None = None
    latest_accepted: bool | None = None


class PracticeHistoryItem(BaseModel):
    session_id: str
    scene_id: str
    title: str
    selected_role: str
    status: str
    turns: int
    total: int
    score: float
    created_at: datetime
    updated_at: datetime


class PracticeHistoryResponse(BaseModel):
    items: list[PracticeHistoryItem]


class ApplePurchaseVerifyRequest(BaseModel):
    product_id: str
    transaction_id: str
    original_transaction_id: str
    jws_representation: str | None = None


class BillingResponse(BaseModel):
    user: UserOut
    verified: bool
    message: str


class BillingLedgerItem(BaseModel):
    id: str
    type: str
    title: str
    amount_cents: int
    balance_after_cents: int
    created_at: datetime


class TokenUsageInfo(BaseModel):
    today_tokens: int
    daily_limit: int
    remaining_tokens: int
    over_limit: bool
    # 月度费用额度（会员月费的 50%）。over_limit 现以「当月费用是否超额」为准。
    month_cost_cents: float = 0.0
    month_budget_cents: float = 0.0
    month_remaining_cents: float = 0.0
    over_budget: bool = False


class BillingAccountResponse(BaseModel):
    user: UserOut
    ledger: list[BillingLedgerItem]
    usage: TokenUsageInfo | None = None


class PlanItem(BaseModel):
    id: str
    tier: Literal["basic", "premium"]
    months: int = Field(ge=1, le=36)
    price_cents: int = Field(ge=0, le=10000000)
    per_month_cents: int = Field(ge=0, le=10000000)
    title: str


class PlanCatalogResponse(BaseModel):
    items: list[PlanItem]
    trial_days: int


class SubscribeRequest(BaseModel):
    plan_id: str = Field(min_length=1, max_length=40)


class AudioJobOut(BaseModel):
    id: str
    filename: str
    size_bytes: int
    status: str
    error: str | None = None
    scene_id: str | None = None
    transcript_chars: int = 0
    created_at: datetime
    updated_at: datetime


class AudioJobListResponse(BaseModel):
    items: list[AudioJobOut]


class QuotaSettingsRequest(BaseModel):
    daily_token_limit_free: int | None = Field(default=None, ge=0, le=100000000)
    daily_token_limit_basic: int | None = Field(default=None, ge=0, le=100000000)
    daily_token_limit_premium: int | None = Field(default=None, ge=0, le=100000000)


class AsrSettingsRequest(BaseModel):
    mode: str | None = Field(default=None, max_length=20)  # cloud | local
    base_url: str | None = Field(default=None, max_length=500)
    api_key: str | None = Field(default=None, max_length=500)
    model: str | None = Field(default=None, max_length=200)
    local_command: str | None = Field(default=None, max_length=1000)


class AudioUploadInitRequest(BaseModel):
    filename: str = Field(min_length=1, max_length=255)
    size_bytes: int = Field(ge=1, le=2 * 1024 * 1024 * 1024)


class AudioUploadInitResponse(BaseModel):
    upload_id: str
    received_bytes: int = 0  # 已接收字节数，断点续传从此处继续


class AudioUploadStatusResponse(BaseModel):
    upload_id: str
    received_bytes: int
    size_bytes: int
    completed: bool = False


class RechargeCreateRequest(BaseModel):
    amount_cents: int = Field(default=0, ge=0, le=1000000)
    method: Literal["wechat", "alipay", "admin"]  # Added "admin" for manual
    plan_id: str | None = Field(default=None, max_length=40)  # 非空=购买会员套餐，金额取套餐价


class RechargeOrderResponse(BaseModel):
    order_id: str
    method: Literal["wechat", "alipay"]
    amount_cents: int
    status: str
    payment_url: str | None = None
    qr_code_text: str | None = None
    qr_code_url: str | None = None  # NEW: base64 QR code data URL for display
    receiver_name: str | None = None
    receiver_account: str | None = None
    message: str
    created_at: datetime
    paid_at: datetime | None = None  # NEW
    expires_at: datetime | None = None  # NEW: when this order expires


class RechargeConfirmRequest(BaseModel):
    order_id: str


class PriceResponse(BaseModel):
    monthly_price_cents: int
    monthly_price_yuan: float
    currency: str = "CNY"
    product_id: str


class AdminUserUpdateRequest(BaseModel):
    display_name: str | None = Field(default=None, max_length=80)
    plan: Literal["free", "pro"] | None = None
    balance_cents: int | None = Field(default=None, ge=0, le=100000000)
    balance_delta_cents: int | None = Field(default=None, ge=-100000000, le=100000000)
    is_banned: bool | None = None
    admin_notes: str | None = Field(default=None, max_length=1000)


class AdminPriceUpdateRequest(BaseModel):
    monthly_price_cents: int = Field(ge=100, le=1000000)


class SessionRecord(BaseModel):
    session_id: str
    user_id: str
    status: Literal["active", "completed"]
    items: list[DrillPrompt]
    index: int
    score: int
    created_at: datetime


class RoleplaySessionRecord(BaseModel):
    session_id: str
    user_id: str
    scene_id: str
    selected_role: str
    ai_role: str
    status: Literal["active", "completed"]
    target_index: int
    turns: int
    score_total: float
    created_at: datetime
    updated_at: datetime


# ============================================================
# User Authentication & Password Reset
# ============================================================

class PasswordLoginRequest(BaseModel):
    email: str = Field(min_length=5, max_length=120)
    password: str = Field(min_length=6, max_length=128)
    device_id: str | None = Field(default=None, max_length=128)


class PasswordRegisterRequest(BaseModel):
    email: str = Field(min_length=5, max_length=120, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    password: str = Field(min_length=6, max_length=128)
    code: str = Field(min_length=4, max_length=12)


class PasswordChangeRequest(BaseModel):
    old_password: str = Field(min_length=6, max_length=128)
    new_password: str = Field(min_length=6, max_length=128)


class PasswordResetSendRequest(BaseModel):
    email: str = Field(min_length=5, max_length=120)


class PasswordResetConfirmRequest(BaseModel):
    token: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=6, max_length=128)


class TokenRefreshRequest(BaseModel):
    refresh_token: str


class AuthTokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int  # seconds


class MessageResponse(BaseModel):
    message: str


# ============================================================
# Admin Management
# ============================================================

class AdminOut(BaseModel):
    id: str
    username: str
    role: str  # superadmin | admin | operator
    display_name: str | None = None
    email: str | None = None
    is_active: bool = True
    last_login_at: datetime | None = None
    last_login_ip: str | None = None
    created_at: datetime


class AdminCreateRequest(BaseModel):
    username: str = Field(min_length=3, max_length=32, pattern=r"^[a-zA-Z0-9_]+$")
    password: str = Field(min_length=8, max_length=128)
    role: Literal["admin", "operator"] = "admin"
    display_name: str | None = Field(default=None, max_length=80)
    email: str | None = Field(default=None, max_length=120)


class AdminUpdateRequest(BaseModel):
    password: str | None = Field(default=None, min_length=8, max_length=128)
    role: Literal["superadmin", "admin", "operator"] | None = None
    display_name: str | None = Field(default=None, max_length=80)
    email: str | None = Field(default=None, max_length=120)
    is_active: bool | None = None


class AdminListResponse(BaseModel):
    items: list[AdminOut]
    total: int
    limit: int
    offset: int


class AdminPasswordChangeRequest(BaseModel):
    old_password: str = Field(min_length=6, max_length=128)
    new_password: str = Field(min_length=8, max_length=128)


class ModelSettingsUpdateRequest(BaseModel):
    """管理台模型配置。留空字段保持不变；api_key 传空字符串表示清除。"""

    provider: str | None = Field(default=None, max_length=40)
    base_url: str | None = Field(default=None, max_length=500)
    api_key: str | None = Field(default=None, max_length=500)
    model: str | None = Field(default=None, max_length=200)
    bot_id: str | None = Field(default=None, max_length=200)
    timeout_seconds: float | None = Field(default=None, ge=5, le=300)
    input_price_per_1m_cents: float | None = Field(default=None, ge=0, le=1000000)
    output_price_per_1m_cents: float | None = Field(default=None, ge=0, le=1000000)


class RealtimeSettingsRequest(BaseModel):
    """高级会员实时语音大模型配置（OpenAI 兼容 Realtime API）。"""

    base_url: str | None = Field(default=None, max_length=500)
    api_key: str | None = Field(default=None, max_length=500)
    model: str | None = Field(default=None, max_length=200)
    voice: str | None = Field(default=None, max_length=40)
    # 计费单价（分/百万 token），文本/音频分开
    input_text_price_per_1m_cents: float | None = Field(default=None, ge=0, le=1000000)
    input_audio_price_per_1m_cents: float | None = Field(default=None, ge=0, le=1000000)
    output_text_price_per_1m_cents: float | None = Field(default=None, ge=0, le=1000000)
    output_audio_price_per_1m_cents: float | None = Field(default=None, ge=0, le=1000000)


class ScenarioSummary(BaseModel):
    scene_id: str
    title: str
    summary: str
    roles: list[ScenarioRole]
    line_count: int
    source_start: datetime
    source_end: datetime
    created_at: datetime


class ScenarioListResponse(BaseModel):
    items: list[ScenarioSummary]
    generated: bool = False  # 本次请求是否触发了自动生成


# ============================================================
# Payment Webhooks
# ============================================================

class PaymentWebhookResponse(BaseModel):
    code: str = "SUCCESS"
    message: str = "OK"


class RechargeQueryRequest(BaseModel):
    order_id: str
