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
    balance_cents: int = 0
    created_at: datetime


class AuthRequest(BaseModel):
    email: str = Field(min_length=5, max_length=120, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    password: str = Field(min_length=6, max_length=128)


class EmailCodeRequest(BaseModel):
    email: str = Field(min_length=5, max_length=120, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class EmailCodeResponse(BaseModel):
    sent: bool
    expires_in_seconds: int
    dev_code: str | None = None


class EmailRegisterRequest(AuthRequest):
    code: str = Field(min_length=4, max_length=12)


class AuthResponse(BaseModel):
    token: str
    user: UserOut


class WeChatLoginRequest(BaseModel):
    code: str = Field(min_length=1, max_length=512)
    nickname: str | None = Field(default=None, max_length=80)
    avatar_url: str | None = Field(default=None, max_length=1000)


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


class RoleplayStartRequest(BaseModel):
    start: datetime
    end: datetime
    selected_role: str
    scene_id: str | None = None
    items: list[TranscriptItem] = Field(default_factory=list)


class RoleplayMessageRequest(BaseModel):
    session_id: str
    message: str = Field(min_length=1, max_length=2000)


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


class BillingAccountResponse(BaseModel):
    user: UserOut
    ledger: list[BillingLedgerItem]


class RechargeCreateRequest(BaseModel):
    amount_cents: int = Field(ge=100, le=1000000)
    method: Literal["wechat", "alipay"]


class RechargeOrderResponse(BaseModel):
    order_id: str
    method: Literal["wechat", "alipay"]
    amount_cents: int
    status: str
    payment_url: str | None = None
    qr_code_text: str | None = None
    receiver_name: str | None = None
    receiver_account: str | None = None
    message: str
    created_at: datetime


class RechargeConfirmRequest(BaseModel):
    order_id: str


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
