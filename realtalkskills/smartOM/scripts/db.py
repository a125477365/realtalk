#!/usr/bin/env python3
"""smartOM 工单技能 · 数据库访问（受限）。

本脚本是本技能能对数据库做的【全部】操作，只有两种：
  - list   ：读取所有「待处理(open)」工单（只读）；可选把截图落到 OS 临时目录供查看。
  - reject ：把指定工单状态改为 'rejected'（不采纳）——唯一允许的写操作。

刻意不提供任何其它写/改/删能力。支持 sqlite 与 postgresql（仅用标准库 + 已装的 DB 驱动，不依赖 sqlalchemy）。
用法：
  python db.py list   --env config.env [--dump-images]
  python db.py reject --env config.env --ids <id1> <id2> ...
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import tempfile
from urllib.parse import urlparse, unquote


def load_env(path: str | None) -> None:
    if not path or not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            os.environ.setdefault(key.strip(), val.strip().strip('"').strip("'"))


def _connect():
    url = os.environ.get("DATABASE_URL", "").strip()
    if not url:
        sys.exit("DATABASE_URL 未配置（在 config.env 里设置）。")
    # 去掉 sqlalchemy 风格的 +driver 后缀
    scheme = url.split("://", 1)[0].split("+", 1)[0].lower()
    if scheme in ("sqlite", ""):
        # sqlite:////abs/path 或 sqlite:///rel/path
        path = url.split("://", 1)[1]
        path = path.lstrip("/") if not path.startswith("//") else path[1:]
        if url.startswith("sqlite:////"):
            path = "/" + url[len("sqlite:////"):]
        import sqlite3

        conn = sqlite3.connect(path)
        conn.row_factory = sqlite3.Row
        return conn, "sqlite"
    if scheme in ("postgresql", "postgres"):
        dsn = "postgresql://" + url.split("://", 1)[1]
        try:
            import psycopg  # type: ignore

            return psycopg.connect(dsn), "postgres"
        except ImportError:
            try:
                import psycopg2  # type: ignore
                import psycopg2.extras  # noqa: F401

                return psycopg2.connect(dsn), "postgres2"
            except ImportError:
                sys.exit("需要 psycopg(3) 或 psycopg2 来连接 PostgreSQL：pip install 'psycopg[binary]'")
    sys.exit(f"不支持的数据库类型：{scheme}")


def _rows(cur, backend):
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def cmd_list(args) -> None:
    conn, backend = _connect()
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT t.id, t.category, t.subject, t.body, t.images_json, t.user_id, t.created_at, "
            "       COALESCE(u.display_name, u.login_identifier) AS user_name "
            "FROM support_tickets t LEFT JOIN users u ON u.id = t.user_id "
            "WHERE t.status = 'open' ORDER BY t.created_at"
        )
        rows = _rows(cur, backend)
    finally:
        conn.close()

    dump_dir = None
    if args.dump_images and rows:
        dump_dir = tempfile.mkdtemp(prefix="smartom-imgs-")

    out = []
    for r in rows:
        images = []
        try:
            images = json.loads(r.get("images_json") or "[]") or []
        except (json.JSONDecodeError, TypeError):
            images = []
        files = []
        if dump_dir:
            for i, data_url in enumerate(images[:4]):
                try:
                    b64 = data_url.split(",", 1)[1]
                    fp = os.path.join(dump_dir, f"{r['id'][:8]}_{i}.jpg")
                    with open(fp, "wb") as fh:
                        fh.write(base64.b64decode(b64))
                    files.append(fp)
                except Exception:  # noqa: BLE001
                    pass
        out.append(
            {
                "id": r["id"],
                "category_user_selected": r.get("category"),
                "subject": r.get("subject"),
                "body": r.get("body"),
                "image_count": len(images),
                "image_files": files,  # 仅在 --dump-images 时落到 OS 临时目录，供只读查看
                "user": r.get("user_name"),
                "created_at": str(r.get("created_at")),
            }
        )
    print(json.dumps({"count": len(out), "tickets": out, "image_dir": dump_dir}, ensure_ascii=False, indent=2))


def cmd_reject(args) -> None:
    if not args.ids:
        sys.exit("reject 需要 --ids <工单号...>")
    conn, backend = _connect()
    placeholder = "?" if backend == "sqlite" else "%s"
    try:
        cur = conn.cursor()
        updated = []
        for tid in args.ids:
            cur.execute(
                f"UPDATE support_tickets SET status='rejected', updated_at=updated_at "
                f"WHERE id={placeholder} AND status='open'",
                (tid,),
            )
            if cur.rowcount and cur.rowcount > 0:
                updated.append(tid)
        conn.commit()
    finally:
        conn.close()
    print(json.dumps({"rejected": updated, "skipped": [i for i in args.ids if i not in updated]}, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser(description="smartOM 工单数据库访问（仅 list / reject）")
    parser.add_argument("command", choices=["list", "reject"])
    parser.add_argument("--env", default="config.env")
    parser.add_argument("--dump-images", action="store_true", help="把截图落到 OS 临时目录供查看（仅 list）")
    parser.add_argument("--ids", nargs="*", default=[], help="reject 的工单号列表")
    args = parser.parse_args()
    load_env(args.env)
    if args.command == "list":
        cmd_list(args)
    else:
        cmd_reject(args)


if __name__ == "__main__":
    main()
