from __future__ import annotations

import hashlib
import hmac
import json
import time
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import urlencode

import httpx
import jwt
from fastapi import HTTPException, Request, status

from .schemas import ApplePurchaseVerifyRequest
from .settings import settings


# ============================================================
# WeChat Pay
# ============================================================

class WeChatPayClient:
    """WeChat Pay v3 API client for native payments."""

    def __init__(self):
        # 注：本对象是模块级单例，import 期实例化。凭据走 DB（管理台可改），故用 property 延迟读取——
        # 既不在 import/未供给时碰库，又能在管理员改库后即时生效（不会缓存成旧值）。
        self.cert_path = settings.wechat_ssl_cert_path   # 商户私钥/证书是每节点本地文件路径（部署项，env）
        self.key_path = settings.wechat_ssl_key_path
        self.base_url = "https://api.mch.weixin.qq.com"

    @property
    def mchid(self):  # 单一来源：只读 DB（与回调验签同一份）
        from .payments import resolve_payment_config
        return resolve_payment_config()["wechat_mchid"]

    @property
    def appid(self):
        from .storage import db
        return db.resolve_wechat_login_config()["app_id"]

    @property
    def api_key(self):
        from .payments import resolve_payment_config
        return resolve_payment_config()["wechat_apiv3_key"]

    def _get_serial_no(self) -> str:
        """Get certificate serial number from PEM file."""
        if not self.cert_path:
            return ""
        try:
            import subprocess
            result = subprocess.run(
                ["openssl", "x509", "-in", self.cert_path, "-serial", "-noout"],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0:
                # Output is like "serial=DEADBEEF1234"
                hex_part = result.stdout.strip().split("=")[-1]
                return hex_part.upper()
        except Exception:
            pass
        return ""

    def _sign_v3(self, sign_str: str) -> str:
        """Create WeChat Pay v3 signature."""
        import os
        if not self.key_path or not os.path.exists(self.key_path):
            # Fallback to API key signing for v2 compatibility
            sign_str_with_key = sign_str + f"&key={self.api_key}"
            return hashlib.md5(sign_str_with_key.encode("utf-8")).hexdigest().upper()
        
        try:
            import subprocess
            result = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", self.key_path],
                input=sign_str.encode("utf-8"),
                capture_output=True,
                timeout=10
            )
            if result.returncode == 0:
                import base64
                return base64.b64encode(result.stdout).decode("utf-8")
        except Exception:
            pass
        
        # Fallback
        sign_str_with_key = sign_str + f"&key={self.api_key}"
        return hashlib.md5(sign_str_with_key.encode("utf-8")).hexdigest().upper()

    async def create_unified_order(
        self,
        out_trade_no: str,
        total_fee: int,
        description: str,
        notify_url: str,
        client_ip: str,
    ) -> dict[str, Any]:
        """
        Create WeChat Pay unified order.
        total_fee is in cents (integer).
        Returns dict with code_url (QR code content) for native payments.
        """
        if not self.mchid or not self.appid:
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="微信支付未配置")

        now = datetime.now(timezone.utc)
        timestamp = str(int(now.timestamp()))
        nonce_str = uuid.uuid4().hex

        # Build request body
        body = {
            "mchid": self.mchid,
            "out_trade_no": out_trade_no,
            "appid": self.appid,
            "description": description,
            "notify_url": notify_url,
            "amount": {
                "total": total_fee,
                "currency": "CNY",
            },
            "payer": {
                "client_ip": client_ip,
            },
            "trade_type": "NATIVE",
        }

        body_json = json.dumps(body, separators=(",", ":"))
        
        # Build signature
        sign_str = f"POST\n/v3/transactions/native\n{timestamp}\n{nonce_str}\n{body_json}\n"
        signature = self._sign_v3(sign_str)
        serial_no = self._get_serial_no()

        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f'WECHATPAY2-SHA256-RSA2048 mchid="{self.mchid}",nonce_str="{nonce_str}",signature="{signature}",timestamp="{timestamp}",serial_no="{serial_no}"',
        }

        url = f"{self.base_url}/v3/transactions/native"
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(url, headers=headers, content=body_json)

        if response.status_code != 200:
            error_data = response.json() if response.headers.get("content-type", "").startswith("application/json") else {}
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail=f"微信支付下单失败: {error_data.get('message', response.text[:200])}",
            )

        data = response.json()
        return {
            "code_url": data.get("code_url"),
            "trade_type": data.get("trade_type", "NATIVE"),
            "prepay_id": data.get("prepay_id"),
            "out_trade_no": out_trade_no,
        }

    async def query_order(self, out_trade_no: str) -> dict[str, Any]:
        """Query WeChat Pay order status."""
        if not self.mchid or not self.appid:
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="微信支付未配置")

        timestamp = str(int(datetime.now(timezone.utc).timestamp()))
        nonce_str = uuid.uuid4().hex
        path = f"/v3/transactions/out-trade-no/{out_trade_no}?mchid={self.mchid}"
        sign_str = f"GET\n{path}\n{timestamp}\n{nonce_str}\n\n"
        signature = self._sign_v3(sign_str)
        serial_no = self._get_serial_no()

        headers = {
            "Accept": "application/json",
            "Authorization": f'WECHATPAY2-SHA256-RSA2048 mchid="{self.mchid}",nonce_str="{nonce_str}",signature="{signature}",timestamp="{timestamp}",serial_no="{serial_no}"',
        }

        url = f"{self.base_url}{path}"
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.get(url, headers=headers)

        if response.status_code == 404:
            return {"trade_state": "NOTFOUND", "out_trade_no": out_trade_no}
        if response.status_code != 200:
            return {"trade_state": "ERROR", "out_trade_no": out_trade_no, "error": response.text[:200]}

        return response.json()

    async def close_order(self, out_trade_no: str) -> bool:
        """Close a pending order."""
        if not self.mchid or not self.appid:
            return False

        timestamp = str(int(datetime.now(timezone.utc).timestamp()))
        nonce_str = uuid.uuid4().hex
        path = f"/v3/transactions/out-trade-no/{out_trade_no}/close"
        body = json.dumps({"mchid": self.mchid}, separators=(",", ":"))
        sign_str = f"POST\n{path}\n{timestamp}\n{nonce_str}\n{body}\n"
        signature = self._sign_v3(sign_str)
        serial_no = self._get_serial_no()

        headers = {
            "Content-Type": "application/json",
            "Authorization": f'WECHATPAY2-SHA256-RSA2048 mchid="{self.mchid}",nonce_str="{nonce_str}",signature="{signature}",timestamp="{timestamp}",serial_no="{serial_no}"',
        }

        url = f"{self.base_url}{path}"
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.post(url, headers=headers, content=body)

        return response.status_code in (200, 204)


# ============================================================
# Alipay
# ============================================================

class AlipayClient:
    """Alipay Alipay+ /当面付 integration."""

    def __init__(self):
        # 模块级单例：appid/支付宝公钥走 DB（管理台可改），用 property 延迟读取，避免 import 期碰库、且改库即时生效。
        self.private_key = settings.alipay_private_key   # 商户私钥是每节点本地文件路径（部署项，env）
        self.notify_url = None  # Set per-request
        self.gateway = "https://openapi.alipaydev.com" if settings.alipay_sandbox else "https://openapi.alipay.com"

    @property
    def app_id(self):  # 单一来源：只读 DB
        from .payments import resolve_payment_config
        return resolve_payment_config()["alipay_app_id"]

    @property
    def alipay_public_key(self):
        from .payments import resolve_payment_config
        return resolve_payment_config()["alipay_public_key"]

    def _sign(self, params: dict) -> str:
        """Sign parameters with RSA2."""
        sorted_params = sorted(params.items())
        sign_string = "&".join(f"{k}={v}" for k, v in sorted_params)
        
        if not self.private_key:
            return ""
        
        try:
            import subprocess
            result = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", self.private_key],
                input=sign_string.encode("utf-8"),
                capture_output=True,
                timeout=10
            )
            if result.returncode == 0:
                import base64
                return base64.b64encode(result.stdout).decode("utf-8")
        except Exception:
            pass
        return ""

    async def create_trade_precreate(
        self,
        out_trade_no: str,
        total_amount: float,
        subject: str,
        notify_url: str,
    ) -> dict[str, Any]:
        """
        Create Alipay QR code payment (当面付).
        Returns dict with qr_code for QR display.
        """
        if not self.app_id or not self.private_key:
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="支付宝未配置")

        now = datetime.now(timezone.utc)
        params = {
            "app_id": self.app_id,
            "method": "alipay.trade.precreate",
            "format": "JSON",
            "charset": "utf-8",
            "sign_type": "RSA2",
            "timestamp": now.strftime("%Y-%m-%d %H:%M:%S"),
            "version": "1.0",
            "biz_content": json.dumps({
                "out_trade_no": out_trade_no,
                "total_amount": f"{total_amount:.2f}",
                "subject": subject,
                "timeout_express": "30m",
            }, separators=(",", ":")),
            "notify_url": notify_url,
        }

        sign = self._sign(params)
        params["sign"] = sign

        url = f"{self.gateway}/gateway.do"
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(url, data=params)

        if response.status_code != 200:
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=f"支付宝下单失败: {response.text[:200]}")

        result = response.json()
        resp = result.get("alipay_trade_precreate_response", {})
        
        if resp.get("code") != "10000":
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail=f"支付宝下单失败: {resp.get('msg', '')} {resp.get('sub_msg', '')}",
            )

        return {
            "qr_code": resp.get("qr_code"),
            "out_trade_no": out_trade_no,
        }

    async def query_trade(self, out_trade_no: str) -> dict[str, Any]:
        """Query Alipay trade status."""
        if not self.app_id or not self.private_key:
            return {"trade_status": "UNKNOWN"}

        now = datetime.now(timezone.utc)
        params = {
            "app_id": self.app_id,
            "method": "alipay.trade.query",
            "format": "JSON",
            "charset": "utf-8",
            "sign_type": "RSA2",
            "timestamp": now.strftime("%Y-%m-%d %H:%M:%S"),
            "version": "1.0",
            "biz_content": json.dumps({"out_trade_no": out_trade_no}, separators=(",", ":")),
        }
        params["sign"] = self._sign(params)

        url = f"{self.gateway}/gateway.do"
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.post(url, data=params)

        if response.status_code != 200:
            return {"trade_status": "ERROR"}

        result = response.json()
        resp = result.get("alipay_trade_query_response", {})
        
        return {
            "trade_status": resp.get("trade_status", "UNKNOWN"),
            "out_trade_no": out_trade_no,
        }


# ============================================================
# Apple IAP (existing, cleaned up)
# ============================================================

class AppleBillingVerifier:
    @staticmethod
    def _cfg() -> dict:
        from .storage import db   # 单一来源：bundle/product/issuer/key/私钥 只读 DB（沙箱与 dev 旁路是每节点 env）
        return db.resolve_apple_iap_config()

    async def verify(self, request: ApplePurchaseVerifyRequest) -> tuple[bool, datetime | None, str]:
        cfg = self._cfg()
        if request.product_id != cfg["product_id"]:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="内购商品 ID 不匹配")

        if settings.apple_iap_dev_bypass:
            return True, datetime.now(timezone.utc) + timedelta(days=31), "开发环境已记录订阅"

        if not self._has_server_api_credentials():
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="Apple IAP 服务端校验未配置")

        payload = await self._fetch_transaction_payload(request.transaction_id)
        if payload.get("bundleId") != cfg["bundle_id"]:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Bundle ID 不匹配")
        if payload.get("productId") != cfg["product_id"]:
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
        cfg = self._cfg()
        now = datetime.now(timezone.utc)
        payload = {
            "iss": cfg["issuer_id"],
            "iat": int(now.timestamp()),
            "exp": int((now + timedelta(minutes=20)).timestamp()),
            "aud": "appstoreconnect-v1",
            "bid": cfg["bundle_id"],
        }
        headers = {"kid": cfg["key_id"], "typ": "JWT"}
        return jwt.encode(payload, cfg["private_key"], algorithm="ES256", headers=headers)

    def _has_server_api_credentials(self) -> bool:
        cfg = self._cfg()
        return all([cfg["issuer_id"], cfg["key_id"], cfg["private_key"]])


def _apple_millis_to_datetime(value: Any) -> datetime | None:
    if value is None:
        return None
    return datetime.fromtimestamp(int(value) / 1000, tz=timezone.utc)


# ============================================================
# Singleton instances
# ============================================================

wechat_pay = WeChatPayClient()
alipay = AlipayClient()
apple_billing = AppleBillingVerifier()
