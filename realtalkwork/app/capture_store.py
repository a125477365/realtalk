from __future__ import annotations

"""对话采集分块暂存（ephemeral chunk staging）。

设计取舍：
采集上传是「先分块攒齐、生成场景后即删」的一次性临时数据，绝不应长期落到主库。
用 Redis 存（成熟 AI 后台处理大上下文上传的常用做法）：天然 TTL 自动回收被放弃的会话、
读写快、跨节点共享、不污染主库，最契合这种「短命、高频、用完即弃」的数据。

重要：REDIS_URL 必须配置且能连通，否则服务启动直接报错（多活部署下本地文件方案会导致
chunk 落在不同机器上无法汇总，因此本地文件兜底已被移除）。
"""

import json
import re

from .schemas import TranscriptItem
from .settings import settings

_TTL_SECONDS = 3600  # 1 小时未完成的采集会话自动过期回收
_VALID_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


class CaptureLimitError(ValueError):
    pass


def _valid(upload_id: str) -> bool:
    return bool(_VALID_ID.match(upload_id or ""))


def _clean_sort(raw_items: list[dict]) -> list[TranscriptItem]:
    from .storage import clean_transcript_items

    items = [TranscriptItem.model_validate(it) for it in raw_items]
    return sorted(clean_transcript_items(items), key=lambda item: item.timestamp)


class _RedisBackend:
    backend = "redis"

    def __init__(self, client) -> None:
        self.r = client

    def _key(self, user_id: str, upload_id: str) -> str:
        return f"rt:capture:{user_id}:{upload_id}"

    def init_session(self, upload_id: str, user_id: str, meta: dict) -> None:
        key = self._key(user_id, upload_id)
        self.r.delete(key)
        self.r.hset(key, "meta", json.dumps(meta, ensure_ascii=False))
        self.r.expire(key, _TTL_SECONDS)

    def append_chunk(self, upload_id: str, user_id: str, chunk_index: int, items: list[dict]) -> int:
        key = self._key(user_id, upload_id)
        if not self.r.exists(key):
            return -1
        field = f"chunk:{chunk_index:06d}"
        encoded = json.dumps(items, ensure_ascii=False)
        # Redis Hash 中只保存短命的采集会话，但仍必须给每个会话设置总量上限。
        data = self.r.hgetall(key)
        old = data.get(field, "")
        chunk_fields = [name for name in data if name.startswith("chunk:")]
        if field not in data and len(chunk_fields) >= settings.capture_upload_max_chunks:
            raise CaptureLimitError("采集分块数超过上限")
        total_bytes = sum(len(value.encode("utf-8")) for name, value in data.items() if name.startswith("chunk:"))
        total_bytes += len(encoded.encode("utf-8")) - len(old.encode("utf-8"))
        if total_bytes > settings.capture_upload_max_bytes:
            raise CaptureLimitError("采集内容超过大小上限")
        total_items = 0
        for name, value in data.items():
            if not name.startswith("chunk:") or name == field:
                continue
            try:
                total_items += len(json.loads(value))
            except (json.JSONDecodeError, TypeError):
                continue
        total_items += len(items)
        if total_items > settings.capture_upload_max_items:
            raise CaptureLimitError("采集条目数超过上限")
        self.r.hset(key, field, encoded)
        self.r.expire(key, _TTL_SECONDS)
        return sum(1 for field in self.r.hkeys(key) if field.startswith("chunk:"))

    def received_chunks(self, upload_id: str, user_id: str) -> list[int]:
        out: list[int] = []
        for field in self.r.hkeys(self._key(user_id, upload_id)):
            if field.startswith("chunk:"):
                try:
                    out.append(int(field.split(":", 1)[1]))
                except (ValueError, IndexError):
                    continue
        return sorted(out)

    def load_items(self, upload_id: str, user_id: str) -> list[TranscriptItem] | None:
        key = self._key(user_id, upload_id)
        if not self.r.exists(key):
            return None
        data = self.r.hgetall(key)
        raw: list[dict] = []
        for field in sorted(f for f in data if f.startswith("chunk:")):
            try:
                raw.extend(json.loads(data[field]))
            except json.JSONDecodeError:
                continue
        return _clean_sort(raw)

    def delete_session(self, upload_id: str, user_id: str) -> None:
        self.r.delete(self._key(user_id, upload_id))

    # ---- 异步场景生成队列（多活：任务推入共享队列，任意节点的消费者领取处理）----

    _JOBS_KEY = "rt:capture:jobs"

    def _lock_key(self, user_id: str, upload_id: str) -> str:
        return f"rt:capture:gen:{user_id}:{upload_id}"

    def enqueue_generation(self, user_id: str, upload_id: str) -> bool:
        """把生成任务推入队列。用 SETNX 锁去重，避免重复 complete 造成重复生成。返回是否新入队。"""
        # 锁 TTL 给足生成时间，过期后允许重试；处理完成会主动清锁
        if not self.r.set(self._lock_key(user_id, upload_id), "1", nx=True, ex=2 * 3600):
            return False
        self.r.lpush(
            self._JOBS_KEY,
            json.dumps({"user_id": user_id, "upload_id": upload_id}, ensure_ascii=False),
        )
        return True

    def dequeue_generation(self, timeout: int = 2) -> dict | None:
        """阻塞等待一个生成任务；多活下由 Redis 把每个任务只分发给一个节点。无任务返回 None。"""
        res = self.r.brpop(self._JOBS_KEY, timeout=timeout)
        if not res:
            return None
        try:
            return json.loads(res[1])
        except (json.JSONDecodeError, IndexError, TypeError):
            return None

    def clear_generation_lock(self, user_id: str, upload_id: str) -> None:
        self.r.delete(self._lock_key(user_id, upload_id))


def _build_store() -> _RedisBackend:
    """构建采集暂存实例。REDIS_URL 必须配置且能连通，否则直接报错终止（不再回退本地文件）。"""
    import time as _time

    url = settings.redis_url
    if not url:
        raise RuntimeError(
            "[capture] REDIS_URL 未配置！对话采集必须使用 Redis 作为分块暂存（多活部署下本地文件会导致 "
            "chunk 落在不同机器上无法汇总）。请在 .env 中设置 REDIS_URL，例如：redis://redis:6379/0"
        )

    try:
        import redis  # type: ignore
    except ImportError as exc:
        raise RuntimeError(
            "[capture] 未安装 redis 库（pip install redis），对话采集必须依赖 Redis，无法回退本地文件。"
        ) from exc

    client = redis.Redis.from_url(
        url, decode_responses=True, socket_timeout=5, socket_connect_timeout=5, retry_on_timeout=True
    )
    # 容器编排下 api 可能先于 redis 就绪：重试最多 10 秒，超时则报错终止（不再静默回退）
    for attempt in range(10):
        try:
            client.ping()
            print(f"[capture] 采集分块暂存已连接 Redis：{url}", flush=True)
            return _RedisBackend(client)
        except Exception as exc:  # noqa: BLE001
            if attempt == 9:
                raise RuntimeError(
                    f"[capture] Redis 连接失败（{url}）：{str(exc)[:120]}。"
                    "对话采集必须依赖 Redis，请检查 REDIS_URL 配置及 Redis 服务是否正常运行。"
                ) from exc
            _time.sleep(1)
    # 理论上不会到这里
    raise RuntimeError("[capture] Redis 初始化异常终止")


capture_store = _build_store()
