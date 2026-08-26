from __future__ import annotations

import hashlib
import json
import os
import re
import uuid
from collections.abc import Mapping
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from sqlalchemy import (
    Column,
    Float,
    ForeignKey,
    Index,
    Integer,
    MetaData,
    Table,
    Text,
    create_engine,
    delete,
    event,
    func,
    insert,
    inspect,
    or_,
    select,
    text,
    update,
)
from sqlalchemy.engine import Engine
from sqlalchemy.exc import IntegrityError as DatabaseIntegrityError

from .schemas import (
    BillingLedgerItem,
    DrillPrompt,
    ExpressionCard,
    PracticeHistoryItem,
    RechargeOrderResponse,
    RoleplayMessageOut,
    RoleplaySessionRecord,
    ScenarioResponse,
    ScenarioRole,
    SceneLine,
    SceneMasteryRecord,
    SessionRecord,
    TranscriptItem,
    UserOut,
)
from .content_policy import filter_sensitive_transcripts
from .settings import settings


def normalize_email(email: str) -> str:
    return email.strip().lower()


class InsufficientBalanceError(Exception):
    """余额不足，missing_cents 表示还差多少分。"""

    def __init__(self, missing_cents: int):
        self.missing_cents = missing_cents
        super().__init__(f"insufficient balance, missing {missing_cents} cents")


def effective_plan_tier(plan: str | None, plan_expires_at: datetime | None) -> str:
    """计算生效套餐：到期即降为 free；历史 'pro' 视为 basic。"""
    tier = (plan or "free").lower()
    if tier == "pro":
        tier = "basic"
    if tier not in ("basic", "premium"):
        return "free"
    if plan_expires_at is None or plan_expires_at > datetime.now(timezone.utc):
        return tier
    return "free"


metadata = MetaData()

users = Table(
    "users",
    metadata,
    Column("id", Text, primary_key=True),
    Column("login_identifier", Text, nullable=False),
    Column("password_salt", Text, nullable=False),
    Column("password_hash", Text, nullable=False),
    Column("plan", Text, nullable=False, default="free"),
    Column("apple_original_transaction_id", Text),
    Column("subscription_expires_at", Text),
    Column("created_at", Text, nullable=False),
    Column("balance_cents", Integer, nullable=False, default=0),
    Column("wechat_openid", Text),
    Column("display_name", Text),
    Column("avatar_url", Text),
    Column("is_banned", Integer, nullable=False, default=0),
    Column("admin_notes", Text),
    Column("last_seen_at", Text),
    Column("plan_expires_at", Text),
    Column("active_device_id", Text),  # 当前唯一允许登录的设备编号（单设备登录）
    Column("token_version", Integer, nullable=False, default=1),  # 递增即吊销该用户全部令牌
    Column("refresh_token_jti", Text),  # 当前有效 refresh token 的唯一编号，轮换后旧令牌立即作废
    Column("plan_monthly_price_cents", Integer),  # 购买会员时锁定的档位标准月费（分），用于月度额度计算
    Column("plan_purchased_at", Text),  # 当前连续会员期的起始购买日，作为每月额度重置的锚点
    Column("tts_voice", Text),  # 用户选择的 AI 朗读音色（练习时朗读 AI 台词用）
)
Index("idx_users_login_identifier", users.c.login_identifier, unique=True)
Index("idx_users_wechat_openid", users.c.wechat_openid, unique=True)

apple_transaction_claims = Table(
    "apple_transaction_claims",
    metadata,
    Column("original_transaction_id", Text, primary_key=True),
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    Column("created_at", Text, nullable=False),
)

transcripts = Table(
    "transcripts",
    metadata,
    Column("id", Text, primary_key=True),
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    Column("timestamp", Text, nullable=False),
    Column("text", Text, nullable=False),
    Column("created_at", Text, nullable=False),
    Column("expires_at", Text, nullable=False),
)
Index("idx_transcripts_user_time", transcripts.c.user_id, transcripts.c.timestamp)
Index("idx_transcripts_expires", transcripts.c.expires_at)

sessions = Table(
    "sessions",
    metadata,
    Column("session_id", Text, primary_key=True),
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    Column("status", Text, nullable=False),
    Column("items_json", Text, nullable=False),
    Column("item_index", Integer, nullable=False, default=0),
    Column("score", Integer, nullable=False, default=0),
    Column("created_at", Text, nullable=False),
)
Index("idx_sessions_user", sessions.c.user_id, sessions.c.created_at)

scenarios = Table(
    "scenarios",
    metadata,
    Column("scene_id", Text, primary_key=True),
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    Column("title", Text, nullable=False),
    Column("summary", Text, nullable=False),
    Column("roles_json", Text, nullable=False),
    Column("lines_json", Text, nullable=False),
    Column("expressions_json", Text, nullable=False),
    Column("source_start", Text, nullable=False),
    Column("source_end", Text, nullable=False),
    Column("created_at", Text, nullable=False),
    Column("expires_at", Text, nullable=False),
    Column("source_hash", Text),  # 采集内容哈希，用于幂等去重，避免重复上传生成重复场景
    # 通用场景（AI 即时模拟）为临时场景：不计入用户「今天/历史」真实场景列表，仅供本次试练
    Column("ephemeral", Integer, nullable=False, server_default="0"),
    # 通用场景（运维在管理台预置、全体用户可见可练）：is_preset=1，归属系统用户；
    # preset_group=主场景名（分组），preset_sort=排序。普通用户的「今天/历史」不含这些。
    Column("is_preset", Integer, nullable=False, server_default="0"),
    Column("preset_group", Text),
    Column("preset_sort", Integer, nullable=False, server_default="0"),
)
Index("idx_scenarios_user_created", scenarios.c.user_id, scenarios.c.created_at)
Index("idx_scenarios_user_hash", scenarios.c.user_id, scenarios.c.source_hash)
Index("idx_scenarios_expires", scenarios.c.expires_at)

roleplay_sessions = Table(
    "roleplay_sessions",
    metadata,
    Column("session_id", Text, primary_key=True),
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    Column("scene_id", Text, ForeignKey("scenarios.scene_id", ondelete="CASCADE"), nullable=False),
    Column("selected_role", Text, nullable=False),
    Column("ai_role", Text, nullable=False),
    Column("status", Text, nullable=False),
    Column("target_index", Integer, nullable=False, default=0),
    Column("turns", Integer, nullable=False, default=0),
    Column("score_total", Float, nullable=False, default=0),
    Column("created_at", Text, nullable=False),
    Column("updated_at", Text, nullable=False),
)
Index("idx_roleplay_sessions_user_created", roleplay_sessions.c.user_id, roleplay_sessions.c.created_at)

roleplay_messages = Table(
    "roleplay_messages",
    metadata,
    Column("id", Text, primary_key=True),
    Column("session_id", Text, ForeignKey("roleplay_sessions.session_id", ondelete="CASCADE"), nullable=False),
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    Column("speaker", Text, nullable=False),
    Column("role", Text, nullable=False),
    Column("content", Text, nullable=False),
    Column("translation", Text),
    Column("feedback", Text),
    Column("created_at", Text, nullable=False),
)
Index("idx_roleplay_messages_session_created", roleplay_messages.c.session_id, roleplay_messages.c.created_at)

# 自由对话（一对一语音老师）：不绑场景，只有连续的用户/AI 消息流；保留近段历史供上下文与字幕回放。
freetalk_messages = Table(
    "freetalk_messages",
    metadata,
    Column("id", Text, primary_key=True),
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    Column("speaker", Text, nullable=False),  # user / ai
    Column("content", Text, nullable=False),
    # 情绪标签（cheerful/encouraging/…，可为空）：合成语音的语气，随消息持久化——
    # 重播时按同样语气重新合成（实时通道的即兴语音无标签，重播按平语气合成）
    Column("tone", Text, nullable=False, server_default=""),
    Column("created_at", Text, nullable=False),
)
Index("idx_freetalk_messages_user_created", freetalk_messages.c.user_id, freetalk_messages.c.created_at)

# 学习提醒：用户拒绝过(挂断/暂不)的场景不再来电。App 主导触发，后端只记幂等状态 → 多活不重复。
reminder_dismissed = Table(
    "reminder_dismissed",
    metadata,
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
    Column("scene_id", Text, primary_key=True),
    Column("created_at", Text, nullable=False),
)

# 用户学习记忆（仿 Claude 记忆文档）：每用户一份 Markdown 式摘要（英文水平/常错点/习惯/生活背景/练习偏好），
# 由模型在对话后增量维护；超长自动压缩（见 ark_client.update_freetalk_memory）。
user_memory = Table(
    "user_memory",
    metadata,
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
    Column("content", Text, nullable=False),
    Column("updated_at", Text, nullable=False),
)

practice_results = Table(
    "practice_results",
    metadata,
    Column("id", Text, primary_key=True),
    Column("session_id", Text, ForeignKey("roleplay_sessions.session_id", ondelete="CASCADE"), nullable=False),
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    Column("scene_id", Text, ForeignKey("scenarios.scene_id", ondelete="CASCADE"), nullable=False),
    Column("line_index", Integer, nullable=False),
    Column("expected_text", Text, nullable=False),
    Column("user_text", Text, nullable=False),
    Column("score", Float, nullable=False),
    Column("feedback", Text, nullable=False),
    Column("created_at", Text, nullable=False),
    # 四维评分(0-100)：训练系统按维度聚合出「掌握度」。0=该轮无评分(旧数据/未打分)。
    Column("dim_pronunciation", Integer, nullable=False, server_default="0"),
    Column("dim_grammar", Integer, nullable=False, server_default="0"),
    Column("dim_naturalness", Integer, nullable=False, server_default="0"),
    Column("dim_vocabulary", Integer, nullable=False, server_default="0"),
)
Index("idx_practice_results_user_created", practice_results.c.user_id, practice_results.c.created_at)

# 场景掌握度（训练系统核心）：每个用户对每个场景的四维掌握情况 + 间隔复习到期时间。
# 一次完整跑完某场景（completed）后更新一行。curriculum 引擎据此排「今日训练路径」：
# 到期未掌握的优先复习，其余推进到没练过的新场景。
scene_mastery = Table(
    "scene_mastery",
    metadata,
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
    Column("scene_id", Text, ForeignKey("scenarios.scene_id", ondelete="CASCADE"), primary_key=True),
    Column("attempts", Integer, nullable=False, server_default="0"),   # 完整跑完的次数
    Column("mastered", Integer, nullable=False, server_default="0"),   # 1=已掌握
    # 最近一次完整跑完的四维平均分（0-100）
    Column("last_pronunciation", Integer, nullable=False, server_default="0"),
    Column("last_grammar", Integer, nullable=False, server_default="0"),
    Column("last_naturalness", Integer, nullable=False, server_default="0"),
    Column("last_vocabulary", Integer, nullable=False, server_default="0"),
    Column("best_overall", Float, nullable=False, server_default="0"),  # 历次最好综合分(0-1)
    Column("last_practiced_at", Text, nullable=False),
    Column("next_review_at", Text, nullable=False),   # 间隔复习到期时间；已掌握推很远
    Column("created_at", Text, nullable=False),
    Column("updated_at", Text, nullable=False),
)
Index("idx_scene_mastery_user_review", scene_mastery.c.user_id, scene_mastery.c.next_review_at)

email_verification_codes = Table(
    "email_verification_codes",
    metadata,
    Column("email", Text, primary_key=True),
    Column("code_hash", Text, nullable=False),
    Column("expires_at", Text, nullable=False),
    Column("consumed_at", Text),
    Column("created_at", Text, nullable=False),
)

email_reset_tokens = Table(
    "email_reset_tokens",
    metadata,
    Column("token_hash", Text, primary_key=True),
    Column("user_id", Text, nullable=False),
    Column("email", Text, nullable=False),
    Column("expires_at", Text, nullable=False),
    Column("consumed_at", Text),
    Column("created_at", Text, nullable=False),
)

billing_ledger = Table(
    "billing_ledger",
    metadata,
    Column("id", Text, primary_key=True),
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    Column("type", Text, nullable=False),
    Column("title", Text, nullable=False),
    Column("amount_cents", Integer, nullable=False),
    Column("balance_after_cents", Integer, nullable=False),
    Column("created_at", Text, nullable=False),
)
Index("idx_billing_ledger_user_created", billing_ledger.c.user_id, billing_ledger.c.created_at)

payment_orders = Table(
    "payment_orders",
    metadata,
    Column("order_id", Text, primary_key=True),
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    Column("method", Text, nullable=False),
    Column("amount_cents", Integer, nullable=False),
    Column("status", Text, nullable=False),
    Column("payment_url", Text),
    Column("qr_code_text", Text),
    Column("receiver_name", Text),
    Column("receiver_account", Text),
    Column("plan_id", Text),  # 非空表示这是「会员套餐」订单，支付成功后激活会员而非加余额
    Column("created_at", Text, nullable=False),
    Column("paid_at", Text),
)
Index("idx_payment_orders_user_created", payment_orders.c.user_id, payment_orders.c.created_at)

payment_webhooks = Table(
    "payment_webhooks",
    metadata,
    Column("id", Text, primary_key=True),
    Column("order_id", Text, nullable=False),
    Column("provider", Text, nullable=False),
    Column("event_type", Text, nullable=False),
    Column("payload_json", Text, nullable=False),
    Column("signature", Text),
    Column("status", Text, nullable=False, default="received"),
    Column("processed_at", Text),
    Column("error_message", Text),
    Column("created_at", Text, nullable=False),
)
Index("idx_payment_webhooks_order", payment_webhooks.c.order_id, payment_webhooks.c.provider)

app_settings = Table(
    "app_settings",
    metadata,
    Column("key", Text, primary_key=True),
    Column("value_text", Text, nullable=False),
    Column("updated_at", Text, nullable=False),
)

admins = Table(
    "admins",
    metadata,
    Column("id", Text, primary_key=True),
    Column("username", Text, nullable=False),
    Column("password_salt", Text, nullable=False),
    Column("password_hash", Text, nullable=False),
    Column("role", Text, nullable=False, default="admin"),
    Column("display_name", Text),
    Column("email", Text),
    Column("is_active", Integer, nullable=False, default=1),
    Column("last_login_at", Text),
    Column("last_login_ip", Text),
    Column("created_at", Text, nullable=False),
    Column("updated_at", Text, nullable=False),
)
Index("idx_admins_username", admins.c.username, unique=True)

admin_sessions = Table(
    "admin_sessions",
    metadata,
    Column("token_hash", Text, primary_key=True),
    Column("admin_id", Text, ForeignKey("admins.id", ondelete="CASCADE"), nullable=False),
    Column("username", Text, nullable=False),
    Column("ip_address", Text),
    Column("user_agent", Text),
    Column("created_at", Text, nullable=False),
    Column("expires_at", Text, nullable=False),
    Column("last_seen_at", Text),  # 最近一次带该会话的请求时间，用于闲置超时
)
Index("idx_admin_sessions_admin", admin_sessions.c.admin_id)
Index("idx_admin_sessions_expires", admin_sessions.c.expires_at)

support_tickets = Table(
    "support_tickets",
    metadata,
    Column("id", Text, primary_key=True),
    Column("user_id", Text, nullable=False),
    Column("category", Text, nullable=False, default="other"),  # refund/feedback/bug/other
    Column("subject", Text, nullable=False),
    Column("body", Text, nullable=False),
    Column("status", Text, nullable=False, default="open"),  # open/processing/resolved/closed/rejected
    Column("admin_reply", Text),
    Column("images_json", Text),  # 截图：base64 data URL 列表的 JSON
    Column("created_at", Text, nullable=False),
    Column("updated_at", Text, nullable=False),
)
Index("idx_support_tickets_user", support_tickets.c.user_id)
Index("idx_support_tickets_status", support_tickets.c.status)

audio_jobs = Table(
    "audio_jobs",
    metadata,
    Column("id", Text, primary_key=True),
    Column("user_id", Text, ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    Column("filename", Text, nullable=False),
    Column("size_bytes", Integer, nullable=False, default=0),
    Column("status", Text, nullable=False, default="pending"),  # pending/transcribing/generating/completed/failed
    Column("error", Text),
    Column("scene_id", Text),
    Column("transcript_chars", Integer, nullable=False, default=0),
    Column("file_hash", Text),  # 文件内容哈希，用于同文件同用户幂等去重
    Column("created_at", Text, nullable=False),
    Column("updated_at", Text, nullable=False),
)
Index("idx_audio_jobs_user_created", audio_jobs.c.user_id, audio_jobs.c.created_at)
Index("idx_audio_jobs_user_hash", audio_jobs.c.user_id, audio_jobs.c.file_hash)

ai_usage = Table(
    "ai_usage",
    metadata,
    Column("id", Text, primary_key=True),
    Column("user_id", Text),
    Column("kind", Text, nullable=False),
    Column("model", Text, nullable=False),
    Column("prompt_tokens", Integer, nullable=False, default=0),
    Column("completion_tokens", Integer, nullable=False, default=0),
    Column("total_tokens", Integer, nullable=False, default=0),
    Column("cost_cents", Float, nullable=False, default=0),
    Column("latency_ms", Integer, nullable=False, default=0),
    Column("created_at", Text, nullable=False),
)
Index("idx_ai_usage_created", ai_usage.c.created_at)
Index("idx_ai_usage_user_created", ai_usage.c.user_id, ai_usage.c.created_at)



class Database:
    def __init__(self, database_url: str | None = None, path: Path | None = None):
        self.url = _database_url(database_url or settings.database_url, path or settings.database_path)
        self.backend = _backend_name(self.url)
        self.engine = self._create_engine()
        self._wait_until_ready()
        # 不在连接时建表/迁移/播种：那是「装库时一次性供给(db_init)」做的事。
        # 多个 API 后端只读已供给的库，避免并发建表/播种竞争与系统参数取值不确定。

    def _wait_until_ready(self, attempts: int = 30, delay: float = 2.0) -> None:
        """等待数据库可连接（容器编排下 API 可能先于 DB 启动）。SQLite 直接跳过。"""
        if self.backend == "sqlite":
            return
        import time as _time

        last_err: Exception | None = None
        for i in range(attempts):
            try:
                with self.engine.connect() as conn:
                    conn.execute(text("SELECT 1"))
                return
            except Exception as exc:  # noqa: BLE001 — 启动期任何连接错误都重试
                last_err = exc
                print(f"[storage] 等待数据库就绪（{i + 1}/{attempts}）：{str(exc)[:120]}", flush=True)
                _time.sleep(delay)
        raise RuntimeError(f"数据库连接失败，已重试 {attempts} 次：{last_err}")

    _SCHEMA_VERSION = "1"

    def is_provisioned(self) -> bool:
        """库是否已供给（建表+播种）。新库看 schema_version；老库兼容看 settings_seeded。
        表都不存在 → 未供给。API 启动据此快速失败，绝不自己建表。"""
        try:
            from sqlalchemy import inspect as _inspect

            insp = _inspect(self.engine)
            if not insp.has_table("app_settings") or not insp.has_table("users"):
                return False
            return bool(self.get_app_setting_str("schema_version") or self.get_app_setting_str("settings_seeded"))
        except Exception:  # noqa: BLE001
            return False

    def mark_provisioned(self) -> None:
        self.set_app_setting("schema_version", self._SCHEMA_VERSION)

    def initialize(self) -> None:
        metadata.create_all(self.engine)
        self._ensure_preset_owner()
        with self.engine.begin() as conn:
            self._ensure_column(conn, "users", "balance_cents", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "freetalk_messages", "tone", "TEXT NOT NULL DEFAULT ''")
            self._ensure_column(conn, "users", "wechat_openid", "TEXT")
            self._ensure_column(conn, "users", "display_name", "TEXT")
            self._ensure_column(conn, "users", "avatar_url", "TEXT")
            self._ensure_column(conn, "users", "is_banned", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "users", "admin_notes", "TEXT")
            self._ensure_column(conn, "users", "last_seen_at", "TEXT")
            self._ensure_column(conn, "users", "plan_expires_at", "TEXT")
            self._ensure_column(conn, "users", "active_device_id", "TEXT")
            self._ensure_column(conn, "users", "token_version", "INTEGER NOT NULL DEFAULT 1")
            self._ensure_column(conn, "users", "refresh_token_jti", "TEXT")
            self._ensure_column(conn, "users", "tts_voice", "TEXT")
            self._ensure_column(conn, "users", "plan_monthly_price_cents", "INTEGER")
            self._ensure_column(conn, "users", "plan_purchased_at", "TEXT")
            self._ensure_column(conn, "scenarios", "source_hash", "TEXT")
            self._ensure_column(conn, "scenarios", "ephemeral", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "scenarios", "is_preset", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "scenarios", "preset_group", "TEXT")
            self._ensure_column(conn, "scenarios", "preset_sort", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "support_tickets", "images_json", "TEXT")
            self._ensure_column(conn, "admin_sessions", "last_seen_at", "TEXT")
            self._ensure_column(conn, "audio_jobs", "file_hash", "TEXT")
            self._ensure_column(conn, "payment_orders", "plan_id", "TEXT")
            self._ensure_index(
                conn,
                "idx_users_login_identifier",
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_login_identifier ON users(login_identifier)",
            )
            self._ensure_index(
                conn,
                "idx_users_wechat_openid",
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_wechat_openid ON users(wechat_openid)",
            )
            self._ensure_column(conn, "admins", "role", "TEXT NOT NULL DEFAULT 'admin'")
            self._ensure_column(conn, "admins", "display_name", "TEXT")
            self._ensure_column(conn, "admins", "email", "TEXT")
            self._ensure_column(conn, "admins", "is_active", "INTEGER NOT NULL DEFAULT 1")
            self._ensure_column(conn, "admins", "last_login_at", "TEXT")
            self._ensure_column(conn, "admins", "last_login_ip", "TEXT")
            self._ensure_column(conn, "admins", "updated_at", "TEXT")
            self._ensure_column(conn, "practice_results", "dim_pronunciation", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "practice_results", "dim_grammar", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "practice_results", "dim_naturalness", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "practice_results", "dim_vocabulary", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_index(
                conn,
                "idx_admins_username",
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_admins_username ON admins(username)",
            )

    def ping(self) -> None:
        with self.engine.connect() as conn:
            conn.execute(text("SELECT 1"))

    def create_user(self, login_identifier: str, salt: str, password_hash: str) -> UserOut:
        user_id = str(uuid.uuid4())
        created_at = _now()
        with self.engine.begin() as conn:
            conn.execute(
                insert(users).values(
                    id=user_id,
                    login_identifier=login_identifier,
                    password_salt=salt,
                    password_hash=password_hash,
                    plan="free",
                    plan_expires_at=None,
                    plan_monthly_price_cents=None,
                    balance_cents=0,
                    created_at=_iso(created_at),
                )
            )
            self._insert_welcome_ledger(conn, user_id, created_at)
        user = self.get_user(user_id)
        if user is None:
            raise ValueError("user not found")
        return user

    def _insert_welcome_ledger(self, conn, user_id: str, now: datetime) -> None:
        conn.execute(
            insert(billing_ledger).values(
                id=str(uuid.uuid4()),
                user_id=user_id,
                type="welcome",
                title="注册成功（非会员，可升级会员解锁更多用量）",
                amount_cents=0,
                balance_after_cents=0,
                created_at=_iso(now),
            )
        )

    def get_user_by_login_identifier(self, login_identifier: str) -> Mapping[str, Any] | None:
        with self.engine.connect() as conn:
            return (
                conn.execute(select(users).where(users.c.login_identifier == login_identifier))
                .mappings()
                .fetchone()
            )

    def get_user_by_email(self, email: str) -> Mapping[str, Any] | None:
        return self.get_user_by_login_identifier(email)

    def get_or_create_wechat_user(
        self,
        openid: str,
        display_name: str | None,
        avatar_url: str | None,
        salt: str,
        password_hash: str,
    ) -> UserOut:
        existing = self.get_user_by_wechat_openid(openid)
        now = _now()
        display_name = display_name or "微信用户"
        if existing is not None:
            with self.engine.begin() as conn:
                conn.execute(
                    update(users)
                    .where(users.c.id == existing["id"])
                    .values(display_name=display_name, avatar_url=avatar_url)
                )
            user = self.get_user(existing["id"])
            if user is None:
                raise ValueError("user not found")
            return user

        user_id = str(uuid.uuid4())
        identity = f"wechat:{openid}"
        with self.engine.begin() as conn:
            conn.execute(
                insert(users).values(
                    id=user_id,
                    login_identifier=identity,
                    password_salt=salt,
                    password_hash=password_hash,
                    plan="free",
                    plan_expires_at=None,
                    plan_monthly_price_cents=None,
                    balance_cents=0,
                    wechat_openid=openid,
                    display_name=display_name,
                    avatar_url=avatar_url,
                    created_at=_iso(now),
                )
            )
            self._insert_welcome_ledger(conn, user_id, now)
        user = self.get_user(user_id)
        if user is None:
            raise ValueError("user not found")
        return user

    def get_user_by_wechat_openid(self, openid: str) -> Mapping[str, Any] | None:
        with self.engine.connect() as conn:
            return conn.execute(select(users).where(users.c.wechat_openid == openid)).mappings().fetchone()

    def get_user_row(self, user_id: str) -> Mapping[str, Any] | None:
        with self.engine.connect() as conn:
            return conn.execute(select(users).where(users.c.id == user_id)).mappings().fetchone()

    def get_user(self, user_id: str) -> UserOut | None:
        row = self.get_user_row(user_id)
        return _user_from_row(row) if row else None

    def get_user_tts_voice(self, user_id: str) -> str | None:
        with self.engine.connect() as conn:
            row = conn.execute(
                select(users.c.tts_voice).where(users.c.id == user_id)
            ).fetchone()
        return row[0] if row and row[0] else None

    def set_user_tts_voice(self, user_id: str, voice: str) -> None:
        with self.engine.begin() as conn:
            conn.execute(update(users).where(users.c.id == user_id).values(tts_voice=voice))

    def touch_user_seen(self, user_id: str) -> None:
        with self.engine.begin() as conn:
            conn.execute(
                update(users)
                .where(users.c.id == user_id)
                .values(last_seen_at=_iso(_now()))
            )

    # ---- 单设备登录：每个用户只保留最近一次登录的设备编号 ----

    def set_active_device(self, user_id: str, device_id: str | None) -> None:
        with self.engine.begin() as conn:
            conn.execute(
                update(users).where(users.c.id == user_id).values(active_device_id=device_id)
            )

    def set_refresh_token_jti(self, user_id: str, jti: str | None) -> None:
        with self.engine.begin() as conn:
            conn.execute(update(users).where(users.c.id == user_id).values(refresh_token_jti=jti))

    def get_active_device(self, user_id: str) -> str | None:
        with self.engine.connect() as conn:
            row = conn.execute(
                select(users.c.active_device_id).where(users.c.id == user_id)
            ).fetchone()
        return row[0] if row and row[0] else None

    def get_token_version(self, user_id: str) -> int:
        with self.engine.connect() as conn:
            row = conn.execute(
                select(users.c.token_version).where(users.c.id == user_id)
            ).fetchone()
        return int(row[0]) if row and row[0] is not None else 1

    def bump_token_version(self, user_id: str) -> int:
        """递增令牌版本：使该用户此前签发的所有 access/refresh 令牌立即失效。"""
        with self.engine.begin() as conn:
            conn.execute(
                update(users)
                .where(users.c.id == user_id)
                .values(token_version=users.c.token_version + 1, refresh_token_jti=None)
            )
            row = conn.execute(
                select(users.c.token_version).where(users.c.id == user_id)
            ).fetchone()
        return int(row[0]) if row and row[0] is not None else 1

    def get_user_session(self, user_id: str) -> dict[str, Any] | None:
        """一次读取构建鉴权所需的全部会话上下文，避免每请求多次查库。

        返回 {user(UserOut), active_device_id, token_version, last_seen_at}；用户不存在则 None。
        """
        row = self.get_user_row(user_id)
        if row is None:
            return None
        return {
            "user": _user_from_row(row),
            "active_device_id": row["active_device_id"] if row.get("active_device_id") else None,
            "token_version": int(row["token_version"]) if row.get("token_version") is not None else 1,
            "last_seen_at": _parse_dt(row["last_seen_at"]) if row.get("last_seen_at") else None,
            "refresh_token_jti": row["refresh_token_jti"] if row.get("refresh_token_jti") else None,
        }

    def get_monthly_price_cents(self) -> int:
        return self.get_app_setting_int("monthly_price_cents", settings.monthly_price_cents)

    # ---- 套餐目录与订阅 ----

    DEFAULT_PLAN_CATALOG = [
        {"id": "basic_1m", "tier": "basic", "months": 1, "price_cents": 3000, "title": "基础 · 月付", "per_month_cents": 3000},
        {"id": "basic_3m", "tier": "basic", "months": 3, "price_cents": 7500, "title": "基础 · 季付", "per_month_cents": 2500},
        {"id": "basic_12m", "tier": "basic", "months": 12, "price_cents": 24000, "title": "基础 · 年付", "per_month_cents": 2000},
        {"id": "premium_1m", "tier": "premium", "months": 1, "price_cents": 5000, "title": "高级 · 月付", "per_month_cents": 5000},
        {"id": "premium_3m", "tier": "premium", "months": 3, "price_cents": 12000, "title": "高级 · 季付", "per_month_cents": 4000},
        {"id": "premium_12m", "tier": "premium", "months": 12, "price_cents": 36000, "title": "高级 · 年付", "per_month_cents": 3000},
    ]

    def get_plan_catalog(self) -> list[dict[str, Any]]:
        raw = self.get_app_setting_str("plan_catalog")
        if raw:
            try:
                catalog = json.loads(raw)
                if isinstance(catalog, list) and catalog:
                    return catalog
            except json.JSONDecodeError:
                pass
        return [dict(item) for item in self.DEFAULT_PLAN_CATALOG]

    def set_plan_catalog(self, catalog: list[dict[str, Any]]) -> None:
        self.set_app_setting("plan_catalog", json.dumps(catalog, ensure_ascii=False))

    # ---- 通用场景目录（管理台可随时增删主/子场景，只存标题，不存对话内容） ----

    DEFAULT_PRESET_SCENARIOS = [
        {
            "id": "daily",
            "title": "日常生活场景",
            "subs": [
                {"id": "greeting", "title": "与朋友打招呼"},
                {"id": "transit", "title": "交通出行"},
                {"id": "shopping", "title": "购物消费"},
                {"id": "dining", "title": "外出就餐"},
                {"id": "medical", "title": "生病就医"},
            ],
        },
        {
            "id": "travel",
            "title": "出国旅游场景",
            "subs": [
                {"id": "airport", "title": "机场出发"},
                {"id": "hotel", "title": "入住酒店"},
                {"id": "sightseeing", "title": "景点参观"},
                {"id": "return", "title": "返程回国"},
            ],
        },
        {
            "id": "workplace",
            "title": "职场入门场景",
            "subs": [
                {"id": "interview", "title": "面试招聘"},
                {"id": "onboarding", "title": "新人入职"},
                {"id": "communication", "title": "上下级沟通"},
            ],
        },
    ]

    def get_preset_scenarios(self) -> list[dict[str, Any]]:
        """通用场景目录。从未配置过时回退到内置预留示例；管理台保存后以 DB 为准（含清空）。"""
        raw = self.get_app_setting_str("preset_scenarios")
        if raw is not None:
            try:
                catalog = json.loads(raw)
                if isinstance(catalog, list):
                    return catalog
            except json.JSONDecodeError:
                pass
        return [dict(item) for item in self.DEFAULT_PRESET_SCENARIOS]

    def set_preset_scenarios(self, catalog: list[dict[str, Any]]) -> None:
        self.set_app_setting("preset_scenarios", json.dumps(catalog, ensure_ascii=False))

    def subscribe_plan(self, user_id: str, plan: dict[str, Any]) -> UserOut:
        """余额购买/续费套餐。同档续费从到期日顺延；升级/降级从当前时间重新计算。"""
        price = int(plan["price_cents"])
        tier = str(plan["tier"])
        months = int(plan["months"])
        now = _now()
        with self.engine.begin() as conn:
            row = conn.execute(select(users).where(users.c.id == user_id)).mappings().fetchone()
            if row is None:
                raise ValueError("user not found")
            balance = int(row["balance_cents"] or 0)
            if balance < price:
                raise InsufficientBalanceError(price - balance)

            current_expiry = _parse_dt(row["plan_expires_at"]) if row.get("plan_expires_at") else None
            same_tier_active = (
                row["plan"] == tier and current_expiry is not None and current_expiry > now
            )
            base = current_expiry if same_tier_active else now
            new_expiry = base + timedelta(days=30 * months)
            new_balance = balance - price
            # 续费（同档有效期内）保留原购买日锚点；升级/降级/重新购买则以本次为新锚点
            purchased_at = row.get("plan_purchased_at") if same_tier_active and row.get("plan_purchased_at") else _iso(now)

            conn.execute(
                update(users)
                .where(users.c.id == user_id)
                .values(
                    plan=tier,
                    plan_expires_at=_iso(new_expiry),
                    balance_cents=new_balance,
                    plan_monthly_price_cents=self._tier_monthly_price_in_conn(conn, tier),
                    plan_purchased_at=purchased_at,
                )
            )
            conn.execute(
                insert(billing_ledger).values(
                    id=str(uuid.uuid4()),
                    user_id=user_id,
                    type="subscription",
                    title=f"订阅{plan.get('title', tier)}（{months} 个月）",
                    amount_cents=-price,
                    balance_after_cents=new_balance,
                    created_at=_iso(now),
                )
            )
        user = self.get_user(user_id)
        if user is None:
            raise ValueError("user not found")
        return user

    # ---- token 配额 ----

    def get_daily_token_limit(self, tier: str) -> int:
        defaults = {
            "free": settings.daily_token_limit_free,
            "basic": settings.daily_token_limit_basic,
            "premium": settings.daily_token_limit_premium,
        }
        return self.get_app_setting_int(f"daily_token_limit_{tier}", defaults.get(tier, settings.daily_token_limit_free))

    def tokens_used_today(self, user_id: str) -> int:
        """今日已用的外部 LLM token 总量（用于每日免费额度兜底）。

        计入所有真实消耗外部 LLM token 的调用：
          - 文字链路：chat / scenario / preset_scenario / learning / evaluate（真实 token）
          - 语音链路：voice_conv（生产走远程 OpenAI Realtime，token 按秒估算 ≈24 tok/秒）
        排除两类不消耗外部 LLM 的：
          - capture_input：用户中文采集原文（不进 LLM）
          - asr / tts / asr_scenario：本地 faster-whisper / Qwen3-TTS（用户自己机器跑）
        """
        today_start = _iso(_now().replace(hour=0, minute=0, second=0, microsecond=0))
        with self.engine.connect() as conn:
            value = conn.execute(
                select(func.coalesce(func.sum(ai_usage.c.total_tokens), 0)).where(
                    ai_usage.c.user_id == user_id,
                    ai_usage.c.kind != "capture_input",  # 采集记账行不算模型用量
                    ai_usage.c.created_at >= today_start,
                )
            ).scalar_one()
        return int(value or 0)

    def cost_used_this_cycle(self, user_id: str) -> float:
        """本计费周期已用的大模型费用（分），文字 + 语音合计。

        会员按「购买日」为每月锚点（如 6 号购买则每月 6 号重置）；无锚点（历史/非会员）回退自然月。
        """
        with self.engine.connect() as conn:
            anchor = conn.execute(
                select(users.c.plan_purchased_at).where(users.c.id == user_id)
            ).scalar_one_or_none()
            cycle_start = _cycle_start(_parse_dt(anchor) if anchor else None)
            value = conn.execute(
                select(func.coalesce(func.sum(ai_usage.c.cost_cents), 0.0)).where(
                    ai_usage.c.user_id == user_id,
                    ai_usage.c.created_at >= _iso(cycle_start),
                )
            ).scalar_one()
        return float(value or 0.0)

    # ---- 非会员（免费）每日限额 ----

    def get_nonmember_daily_chat_tokens(self) -> int:
        return self.get_app_setting_int("nonmember_daily_chat_tokens", settings.nonmember_daily_chat_tokens)

    def get_nonmember_daily_capture_tokens(self) -> int:
        return self.get_app_setting_int("nonmember_daily_capture_tokens", settings.nonmember_daily_capture_tokens)

    def capture_tokens_used_today(self, user_id: str) -> int:
        """非会员当日已采集的文字输入量（token≈字符），用于每日采集限额。"""
        today_start = _iso(_now().replace(hour=0, minute=0, second=0, microsecond=0))
        with self.engine.connect() as conn:
            value = conn.execute(
                select(func.coalesce(func.sum(ai_usage.c.total_tokens), 0)).where(
                    ai_usage.c.user_id == user_id,
                    ai_usage.c.kind == "capture_input",
                    ai_usage.c.created_at >= today_start,
                )
            ).scalar_one()
        return int(value or 0)

    def record_capture_input(self, user_id: str, tokens: int) -> None:
        """记录采集文字输入量（计入每日采集限额，不计费）。"""
        self.record_ai_usage(
            user_id=user_id,
            kind="capture_input",
            model="capture",
            prompt_tokens=int(tokens),
            completion_tokens=0,
            cost_cents=0.0,
            latency_ms=0,
        )

    # ---- 客服工单 ----

    @staticmethod
    def _ticket_row_to_dict(row) -> dict[str, Any]:
        item = dict(row)
        raw = item.pop("images_json", None)
        try:
            item["images"] = json.loads(raw) if raw else []
        except (json.JSONDecodeError, TypeError):
            item["images"] = []
        return item

    def create_support_ticket(
        self, user_id: str, category: str, subject: str, body: str, images: list[str] | None = None
    ) -> dict[str, Any]:
        now = _now()
        ticket_id = str(uuid.uuid4())
        with self.engine.begin() as conn:
            conn.execute(
                insert(support_tickets).values(
                    id=ticket_id,
                    user_id=user_id,
                    category=category,
                    subject=subject,
                    body=body,
                    status="open",
                    admin_reply=None,
                    images_json=json.dumps(images or [], ensure_ascii=False),
                    created_at=_iso(now),
                    updated_at=_iso(now),
                )
            )
        return self.get_support_ticket(ticket_id)  # type: ignore[return-value]

    def get_support_ticket(self, ticket_id: str) -> dict[str, Any] | None:
        with self.engine.connect() as conn:
            row = conn.execute(
                select(support_tickets).where(support_tickets.c.id == ticket_id)
            ).mappings().fetchone()
        return self._ticket_row_to_dict(row) if row else None

    def list_user_tickets(self, user_id: str, limit: int = 50) -> list[dict[str, Any]]:
        with self.engine.connect() as conn:
            rows = conn.execute(
                select(support_tickets)
                .where(support_tickets.c.user_id == user_id)
                .order_by(support_tickets.c.created_at.desc())
                .limit(limit)
            ).mappings().fetchall()
        return [self._ticket_row_to_dict(r) for r in rows]

    def list_support_tickets(
        self,
        status: str | None = None,
        category: str | None = None,
        start: datetime | None = None,
        end: datetime | None = None,
        limit: int = 200,
    ) -> list[dict[str, Any]]:
        """管理台：按状态/类型/日期筛选工单并附用户展示信息。"""
        with self.engine.connect() as conn:
            stmt = select(support_tickets).order_by(support_tickets.c.created_at.desc()).limit(limit)
            if status:
                stmt = stmt.where(support_tickets.c.status == status)
            if category:
                stmt = stmt.where(support_tickets.c.category == category)
            if start is not None:
                stmt = stmt.where(support_tickets.c.created_at >= _iso(start))
            if end is not None:
                stmt = stmt.where(support_tickets.c.created_at < _iso(end))
            rows = conn.execute(stmt).mappings().fetchall()
            user_ids = list({r["user_id"] for r in rows})
            user_map: dict[str, Any] = {}
            if user_ids:
                user_rows = conn.execute(select(users).where(users.c.id.in_(user_ids))).mappings().fetchall()
                user_map = {ur["id"]: ur for ur in user_rows}
        items = []
        for r in rows:
            ur = user_map.get(r["user_id"])
            item = self._ticket_row_to_dict(r)
            item["user_display_name"] = (ur["display_name"] if ur else None) or (ur["login_identifier"] if ur else r["user_id"][:8])
            item["user_login_identifier"] = ur["login_identifier"] if ur else None
            items.append(item)
        return items

    def update_support_ticket(
        self, ticket_id: str, status: str | None = None, admin_reply: str | None = None
    ) -> dict[str, Any] | None:
        updates: dict[str, Any] = {"updated_at": _iso(_now())}
        if status is not None:
            updates["status"] = status
        if admin_reply is not None:
            updates["admin_reply"] = admin_reply
        with self.engine.begin() as conn:
            result = conn.execute(
                update(support_tickets).where(support_tickets.c.id == ticket_id).values(**updates)
            )
            if result.rowcount == 0:
                return None
        return self.get_support_ticket(ticket_id)

    def get_tier_monthly_price_cents(self, tier: str) -> int:
        """会员档位的「标准月价」（分）：取该档位月付套餐价。免费档为 0。"""
        if tier not in ("basic", "premium"):
            return 0
        for plan in self.get_plan_catalog():
            if str(plan.get("tier")) == tier and int(plan.get("months", 0)) == 1:
                return int(plan.get("price_cents", 0))
        return 0

    def _tier_monthly_price_in_conn(self, conn, tier: str) -> int:
        """在已有连接内读取档位标准月价（用于下单/续费事务里锁定购买时的月费）。"""
        if tier not in ("basic", "premium"):
            return 0
        raw = conn.execute(
            select(app_settings.c.value_text).where(app_settings.c.key == "plan_catalog")
        ).scalar_one_or_none()
        catalog = self.DEFAULT_PLAN_CATALOG
        if raw:
            try:
                parsed = json.loads(raw)
                if isinstance(parsed, list) and parsed:
                    catalog = parsed
            except json.JSONDecodeError:
                pass
        for plan in catalog:
            if str(plan.get("tier")) == tier and int(plan.get("months", 0)) == 1:
                return int(plan.get("price_cents", 0))
        return 0

    def get_budget_ratio(self) -> float:
        """月度 token 费用额度占会员月费的比例（默认 0.5）。管理台可在线配置、实时生效。"""
        raw = self.get_app_setting_str("budget_ratio")
        if raw:
            try:
                return max(0.0, min(1.0, float(raw)))
            except ValueError:
                pass
        return settings.budget_ratio

    def user_monthly_budget_cents(self, user_id: str, tier: str) -> float:
        """用户当月可用费用额度（分）= 购买会员时锁定的档位标准月费 × 比例。

        旧用户即使后台改了会员价，仍按其购买时的月费算；会员到期重新购买后才用新价。
        未锁定（历史用户）时回退当前档位标准月价。免费档为 0。
        """
        if tier not in ("basic", "premium"):
            return 0.0
        with self.engine.connect() as conn:
            locked = conn.execute(
                select(users.c.plan_monthly_price_cents).where(users.c.id == user_id)
            ).scalar_one_or_none()
        monthly = int(locked) if locked else self.get_tier_monthly_price_cents(tier)
        return monthly * self.get_budget_ratio()

    def admin_usage_users(self, days: int = 30, limit: int = 100) -> list[dict[str, Any]]:
        """按今日 token 用量倒序的用户列表，标记接近/超过限额的用户。"""
        now = _now()
        today_start = _iso(now.replace(hour=0, minute=0, second=0, microsecond=0))
        period_start = _iso(now - timedelta(days=days))
        with self.engine.connect() as conn:
            today_rows = conn.execute(
                select(
                    ai_usage.c.user_id,
                    func.coalesce(func.sum(ai_usage.c.total_tokens), 0),
                    func.coalesce(func.sum(ai_usage.c.cost_cents), 0),
                )
                .where(ai_usage.c.created_at >= today_start, ai_usage.c.user_id.isnot(None))
                .group_by(ai_usage.c.user_id)
            ).fetchall()
            period_rows = conn.execute(
                select(
                    ai_usage.c.user_id,
                    func.coalesce(func.sum(ai_usage.c.total_tokens), 0),
                    func.coalesce(func.sum(ai_usage.c.cost_cents), 0),
                    func.count(),
                )
                .where(ai_usage.c.created_at >= period_start, ai_usage.c.user_id.isnot(None))
                .group_by(ai_usage.c.user_id)
            ).fetchall()
            today_map = {r[0]: (int(r[1]), float(r[2])) for r in today_rows}
            period_map = {r[0]: (int(r[1]), float(r[2]), int(r[3])) for r in period_rows}
            user_ids = list({*today_map.keys(), *period_map.keys()})
            user_rows = []
            if user_ids:
                user_rows = conn.execute(select(users).where(users.c.id.in_(user_ids))).mappings().fetchall()
        items = []
        for row in user_rows:
            user = _user_from_row(row)
            today_tokens, today_cost = today_map.get(user.id, (0, 0.0))
            period_tokens, period_cost, calls = period_map.get(user.id, (0, 0.0, 0))
            daily_limit = self.get_daily_token_limit(user.plan_tier)
            items.append(
                {
                    "user_id": user.id,
                    "display_name": user.display_name,
                    "login_identifier": user.login_identifier,
                    "plan_tier": user.plan_tier,
                    "today_tokens": today_tokens,
                    "today_cost_cents": round(today_cost, 2),
                    "daily_limit": daily_limit,
                    "usage_ratio": round(today_tokens / daily_limit, 3) if daily_limit else 0,
                    "over_limit": daily_limit > 0 and today_tokens >= daily_limit,
                    "near_limit": daily_limit > 0 and today_tokens >= daily_limit * 0.8,
                    "period_tokens": period_tokens,
                    "period_cost_cents": round(period_cost, 2),
                    "period_calls": calls,
                }
            )
        items.sort(key=lambda item: item["today_tokens"], reverse=True)
        return items[:limit]

    # ---- 音频转写任务 ----

    def create_audio_job(self, user_id: str, filename: str, size_bytes: int, file_hash: str | None = None) -> dict[str, Any]:
        job_id = str(uuid.uuid4())
        now = _iso(_now())
        with self.engine.begin() as conn:
            conn.execute(
                insert(audio_jobs).values(
                    id=job_id,
                    user_id=user_id,
                    filename=filename,
                    size_bytes=size_bytes,
                    status="pending",
                    file_hash=file_hash,
                    created_at=now,
                    updated_at=now,
                )
            )
        return self.get_audio_job(user_id, job_id)

    def find_audio_job_by_hash(self, user_id: str, file_hash: str) -> dict[str, Any] | None:
        """同一用户、同一文件哈希、已成功生成场景的任务——用于幂等，避免同一文件重复转写生成。"""
        if not file_hash:
            return None
        with self.engine.connect() as conn:
            row = conn.execute(
                select(audio_jobs).where(
                    audio_jobs.c.user_id == user_id,
                    audio_jobs.c.file_hash == file_hash,
                    audio_jobs.c.status == "completed",
                    audio_jobs.c.scene_id.isnot(None),
                ).order_by(audio_jobs.c.created_at.desc())
            ).mappings().fetchone()
        return _audio_job_dict(row) if row else None

    def get_audio_job(self, user_id: str, job_id: str) -> dict[str, Any] | None:
        with self.engine.connect() as conn:
            row = conn.execute(
                select(audio_jobs).where(audio_jobs.c.id == job_id, audio_jobs.c.user_id == user_id)
            ).mappings().fetchone()
        return _audio_job_dict(row) if row else None

    def update_audio_job(
        self,
        job_id: str,
        status: str,
        error: str | None = None,
        scene_id: str | None = None,
        transcript_chars: int | None = None,
    ) -> None:
        values: dict[str, Any] = {"status": status, "updated_at": _iso(_now())}
        if error is not None:
            values["error"] = error[:500]
        if scene_id is not None:
            values["scene_id"] = scene_id
        if transcript_chars is not None:
            values["transcript_chars"] = transcript_chars
        with self.engine.begin() as conn:
            conn.execute(update(audio_jobs).where(audio_jobs.c.id == job_id).values(**values))

    def list_audio_jobs(self, user_id: str, limit: int = 20) -> list[dict[str, Any]]:
        with self.engine.connect() as conn:
            rows = conn.execute(
                select(audio_jobs)
                .where(audio_jobs.c.user_id == user_id)
                .order_by(audio_jobs.c.created_at.desc())
                .limit(limit)
            ).mappings().fetchall()
        return [_audio_job_dict(row) for row in rows]

    def get_app_setting_int(self, key: str, default: int) -> int:
        with self.engine.connect() as conn:
            value = conn.execute(
                select(app_settings.c.value_text).where(app_settings.c.key == key)
            ).scalar_one_or_none()
        if value is None:
            return default
        try:
            return int(value)
        except ValueError:
            return default

    def get_app_setting_float(self, key: str, default: float) -> float:
        with self.engine.connect() as conn:
            value = conn.execute(
                select(app_settings.c.value_text).where(app_settings.c.key == key)
            ).scalar_one_or_none()
        if value is None or value == "":
            return default
        try:
            return float(value)
        except ValueError:
            return default

    def get_app_setting_bool(self, key: str, default: bool) -> bool:
        with self.engine.connect() as conn:
            value = conn.execute(
                select(app_settings.c.value_text).where(app_settings.c.key == key)
            ).scalar_one_or_none()
        if value is None or value == "":
            return default
        return str(value).strip().lower() in ("1", "true", "yes", "on")

    def get_app_setting_str(self, key: str, default: str | None = None) -> str | None:
        with self.engine.connect() as conn:
            value = conn.execute(
                select(app_settings.c.value_text).where(app_settings.c.key == key)
            ).scalar_one_or_none()
        if value is None or value == "":
            return default
        return value

    def get_app_settings_map(self, keys: list[str]) -> dict[str, str]:
        with self.engine.connect() as conn:
            rows = conn.execute(
                select(app_settings.c.key, app_settings.c.value_text).where(app_settings.c.key.in_(keys))
            ).fetchall()
        return {row[0]: row[1] for row in rows if row[1] not in (None, "")}

    def set_app_setting(self, key: str, value: str) -> None:
        # 原「先查后插」在多 worker/多活并发下会撞主键(UniqueViolation→500)。改为原生 UPSERT：
        # PostgreSQL / SQLite 均支持 ON CONFLICT DO UPDATE，单语句原子、无竞态。
        now = _iso(_now())
        # 注意 _backend_name 对 PG 返回 "postgresql-compatible"——以 sqlite 为特例判断，其余按 PG 方言
        if self.backend == "sqlite":
            from sqlalchemy.dialects.sqlite import insert as sqlite_insert

            stmt = sqlite_insert(app_settings).values(key=key, value_text=value, updated_at=now)
            stmt = stmt.on_conflict_do_update(index_elements=["key"], set_={"value_text": value, "updated_at": now})
        else:
            from sqlalchemy.dialects.postgresql import insert as pg_insert

            stmt = pg_insert(app_settings).values(key=key, value_text=value, updated_at=now)
            stmt = stmt.on_conflict_do_update(index_elements=["key"], set_={"value_text": value, "updated_at": now})
        with self.engine.begin() as conn:
            conn.execute(stmt)

    # ===== A：多活共用凭据（只读 DB，单一来源；env/setup.sh 仅 db_init 首装播种）=====

    def resolve_smtp_config(self) -> dict[str, Any]:
        ov = self.get_app_settings_map(["smtp_host", "smtp_port", "smtp_username", "smtp_password", "smtp_from"])
        return {
            "host": ov.get("smtp_host"),
            "port": int(ov["smtp_port"]) if ov.get("smtp_port", "").isdigit() else 587,
            "username": ov.get("smtp_username"),
            "password": ov.get("smtp_password"),
            "from_addr": ov.get("smtp_from") or "RealTalk <noreply@realtalk.local>",
            "code_ttl_minutes": self.get_app_setting_int("email_code_ttl_minutes", settings.email_code_ttl_minutes),
        }

    def smtp_configured(self) -> bool:
        c = self.resolve_smtp_config()
        return bool(c["host"] and c["username"] and c["password"])

    def resolve_wechat_login_config(self) -> dict[str, str | None]:
        ov = self.get_app_settings_map(
            ["wechat_app_id", "wechat_app_secret", "wechat_web_app_id", "wechat_web_app_secret"]
        )
        return {
            "app_id": ov.get("wechat_app_id"),
            "app_secret": ov.get("wechat_app_secret"),
            "web_app_id": ov.get("wechat_web_app_id"),
            "web_app_secret": ov.get("wechat_web_app_secret"),
        }

    def resolve_apple_iap_config(self) -> dict[str, str | None]:
        ov = self.get_app_settings_map(
            ["apple_product_id", "apple_bundle_id", "apple_issuer_id", "apple_key_id", "apple_private_key"]
        )
        return {
            "product_id": ov.get("apple_product_id") or settings.apple_product_id,   # 非密钥默认（占位 bundle/product）
            "bundle_id": ov.get("apple_bundle_id") or settings.apple_bundle_id,
            "issuer_id": ov.get("apple_issuer_id"),
            "key_id": ov.get("apple_key_id"),
            "private_key": ov.get("apple_private_key"),
        }

    # ===== B：会话/留存策略（DB 为唯一运行期来源 + 管理台可改；settings.X 仅作首装默认）=====

    def get_access_token_ttl_minutes(self) -> int:
        return self.get_app_setting_int("access_token_ttl_minutes", settings.access_token_ttl_minutes)

    def get_refresh_token_ttl_days(self) -> int:
        return self.get_app_setting_int("refresh_token_ttl_days", settings.refresh_token_ttl_days)

    def get_idle_timeout_app_minutes(self) -> int:
        return self.get_app_setting_int("idle_timeout_app_minutes", settings.idle_timeout_app_minutes)

    def get_idle_timeout_web_minutes(self) -> int:
        return self.get_app_setting_int("idle_timeout_web_minutes", settings.idle_timeout_web_minutes)

    def get_admin_idle_timeout_minutes(self) -> int:
        return self.get_app_setting_int("admin_idle_timeout_minutes", settings.admin_idle_timeout_minutes)

    def get_retention_days(self) -> int:
        return self.get_app_setting_int("retention_days", settings.retention_days)

    def get_history_retention_days(self) -> int:
        return self.get_app_setting_int("history_retention_days", settings.history_retention_days)

    def get_online_window_minutes(self) -> int:
        return self.get_app_setting_int("online_window_minutes", settings.online_window_minutes)

    def get_roleplay_accept_score(self) -> float:
        return self.get_app_setting_float("roleplay_accept_score", settings.roleplay_accept_score)

    def get_political_filter_enabled(self) -> bool:
        return self.get_app_setting_bool("political_filter_enabled", settings.political_filter_enabled)

    def get_or_create_jwt_secret(self) -> str:
        """JWT 签名密钥：单一来源=共享 DB（系统参数表），保证多活各后端用同一把——否则 A 节点签的令牌 B 节点不认。
        库里已有则直接返回；库空时优先把 env JWT_SECRET「播种」入库（兼容已用 env 签发过令牌的老部署，
        切换后令牌不失效），env 未设才随机生成；写入后重读（化解并发首启竞态，各节点收敛到同一值）。
        env 仅作首次播种来源，运行期一律只读 DB。"""
        existing = self.get_app_setting_str("jwt_secret")
        if existing:
            return existing
        env = os.getenv("JWT_SECRET")
        seed_value = env if (env and env != "change-me-before-production") else os.urandom(32).hex()
        try:
            self.set_app_setting("jwt_secret", seed_value)
        except Exception:  # noqa: BLE001 — 并发首启可能撞键，忽略后重读
            pass
        return self.get_app_setting_str("jwt_secret") or ""

    def seed_app_settings_from_env(self) -> int:
        """只在「全新数据库的首次启动」把这些「DB 存储型」参数从 env/默认值初始化进 app_settings。

        以后这些参数以 DB 为唯一来源（管理台管理）；用标记 settings_seeded 确保只跑一次，
        不会每次启动都跑，也不会覆盖管理台改过或管理员删过的值。返回新写入的键数。
        """
        # 已初始化过则直接跳过（首次落库后置标记）
        if self.get_app_setting_str("settings_seeded") == "1":
            return 0
        s = settings
        # 数值类（价格/限额/比例/预估）：始终用默认值补缺
        numeric = {
            "ai_input_price_per_1m_cents": s.ai_input_price_per_1m_cents,
            "ai_output_price_per_1m_cents": s.ai_output_price_per_1m_cents,
            "ai_timeout_seconds": s.ai_timeout_seconds,
            "ai_timeout_long_seconds": s.ai_timeout_long_seconds,
            "ai_max_tokens_normal": s.ai_max_tokens_normal,
            "ai_max_tokens_long": s.ai_max_tokens_long,
            "daily_token_limit_free": s.daily_token_limit_free,
            "daily_token_limit_basic": s.daily_token_limit_basic,
            "daily_token_limit_premium": s.daily_token_limit_premium,
            "free_daily_token_total": s.free_daily_token_total,
            "budget_ratio": s.budget_ratio,
            "nonmember_daily_chat_tokens": s.nonmember_daily_chat_tokens,
            "nonmember_daily_capture_tokens": s.nonmember_daily_capture_tokens,
            "nonmember_daily_capture_seconds": s.nonmember_daily_capture_seconds,
            "monthly_price_cents": s.monthly_price_cents,
            "ai_estimate_output_tokens": s.ai_estimate_output_tokens,
            "ai_estimate_min_input_tokens": s.ai_estimate_min_input_tokens,
            # B：会话/留存策略（多活共用，DB 为唯一运行期来源 + 管理台可改）
            "access_token_ttl_minutes": s.access_token_ttl_minutes,
            "refresh_token_ttl_days": s.refresh_token_ttl_days,
            "idle_timeout_app_minutes": s.idle_timeout_app_minutes,
            "idle_timeout_web_minutes": s.idle_timeout_web_minutes,
            "admin_idle_timeout_minutes": s.admin_idle_timeout_minutes,
            "retention_days": s.retention_days,
            "history_retention_days": s.history_retention_days,
            "online_window_minutes": s.online_window_minutes,
            "roleplay_accept_score": s.roleplay_accept_score,
            "email_code_ttl_minutes": s.email_code_ttl_minutes,
            "political_filter_enabled": 1 if s.political_filter_enabled else 0,
            # Apple 非密钥标识（占位默认，管理台可改）
            "apple_product_id": s.apple_product_id,
            "apple_bundle_id": s.apple_bundle_id,
        }
        # 连接/密钥类：仅当 env 非空才补，避免把空串写进库
        strings = {
            "ai_base_url": getattr(s, "ai_base_url", None),
            "ai_api_key": getattr(s, "ai_api_key", None),
            "ai_model": getattr(s, "ai_model", None),
            "asr_base_url": getattr(s, "asr_base_url", None),
            "asr_api_key": getattr(s, "asr_api_key", None),
            "asr_model": getattr(s, "asr_model", None),
            # 按功能归属分开的 A/B 类配置：A=场景生成专用 ASR；B=对话语音模型一张卡（派生全部端点）
            "scenario_asr_base_url": getattr(s, "scenario_asr_base_url", None),
            "scenario_asr_api_key": getattr(s, "scenario_asr_api_key", None),
            "scenario_asr_model": getattr(s, "scenario_asr_model", None),
            "conv_voice_base_url": getattr(s, "conv_voice_base_url", None),
            "conv_voice_api_key": getattr(s, "conv_voice_api_key", None),
            "conv_voice_model": getattr(s, "conv_voice_model", None),
            "conv_voice_voice": getattr(s, "conv_voice_voice", None),
            # 分端点计费单价（a=ASR分/分钟、b=TTS分/百万字符、d=实时通道分/分钟；c 用原 token 单价）
            "asr_price_per_minute_cents": getattr(s, "asr_price_per_minute_cents", None),
            "tts_price_per_1m_chars_cents": getattr(s, "tts_price_per_1m_chars_cents", None),
            "conv_voice_price_per_minute_cents": getattr(s, "conv_voice_price_per_minute_cents", None),
            # TTS 云端配置（管理台可改；mode/本地命令是每节点的，不入库）
            "tts_base_url": getattr(s, "tts_base_url", None),
            "tts_api_key": getattr(s, "tts_api_key", None),
            "tts_model": getattr(s, "tts_model", None),
            "tts_voices": getattr(s, "tts_voices", None),
            "tts_default_voice": getattr(s, "tts_default_voice", None),
            # 支付验签凭证（多活后端共用，DB 为准；env/setup.sh 仅首装播种）
            "wechat_mchid": getattr(s, "wechat_mchid", None),
            "wechat_apiv3_key": getattr(s, "wechat_api_key", None),
            "wechat_platform_cert": getattr(s, "wechat_platform_cert", None),
            "wechat_cert_serial": getattr(s, "wechat_cert_serial", None),
            "alipay_app_id": getattr(s, "alipay_app_id", None),
            "alipay_public_key": getattr(s, "alipay_public_key", None),
            # 回调地址 + 商户下单签名凭据（多活共用，DB 为准；env/setup.sh 仅首装播种）
            "wechat_notify_url": getattr(s, "wechat_notify_url", None),
            "alipay_notify_url": getattr(s, "alipay_notify_url", None),
            "wechat_merchant_cert": getattr(s, "wechat_merchant_cert", None),
            "wechat_merchant_private_key": getattr(s, "wechat_merchant_private_key", None),
            "alipay_merchant_private_key": getattr(s, "alipay_merchant_private_key", None),
            # 人工收款兜底（多活共用，DB 为准；env/setup.sh 仅首装播种）
            "payment_receiver_name": getattr(s, "payment_receiver_name", None),
            "wechat_receiver_account": getattr(s, "wechat_receiver_account", None),
            "alipay_receiver_account": getattr(s, "alipay_receiver_account", None),
            "wechat_pay_url": getattr(s, "wechat_pay_url", None),
            "alipay_pay_url": getattr(s, "alipay_pay_url", None),
            # A：多活共用凭据（DB 为准，env/setup.sh 仅首装播种）——SMTP / 微信登录 / Apple IAP
            "smtp_host": getattr(s, "smtp_host", None),
            "smtp_port": str(getattr(s, "smtp_port", "") or ""),
            "smtp_username": getattr(s, "smtp_username", None),
            "smtp_password": getattr(s, "smtp_password", None),
            "smtp_from": getattr(s, "smtp_from", None),
            "wechat_app_id": getattr(s, "wechat_app_id", None),
            "wechat_app_secret": getattr(s, "wechat_app_secret", None),
            "wechat_web_app_id": getattr(s, "wechat_web_app_id", None),
            "wechat_web_app_secret": getattr(s, "wechat_web_app_secret", None),
            "apple_issuer_id": getattr(s, "apple_issuer_id", None),
            "apple_key_id": getattr(s, "apple_key_id", None),
            "apple_private_key": getattr(s, "apple_private_key", None),
        }
        existing = self.get_app_settings_map(list(numeric) + list(strings))
        written = 0
        for key, value in numeric.items():
            if key not in existing and value is not None:
                self.set_app_setting(key, str(value))
                written += 1
        for key, value in strings.items():
            if key not in existing and value:
                self.set_app_setting(key, str(value))
                written += 1
        # 置首装完成标记，确保只跑一次（之后以 DB 为唯一来源）
        self.set_app_setting("settings_seeded", "1")
        return written

    def update_subscription(
        self,
        user_id: str,
        original_transaction_id: str,
        expires_at: datetime | None,
    ) -> UserOut:
        with self.engine.begin() as conn:
            conn.execute(
                update(users)
                .where(users.c.id == user_id)
                .values(
                    plan="basic",
                    plan_expires_at=_iso(expires_at) if expires_at else None,
                    apple_original_transaction_id=original_transaction_id,
                    subscription_expires_at=_iso(expires_at) if expires_at else None,
                )
            )
        user = self.get_user(user_id)
        if user is None:
            raise ValueError("user not found")
        return user

    def claim_apple_subscription(
        self, user_id: str, original_transaction_id: str, expires_at: datetime | None
    ) -> UserOut:
        """原子地把 Apple 原始交易绑定到一个账号；交易不可跨账号重复领取。"""
        if not original_transaction_id:
            raise ValueError("missing original transaction id")
        now = _now()
        with self.engine.begin() as conn:
            claim = conn.execute(
                select(apple_transaction_claims.c.user_id).where(
                    apple_transaction_claims.c.original_transaction_id == original_transaction_id
                )
            ).fetchone()
            if claim is not None and claim[0] != user_id:
                raise ValueError("Apple 订阅已绑定到其他账号")
            if claim is None:
                conn.execute(insert(apple_transaction_claims).values(
                    original_transaction_id=original_transaction_id, user_id=user_id, created_at=_iso(now)
                ))
            conn.execute(
                update(users).where(users.c.id == user_id).values(
                    plan="basic", plan_expires_at=_iso(expires_at) if expires_at else None,
                    apple_original_transaction_id=original_transaction_id,
                    subscription_expires_at=_iso(expires_at) if expires_at else None,
                )
            )
        user = self.get_user(user_id)
        if user is None:
            raise ValueError("user not found")
        return user

    def update_user_password(self, user_id: str, salt: str, password_hash: str) -> bool:
        with self.engine.begin() as conn:
            result = conn.execute(
                update(users)
                .where(users.c.id == user_id)
                .values(password_salt=salt, password_hash=password_hash)
            )
        return result.rowcount > 0

    def update_user_email(self, user_id: str, new_email: str) -> bool:
        normalized = normalize_email(new_email)
        with self.engine.begin() as conn:
            existing = conn.execute(
                select(users.c.id).where(
                    users.c.login_identifier == normalized,
                    users.c.id != user_id,
                )
            ).scalar_one_or_none()
            if existing:
                return False
            conn.execute(
                update(users)
                .where(users.c.id == user_id)
                .values(login_identifier=normalized)
            )
        return True

    def user_password_reset(self, user_id: str, salt: str, password_hash: str) -> bool:
        return self.update_user_password(user_id, salt, password_hash)

    def store_email_code(self, email: str, code_hash: str, expires_at: datetime) -> None:
        now = _now()
        with self.engine.begin() as conn:
            conn.execute(delete(email_verification_codes).where(email_verification_codes.c.email == email))
            conn.execute(
                insert(email_verification_codes).values(
                    email=email,
                    code_hash=code_hash,
                    expires_at=_iso(expires_at),
                    consumed_at=None,
                    created_at=_iso(now),
                )
            )

    def consume_email_code(self, email: str, code_hash: str) -> bool:
        now = _now()
        with self.engine.begin() as conn:
            row = (
                conn.execute(
                    select(email_verification_codes).where(
                        email_verification_codes.c.email == email,
                        email_verification_codes.c.consumed_at.is_(None),
                    )
                )
                .mappings()
                .fetchone()
            )
            if row is None:
                return False
            if row["code_hash"] != code_hash or _parse_dt(row["expires_at"]) < now:
                return False
            conn.execute(
                update(email_verification_codes)
                .where(email_verification_codes.c.email == email)
                .values(consumed_at=_iso(now))
            )
        return True

    def create_email_reset_token(self, user_id: str, email: str, token_hash: str, expires_at: datetime) -> None:
        now = _now()
        with self.engine.begin() as conn:
            conn.execute(delete(email_reset_tokens).where(email_reset_tokens.c.user_id == user_id))
            conn.execute(
                insert(email_reset_tokens).values(
                    token_hash=token_hash,
                    user_id=user_id,
                    email=email,
                    expires_at=_iso(expires_at),
                    consumed_at=None,
                    created_at=_iso(now),
                )
            )

    def consume_email_reset_token(self, token_hash: str) -> dict[str, Any] | None:
        now = _now()
        with self.engine.begin() as conn:
            row = (
                conn.execute(
                    select(email_reset_tokens).where(
                        email_reset_tokens.c.token_hash == token_hash,
                        email_reset_tokens.c.consumed_at.is_(None),
                    )
                )
                .mappings()
                .fetchone()
            )
            if row is None:
                return None
            if _parse_dt(row["expires_at"]) < now:
                return None
            conn.execute(
                update(email_reset_tokens)
                .where(email_reset_tokens.c.token_hash == token_hash)
                .values(consumed_at=_iso(now))
            )
            user = self.get_user(row["user_id"])
            if user is None:
                return None
            return {
                "user_id": user.id,
                "email": user.login_identifier,
            }

    def list_billing_ledger(self, user_id: str, limit: int = 30) -> list[BillingLedgerItem]:
        with self.engine.connect() as conn:
            rows = (
                conn.execute(
                    select(billing_ledger)
                    .where(billing_ledger.c.user_id == user_id)
                    # 账单明细只列与「支付/计费」相关的流水；注册欢迎条(welcome,无支付)不显示
                    .where(billing_ledger.c.type != "welcome")
                    .order_by(billing_ledger.c.created_at.desc())
                    .limit(limit)
                )
                .mappings()
                .fetchall()
            )
        return [_billing_ledger_from_row(row) for row in rows]

    def create_recharge_order(
        self,
        user_id: str,
        method: str,
        amount_cents: int,
        payment_url: str | None,
        qr_code_text: str | None,
        receiver_name: str | None,
        receiver_account: str | None,
        plan_id: str | None = None,
    ) -> RechargeOrderResponse:
        order_id = str(uuid.uuid4())
        now = _now()
        with self.engine.begin() as conn:
            conn.execute(
                insert(payment_orders).values(
                    order_id=order_id,
                    user_id=user_id,
                    method=method,
                    amount_cents=amount_cents,
                    status="pending",
                    payment_url=payment_url,
                    qr_code_text=qr_code_text,
                    receiver_name=receiver_name,
                    receiver_account=receiver_account,
                    plan_id=plan_id,
                    created_at=_iso(now),
                )
            )
        return RechargeOrderResponse(
            order_id=order_id,
            method=method,
            amount_cents=amount_cents,
            status="pending",
            payment_url=payment_url,
            qr_code_text=qr_code_text,
            receiver_name=receiver_name,
            receiver_account=receiver_account,
            message="订单已创建",
            created_at=now,
        )

    def _grant_plan_in_conn(self, conn, user_id: str, plan: dict[str, Any], now: datetime) -> None:
        """在已开启的事务里激活/续费会员（不扣余额，用于支付成功后）。"""
        tier = str(plan["tier"])
        months = int(plan["months"])
        row = conn.execute(select(users).where(users.c.id == user_id)).mappings().fetchone()
        current_expiry = _parse_dt(row["plan_expires_at"]) if row and row.get("plan_expires_at") else None
        same_tier_active = row and row["plan"] == tier and current_expiry is not None and current_expiry > now
        base = current_expiry if same_tier_active else now
        new_expiry = base + timedelta(days=30 * months)
        existing_anchor = row.get("plan_purchased_at") if row else None
        purchased_at = existing_anchor if same_tier_active and existing_anchor else _iso(now)
        conn.execute(
            update(users).where(users.c.id == user_id)
            .values(
                plan=tier,
                plan_expires_at=_iso(new_expiry),
                plan_monthly_price_cents=self._tier_monthly_price_in_conn(conn, tier),
                plan_purchased_at=purchased_at,
            )
        )
        balance_after = int(conn.execute(select(users.c.balance_cents).where(users.c.id == user_id)).scalar_one() or 0)
        conn.execute(
            insert(billing_ledger).values(
                id=str(uuid.uuid4()),
                user_id=user_id,
                type="subscription",
                title=f"开通{plan.get('title', tier)}（{months} 个月）",
                amount_cents=-int(plan["price_cents"]),
                balance_after_cents=balance_after,
                created_at=_iso(now),
            )
        )

    def _plan_by_id(self, plan_id: str) -> dict[str, Any] | None:
        return next((p for p in self.get_plan_catalog() if p.get("id") == plan_id), None)

    def mark_recharge_paid(self, user_id: str, order_id: str) -> tuple[RechargeOrderResponse, UserOut]:
        now = _now()
        with self.engine.begin() as conn:
            order = (
                conn.execute(
                    select(payment_orders).where(
                        payment_orders.c.user_id == user_id,
                        payment_orders.c.order_id == order_id,
                    )
                )
                .mappings()
                .fetchone()
            )
            if order is None:
                raise ValueError("order not found")

            result = conn.execute(
                update(payment_orders)
                .where(
                    payment_orders.c.user_id == user_id,
                    payment_orders.c.order_id == order_id,
                    payment_orders.c.status != "paid",
                )
                .values(status="paid", paid_at=_iso(now))
            )
            if result.rowcount:
                plan = self._plan_by_id(order["plan_id"]) if order.get("plan_id") else None
                if plan is not None:
                    # 会员套餐订单：激活会员，不加余额
                    self._grant_plan_in_conn(conn, user_id, plan, now)
                else:
                    amount_cents = int(order["amount_cents"])
                    conn.execute(
                        update(users)
                        .where(users.c.id == user_id)
                        .values(balance_cents=users.c.balance_cents + amount_cents)
                    )
                    balance_after = int(
                        conn.execute(select(users.c.balance_cents).where(users.c.id == user_id)).scalar_one()
                    )
                    conn.execute(
                        insert(billing_ledger).values(
                            id=str(uuid.uuid4()),
                            user_id=user_id,
                            type="recharge",
                            title=f"{_payment_method_title(order['method'])}充值",
                            amount_cents=amount_cents,
                            balance_after_cents=balance_after,
                            created_at=_iso(now),
                        )
                    )

            order = (
                conn.execute(
                    select(payment_orders).where(
                        payment_orders.c.user_id == user_id,
                        payment_orders.c.order_id == order_id,
                    )
                )
                .mappings()
                .one()
            )
        user = self.get_user(user_id)
        if user is None:
            raise ValueError("user not found")
        return _payment_order_from_row(order, "支付成功"), user

    def mark_recharge_paid_by_order_id(
        self, order_id: str, paid_amount_cents: int, *, manual: bool = False
    ) -> tuple[RechargeOrderResponse, UserOut]:
        """支付回调必须金额相符；仅管理员人工对账可显式跳过第三方金额字段。"""
        now = _now()
        with self.engine.begin() as conn:
            order = (
                conn.execute(
                    select(payment_orders).where(
                        payment_orders.c.order_id == order_id,
                    )
                )
                .mappings()
                .fetchone()
            )
            if order is None:
                raise ValueError("order not found")
            if order["status"] == "paid":
                user = self.get_user(order["user_id"])
                return _payment_order_from_row(order, "已支付"), user

            expected_amount_cents = int(order["amount_cents"])
            if not manual and paid_amount_cents != expected_amount_cents:
                raise ValueError("支付金额与订单金额不一致")
            amount_cents = expected_amount_cents
            result = conn.execute(
                update(payment_orders)
                .where(
                    payment_orders.c.order_id == order_id,
                    payment_orders.c.status != "paid",
                )
                .values(status="paid", paid_at=_iso(now))
            )
            if result.rowcount:
                plan = self._plan_by_id(order["plan_id"]) if order.get("plan_id") else None
                if plan is not None:
                    self._grant_plan_in_conn(conn, order["user_id"], plan, now)
                else:
                    conn.execute(
                        update(users)
                        .where(users.c.id == order["user_id"])
                        .values(balance_cents=users.c.balance_cents + amount_cents)
                    )
                    balance_after = int(
                        conn.execute(select(users.c.balance_cents).where(users.c.id == order["user_id"])).scalar_one()
                    )
                    conn.execute(
                        insert(billing_ledger).values(
                            id=str(uuid.uuid4()),
                            user_id=order["user_id"],
                            type="recharge",
                            title=f"{_payment_method_title(order['method'])}充值",
                            amount_cents=amount_cents,
                            balance_after_cents=balance_after,
                            created_at=_iso(now),
                        )
                    )

            order = (
                conn.execute(
                    select(payment_orders).where(payment_orders.c.order_id == order_id)
                )
                .mappings()
                .one()
            )
        user = self.get_user(order["user_id"])
        if user is None:
            raise ValueError("user not found")
        return _payment_order_from_row(order, "充值成功"), user

    def store_payment_webhook(
        self,
        order_id: str,
        provider: str,
        event_type: str,
        payload_json: str,
        signature: str | None = None,
    ) -> str:
        webhook_id = str(uuid.uuid4())
        now = _now()
        with self.engine.begin() as conn:
            conn.execute(
                insert(payment_webhooks).values(
                    id=webhook_id,
                    order_id=order_id,
                    provider=provider,
                    event_type=event_type,
                    payload_json=payload_json,
                    signature=signature,
                    status="received",
                    created_at=_iso(now),
                )
            )
        return webhook_id

    def mark_webhook_processed(self, webhook_id: str) -> None:
        now = _iso(_now())
        with self.engine.begin() as conn:
            conn.execute(
                update(payment_webhooks)
                .where(payment_webhooks.c.id == webhook_id)
                .values(status="processed", processed_at=now)
            )

    def mark_webhook_failed(self, webhook_id: str, error_message: str) -> None:
        now = _iso(_now())
        with self.engine.begin() as conn:
            conn.execute(
                update(payment_webhooks)
                .where(payment_webhooks.c.id == webhook_id)
                .values(status="failed", error_message=error_message[:500], processed_at=now)
            )

    def insert_transcripts(self, user_id: str, items: list[TranscriptItem]) -> int:
        """[已废弃] 原始对话不再入库。

        采集结束后由 /capture/upload/complete 直接交模型生成场景，原文只在上传过程中
        以临时文件存在、用完即删。本方法与 transcripts 表仅为兼容旧数据保留，已无调用方。
        """
        now = _now()
        rows = []
        for item in clean_transcript_items(items):
            timestamp = _utc(item.timestamp)
            retention_days = self.get_retention_days()
            if timestamp < now - timedelta(days=retention_days):
                continue
            expires_at = timestamp + timedelta(days=retention_days)
            rows.append(
                {
                    "id": item.id,
                    "user_id": user_id,
                    "timestamp": _iso(timestamp),
                    "text": item.text.strip(),
                    "created_at": _iso(now),
                    "expires_at": _iso(expires_at),
                }
            )

        if not rows:
            return 0

        with self.engine.begin() as conn:
            conn.execute(delete(transcripts).where(transcripts.c.id.in_([row["id"] for row in rows])))
            conn.execute(insert(transcripts), rows)
        return len(rows)

    def query_transcripts(self, user_id: str, start: datetime, end: datetime) -> list[TranscriptItem]:
        self.cleanup_expired()
        with self.engine.connect() as conn:
            rows = (
                conn.execute(
                    select(transcripts.c.id, transcripts.c.timestamp, transcripts.c.text)
                    .where(
                        transcripts.c.user_id == user_id,
                        transcripts.c.timestamp.between(_iso(_utc(start)), _iso(_utc(end))),
                    )
                    .order_by(transcripts.c.timestamp.asc())
                )
                .mappings()
                .fetchall()
            )
        return [
            TranscriptItem(id=row["id"], timestamp=_parse_dt(row["timestamp"]), text=row["text"])
            for row in rows
        ]

    def create_session(self, user_id: str, drills: list[DrillPrompt]) -> SessionRecord:
        session_id = str(uuid.uuid4())
        now = _now()
        items_json = json.dumps([item.model_dump() for item in drills], ensure_ascii=False)
        with self.engine.begin() as conn:
            conn.execute(
                insert(sessions).values(
                    session_id=session_id,
                    user_id=user_id,
                    status="active",
                    items_json=items_json,
                    item_index=0,
                    score=0,
                    created_at=_iso(now),
                )
            )
        return SessionRecord(
            session_id=session_id,
            user_id=user_id,
            status="active",
            items=drills,
            index=0,
            score=0,
            created_at=now,
        )

    def get_session(self, user_id: str, session_id: str) -> SessionRecord | None:
        with self.engine.connect() as conn:
            row = (
                conn.execute(
                    select(sessions).where(sessions.c.user_id == user_id, sessions.c.session_id == session_id)
                )
                .mappings()
                .fetchone()
            )
        return _session_from_row(row) if row else None

    def update_session(self, session: SessionRecord) -> None:
        with self.engine.begin() as conn:
            conn.execute(
                update(sessions)
                .where(sessions.c.session_id == session.session_id, sessions.c.user_id == session.user_id)
                .values(status=session.status, item_index=session.index, score=session.score)
            )

    def create_scenario(
        self,
        user_id: str,
        start: datetime,
        end: datetime,
        scenario: ScenarioResponse,
        source_hash: str | None = None,
        ephemeral: bool = False,
    ) -> ScenarioResponse:
        scene_id = str(uuid.uuid4())
        now = _now()
        expires_at = now + timedelta(days=self.get_history_retention_days())
        saved = scenario.model_copy(update={"scene_id": scene_id})
        with self.engine.begin() as conn:
            if source_hash:
                # 事务内再查一次：并发/重复提交（双路径或客户端重试）下若已有相同内容的未过期场景，
                # 直接返回它、不再重复插入——修复「一次采集生成两个场景」及连带的「要删两次」。
                dup = conn.execute(
                    select(scenarios).where(
                        scenarios.c.user_id == user_id,
                        scenarios.c.source_hash == source_hash,
                        scenarios.c.expires_at > _iso(now),
                    ).order_by(scenarios.c.created_at.desc())
                ).mappings().fetchone()
                if dup is not None:
                    return _scenario_from_row(dup)
            conn.execute(
                insert(scenarios).values(
                    scene_id=scene_id,
                    user_id=user_id,
                    title=saved.title,
                    summary=saved.summary,
                    roles_json=json.dumps([item.model_dump() for item in saved.roles], ensure_ascii=False),
                    lines_json=json.dumps([item.model_dump() for item in saved.lines], ensure_ascii=False),
                    expressions_json=json.dumps(
                        [item.model_dump() for item in saved.expressions],
                        ensure_ascii=False,
                    ),
                    source_start=_iso(start),
                    source_end=_iso(end),
                    created_at=_iso(now),
                    expires_at=_iso(expires_at),
                    source_hash=source_hash,
                    ephemeral=1 if ephemeral else 0,
                )
            )
        return saved

    def purge_ephemeral_scenarios(self, user_id: str) -> int:
        """清理该用户的临时（通用场景）记录：连带级联删除其对练会话/消息。

        通用场景只供试练、不入「今天/历史」列表；生成新的之前先清掉旧的，避免任何累积。
        """
        with self.engine.begin() as conn:
            result = conn.execute(
                delete(scenarios).where(
                    scenarios.c.user_id == user_id,
                    scenarios.c.ephemeral == 1,
                )
            )
        return result.rowcount or 0

    # ---- 通用场景（运维在管理台预置的全局场景，全体用户可见可练；与用户自己的场景同表、同对话流程）----

    PRESET_OWNER_ID = "__preset_system__"

    def _ensure_preset_owner(self) -> None:
        """确保预置场景的归属系统用户存在（scenarios.user_id 外键需指向有效用户）。"""
        with self.engine.begin() as conn:
            exists = conn.execute(
                select(users.c.id).where(users.c.id == self.PRESET_OWNER_ID)
            ).fetchone()
            if exists is None:
                conn.execute(
                    insert(users).values(
                        id=self.PRESET_OWNER_ID,
                        login_identifier=self.PRESET_OWNER_ID,
                        password_salt="",
                        password_hash="",
                        plan="free",
                        balance_cents=0,
                        created_at=_iso(_now()),
                        is_banned=1,  # 系统占位用户，禁止登录
                    )
                )

    def create_preset_scenario(
        self,
        group: str,
        title: str,
        scenario: ScenarioResponse,
        sort: int = 0,
    ) -> ScenarioResponse:
        """新建一条全局预置场景（运维管理台用）。内容格式与用户自采集场景完全一致。"""
        scene_id = str(uuid.uuid4())
        now = _now()
        far_future = now + timedelta(days=3650)  # 预置场景不随用户场景过期
        saved = scenario.model_copy(update={"scene_id": scene_id})
        with self.engine.begin() as conn:
            conn.execute(
                insert(scenarios).values(
                    scene_id=scene_id,
                    user_id=self.PRESET_OWNER_ID,
                    title=title or saved.title,
                    summary=saved.summary,
                    roles_json=json.dumps([item.model_dump() for item in saved.roles], ensure_ascii=False),
                    lines_json=json.dumps([item.model_dump() for item in saved.lines], ensure_ascii=False),
                    expressions_json=json.dumps([item.model_dump() for item in saved.expressions], ensure_ascii=False),
                    source_start=_iso(now),
                    source_end=_iso(now),
                    created_at=_iso(now),
                    expires_at=_iso(far_future),
                    source_hash=None,
                    ephemeral=0,
                    is_preset=1,
                    preset_group=group or "",
                    preset_sort=sort,
                )
            )
        return saved.model_copy(update={"title": title or saved.title})

    def update_preset_scenario(
        self,
        scene_id: str,
        group: str,
        title: str,
        scenario: ScenarioResponse,
        sort: int = 0,
    ) -> bool:
        with self.engine.begin() as conn:
            result = conn.execute(
                update(scenarios)
                .where(scenarios.c.scene_id == scene_id, scenarios.c.is_preset == 1)
                .values(
                    title=title or scenario.title,
                    summary=scenario.summary,
                    roles_json=json.dumps([item.model_dump() for item in scenario.roles], ensure_ascii=False),
                    lines_json=json.dumps([item.model_dump() for item in scenario.lines], ensure_ascii=False),
                    expressions_json=json.dumps([item.model_dump() for item in scenario.expressions], ensure_ascii=False),
                    preset_group=group or "",
                    preset_sort=sort,
                )
            )
        return (result.rowcount or 0) > 0

    def delete_preset_scenario(self, scene_id: str) -> bool:
        with self.engine.begin() as conn:
            result = conn.execute(
                delete(scenarios).where(scenarios.c.scene_id == scene_id, scenarios.c.is_preset == 1)
            )
        return (result.rowcount or 0) > 0

    def delete_scenario(self, user_id: str, scene_id: str) -> bool:
        """删除用户自己的场景（不可删全局预置场景）；连带级联删除其对练会话/消息/结果。"""
        with self.engine.begin() as conn:
            result = conn.execute(
                delete(scenarios).where(
                    scenarios.c.scene_id == scene_id,
                    scenarios.c.user_id == user_id,
                    scenarios.c.is_preset == 0,
                )
            )
        return (result.rowcount or 0) > 0

    def list_preset_scenarios(self) -> list[dict[str, Any]]:
        """全部预置场景（含完整内容），按分组与排序返回，供管理台编辑与用户端展示。"""
        stmt = (
            select(scenarios)
            .where(scenarios.c.is_preset == 1)
            .order_by(scenarios.c.preset_group, scenarios.c.preset_sort, scenarios.c.created_at)
        )
        with self.engine.connect() as conn:
            rows = conn.execute(stmt).mappings().fetchall()
        items: list[dict[str, Any]] = []
        for row in rows:
            lines = json.loads(row["lines_json"])
            items.append(
                {
                    "scene_id": row["scene_id"],
                    "group": row["preset_group"] or "",
                    "title": row["title"],
                    "summary": row["summary"],
                    "roles": json.loads(row["roles_json"]),
                    "lines": lines,
                    "expressions": json.loads(row["expressions_json"]),
                    "line_count": len(lines),
                    "sort": int(row["preset_sort"] or 0),
                }
            )
        return items

    def list_unpracticed_scenarios(self, user_id: str, limit: int = 8) -> list[dict[str, str]]:
        """私教场景感知：用户自己生成、还没真正开练过（无任何有得分对练会话）的场景，最新优先。
        返回轻量字段（scene_id/title/summary），注入私教提示词供其主动邀练。"""
        items = self.list_scenarios(user_id, limit=30)
        if not items:
            return []
        scores = self.last_practice_scores(user_id, [it["scene_id"] for it in items])
        out: list[dict[str, str]] = []
        for it in items:
            st = scores.get(it["scene_id"]) or {}
            if "score" in st or st.get("completed"):
                continue   # 有得分/完成记录 = 练过
            out.append({"scene_id": it["scene_id"], "title": it["title"], "summary": it.get("summary") or ""})
            if len(out) >= limit:
                break
        return out

    def last_practice_scores(self, user_id: str, scene_ids: list[str]) -> dict[str, dict[str, Any]]:
        """各场景该用户的：①「最近一次有得分的对练」分数/是否完成/时间（场景卡展示上次成绩）；
        ②「最近一个未完成(active)会话」是否可继续 + 会话 id + 已练句数（场景卡展示「继续/重新开始」）。
        两者分别取，互不覆盖：刚新建尚无得分的会话不会把历史成绩清零。"""
        if not scene_ids:
            return {}
        stmt = (
            select(
                roleplay_sessions.c.scene_id,
                roleplay_sessions.c.session_id,
                roleplay_sessions.c.score_total,
                roleplay_sessions.c.turns,
                roleplay_sessions.c.status,
                roleplay_sessions.c.updated_at,
            )
            .where(
                roleplay_sessions.c.user_id == user_id,
                roleplay_sessions.c.scene_id.in_(scene_ids),
            )
            .order_by(roleplay_sessions.c.updated_at.desc())
        )
        scored: dict[str, dict[str, Any]] = {}   # 最近一次有得分（turns>0）
        resume: dict[str, dict[str, Any]] = {}   # 最近一个未完成（active）
        with self.engine.connect() as conn:
            for row in conn.execute(stmt).mappings():
                sid = row["scene_id"]
                turns = int(row["turns"] or 0)
                if turns > 0 and sid not in scored:
                    scored[sid] = {
                        "score": round((float(row["score_total"]) / turns) * 100),
                        "completed": row["status"] == "completed",
                        "at": _parse_dt(row["updated_at"]),
                    }
                if row["status"] == "active" and sid not in resume:
                    resume[sid] = {"resume_session_id": row["session_id"], "resume_progress": turns}
        result: dict[str, dict[str, Any]] = {}
        for sid in set(scored) | set(resume):
            entry = dict(scored.get(sid, {}))
            if sid in resume:
                entry["in_progress"] = True
                entry.update(resume[sid])
            result[sid] = entry
        return result

    def get_resumable_roleplay_session(
        self, user_id: str, scene_id: str, selected_role: str
    ) -> RoleplaySessionRecord | None:
        """同场景+同角色「最近一个未完成(active)」会话，用于「继续上次进度」。"""
        with self.engine.connect() as conn:
            row = (
                conn.execute(
                    select(roleplay_sessions)
                    .where(
                        roleplay_sessions.c.user_id == user_id,
                        roleplay_sessions.c.scene_id == scene_id,
                        roleplay_sessions.c.selected_role == selected_role,
                        roleplay_sessions.c.status == "active",
                    )
                    .order_by(roleplay_sessions.c.updated_at.desc())
                    .limit(1)
                )
                .mappings()
                .fetchone()
            )
        return _roleplay_session_from_row(row) if row else None

    def abandon_active_roleplay_sessions(
        self, user_id: str, scene_id: str, selected_role: str, except_session_id: str | None = None
    ) -> int:
        """「重新开始」时把该场景+角色旧的未完成会话置为 abandoned，
        保证「可继续」只指向最新那一个（旧进度仍按场景留存期随级联清理）。"""
        stmt = update(roleplay_sessions).where(
            roleplay_sessions.c.user_id == user_id,
            roleplay_sessions.c.scene_id == scene_id,
            roleplay_sessions.c.selected_role == selected_role,
            roleplay_sessions.c.status == "active",
        )
        if except_session_id:
            stmt = stmt.where(roleplay_sessions.c.session_id != except_session_id)
        with self.engine.begin() as conn:
            result = conn.execute(stmt.values(status="abandoned", updated_at=_iso(_now())))
        return result.rowcount or 0

    def find_scenario_by_source_hash(self, user_id: str, source_hash: str) -> ScenarioResponse | None:
        """按采集内容哈希查已生成的未过期场景，用于幂等去重（重复上传不再重复生成）。"""
        if not source_hash:
            return None
        now_iso = _iso(_now())
        with self.engine.connect() as conn:
            row = conn.execute(
                select(scenarios).where(
                    scenarios.c.user_id == user_id,
                    scenarios.c.source_hash == source_hash,
                    scenarios.c.expires_at > now_iso,
                ).order_by(scenarios.c.created_at.desc())
            ).mappings().fetchone()
        return _scenario_from_row(row) if row else None

    def get_scenario(self, user_id: str, scene_id: str) -> ScenarioResponse | None:
        # 既能取用户自己的场景，也能取全局预置场景（通用场景），二者对练流程完全一致
        with self.engine.connect() as conn:
            row = (
                conn.execute(
                    select(scenarios).where(
                        scenarios.c.scene_id == scene_id,
                        or_(scenarios.c.user_id == user_id, scenarios.c.is_preset == 1),
                    )
                )
                .mappings()
                .fetchone()
            )
        return _scenario_from_row(row) if row else None

    def list_scenarios(
        self,
        user_id: str,
        start: datetime | None = None,
        end: datetime | None = None,
        limit: int = 50,
    ) -> list[dict[str, Any]]:
        stmt = (
            select(scenarios)
            .where(scenarios.c.user_id == user_id, scenarios.c.ephemeral == 0, scenarios.c.is_preset == 0)
            .order_by(scenarios.c.created_at.desc())
            .limit(limit)
        )
        if start is not None:
            stmt = stmt.where(scenarios.c.created_at >= _iso(start))
        if end is not None:
            stmt = stmt.where(scenarios.c.created_at < _iso(end))
        with self.engine.connect() as conn:
            rows = conn.execute(stmt).mappings().fetchall()
        items: list[dict[str, Any]] = []
        for row in rows:
            roles = [ScenarioRole(**item) for item in json.loads(row["roles_json"])]
            lines = json.loads(row["lines_json"])
            items.append(
                {
                    "scene_id": row["scene_id"],
                    "title": row["title"],
                    "summary": row["summary"],
                    "roles": [role.model_dump() for role in roles],
                    "line_count": len(lines),
                    "source_start": _parse_dt(row["source_start"]),
                    "source_end": _parse_dt(row["source_end"]),
                    "created_at": _parse_dt(row["created_at"]),
                }
            )
        return items

    def record_ai_usage(
        self,
        user_id: str | None,
        kind: str,
        model: str,
        prompt_tokens: int,
        completion_tokens: int,
        cost_cents: float,
        latency_ms: int,
    ) -> None:
        now = _now()
        with self.engine.begin() as conn:
            conn.execute(
                insert(ai_usage).values(
                    id=str(uuid.uuid4()),
                    user_id=user_id,
                    kind=kind,
                    model=model,
                    prompt_tokens=prompt_tokens,
                    completion_tokens=completion_tokens,
                    total_tokens=prompt_tokens + completion_tokens,
                    cost_cents=cost_cents,
                    latency_ms=latency_ms,
                    created_at=_iso(now),
                )
            )

    def create_roleplay_session(
        self,
        user_id: str,
        scene_id: str,
        selected_role: str,
        ai_role: str,
    ) -> RoleplaySessionRecord:
        session_id = str(uuid.uuid4())
        now = _now()
        with self.engine.begin() as conn:
            conn.execute(
                insert(roleplay_sessions).values(
                    session_id=session_id,
                    user_id=user_id,
                    scene_id=scene_id,
                    selected_role=selected_role,
                    ai_role=ai_role,
                    status="active",
                    target_index=0,
                    turns=0,
                    score_total=0,
                    created_at=_iso(now),
                    updated_at=_iso(now),
                )
            )
        return RoleplaySessionRecord(
            session_id=session_id,
            user_id=user_id,
            scene_id=scene_id,
            selected_role=selected_role,
            ai_role=ai_role,
            status="active",
            target_index=0,
            turns=0,
            score_total=0,
            created_at=now,
            updated_at=now,
        )

    def get_roleplay_session(self, user_id: str, session_id: str) -> RoleplaySessionRecord | None:
        with self.engine.connect() as conn:
            row = (
                conn.execute(
                    select(roleplay_sessions).where(
                        roleplay_sessions.c.user_id == user_id,
                        roleplay_sessions.c.session_id == session_id,
                    )
                )
                .mappings()
                .fetchone()
            )
        return _roleplay_session_from_row(row) if row else None

    def update_roleplay_session(self, session: RoleplaySessionRecord) -> RoleplaySessionRecord:
        session.updated_at = _now()
        with self.engine.begin() as conn:
            conn.execute(
                update(roleplay_sessions)
                .where(
                    roleplay_sessions.c.user_id == session.user_id,
                    roleplay_sessions.c.session_id == session.session_id,
                )
                .values(
                    status=session.status,
                    target_index=session.target_index,
                    turns=session.turns,
                    score_total=session.score_total,
                    updated_at=_iso(session.updated_at),
                )
            )
        return session

    def add_roleplay_message(
        self,
        user_id: str,
        session_id: str,
        speaker: str,
        role: str,
        content: str,
        translation: str | None = None,
        feedback: str | None = None,
    ) -> RoleplayMessageOut:
        message_id = str(uuid.uuid4())
        now = _now()
        with self.engine.begin() as conn:
            conn.execute(
                insert(roleplay_messages).values(
                    id=message_id,
                    session_id=session_id,
                    user_id=user_id,
                    speaker=speaker,
                    role=role,
                    content=content,
                    translation=translation,
                    feedback=feedback,
                    created_at=_iso(now),
                )
            )
        return RoleplayMessageOut(
            id=message_id,
            speaker=speaker,
            role=role,
            content=content,
            translation=translation,
            feedback=feedback,
            created_at=now,
        )

    def list_roleplay_messages(self, user_id: str, session_id: str) -> list[RoleplayMessageOut]:
        with self.engine.connect() as conn:
            rows = (
                conn.execute(
                    select(roleplay_messages)
                    .where(
                        roleplay_messages.c.user_id == user_id,
                        roleplay_messages.c.session_id == session_id,
                    )
                    .order_by(roleplay_messages.c.created_at.asc())
                )
                .mappings()
                .fetchall()
            )
        return [_message_from_row(row) for row in rows]

    # ---- 自由对话（一对一语音老师）----

    _FREETALK_KEEP_MESSAGES = 200   # 每用户最多保留的历史条数（超过删最旧，字幕回放/上下文都用不到更早的）

    def add_freetalk_message(self, user_id: str, speaker: str, content: str, tone: str = "") -> None:
        now = _iso(_now())
        with self.engine.begin() as conn:
            conn.execute(
                insert(freetalk_messages).values(
                    id=str(uuid.uuid4()), user_id=user_id, speaker=speaker, content=content,
                    tone=(tone or "")[:40], created_at=now,
                )
            )
            # 裁剪：只留最近 N 条（按时间删最旧）
            old = conn.execute(
                select(freetalk_messages.c.id)
                .where(freetalk_messages.c.user_id == user_id)
                .order_by(freetalk_messages.c.created_at.desc())
                .offset(self._FREETALK_KEEP_MESSAGES)
            ).fetchall()
            if old:
                conn.execute(delete(freetalk_messages).where(freetalk_messages.c.id.in_([r[0] for r in old])))

    def apply_light_migrations(self) -> None:
        """追加型小迁移（只加列，幂等、多活安全）：API 启动时自动执行，
        升级镜像后无需手动去装库节点跑 db_init。破坏性变更仍必须走 db_init。"""
        try:
            with self.engine.begin() as conn:
                self._ensure_column(conn, "freetalk_messages", "tone", "TEXT NOT NULL DEFAULT ''")
        except Exception as exc:  # noqa: BLE001 — 迁移失败要醒目留日志，但不阻断启动（列缺失时写入会再报错）
            print(f"[db] 轻量迁移失败：{str(exc)[:200]}", flush=True)

    def clear_freetalk_messages(self, user_id: str) -> int:
        """清空该用户的私教/自由对话聊天记录（设置页「清除聊天记录」）。返回删除条数。"""
        with self.engine.begin() as conn:
            result = conn.execute(delete(freetalk_messages).where(freetalk_messages.c.user_id == user_id))
        return int(result.rowcount or 0)

    def list_freetalk_messages(self, user_id: str, limit: int = 30) -> list[dict[str, str]]:
        """最近 limit 条（时间正序返回），供上下文与开场字幕回放。"""
        with self.engine.connect() as conn:
            rows = (
                conn.execute(
                    select(freetalk_messages)
                    .where(freetalk_messages.c.user_id == user_id)
                    .order_by(freetalk_messages.c.created_at.desc())
                    .limit(limit)
                )
                .mappings()
                .fetchall()
            )
        return [{"speaker": r["speaker"], "content": r["content"], "tone": r["tone"] or ""} for r in reversed(rows)]

    # ---- 学习提醒（智能电话）----

    def dismiss_reminder(self, user_id: str, scene_id: str) -> None:
        """该场景不再来电提醒（用户挂断/暂不练习）。幂等：重复调用不报错。"""
        now = _iso(_now())
        try:
            with self.engine.begin() as conn:
                conn.execute(insert(reminder_dismissed).values(user_id=user_id, scene_id=scene_id, created_at=now))
        except DatabaseIntegrityError:
            pass

    def list_dismissed_reminders(self, user_id: str) -> set[str]:
        with self.engine.connect() as conn:
            rows = conn.execute(
                select(reminder_dismissed.c.scene_id).where(reminder_dismissed.c.user_id == user_id)
            ).fetchall()
        return {r[0] for r in rows}

    def get_user_memory(self, user_id: str) -> str:
        with self.engine.connect() as conn:
            row = conn.execute(select(user_memory.c.content).where(user_memory.c.user_id == user_id)).fetchone()
        return row[0] if row else ""

    def set_user_memory(self, user_id: str, content: str) -> None:
        now = _iso(_now())
        with self.engine.begin() as conn:
            updated = conn.execute(
                update(user_memory).where(user_memory.c.user_id == user_id).values(content=content, updated_at=now)
            )
            if (updated.rowcount or 0) == 0:
                conn.execute(insert(user_memory).values(user_id=user_id, content=content, updated_at=now))

    def add_practice_result(
        self,
        user_id: str,
        session_id: str,
        scene_id: str,
        line_index: int,
        expected_text: str,
        user_text: str,
        score: float,
        feedback: str,
        dim_pronunciation: int = 0,
        dim_grammar: int = 0,
        dim_naturalness: int = 0,
        dim_vocabulary: int = 0,
    ) -> None:
        now = _now()
        with self.engine.begin() as conn:
            conn.execute(
                insert(practice_results).values(
                    id=str(uuid.uuid4()),
                    session_id=session_id,
                    user_id=user_id,
                    scene_id=scene_id,
                    line_index=line_index,
                    expected_text=expected_text,
                    user_text=user_text,
                    score=score,
                    feedback=feedback,
                    created_at=_iso(now),
                    dim_pronunciation=int(dim_pronunciation),
                    dim_grammar=int(dim_grammar),
                    dim_naturalness=int(dim_naturalness),
                    dim_vocabulary=int(dim_vocabulary),
                )
            )

    def aggregate_session_dims(self, session_id: str) -> dict[str, int]:
        """把一次会话的四维分聚合成场景级掌握信号：每个 line 取历次尝试中综合分最高的一次，
        再对四维求平均（反映用户「最终把每句练到多好」，而非把重试的低分也算进去）。"""
        with self.engine.connect() as conn:
            rows = (
                conn.execute(
                    select(
                        practice_results.c.line_index,
                        practice_results.c.score,
                        practice_results.c.dim_pronunciation,
                        practice_results.c.dim_grammar,
                        practice_results.c.dim_naturalness,
                        practice_results.c.dim_vocabulary,
                    ).where(practice_results.c.session_id == session_id)
                )
                .mappings()
                .fetchall()
            )
        best: dict[int, Mapping[str, Any]] = {}
        for r in rows:
            li = r["line_index"]
            if li not in best or (r["score"] or 0) > (best[li]["score"] or 0):
                best[li] = r
        if not best:
            return {"pronunciation": 0, "grammar": 0, "naturalness": 0, "vocabulary": 0}
        n = len(best)
        def avg(col: str) -> int:
            return round(sum(int(r[col] or 0) for r in best.values()) / n)
        return {
            "pronunciation": avg("dim_pronunciation"),
            "grammar": avg("dim_grammar"),
            "naturalness": avg("dim_naturalness"),
            "vocabulary": avg("dim_vocabulary"),
        }

    def upsert_scene_mastery(
        self,
        user_id: str,
        scene_id: str,
        dims: dict[str, int],
        overall: float,
        mastered: bool,
        next_review_at: str,
    ) -> None:
        now = _iso(_now())
        with self.engine.begin() as conn:
            existing = (
                conn.execute(
                    select(scene_mastery.c.attempts, scene_mastery.c.best_overall).where(
                        scene_mastery.c.user_id == user_id,
                        scene_mastery.c.scene_id == scene_id,
                    )
                )
                .mappings()
                .fetchone()
            )
            values = dict(
                attempts=(int(existing["attempts"]) + 1) if existing else 1,
                mastered=1 if mastered else 0,
                last_pronunciation=int(dims.get("pronunciation", 0)),
                last_grammar=int(dims.get("grammar", 0)),
                last_naturalness=int(dims.get("naturalness", 0)),
                last_vocabulary=int(dims.get("vocabulary", 0)),
                best_overall=max(float(overall), float(existing["best_overall"])) if existing else float(overall),
                last_practiced_at=now,
                next_review_at=next_review_at,
                updated_at=now,
            )
            if existing:
                conn.execute(
                    update(scene_mastery)
                    .where(scene_mastery.c.user_id == user_id, scene_mastery.c.scene_id == scene_id)
                    .values(**values)
                )
            else:
                conn.execute(
                    insert(scene_mastery).values(
                        user_id=user_id, scene_id=scene_id, created_at=now, **values
                    )
                )

    def _scene_mastery_from_row(self, r: Mapping[str, Any]) -> SceneMasteryRecord:
        return SceneMasteryRecord(
            user_id=r["user_id"],
            scene_id=r["scene_id"],
            attempts=int(r["attempts"]),
            mastered=bool(r["mastered"]),
            last_pronunciation=int(r["last_pronunciation"]),
            last_grammar=int(r["last_grammar"]),
            last_naturalness=int(r["last_naturalness"]),
            last_vocabulary=int(r["last_vocabulary"]),
            best_overall=float(r["best_overall"]),
            last_practiced_at=_parse_dt(r["last_practiced_at"]),
            next_review_at=_parse_dt(r["next_review_at"]),
        )

    def list_scene_mastery(self, user_id: str) -> list[SceneMasteryRecord]:
        with self.engine.connect() as conn:
            rows = (
                conn.execute(select(scene_mastery).where(scene_mastery.c.user_id == user_id))
                .mappings()
                .fetchall()
            )
        return [self._scene_mastery_from_row(r) for r in rows]

    def get_scene_mastery(self, user_id: str, scene_id: str) -> SceneMasteryRecord | None:
        with self.engine.connect() as conn:
            row = (
                conn.execute(
                    select(scene_mastery).where(
                        scene_mastery.c.user_id == user_id,
                        scene_mastery.c.scene_id == scene_id,
                    )
                )
                .mappings()
                .fetchone()
            )
        return self._scene_mastery_from_row(row) if row else None

    def has_rejected_practice_attempt(
        self,
        user_id: str,
        session_id: str,
        line_index: int,
        accept_score: float,
    ) -> bool:
        with self.engine.connect() as conn:
            row = (
                conn.execute(
                    select(practice_results.c.id)
                    .where(
                        practice_results.c.user_id == user_id,
                        practice_results.c.session_id == session_id,
                        practice_results.c.line_index == line_index,
                        practice_results.c.score < accept_score,
                    )
                    .limit(1)
                )
                .mappings()
                .fetchone()
            )
        return row is not None

    def list_practice_history(self, user_id: str, limit: int = 20) -> list[PracticeHistoryItem]:
        with self.engine.connect() as conn:
            rows = (
                conn.execute(
                    select(
                        roleplay_sessions.c.session_id,
                        roleplay_sessions.c.scene_id,
                        scenarios.c.title,
                        roleplay_sessions.c.selected_role,
                        roleplay_sessions.c.status,
                        roleplay_sessions.c.turns,
                        roleplay_sessions.c.score_total,
                        roleplay_sessions.c.created_at,
                        roleplay_sessions.c.updated_at,
                        scenarios.c.lines_json,
                    )
                    .join(scenarios, scenarios.c.scene_id == roleplay_sessions.c.scene_id)
                    .where(roleplay_sessions.c.user_id == user_id, scenarios.c.ephemeral == 0)
                    .order_by(roleplay_sessions.c.updated_at.desc())
                    .limit(limit)
                )
                .mappings()
                .fetchall()
            )

        items: list[PracticeHistoryItem] = []
        for row in rows:
            lines = [SceneLine(**item) for item in json.loads(row["lines_json"])]
            total = sum(1 for line in lines if line.target_role == row["selected_role"])
            turns = int(row["turns"])
            average_score = round(float(row["score_total"]) / turns, 3) if turns else 0
            items.append(
                PracticeHistoryItem(
                    session_id=row["session_id"],
                    scene_id=row["scene_id"],
                    title=row["title"],
                    selected_role=row["selected_role"],
                    status=row["status"],
                    turns=turns,
                    total=total,
                    score=average_score,
                    created_at=_parse_dt(row["created_at"]),
                    updated_at=_parse_dt(row["updated_at"]),
                )
            )
        return items

    def admin_overview(self) -> dict[str, Any]:
        online_window_minutes = self.get_online_window_minutes()
        online_since = _iso(_now() - timedelta(minutes=online_window_minutes))
        with self.engine.connect() as conn:
            total_users = int(conn.execute(select(func.count()).select_from(users)).scalar_one() or 0)
            banned_users = int(
                conn.execute(select(func.count()).select_from(users).where(users.c.is_banned == 1)).scalar_one() or 0
            )
            online_users = int(
                conn.execute(
                    select(func.count())
                    .select_from(users)
                    .where(users.c.is_banned == 0, users.c.last_seen_at >= online_since)
                ).scalar_one() or 0
            )
            total_balance_cents = int(
                conn.execute(select(func.coalesce(func.sum(users.c.balance_cents), 0))).scalar_one() or 0
            )
            paid_recharge_cents = int(
                conn.execute(
                    select(func.coalesce(func.sum(payment_orders.c.amount_cents), 0))
                    .where(payment_orders.c.status == "paid")
                ).scalar_one() or 0
            )
            pending_recharge_cents = int(
                conn.execute(
                    select(func.coalesce(func.sum(payment_orders.c.amount_cents), 0))
                    .where(payment_orders.c.status == "pending")
                ).scalar_one() or 0
            )
            paid_orders = int(
                conn.execute(
                    select(func.count()).select_from(payment_orders).where(payment_orders.c.status == "paid")
                ).scalar_one() or 0
            )
            roleplay_session_count = int(
                conn.execute(select(func.count()).select_from(roleplay_sessions)).scalar_one() or 0
            )
            practice_result_count = int(
                conn.execute(select(func.count()).select_from(practice_results)).scalar_one() or 0
            )
            transcript_count = int(conn.execute(select(func.count()).select_from(transcripts)).scalar_one() or 0)
            today_start = _iso(_now().replace(hour=0, minute=0, second=0, microsecond=0))
            today_revenue_cents = int(
                conn.execute(
                    select(func.coalesce(func.sum(payment_orders.c.amount_cents), 0)).where(
                        payment_orders.c.status == "paid",
                        payment_orders.c.paid_at >= today_start,
                    )
                ).scalar_one() or 0
            )
            today_new_users = int(
                conn.execute(
                    select(func.count()).select_from(users).where(users.c.created_at >= today_start)
                ).scalar_one() or 0
            )
            ai_calls = int(conn.execute(select(func.count()).select_from(ai_usage)).scalar_one() or 0)
            ai_total_tokens = int(
                conn.execute(select(func.coalesce(func.sum(ai_usage.c.total_tokens), 0))).scalar_one() or 0
            )
            ai_cost_cents = float(
                conn.execute(select(func.coalesce(func.sum(ai_usage.c.cost_cents), 0))).scalar_one() or 0
            )
            ai_cost_today_cents = float(
                conn.execute(
                    select(func.coalesce(func.sum(ai_usage.c.cost_cents), 0)).where(
                        ai_usage.c.created_at >= today_start
                    )
                ).scalar_one() or 0
            )
        return {
            "total_users": total_users,
            "banned_users": banned_users,
            "online_users": online_users,
            "online_window_minutes": online_window_minutes,
            "total_balance_cents": total_balance_cents,
            "paid_recharge_cents": paid_recharge_cents,
            "pending_recharge_cents": pending_recharge_cents,
            "paid_orders": paid_orders,
            "roleplay_session_count": roleplay_session_count,
            "practice_result_count": practice_result_count,
            "transcript_count": transcript_count,
            "monthly_price_cents": self.get_monthly_price_cents(),
            "today_revenue_cents": today_revenue_cents,
            "today_new_users": today_new_users,
            "ai_calls": ai_calls,
            "ai_total_tokens": ai_total_tokens,
            "ai_cost_cents": round(ai_cost_cents, 2),
            "ai_cost_today_cents": round(ai_cost_today_cents, 2),
            "gross_margin_cents": round(paid_recharge_cents - ai_cost_cents, 2),
        }

    def admin_stats_timeseries(self, days: int = 30) -> dict[str, Any]:
        start = (_now() - timedelta(days=days - 1)).replace(hour=0, minute=0, second=0, microsecond=0)
        start_iso = _iso(start)
        # 在 Python 里按天分桶，避免依赖任何数据库方言的日期函数（跨 SQLite/PostgreSQL 一致）
        new_users: dict[str, int] = {}
        revenue: dict[str, int] = {}
        ai_cost: dict[str, float] = {}
        ai_calls: dict[str, int] = {}
        sessions_created: dict[str, int] = {}

        def bucket_count(target: dict, value: str | None) -> None:
            if not value:
                return
            day = str(value)[:10]
            target[day] = target.get(day, 0) + 1

        def bucket_sum(target: dict, value: str | None, amount) -> None:
            if not value:
                return
            day = str(value)[:10]
            target[day] = target.get(day, 0) + (amount or 0)

        try:
            with self.engine.connect() as conn:
                for (created_at,) in conn.execute(
                    select(users.c.created_at).where(users.c.created_at >= start_iso)
                ):
                    bucket_count(new_users, created_at)
                for paid_at, amount in conn.execute(
                    select(payment_orders.c.paid_at, payment_orders.c.amount_cents)
                    .where(payment_orders.c.status == "paid", payment_orders.c.paid_at >= start_iso)
                ):
                    bucket_sum(revenue, paid_at, int(amount or 0))
                for created_at, cost in conn.execute(
                    select(ai_usage.c.created_at, ai_usage.c.cost_cents).where(ai_usage.c.created_at >= start_iso)
                ):
                    bucket_count(ai_calls, created_at)
                    bucket_sum(ai_cost, created_at, float(cost or 0))
                for (created_at,) in conn.execute(
                    select(roleplay_sessions.c.created_at).where(roleplay_sessions.c.created_at >= start_iso)
                ):
                    bucket_count(sessions_created, created_at)
        except Exception as exc:  # noqa: BLE001 — 仪表盘不能因统计异常而 500，返回零序列并记日志
            print(f"[stats] admin_stats_timeseries 失败：{exc}", flush=True)

        items = []
        for offset in range(days):
            day = (start + timedelta(days=offset)).date().isoformat()
            items.append(
                {
                    "date": day,
                    "new_users": int(new_users.get(day, 0)),
                    "revenue_cents": int(revenue.get(day, 0)),
                    "ai_cost_cents": round(float(ai_cost.get(day, 0)), 2),
                    "ai_calls": int(ai_calls.get(day, 0)),
                    "roleplay_sessions": int(sessions_created.get(day, 0)),
                }
            )
        return {"days": days, "items": items}

    def admin_list_orders(
        self,
        limit: int = 50,
        offset: int = 0,
        status: str | None = None,
        method: str | None = None,
        query: str | None = None,
    ) -> dict[str, Any]:
        stmt = (
            select(payment_orders, users.c.display_name, users.c.login_identifier)
            .join(users, users.c.id == payment_orders.c.user_id, isouter=True)
            .order_by(payment_orders.c.created_at.desc())
        )
        count_stmt = (
            select(func.count())
            .select_from(payment_orders)
            .join(users, users.c.id == payment_orders.c.user_id, isouter=True)
        )
        if status:
            stmt = stmt.where(payment_orders.c.status == status)
            count_stmt = count_stmt.where(payment_orders.c.status == status)
        if method:
            stmt = stmt.where(payment_orders.c.method == method)
            count_stmt = count_stmt.where(payment_orders.c.method == method)
        if query:
            pattern = f"%{query.strip()}%"
            cond = or_(
                payment_orders.c.order_id.like(pattern),
                payment_orders.c.user_id.like(pattern),
                users.c.login_identifier.like(pattern),   # 短码+邮箱前缀场景：用「前半段」也能搜到
                users.c.display_name.like(pattern),
            )
            stmt = stmt.where(cond)
            count_stmt = count_stmt.where(cond)
        with self.engine.connect() as conn:
            total = int(conn.execute(count_stmt).scalar_one() or 0)
            rows = conn.execute(stmt.limit(limit).offset(offset)).mappings().fetchall()
        items = []
        for row in rows:
            item = _payment_order_dict(row)
            item["user_display_name"] = row.get("display_name")
            item["user_login_identifier"] = row.get("login_identifier")
            items.append(item)
        return {"items": items, "total": total, "limit": limit, "offset": offset}

    def admin_list_users(self, limit: int = 100, query: str | None = None) -> list[dict[str, Any]]:
        # 排除预置场景归属的系统占位用户（__preset_system__），它不是真实用户
        stmt = select(users).where(users.c.id != self.PRESET_OWNER_ID).order_by(users.c.created_at.desc()).limit(limit)
        if query:
            pattern = f"%{query.strip()}%"
            stmt = stmt.where(
                or_(
                    users.c.id.like(pattern),
                    users.c.login_identifier.like(pattern),
                    users.c.display_name.like(pattern),
                    users.c.wechat_openid.like(pattern),
                )
            )
        with self.engine.connect() as conn:
            rows = conn.execute(stmt).mappings().fetchall()
        return [_admin_user_from_row(row) for row in rows]

    def admin_get_user_detail(self, user_id: str) -> dict[str, Any] | None:
        row = self.get_user_row(user_id)
        if row is None:
            return None
        with self.engine.connect() as conn:
            transcript_count = int(
                conn.execute(select(func.count()).select_from(transcripts).where(transcripts.c.user_id == user_id))
                .scalar_one() or 0
            )
            scenario_count = int(
                conn.execute(select(func.count()).select_from(scenarios).where(scenarios.c.user_id == user_id))
                .scalar_one() or 0
            )
            roleplay_count = int(
                conn.execute(
                    select(func.count()).select_from(roleplay_sessions).where(roleplay_sessions.c.user_id == user_id)
                ).scalar_one() or 0
            )
            practice_count = int(
                conn.execute(
                    select(func.count()).select_from(practice_results).where(practice_results.c.user_id == user_id)
                ).scalar_one() or 0
            )
            paid_recharge_cents = int(
                conn.execute(
                    select(func.coalesce(func.sum(payment_orders.c.amount_cents), 0)).where(
                        payment_orders.c.user_id == user_id,
                        payment_orders.c.status == "paid",
                    )
                ).scalar_one() or 0
            )
            payment_rows = (
                conn.execute(
                    select(payment_orders)
                    .where(payment_orders.c.user_id == user_id)
                    .order_by(payment_orders.c.created_at.desc())
                    .limit(50)
                )
                .mappings()
                .fetchall()
            )
        return {
            "user": _admin_user_from_row(row),
            "usage": {
                "transcript_count": transcript_count,
                "scenario_count": scenario_count,
                "roleplay_session_count": roleplay_count,
                "practice_result_count": practice_count,
                "paid_recharge_cents": paid_recharge_cents,
            },
            "ledger": [item.model_dump() for item in self.list_billing_ledger(user_id, limit=100)],
            "payment_orders": [_payment_order_dict(row) for row in payment_rows],
        }

    def admin_update_user(
        self,
        user_id: str,
        *,
        display_name: str | None = None,
        plan: str | None = None,
        balance_cents: int | None = None,
        balance_delta_cents: int | None = None,
        is_banned: bool | None = None,
        admin_notes: str | None = None,
    ) -> dict[str, Any] | None:
        now = _now()
        with self.engine.begin() as conn:
            row = conn.execute(select(users).where(users.c.id == user_id)).mappings().fetchone()
            if row is None:
                return None
            values: dict[str, Any] = {}
            if display_name is not None:
                values["display_name"] = display_name.strip() or None
            if plan is not None:
                values["plan"] = plan
            if is_banned is not None:
                values["is_banned"] = 1 if is_banned else 0
            if admin_notes is not None:
                values["admin_notes"] = admin_notes.strip() or None

            old_balance = int(row["balance_cents"] or 0)
            new_balance = old_balance
            if balance_delta_cents is not None:
                new_balance = max(0, old_balance + int(balance_delta_cents))
                values["balance_cents"] = new_balance
            elif balance_cents is not None:
                new_balance = int(balance_cents)
                values["balance_cents"] = new_balance

            if values:
                conn.execute(update(users).where(users.c.id == user_id).values(**values))

            if new_balance != old_balance:
                amount = new_balance - old_balance
                conn.execute(
                    insert(billing_ledger).values(
                        id=str(uuid.uuid4()),
                        user_id=user_id,
                        type="admin_adjustment",
                        title="后台余额调整",
                        amount_cents=amount,
                        balance_after_cents=new_balance,
                        created_at=_iso(now),
                    )
                )
        return self.admin_get_user_detail(user_id)

    def admin_create_user(
        self,
        login_identifier: str,
        email: str | None,
        password_salt: str,
        password_hash: str,
        display_name: str | None = None,
    ) -> dict[str, Any]:
        user_id = str(uuid.uuid4())
        created_at = _now()
        with self.engine.begin() as conn:
            conn.execute(
                insert(users).values(
                    id=user_id,
                    login_identifier=login_identifier,
                    password_salt=password_salt,
                    password_hash=password_hash,
                    plan="free",
                    balance_cents=0,
                    display_name=display_name,
                    created_at=_iso(created_at),
                )
            )
        return self.admin_get_user_detail(user_id)

    def admin_list_all(
        self,
        limit: int = 100,
        offset: int = 0,
        query: str | None = None,
        role: str | None = None,
        is_active: bool | None = None,
    ) -> dict[str, Any]:
        stmt = select(admins).order_by(admins.c.created_at.desc())
        count_stmt = select(func.count()).select_from(admins)
        if query:
            pattern = f"%{query.strip()}%"
            stmt = stmt.where(or_(
                admins.c.username.like(pattern),
                admins.c.display_name.like(pattern),
                admins.c.email.like(pattern),
            ))
            count_stmt = count_stmt.where(or_(
                admins.c.username.like(pattern),
                admins.c.display_name.like(pattern),
                admins.c.email.like(pattern),
            ))
        if role:
            stmt = stmt.where(admins.c.role == role)
            count_stmt = count_stmt.where(admins.c.role == role)
        if is_active is not None:
            val = 1 if is_active else 0
            stmt = stmt.where(admins.c.is_active == val)
            count_stmt = count_stmt.where(admins.c.is_active == val)
        with self.engine.begin() as conn:
            total = int(conn.execute(count_stmt).scalar_one() or 0)
            rows = conn.execute(stmt.limit(limit).offset(offset)).mappings().fetchall()
        return {
            "items": [_admin_from_row(row) for row in rows],
            "total": total,
            "limit": limit,
            "offset": offset,
        }

    def admin_create(
        self,
        username: str,
        password_salt: str,
        password_hash: str,
        role: str = "admin",
        display_name: str | None = None,
        email: str | None = None,
    ) -> dict[str, Any]:
        admin_id = str(uuid.uuid4())
        now = _now()
        with self.engine.begin() as conn:
            conn.execute(
                insert(admins).values(
                    id=admin_id,
                    username=username,
                    password_salt=password_salt,
                    password_hash=password_hash,
                    role=role,
                    display_name=display_name,
                    email=email,
                    is_active=1,
                    created_at=_iso(now),
                    updated_at=_iso(now),
                )
            )
        return self.admin_get(admin_id)

    def admin_get(self, admin_id: str) -> dict[str, Any] | None:
        with self.engine.connect() as conn:
            row = conn.execute(select(admins).where(admins.c.id == admin_id)).mappings().fetchone()
        return _admin_from_row(row) if row else None

    def admin_get_by_username(self, username: str) -> dict[str, Any] | None:
        with self.engine.connect() as conn:
            row = conn.execute(select(admins).where(admins.c.username == username)).mappings().fetchone()
        return _admin_from_row(row) if row else None

    def admin_update(
        self,
        admin_id: str,
        *,
        password_salt: str | None = None,
        password_hash: str | None = None,
        role: str | None = None,
        display_name: str | None = None,
        email: str | None = None,
        is_active: bool | None = None,
    ) -> dict[str, Any] | None:
        now = _now()
        with self.engine.begin() as conn:
            row = conn.execute(select(admins).where(admins.c.id == admin_id)).mappings().fetchone()
            if row is None:
                return None
            values: dict[str, Any] = {"updated_at": _iso(now)}
            if password_salt is not None and password_hash is not None:
                values["password_salt"] = password_salt
                values["password_hash"] = password_hash
            if role is not None:
                values["role"] = role
            if display_name is not None:
                values["display_name"] = display_name.strip() or None
            if email is not None:
                values["email"] = email.strip() or None
            if is_active is not None:
                values["is_active"] = 1 if is_active else 0
            conn.execute(update(admins).where(admins.c.id == admin_id).values(**values))
        return self.admin_get(admin_id)

    def admin_touch_login(self, admin_id: str, ip_address: str | None = None) -> None:
        now = _now()
        with self.engine.begin() as conn:
            conn.execute(
                update(admins)
                .where(admins.c.id == admin_id)
                .values(last_login_at=_iso(now), last_login_ip=ip_address)
            )

    def admin_delete(self, admin_id: str) -> bool:
        with self.engine.begin() as conn:
            result = conn.execute(delete(admins).where(admins.c.id == admin_id))
        return result.rowcount > 0

    def admin_session_create(
        self,
        admin_id: str,
        username: str,
        ip_address: str | None = None,
        user_agent: str | None = None,
        ttl_hours: int = 168,
    ) -> str:
        token = os.urandom(32).hex()
        token_hash = hashlib.sha256(token.encode()).hexdigest()
        now = _now()
        expires_at = now + timedelta(hours=ttl_hours)
        with self.engine.begin() as conn:
            conn.execute(delete(admin_sessions).where(admin_sessions.c.admin_id == admin_id))
            conn.execute(
                insert(admin_sessions).values(
                    token_hash=token_hash,
                    admin_id=admin_id,
                    username=username,
                    ip_address=ip_address,
                    user_agent=user_agent,
                    created_at=_iso(now),
                    expires_at=_iso(expires_at),
                    last_seen_at=_iso(now),
                )
            )
        return token

    def admin_session_verify(self, token: str) -> dict[str, Any] | None:
        token_hash = hashlib.sha256(token.encode()).hexdigest()
        with self.engine.connect() as conn:
            row = conn.execute(
                select(admin_sessions).where(admin_sessions.c.token_hash == token_hash)
            ).mappings().fetchone()
        if row is None:
            return None
        now = _now()
        if _parse_dt(row["expires_at"]) < now:  # 绝对过期（最长会话寿命）
            return None
        # 闲置超时：超过 admin_idle_timeout_minutes 无操作即失效，需重新登录
        last_seen = _parse_dt(row["last_seen_at"]) if row.get("last_seen_at") else None
        if last_seen is not None and (now - last_seen).total_seconds() > self.get_admin_idle_timeout_minutes() * 60:
            return None
        admin = self.admin_get(row["admin_id"])
        if admin is None or not admin.get("is_active"):
            return None
        # 活跃滑动续期 last_seen（节流，避免每请求写库）
        if last_seen is None or (now - last_seen).total_seconds() > 30:
            with self.engine.begin() as conn:
                conn.execute(
                    update(admin_sessions)
                    .where(admin_sessions.c.token_hash == token_hash)
                    .values(last_seen_at=_iso(now))
                )
        return admin

    def admin_session_destroy(self, token: str) -> None:
        token_hash = hashlib.sha256(token.encode()).hexdigest()
        with self.engine.begin() as conn:
            conn.execute(delete(admin_sessions).where(admin_sessions.c.token_hash == token_hash))

    def admin_session_destroy_all(self, admin_id: str) -> None:
        with self.engine.begin() as conn:
            conn.execute(delete(admin_sessions).where(admin_sessions.c.admin_id == admin_id))

    def admin_session_cleanup(self) -> None:
        now = _iso(_now())
        with self.engine.begin() as conn:
            conn.execute(delete(admin_sessions).where(admin_sessions.c.expires_at < now))

    _CLEANUP_MIN_INTERVAL_SECONDS = 600

    def cleanup_expired(self, force: bool = False) -> None:
        # 节流：过期清理是全表 DELETE 扫描，高并发下不能挂在每个请求上跑
        now_ts = _now()
        last = getattr(self, "_last_cleanup_at", None)
        if not force and last is not None and (now_ts - last).total_seconds() < self._CLEANUP_MIN_INTERVAL_SECONDS:
            return
        self._last_cleanup_at = now_ts

        now = _iso(now_ts)
        cutoff = _iso(now_ts - timedelta(days=self.get_retention_days()))
        history_cutoff = _iso(now_ts - timedelta(days=self.get_history_retention_days()))
        with self.engine.begin() as conn:
            conn.execute(delete(transcripts).where(transcripts.c.expires_at < now))
            conn.execute(delete(sessions).where(sessions.c.created_at < cutoff))
            conn.execute(delete(scenarios).where(scenarios.c.expires_at < now))
            conn.execute(delete(practice_results).where(practice_results.c.created_at < history_cutoff))
        self.admin_session_cleanup()

    def _create_engine(self) -> Engine:
        kwargs: dict[str, Any] = {"pool_pre_ping": True, "future": True}
        if self.backend == "sqlite":
            kwargs["connect_args"] = {"check_same_thread": False}
        else:
            # PostgreSQL：连接池按并发量配置（每 worker 进程独立一套池）
            kwargs["pool_size"] = settings.db_pool_size
            kwargs["max_overflow"] = settings.db_max_overflow
            kwargs["pool_recycle"] = 1800
        engine = create_engine(self.url, **kwargs)
        if self.backend == "sqlite":
            event.listen(engine, "connect", _enable_sqlite_foreign_keys)
        return engine

    def _ensure_column(self, conn, table: str, column: str, definition: str) -> None:
        columns = {item["name"] for item in inspect(conn).get_columns(table)}
        if column not in columns:
            conn.execute(text(f"ALTER TABLE {table} ADD COLUMN {column} {definition}"))

    def _ensure_index(self, conn, name: str, statement: str) -> None:
        indexes = {item["name"] for item in inspect(conn).get_indexes("users")}
        if name not in indexes:
            conn.execute(text(statement))


def _enable_sqlite_foreign_keys(dbapi_connection, _connection_record) -> None:
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.close()


def _database_url(database_url: str | None, path: Path) -> str:
    if database_url:
        if database_url.startswith("postgres://"):
            return database_url.replace("postgres://", "postgresql+psycopg://", 1)
        if database_url.startswith("postgresql://"):
            return database_url.replace("postgresql://", "postgresql+psycopg://", 1)
        return database_url

    resolved = path.expanduser()
    if not resolved.is_absolute():
        resolved = (Path.cwd() / resolved).resolve()
    if resolved.parent:
        resolved.parent.mkdir(parents=True, exist_ok=True)
    return f"sqlite:///{resolved}"


def clean_transcript_items(items: list[TranscriptItem]) -> list[TranscriptItem]:
    cleaned: list[TranscriptItem] = []
    seen_ids: set[str] = set()
    for item in filter_sensitive_transcripts(items):
        if item.id in seen_ids:
            continue
        seen_ids.add(item.id)
        text = _clean_transcript_text(item.text)
        if text is None:
            continue
        cleaned.append(item.model_copy(update={"text": text}))
    return cleaned


_TEXT_SIGNAL_RE = re.compile(r"[0-9A-Za-z\u4e00-\u9fff]")
_NOISE_TEXTS = {
    "开始录音",
    "停止录音",
    "正在录音",
    "识别中",
    "采集中",
    "未检测到语音",
    "麦克风已开启",
    "麦克风已关闭",
    "字幕由ai生成",
    "字幕由 ai 生成",
    "谢谢观看",
    "感谢观看",
    "请点赞",
    "请订阅",
}
_NOISE_KEYS = {re.sub(r"\s+", "", value.lower()) for value in _NOISE_TEXTS}


def _clean_transcript_text(text: str) -> str | None:
    normalized = " ".join(text.strip().split())
    if not normalized:
        return None
    compact = re.sub(r"\s+", "", normalized.lower())
    if compact in _NOISE_KEYS:
        return None
    if _TEXT_SIGNAL_RE.search(normalized) is None:
        return None
    return normalized


def _backend_name(database_url: str) -> str:
    if database_url.startswith("sqlite"):
        return "sqlite"
    if database_url.startswith("postgresql"):
        return "postgresql-compatible"
    return database_url.split(":", 1)[0]


def _admin_from_row(row: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "username": row["username"],
        "password_salt": row["password_salt"],
        "password_hash": row["password_hash"],
        "role": row["role"],
        "display_name": row.get("display_name"),
        "email": row.get("email"),
        "is_active": bool(row.get("is_active") or 0),
        "last_login_at": _parse_dt(row["last_login_at"]) if row.get("last_login_at") else None,
        "last_login_ip": row.get("last_login_ip"),
        "created_at": _parse_dt(row["created_at"]),
        "updated_at": _parse_dt(row["updated_at"]) if row.get("updated_at") else None,
    }


def _user_from_row(row: Mapping[str, Any]) -> UserOut:
    plan_expires_at = _parse_dt(row["plan_expires_at"]) if row.get("plan_expires_at") else None
    return UserOut(
        id=row["id"],
        login_identifier=row["login_identifier"],
        display_name=row.get("display_name"),
        avatar_url=row.get("avatar_url"),
        plan=row["plan"],
        plan_expires_at=plan_expires_at,
        plan_tier=effective_plan_tier(row["plan"], plan_expires_at),
        balance_cents=int(row.get("balance_cents") or 0),
        is_banned=bool(row.get("is_banned") or 0),
        admin_notes=row.get("admin_notes"),
        last_seen_at=_parse_dt(row["last_seen_at"]) if row.get("last_seen_at") else None,
        created_at=_parse_dt(row["created_at"]),
    )


def _audio_job_dict(row: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "filename": row["filename"],
        "size_bytes": int(row["size_bytes"] or 0),
        "status": row["status"],
        "error": row.get("error"),
        "scene_id": row.get("scene_id"),
        "transcript_chars": int(row.get("transcript_chars") or 0),
        "created_at": _parse_dt(row["created_at"]),
        "updated_at": _parse_dt(row["updated_at"]),
    }


def _admin_user_from_row(row: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "login_identifier": row["login_identifier"],
        "wechat_openid": row.get("wechat_openid"),
        "display_name": row.get("display_name"),
        "avatar_url": row.get("avatar_url"),
        "plan": row["plan"],
        "balance_cents": int(row.get("balance_cents") or 0),
        "is_banned": bool(row.get("is_banned") or 0),
        "admin_notes": row.get("admin_notes"),
        "last_seen_at": _parse_dt(row["last_seen_at"]) if row.get("last_seen_at") else None,
        "created_at": _parse_dt(row["created_at"]),
    }


def _session_from_row(row: Mapping[str, Any]) -> SessionRecord:
    items = [DrillPrompt(**item) for item in json.loads(row["items_json"])]
    return SessionRecord(
        session_id=row["session_id"],
        user_id=row["user_id"],
        status=row["status"],
        items=items,
        index=row["item_index"],
        score=row["score"],
        created_at=_parse_dt(row["created_at"]),
    )


def _scenario_from_row(row: Mapping[str, Any]) -> ScenarioResponse:
    return ScenarioResponse(
        scene_id=row["scene_id"],
        title=row["title"],
        summary=row["summary"],
        roles=[ScenarioRole(**item) for item in json.loads(row["roles_json"])],
        lines=[SceneLine(**item) for item in json.loads(row["lines_json"])],
        expressions=[ExpressionCard(**item) for item in json.loads(row["expressions_json"])],
    )


def _roleplay_session_from_row(row: Mapping[str, Any]) -> RoleplaySessionRecord:
    return RoleplaySessionRecord(
        session_id=row["session_id"],
        user_id=row["user_id"],
        scene_id=row["scene_id"],
        selected_role=row["selected_role"],
        ai_role=row["ai_role"],
        status=row["status"],
        target_index=row["target_index"],
        turns=row["turns"],
        score_total=float(row["score_total"]),
        created_at=_parse_dt(row["created_at"]),
        updated_at=_parse_dt(row["updated_at"]),
    )


def _message_from_row(row: Mapping[str, Any]) -> RoleplayMessageOut:
    return RoleplayMessageOut(
        id=row["id"],
        speaker=row["speaker"],
        role=row["role"],
        content=row["content"],
        translation=row["translation"],
        feedback=row["feedback"],
        created_at=_parse_dt(row["created_at"]),
    )


def _billing_ledger_from_row(row: Mapping[str, Any]) -> BillingLedgerItem:
    return BillingLedgerItem(
        id=row["id"],
        type=row["type"],
        title=row["title"],
        amount_cents=int(row["amount_cents"]),
        balance_after_cents=int(row["balance_after_cents"]),
        created_at=_parse_dt(row["created_at"]),
    )


def _payment_order_from_row(row: Mapping[str, Any], message: str) -> RechargeOrderResponse:
    return RechargeOrderResponse(
        order_id=row["order_id"],
        method=row["method"],
        amount_cents=int(row["amount_cents"]),
        status=row["status"],
        payment_url=row["payment_url"],
        qr_code_text=row["qr_code_text"],
        receiver_name=row["receiver_name"],
        receiver_account=row["receiver_account"],
        message=message,
        created_at=_parse_dt(row["created_at"]),
    )


def _payment_order_dict(row: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "order_id": row["order_id"],
        "user_id": row["user_id"],
        "method": row["method"],
        "amount_cents": int(row["amount_cents"]),
        "status": row["status"],
        "payment_url": row["payment_url"],
        "qr_code_text": row["qr_code_text"],
        "receiver_name": row["receiver_name"],
        "receiver_account": row["receiver_account"],
        "created_at": _parse_dt(row["created_at"]),
        "paid_at": _parse_dt(row["paid_at"]) if row.get("paid_at") else None,
    }


def _payment_method_title(method: str) -> str:
    if method == "wechat":
        return "微信"
    if method == "alipay":
        return "支付宝"
    return method


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _iso(value: datetime) -> str:
    return _utc(value).isoformat()


def _parse_dt(value: str) -> datetime:
    return datetime.fromisoformat(value).astimezone(timezone.utc)


def _cycle_start(anchor: datetime | None, now: datetime | None = None) -> datetime:
    """计费周期起点：按锚点日（购买日）取最近一次「不晚于现在」的当月锚点；无锚点回退自然月 1 号。"""
    now = now or _now()
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if anchor is None:
        return midnight.replace(day=1)
    day = min(_utc(anchor).day, 28)  # 取 ≤28 避免月末缺日
    candidate = midnight.replace(day=day)
    if candidate > now:
        prev_month_last = midnight.replace(day=1) - timedelta(days=1)
        candidate = prev_month_last.replace(day=day, hour=0, minute=0, second=0, microsecond=0)
    return candidate


db = Database()
