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
    # 多活共用、改为只读 DB：回调地址 + 商户「下单签名」凭据（证书/私钥内容入库，不再每节点放文件）
    "wechat_notify_url", "alipay_notify_url",
    "wechat_merchant_cert", "wechat_merchant_private_key", "alipay_merchant_private_key",
]


def resolve_payment_config() -> dict[str, str | None]:
    """支付相关参数单一来源：只读 DB（装库时由 db_init 入库），不回退 env。"""
    from .storage import db

    ov = db.get_app_settings_map(_PAYMENT_KEYS)
    return {
        "wechat_mchid": ov.get("wechat_mchid"),
        "wechat_apiv3_key": ov.get("wechat_apiv3_key"),
        "wechat_platform_cert": ov.get("wechat_platform_cert"),
        "wechat_cert_serial": ov.get("wechat_cert_serial"),
        "alipay_app_id": ov.get("alipay_app_id"),
        "alipay_public_key": ov.get("alipay_public_key"),
        "wechat_notify_url": ov.get("wechat_notify_url"),
        "alipay_notify_url": ov.get("alipay_notify_url"),
        "wechat_merchant_cert": ov.get("wechat_merchant_cert"),
        "wechat_merchant_private_key": ov.get("wechat_merchant_private_key"),
        "alipay_merchant_private_key": ov.get("alipay_merchant_private_key"),
    }


def rsa_sign_base64(private_key_pem: str | None, message: str) -> str:
    """商户 RSA 私钥对待签名串做 SHA256 签名，返回 base64（微信支付 v3 / 支付宝 RSA2 同此算法）。
    进程内用 cryptography 完成（私钥内容只读 DB），不再 openssl 读本地文件、不在节点落盘私钥。"""
    if not private_key_pem:
        return ""
    key = serialization.load_pem_private_key(private_key_pem.encode("utf-8"), password=None)
    signature = key.sign(message.encode("utf-8"), padding.PKCS1v15(), hashes.SHA256())
    return base64.b64encode(signature).decode("ascii")


def cert_serial_no(cert_pem: str | None) -> str:
    """从商户证书 PEM 解析序列号（大写十六进制），用于微信支付 v3 Authorization 头。"""
    if not cert_pem:
        return ""
    try:
        cert = load_pem_x509_certificate(cert_pem.encode("utf-8"))
        return format(cert.serial_number, "X")
    except (ValueError, Exception):  # noqa: BLE001
        return ""


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
