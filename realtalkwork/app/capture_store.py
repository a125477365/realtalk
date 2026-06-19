from __future__ import annotations

"""对话采集分块暂存（ephemeral chunk staging）。

设计取舍（Part 3 分析）：
采集上传是「先分块攒齐、生成场景后即删」的一次性临时数据，绝不应长期落到主库。
- 用 PostgreSQL 表（chunks_json TEXT）存：每条 chunk 都是 INSERT/UPDATE + 完成后 DELETE，
  造成写放大、表膨胀、VACUUM/WAL 压力，且大文本挤占主库连接与缓存；
- 用本地文件存：单机可行，但多 worker 节点时 chunk 可能落在不同机器上无法汇总；
- 用 Redis 存（成熟 AI 后台处理大上下文上传的常用做法）：天然 TTL 自动回收被放弃的会话、
  读写快、跨节点共享、不污染主库，最契合这种「短命、高频、用完即弃」的数据。

因此：配置了 REDIS_URL 就用 Redis（每会话一个带 TTL 的 hash）；否则回退本地文件（单机够用）。
"""

import json
import os
import re
import shutil
import time
from pathlib import Path

from .schemas import TranscriptItem
from .settings import settings

_TTL_SECONDS = 3600  # 1 小时未完成的采集会话自动过期回收
_VALID_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def _valid(upload_id: str) -> bool:
    return bool(_VALID_ID.match(upload_id or ""))


def _clean_sort(raw_items: list[dict]) -> list[TranscriptItem]:
    from .storage import clean_transcript_items

    items = [TranscriptItem.model_validate(it) for it in raw_items]
    return sorted(clean_transcript_items(items), key=lambda item: item.timestamp)


class _FileBackend:
    backend = "filesystem"

    def _root(self) -> Path:
        root = settings.upload_dir / "capture_text"
        root.mkdir(parents=True, exist_ok=True)
        return root

    def _dir(self, user_id: str, upload_id: str) -> Path:
        return self._root() / user_id / upload_id

    def _cleanup_stale(self) -> None:
        cutoff = time.time() - _TTL_SECONDS
        root = self._root()
        if not root.exists():
            return
        for user_dir in root.iterdir():
            if not user_dir.is_dir():
                continue
            for sess in user_dir.iterdir():
                try:
                    marker = sess / "meta.json"
                    mtime = marker.stat().st_mtime if marker.exists() else sess.stat().st_mtime
                    if sess.is_dir() and mtime < cutoff:
                        shutil.rmtree(sess, ignore_errors=True)
                except OSError:
                    continue

    def init_session(self, upload_id: str, user_id: str, meta: dict) -> None:
        self._cleanup_stale()
        session_dir = self._dir(user_id, upload_id)
        (session_dir / "chunks").mkdir(parents=True, exist_ok=True)
        (session_dir / "meta.json").write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")

    def append_chunk(self, upload_id: str, user_id: str, chunk_index: int, items: list[dict]) -> int:
        session_dir = self._dir(user_id, upload_id)
        if not session_dir.exists():
            return -1
        chunks = session_dir / "chunks"
        chunks.mkdir(parents=True, exist_ok=True)
        (chunks / f"{chunk_index:06d}.json").write_text(json.dumps(items, ensure_ascii=False), encoding="utf-8")
        # 续期：刷新 meta.json 的 mtime，避免长时间上传被回收
        try:
            os.utime(session_dir / "meta.json", None)
        except OSError:
            pass
        return len(list(chunks.glob("*.json")))

    def received_chunks(self, upload_id: str, user_id: str) -> list[int]:
        chunks = self._dir(user_id, upload_id) / "chunks"
        out: list[int] = []
        if chunks.exists():
            for path in chunks.glob("*.json"):
                try:
                    out.append(int(path.stem))
                except ValueError:
                    continue
        return sorted(out)

    def load_items(self, upload_id: str, user_id: str) -> list[TranscriptItem] | None:
        session_dir = self._dir(user_id, upload_id)
        if not session_dir.exists():
            return None
        chunks = session_dir / "chunks"
        raw: list[dict] = []
        if chunks.exists():
            for path in sorted(chunks.glob("*.json")):
                try:
                    raw.extend(json.loads(path.read_text(encoding="utf-8")))
                except (OSError, json.JSONDecodeError):
                    continue
        return _clean_sort(raw)

    def delete_session(self, upload_id: str, user_id: str) -> None:
        shutil.rmtree(self._dir(user_id, upload_id), ignore_errors=True)


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
        self.r.hset(key, f"chunk:{chunk_index:06d}", json.dumps(items, ensure_ascii=False))
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


def _build_store():
    url = settings.redis_url
    if not url:
        return _FileBackend()
    try:
        import redis  # type: ignore
    except ImportError:
        print("[capture] 未安装 redis 库，回退本地文件暂存", flush=True)
        return _FileBackend()

    client = redis.Redis.from_url(
        url, decode_responses=True, socket_timeout=5, socket_connect_timeout=5, retry_on_timeout=True
    )
    # 容器编排下 api 可能先于 redis 就绪：短暂重试，避免误判为不可用而回退
    import time as _time

    for attempt in range(5):
        try:
            client.ping()
            print("[capture] 采集分块暂存使用 Redis", flush=True)
            return _RedisBackend(client)
        except Exception as exc:  # noqa: BLE001
            if attempt == 4:
                print(f"[capture] Redis 暂不可用，回退本地文件暂存：{str(exc)[:120]}", flush=True)
                return _FileBackend()
            _time.sleep(1)
    return _FileBackend()


capture_store = _build_store()
