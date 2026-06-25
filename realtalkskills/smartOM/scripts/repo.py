#!/usr/bin/env python3
"""smartOM 工单技能 · 只读拉取代码用于核验缺陷工单。

只做一件事：把仓库浅克隆到【操作系统临时目录】，打印该路径，供 agent 只读分析。
不碰安装方的工作副本、不改生产代码、不提交、不推送。克隆失败会提示向运维索取只读凭据。

用法：python repo.py pull --env config.env
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from urllib.parse import urlparse


def load_env(path: str | None) -> None:
    if not path or not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def _auth_url(url: str, token: str | None) -> str:
    if not token or "@" in url.split("://", 1)[-1].split("/", 1)[0]:
        return url
    if url.startswith("https://"):
        return "https://" + token + "@" + url[len("https://"):]
    return url


def cmd_pull(args) -> None:
    url = os.environ.get("REPO_URL", "https://github.com/a125477365/realtalk.git").strip()
    token = os.environ.get("REPO_TOKEN", "").strip() or None
    dest = tempfile.mkdtemp(prefix="smartom-repo-")
    clone_url = _auth_url(url, token)
    try:
        subprocess.run(
            ["git", "clone", "--depth", "1", clone_url, dest],
            check=True, capture_output=True, text=True, timeout=300,
        )
    except subprocess.CalledProcessError as exc:
        print(json.dumps({
            "ok": False,
            "error": (exc.stderr or "")[:400],
            "hint": "克隆失败：若为私有库/无凭据，请向运维索取只读账号或带 token 的 URL，填入 config.env 的 REPO_URL/REPO_TOKEN 后重试。",
        }, ensure_ascii=False))
        sys.exit(1)
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)[:200]}, ensure_ascii=False))
        sys.exit(1)
    print(json.dumps({"ok": True, "path": dest, "note": "只读分析用，分析完可丢弃；勿提交/推送/改动。"}, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser(description="smartOM 只读拉取代码")
    parser.add_argument("command", choices=["pull"])
    parser.add_argument("--env", default="config.env")
    args = parser.parse_args()
    load_env(args.env)
    cmd_pull(args)


if __name__ == "__main__":
    main()
