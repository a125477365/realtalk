#!/usr/bin/env python3
"""smartOM 工单技能 · 把工单日报推送到渠道（飞书 / 企业微信机器人）。

只做一件事：把一段 Markdown/文本报告发到配置的 Webhook。不读不改任何业务数据。
配置（config.env，任一）：
  FEISHU_WEBHOOK=https://open.feishu.cn/open-apis/bot/v2/hook/xxxx
  WECHAT_WEBHOOK=https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxx

用法：python notify.py --env config.env --file report.md
      python notify.py --env config.env --text "一行文本"
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request


def load_env(path: str | None) -> None:
    if not path or not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def _post(url: str, payload: dict) -> tuple[int, str]:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:  # noqa: S310 — 受信任的 webhook
        return resp.status, resp.read().decode("utf-8", "ignore")


def main() -> None:
    parser = argparse.ArgumentParser(description="smartOM 渠道推送")
    parser.add_argument("--env", default="config.env")
    parser.add_argument("--file", help="报告 Markdown 文件路径")
    parser.add_argument("--text", help="直接发送的文本")
    parser.add_argument("--title", default="RealTalk 工单日报")
    args = parser.parse_args()
    load_env(args.env)

    if args.file:
        with open(args.file, "r", encoding="utf-8") as fh:
            content = fh.read()
    elif args.text:
        content = args.text
    else:
        sys.exit("需要 --file 或 --text")

    feishu = os.environ.get("FEISHU_WEBHOOK", "").strip()
    wechat = os.environ.get("WECHAT_WEBHOOK", "").strip()
    if not feishu and not wechat:
        sys.exit("未配置 FEISHU_WEBHOOK 或 WECHAT_WEBHOOK。")

    sent = []
    if feishu:
        # 飞书自定义机器人：文本消息（Markdown 以纯文本形式发送，保证兼容）
        status, _ = _post(feishu, {"msg_type": "text", "content": {"text": content}})
        sent.append(("feishu", status))
    if wechat:
        # 企业微信机器人：markdown 消息（长度上限约 4096 字节，超长自动截断）
        body = content if len(content.encode("utf-8")) < 4000 else content.encode("utf-8")[:4000].decode("utf-8", "ignore") + "\n…(已截断)"
        status, _ = _post(wechat, {"msgtype": "markdown", "markdown": {"content": body}})
        sent.append(("wechat", status))
    print(json.dumps({"sent": sent}, ensure_ascii=False))


if __name__ == "__main__":
    main()
