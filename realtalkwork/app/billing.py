from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

import httpx
import jwt
from fastapi import HTTPException, status

from .schemas import ApplePurchaseVerifyRequest
from .settings import settings


class AppleBillingVerifier:
    async def verify(self, request: ApplePurchaseVerifyRequest) -> tuple[bool, datetime | None, str]:
        if request.product_id != settings.apple_product_id:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="内购商品 ID 不匹配")

        if settings.apple_iap_dev_bypass:
            return True, datetime.now(timezone.utc) + timedelta(days=31), "开发环境已记录订阅"

        if not self._has_server_api_credentials():
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="Apple IAP 服务端校验未配置")

        payload = await self._fetch_transaction_payload(request.transaction_id)
        if payload.get("bundleId") != settings.apple_bundle_id:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Bundle ID 不匹配")
        if payload.get("productId") != settings.apple_product_id:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="商品 ID 不匹配")

        expires_at = _apple_millis_to_datetime(payload.get("expiresDate"))
        if expires_at and expires_at < datetime.now(timezone.utc):
            raise HTTPException(status_code=status.HTTP_402_PAYMENT_REQUIRED, detail="订阅已过期")

        return True, expires_at, "Apple 订阅已验证"

    async def _fetch_transaction_payload(self, transaction_id: str) -> dict[str, Any]:
        token = self._make_app_store_server_token()
        host = "https://api.storekit-sandbox.itunes.apple.com" if settings.apple_use_sandbox else "https://api.storekit.itunes.apple.com"
        url = f"{host}/inApps/v1/transactions/{transaction_id}"
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.get(url, headers={"Authorization": f"Bearer {token}"})
            response.raise_for_status()
        signed_info = response.json()["signedTransactionInfo"]
        return jwt.decode(signed_info, options={"verify_signature": False})

    def _make_app_store_server_token(self) -> str:
        now = datetime.now(timezone.utc)
        payload = {
            "iss": settings.apple_issuer_id,
            "iat": int(now.timestamp()),
            "exp": int((now + timedelta(minutes=20)).timestamp()),
            "aud": "appstoreconnect-v1",
            "bid": settings.apple_bundle_id,
        }
        headers = {"kid": settings.apple_key_id, "typ": "JWT"}
        return jwt.encode(payload, settings.apple_private_key, algorithm="ES256", headers=headers)

    def _has_server_api_credentials(self) -> bool:
        return all([settings.apple_issuer_id, settings.apple_key_id, settings.apple_private_key])


def _apple_millis_to_datetime(value: Any) -> datetime | None:
    if value is None:
        return None
    return datetime.fromtimestamp(int(value) / 1000, tz=timezone.utc)


apple_billing = AppleBillingVerifier()
