"""支付回调（webhook）验签与解密：防伪造支付通知白嫖会员。

- 微信支付 v3：验 `Wechatpay-Signature`（用微信支付平台证书 RSA-SHA256 验签）+ 时间窗防重放，
  再用 APIv3 密钥 AES-256-GCM 解密 `resource`（真实金额/状态在密文里，明文字段不可信）。
- 支付宝：RSA2（SHA256）验签（用支付宝公钥），构造待签名串 = 排除 sign/sign_type 后按 key 升序的 k=v&…。

凭证（mchid / APIv3 密钥 / 平台证书 / 支付宝公钥+app_id）走【管理台可维护 + DB 系统参数表】，
多活部署多个后端共用同一份（DB 为准，env/setup.sh 仅首装播种）。未配置或验签失败 → 回调直接拒绝、不处理。
"""
from __future__ import annotations

import base64
import json
import time

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.x509 import load_pem_x509_certificate

from .settings import settings

_PAYMENT_KEYS = [
    "wechat_mchid", "wechat_apiv3_key", "wechat_platform_cert", "wechat_cert_serial",
    "alipay_app_id", "alipay_public_key",
]


def resolve_payment_config() -> dict[str, str | None]:
    """DB 系统参数为准，env 仅兜底（首装由 seed 播种）。"""
    from .storage import db

    ov = db.get_app_settings_map(_PAYMENT_KEYS)
    return {
        "wechat_mchid": ov.get("wechat_mchid") or settings.wechat_mchid,
        "wechat_apiv3_key": ov.get("wechat_apiv3_key") or settings.wechat_api_key,
        "wechat_platform_cert": ov.get("wechat_platform_cert") or settings.wechat_platform_cert,
        "wechat_cert_serial": ov.get("wechat_cert_serial") or settings.wechat_cert_serial,
        "alipay_app_id": ov.get("alipay_app_id") or settings.alipay_app_id,
        "alipay_public_key": ov.get("alipay_public_key") or settings.alipay_public_key,
    }


# ---- 微信支付 v3 ----

def wechat_configured(config: dict | None = None) -> bool:
    c = config or resolve_payment_config()
    return bool(c["wechat_apiv3_key"] and c["wechat_platform_cert"])


def verify_wechat_signature(headers: dict, body: bytes, config: dict) -> bool:
    """验证微信支付回调签名。任一缺失/过期/验签失败都返回 False（调用方拒绝处理）。"""
    cert_pem = config.get("wechat_platform_cert")
    if not cert_pem:
        return False
    ts = headers.get("wechatpay-timestamp")
    nonce = headers.get("wechatpay-nonce")
    sig = headers.get("wechatpay-signature")
    serial = headers.get("wechatpay-serial")
    if not (ts and nonce and sig):
        return False
    # 时间窗防重放（±5 分钟）
    try:
        if abs(time.time() - int(ts)) > 300:
            return False
    except (ValueError, TypeError):
        return False
    # 若配置了平台证书序列号，要求与回调头一致
    want_serial = (config.get("wechat_cert_serial") or "").strip()
    if want_serial and serial and serial.strip().lower() != want_serial.lower():
        return False
    message = f"{ts}\n{nonce}\n{body.decode('utf-8')}\n".encode("utf-8")
    try:
        cert = load_pem_x509_certificate(cert_pem.encode("utf-8"))
        cert.public_key().verify(base64.b64decode(sig), message, padding.PKCS1v15(), hashes.SHA256())
        return True
    except (InvalidSignature, ValueError, Exception):  # noqa: BLE001
        return False


def decrypt_wechat_resource(resource: dict, apiv3_key: str) -> dict:
    """AES-256-GCM 解密回调密文，返回真实交易明文（含 out_trade_no / trade_state / amount）。"""
    key = apiv3_key.encode("utf-8")  # APIv3 密钥为 32 位字符 → 32 字节
    ciphertext = base64.b64decode(resource["ciphertext"])
    nonce = resource["nonce"].encode("utf-8")
    aad = (resource.get("associated_data") or "").encode("utf-8")
    plaintext = AESGCM(key).decrypt(nonce, ciphertext, aad)
    return json.loads(plaintext.decode("utf-8"))


# ---- 支付宝 ----

def alipay_configured(config: dict | None = None) -> bool:
    c = config or resolve_payment_config()
    return bool(c["alipay_public_key"])


def _load_alipay_public_key(raw: str):
    raw = raw.strip()
    if "-----BEGIN" not in raw:
        # 裸 base64 → 包成 PEM
        b64 = "".join(raw.split())
        lines = "\n".join(b64[i:i + 64] for i in range(0, len(b64), 64))
        raw = f"-----BEGIN PUBLIC KEY-----\n{lines}\n-----END PUBLIC KEY-----\n"
    return serialization.load_pem_public_key(raw.encode("utf-8"))


def verify_alipay_signature(params: dict, alipay_public_key: str | None) -> bool:
    """RSA2(SHA256)/RSA(SHA1) 验签。构造待签名串=排除 sign/sign_type 后按 key 升序的 k=v&…。"""
    if not alipay_public_key:
        return False
    sign = params.get("sign")
    if not sign:
        return False
    sign_type = (params.get("sign_type") or "RSA2").upper()
    algo = hashes.SHA256() if sign_type == "RSA2" else hashes.SHA1()
    items = sorted((k, v) for k, v in params.items() if k not in ("sign", "sign_type") and v != "")
    message = "&".join(f"{k}={v}" for k, v in items).encode("utf-8")
    try:
        pub = _load_alipay_public_key(alipay_public_key)
        pub.verify(base64.b64decode(sign), message, padding.PKCS1v15(), algo)
        return True
    except (InvalidSignature, ValueError, Exception):  # noqa: BLE001
        return False
