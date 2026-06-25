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
    status: str = "done"  # "processing" = 已接收，场景由后台异步生成；生成完出现在场景列表


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
    over_budget: bool = False
    # 客户端展示用「已用百分比」（会员=本周期费用/额度；非会员=当日 token/每日上限）。
    # 金额额度属内部口径，客户端只展示百分比，不展示具体金额（避免「月费一半」的疑惑）。
    usage_percent: float = 0.0
    is_member: bool = False
    # 兼容已发布旧客户端（保留字段，新客户端改用 usage_percent；金额不再在 UI 展示）
    month_cost_cents: float = 0.0
    month_budget_cents: float = 0.0
    month_remaining_cents: float = 0.0


class NonmemberLimits(BaseModel):
    """非会员每日限额，登录后同步给客户端用于本地控制采集/时长。"""
    daily_chat_tokens: int
    daily_capture_tokens: int
    daily_capture_seconds: int


class CaptureQuotaResponse(BaseModel):
    """采集前/采集中查询的剩余额度（按 token 估算）。"""
    remaining_tokens: int          # 估算还能用于采集→生成场景的 token 余量（0 表示已用尽）
    can_capture: bool              # 是否允许开始采集（额度未用尽）
    approx_sentences: int          # 余量大约还能采集多少句
    is_member: bool
    message: str = ""              # 不足/超额时给用户的提示文案


class BillingAccountResponse(BaseModel):
    user: UserOut
    ledger: list[BillingLedgerItem]
    usage: TokenUsageInfo | None = None
    nonmember_limits: NonmemberLimits | None = None


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


# ---- 通用场景（运维预置的全局场景，全体用户可见可练；内容/流程与用户自采集场景一致）----

class PresetSceneItem(BaseModel):
    """用户端：通用场景里的一个子场景（已含完整对话，可直接进入对练）。"""

    scene_id: str
    title: str
    line_count: int
    roles: list["ScenarioRole"] = Field(default_factory=list)
    last_score: int | None = None
    last_practiced_at: datetime | None = None


class PresetSceneGroup(BaseModel):
    group: str
    scenes: list[PresetSceneItem] = Field(default_factory=list)


class PresetScenarioCatalogResponse(BaseModel):
    items: list[PresetSceneGroup] = Field(default_factory=list)


class PresetSceneAdminItem(BaseModel):
    """管理台：一条预置场景的完整内容（与 ScenarioResponse 同构 + 分组/排序）。"""

    scene_id: str
    group: str = ""
    title: str
    summary: str = ""
    roles: list["ScenarioRole"] = Field(default_factory=list)
    lines: list["SceneLine"] = Field(default_factory=list)
    expressions: list["ExpressionCard"] = Field(default_factory=list)
    line_count: int = 0
    sort: int = 0


class PresetSceneListResponse(BaseModel):
    items: list[PresetSceneAdminItem] = Field(default_factory=list)


class PresetSceneSaveRequest(BaseModel):
    """管理台新增/编辑预置场景。scene_id 为空=新增。"""

    scene_id: str | None = None
    group: str = Field(default="", max_length=60)
    title: str = Field(min_length=1, max_length=60)
    summary: str = Field(default="", max_length=400)
    roles: list["ScenarioRole"] = Field(default_factory=list)
    lines: list["SceneLine"] = Field(default_factory=list)
    expressions: list["ExpressionCard"] = Field(default_factory=list)
    sort: int = 0


class PresetSceneGenerateRequest(BaseModel):
    """管理台「用 AI 生成草稿」：按主题让 AI 生成内容，返回供运维编辑（不落库）。"""

    group: str = Field(default="", max_length=60)
    title: str = Field(min_length=1, max_length=60)


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
    # 月度 token 费用额度 = 购买会员时档位标准月费 × 该比例（0~1，默认 0.5）
    budget_ratio: float | None = Field(default=None, ge=0, le=1)
    # 非会员（免费）每日限额
    nonmember_daily_chat_tokens: int | None = Field(default=None, ge=0, le=100000000)
    nonmember_daily_capture_tokens: int | None = Field(default=None, ge=0, le=100000000)
    nonmember_daily_capture_seconds: int | None = Field(default=None, ge=0, le=86400)


class AsrSettingsRequest(BaseModel):
    mode: str | None = Field(default=None, max_length=20)  # cloud | local
    base_url: str | None = Field(default=None, max_length=500)
    api_key: str | None = Field(default=None, max_length=500)
    model: str | None = Field(default=None, max_length=200)
    local_command: str | None = Field(default=None, max_length=1000)


class VoiceServersRequest(BaseModel):
    # 可处理语音文件的服务器列表，格式 ip:port;ip:port，例如 192.168.6.12:8000;192.168.6.3:8000
    servers: str = Field(default="", max_length=4000)


class TtsSettingsRequest(BaseModel):
    base_url: str | None = Field(default=None, max_length=500)
    api_key: str | None = Field(default=None, max_length=500)
    model: str | None = Field(default=None, max_length=200)
    voices: str | None = Field(default=None, max_length=500)         # 逗号分隔的可选音色
    default_voice: str | None = Field(default=None, max_length=100)


class TtsVoiceRequest(BaseModel):
    voice: str = Field(min_length=1, max_length=100)


class TtsVoicesResponse(BaseModel):
    voices: list[str]
    current: str
    configured: bool


class AudioUploadInitRequest(BaseModel):
    filename: str = Field(min_length=1, max_length=255)
    size_bytes: int = Field(ge=1, le=2 * 1024 * 1024 * 1024)
    md5: str = Field(min_length=32, max_length=32, pattern=r"^[0-9a-fA-F]{32}$")  # 整文件 MD5：路由+命名+去重


class AudioUploadInitResponse(BaseModel):
    upload_id: str  # = md5，后续 chunk/complete 都用它
    received_bytes: int = 0  # 已接收字节数，断点续传从此处继续
    done: bool = False  # 服务器已有同文件（已传完/已转写）→ 直接视为上传成功，客户端无需再传


class AudioUploadStatusResponse(BaseModel):
    upload_id: str
    received_bytes: int
    size_bytes: int
    completed: bool = False


class AudioUploadCompleteResponse(BaseModel):
    upload_id: str
    status: str = "uploaded"  # 已存盘待后台转写+生成场景；生成完出现在场景列表


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
    last_score: int | None = None              # 上一次对练得分(0-100)，没练过则空
    last_practiced_at: datetime | None = None  # 上一次对练时间


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


# ==================== 客服工单 ====================
class SupportTicketCreate(BaseModel):
    category: Literal["refund", "feedback", "bug", "other"] = "other"
    subject: str = Field(min_length=1, max_length=120)
    body: str = Field(min_length=1, max_length=4000)
    # 截图：base64 data URL（如 data:image/png;base64,...），最多 4 张
    images: list[str] = Field(default_factory=list, max_length=4)


class SupportTicketOut(BaseModel):
    id: str
    category: str
    subject: str
    body: str
    status: str
    admin_reply: str | None = None
    images: list[str] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime


class SupportTicketListResponse(BaseModel):
    items: list[SupportTicketOut]


class SupportTicketUpdateRequest(BaseModel):
    # rejected = 不采纳（smartOM 技能用）
    status: Literal["open", "processing", "resolved", "closed", "rejected"] | None = None
    admin_reply: str | None = Field(default=None, max_length=4000)
