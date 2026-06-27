from __future__ import annotations

import re

from .schemas import TranscriptItem
from .settings import settings


_POLITICAL_KEYWORDS = {
    "中国政治",
    "中国政府",
    "中共",
    "共产党",
    "政治局",
    "常委",
    "总书记",
    "国家主席",
    "中央军委",
    "人大",
    "政协",
    "国务院",
    "习近平",
    "习主席",
    "李强",
    "毛泽东",
    "邓小平",
    "江泽民",
    "胡锦涛",
    "六四",
    "天安门事件",
    "法轮功",
    "民主运动",
    "台独",
    "港独",
    "藏独",
    "疆独",
    "台湾独立",
    "香港独立",
    "新疆独立",
    "西藏独立",
    "xi jinping",
    "ccp",
    "chinese communist party",
    "communist party of china",
    "tiananmen",
    "falun gong",
}


_GENERAL_POLITICAL_PATTERNS = (
    re.compile(r"(政治|政党|选举|总统|议会|政府|领导人|国家领导).{0,12}(评价|讨论|看法|观点|支持|反对|批评|预测)"),
    re.compile(r"(评价|讨论|看法|观点|支持|反对|批评|预测).{0,12}(政治|政党|选举|总统|议会|政府|领导人|国家领导)"),
)


def is_political_sensitive(text: str | None) -> bool:
    if not text:
        return False
    # 单一来源：只读 DB（装库时由 db_init 入库）。开关读取异常一律按「开启过滤」处理（涉政过滤只能更严不能更松）。
    try:
        from .storage import db

        enabled = db.get_political_filter_enabled()
    except Exception:  # noqa: BLE001 — 失败即默认开启过滤，绝不因配置读取失败而放行涉政内容
        enabled = True
    if not enabled:
        return False
    normalized = re.sub(r"\s+", "", text.lower())
    if not normalized:
        return False
    if any(keyword.lower().replace(" ", "") in normalized for keyword in _POLITICAL_KEYWORDS):
        return True
    return any(pattern.search(text) for pattern in _GENERAL_POLITICAL_PATTERNS)


def filter_sensitive_transcripts(items: list[TranscriptItem]) -> list[TranscriptItem]:
    return [item for item in items if not is_political_sensitive(item.text)]
