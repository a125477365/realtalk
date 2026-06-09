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
    SessionRecord,
    TranscriptItem,
    UserOut,
)
from .content_policy import filter_sensitive_transcripts
from .settings import settings


def normalize_email(email: str) -> str:
    return email.strip().lower()


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
)
Index("idx_users_login_identifier", users.c.login_identifier, unique=True)
Index("idx_users_wechat_openid", users.c.wechat_openid, unique=True)

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
)
Index("idx_scenarios_user_created", scenarios.c.user_id, scenarios.c.created_at)
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
)
Index("idx_practice_results_user_created", practice_results.c.user_id, practice_results.c.created_at)

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
)
Index("idx_admin_sessions_admin", admin_sessions.c.admin_id)
Index("idx_admin_sessions_expires", admin_sessions.c.expires_at)


class Database:
    def __init__(self, database_url: str | None = None, path: Path | None = None):
        self.url = _database_url(database_url or settings.database_url, path or settings.database_path)
        self.backend = _backend_name(self.url)
        self.engine = self._create_engine()
        self.initialize()

    def initialize(self) -> None:
        metadata.create_all(self.engine)
        with self.engine.begin() as conn:
            self._ensure_column(conn, "users", "balance_cents", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "users", "wechat_openid", "TEXT")
            self._ensure_column(conn, "users", "display_name", "TEXT")
            self._ensure_column(conn, "users", "avatar_url", "TEXT")
            self._ensure_column(conn, "users", "is_banned", "INTEGER NOT NULL DEFAULT 0")
            self._ensure_column(conn, "users", "admin_notes", "TEXT")
            self._ensure_column(conn, "users", "last_seen_at", "TEXT")
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
                    balance_cents=0,
                    created_at=_iso(created_at),
                )
            )
        return UserOut(
            id=user_id,
            login_identifier=login_identifier,
            plan="free",
            balance_cents=0,
            created_at=created_at,
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
                    balance_cents=0,
                    wechat_openid=openid,
                    display_name=display_name,
                    avatar_url=avatar_url,
                    created_at=_iso(now),
                )
            )
        return UserOut(
            id=user_id,
            login_identifier=identity,
            display_name=display_name,
            avatar_url=avatar_url,
            plan="free",
            balance_cents=0,
            created_at=now,
        )

    def get_user_by_wechat_openid(self, openid: str) -> Mapping[str, Any] | None:
        with self.engine.connect() as conn:
            return conn.execute(select(users).where(users.c.wechat_openid == openid)).mappings().fetchone()

    def get_user_row(self, user_id: str) -> Mapping[str, Any] | None:
        with self.engine.connect() as conn:
            return conn.execute(select(users).where(users.c.id == user_id)).mappings().fetchone()

    def get_user(self, user_id: str) -> UserOut | None:
        row = self.get_user_row(user_id)
        return _user_from_row(row) if row else None

    def touch_user_seen(self, user_id: str) -> None:
        with self.engine.begin() as conn:
            conn.execute(
                update(users)
                .where(users.c.id == user_id)
                .values(last_seen_at=_iso(_now()))
            )

    def get_monthly_price_cents(self) -> int:
        return self.get_app_setting_int("monthly_price_cents", settings.monthly_price_cents)

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

    def set_app_setting(self, key: str, value: str) -> None:
        now = _iso(_now())
        with self.engine.begin() as conn:
            existing = conn.execute(
                select(app_settings.c.key).where(app_settings.c.key == key)
            ).scalar_one_or_none()
            if existing:
                conn.execute(
                    update(app_settings)
                    .where(app_settings.c.key == key)
                    .values(value_text=value, updated_at=now)
                )
            else:
                conn.execute(
                    insert(app_settings).values(key=key, value_text=value, updated_at=now)
                )

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
                    plan="pro",
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
            message="充值订单已创建",
            created_at=now,
        )

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
        return _payment_order_from_row(order, "充值成功"), user

    def mark_recharge_paid_by_order_id(self, order_id: str, paid_amount_cents: int) -> tuple[RechargeOrderResponse, UserOut]:
        """Mark a recharge order as paid using only the order_id. Used by payment webhooks."""
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

            amount_cents = paid_amount_cents or int(order["amount_cents"])
            result = conn.execute(
                update(payment_orders)
                .where(
                    payment_orders.c.order_id == order_id,
                    payment_orders.c.status != "paid",
                )
                .values(status="paid", paid_at=_iso(now))
            )
            if result.rowcount:
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
        now = _now()
        rows = []
        for item in clean_transcript_items(items):
            timestamp = _utc(item.timestamp)
            if timestamp < now - timedelta(days=settings.retention_days):
                continue
            expires_at = timestamp + timedelta(days=settings.retention_days)
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
    ) -> ScenarioResponse:
        scene_id = str(uuid.uuid4())
        now = _now()
        expires_at = now + timedelta(days=settings.history_retention_days)
        saved = scenario.model_copy(update={"scene_id": scene_id})
        with self.engine.begin() as conn:
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
                )
            )
        return saved

    def get_scenario(self, user_id: str, scene_id: str) -> ScenarioResponse | None:
        with self.engine.connect() as conn:
            row = (
                conn.execute(
                    select(scenarios).where(scenarios.c.user_id == user_id, scenarios.c.scene_id == scene_id)
                )
                .mappings()
                .fetchone()
            )
        return _scenario_from_row(row) if row else None

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
                )
            )

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
                    .where(roleplay_sessions.c.user_id == user_id)
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
        online_since = _iso(_now() - timedelta(minutes=settings.online_window_minutes))
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
        return {
            "total_users": total_users,
            "banned_users": banned_users,
            "online_users": online_users,
            "online_window_minutes": settings.online_window_minutes,
            "total_balance_cents": total_balance_cents,
            "paid_recharge_cents": paid_recharge_cents,
            "pending_recharge_cents": pending_recharge_cents,
            "paid_orders": paid_orders,
            "roleplay_session_count": roleplay_session_count,
            "practice_result_count": practice_result_count,
            "transcript_count": transcript_count,
            "monthly_price_cents": self.get_monthly_price_cents(),
        }

    def admin_list_users(self, limit: int = 100, query: str | None = None) -> list[dict[str, Any]]:
        stmt = select(users).order_by(users.c.created_at.desc()).limit(limit)
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
        if _parse_dt(row["expires_at"]) < _now():
            return None
        admin = self.admin_get(row["admin_id"])
        if admin is None or not admin.get("is_active"):
            return None
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

    def cleanup_expired(self) -> None:
        now = _iso(_now())
        cutoff = _iso(_now() - timedelta(days=settings.retention_days))
        history_cutoff = _iso(_now() - timedelta(days=settings.history_retention_days))
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
    return UserOut(
        id=row["id"],
        login_identifier=row["login_identifier"],
        display_name=row.get("display_name"),
        avatar_url=row.get("avatar_url"),
        plan=row["plan"],
        balance_cents=int(row.get("balance_cents") or 0),
        is_banned=bool(row.get("is_banned") or 0),
        admin_notes=row.get("admin_notes"),
        last_seen_at=_parse_dt(row["last_seen_at"]) if row.get("last_seen_at") else None,
        created_at=_parse_dt(row["created_at"]),
    )


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


db = Database()
