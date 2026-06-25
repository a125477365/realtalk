"""语音文件服务器：列表配置 / MD5 路由 / 本地存放命名 / 定时任务文件扫描。

设计要点（与需求一致）：
- 「可处理语音文件的服务器列表」在管理台配置并存库（app_settings.voice_servers，格式 `ip:port;ip:port`）。
  未配置则上传直接报错，不本地兜底。
- 路由规则：某文件该由哪台处理 = 服务器列表[ int(md5 后4位十六进制, 16) % 服务器数 ]
  （示例 c592→50578，50578%3=1，第 2 台）。本机命中则本地处理，否则把整请求转发到目标 ip:port。
- 本机地址（settings.voice_node_addr / .env VOICE_NODE_ADDR）用于判断「该文件是否归我处理」。
- 本地命名：{user_id}_{md5}{原后缀}（边传边写）。完成后打一个同名 `.ready` 标记，定时任务据此识别「已传完」。
  转写后写 {user_id}_{md5}.txt 并删音频；生成场景后打 {user_id}_{md5}.txt.done 标记。
"""
from __future__ import annotations

import re
import time
from pathlib import Path

from .settings import settings

_AUDIO_EXTS = {".mp3", ".wav", ".m4a"}
_SAFE = re.compile(r"[^A-Za-z0-9_-]")
_MD5_RE = re.compile(r"^[0-9a-fA-F]{32}$")


# ---- 服务器列表与路由 ----

def voice_servers() -> list[str]:
    """从数据库读取可处理语音文件的服务器列表（管理台配置）。返回 ip:port 列表，未配置返回空。"""
    from .storage import db

    raw = db.get_app_setting_str("voice_servers") or ""
    out: list[str] = []
    seen: set[str] = set()
    for part in raw.replace(",", ";").replace("\n", ";").split(";"):
        addr = normalize_addr(part)
        if addr and addr not in seen:  # 去重，避免重复项打乱 MD5 取模分布
            seen.add(addr)
            out.append(addr)
    return out


def normalize_addr(addr: str | None) -> str:
    """去掉协议/空白/尾斜杠，统一成 ip:port 形式。"""
    if not addr:
        return ""
    a = addr.strip().lower()
    if "//" in a:
        a = a.split("//", 1)[1]
    return a.strip("/").strip()


def valid_md5(md5: str | None) -> bool:
    return bool(md5 and _MD5_RE.match(md5))


def route_target(md5: str, servers: list[str]) -> str:
    """按 md5 后 4 位十六进制取模选服务器：servers[int(md5[-4:],16) % N]。"""
    if not servers:
        raise ValueError("语音服务器列表为空")
    idx = int(md5[-4:], 16) % len(servers)
    return servers[idx]


def is_self(addr: str) -> bool:
    """目标地址是否就是本机（settings.voice_node_addr）。容忍只配 ip（无端口）的情况。"""
    me = normalize_addr(settings.voice_node_addr)
    if not me:
        return False
    target = normalize_addr(addr)
    if me == target:
        return True
    # 只配了 ip 没配端口时，按 ip 比对
    return me.split(":", 1)[0] == target.split(":", 1)[0] and (":" not in me or ":" not in target)


# ---- 本地命名与路径 ----

def _safe(user_id: str) -> str:
    return _SAFE.sub("", user_id or "")


def voice_dir() -> Path:
    d = settings.voice_dir
    d.mkdir(parents=True, exist_ok=True)
    return d


def audio_path(user_id: str, md5: str, ext: str) -> Path:
    return voice_dir() / f"{_safe(user_id)}_{md5}{ext}"


def ready_marker(audio: Path) -> Path:
    return audio.with_name(audio.name + ".ready")


def txt_path(user_id: str, md5: str) -> Path:
    return voice_dir() / f"{_safe(user_id)}_{md5}.txt"


def done_marker(user_id: str, md5: str) -> Path:
    return voice_dir() / f"{_safe(user_id)}_{md5}.txt.done"


def find_audio(user_id: str, md5: str) -> Path | None:
    """找已存在的（完整或半截的）音频文件 {user_id}_{md5}.{ext}。"""
    prefix = f"{_safe(user_id)}_{md5}"
    for p in voice_dir().glob(prefix + ".*"):
        if p.suffix.lower() in _AUDIO_EXTS:
            return p
    return None


def parse_audio_name(path: Path) -> tuple[str, str, str]:
    """{user_id}_{md5}.{ext} → (user_id, md5, ext)。user_id 为 uuid hex（无下划线），md5 为 32 位。"""
    stem = path.stem  # user_id_md5
    user_id, _, md5 = stem.partition("_")
    return user_id, md5, path.suffix


# ---- 定时任务的文件扫描 ----

def list_ready_audio() -> list[Path]:
    """列出「已传完（有 .ready 标记）且尚未转写（无 .txt）」的音频文件。"""
    out: list[Path] = []
    for ready in voice_dir().glob("*.ready"):
        audio = ready.with_name(ready.name[: -len(".ready")])  # 去掉 .ready
        if audio.suffix.lower() not in _AUDIO_EXTS or not audio.exists():
            ready.unlink(missing_ok=True)
            continue
        user_id, md5, _ = parse_audio_name(audio)
        if txt_path(user_id, md5).exists():  # 已转写则清掉残留标记
            ready.unlink(missing_ok=True)
            continue
        out.append(audio)
    return out


def list_pending_txt() -> list[Path]:
    """列出「已转写但尚未生成场景（无 .txt.done 标记）」的 txt 文件。"""
    out: list[Path] = []
    for txt in voice_dir().glob("*.txt"):
        user_id, md5, _ = parse_audio_name(txt)  # {user_id}_{md5}.txt 同样可解析
        if done_marker(user_id, md5).exists():
            continue
        out.append(txt)
    return out


def cleanup_old(days: int = 3) -> int:
    """清理 voice_dir 下所有修改时间早于 days 天的文件（音频/中间/txt/标记一律清，失败即失败用户重传）。"""
    cutoff = time.time() - days * 86400
    removed = 0
    d = settings.voice_dir
    if not d.exists():
        return 0
    for p in d.iterdir():
        if not p.is_file():
            continue
        try:
            if p.stat().st_mtime < cutoff:
                p.unlink(missing_ok=True)
                removed += 1
        except OSError:
            continue
    return removed
