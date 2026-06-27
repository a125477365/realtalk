"""数据库供给（一次性，装库时跑）：建表 + 迁移 + 把「系统参数」入库 + 建默认管理员 + 打供给标记。

用法（装库节点跑一次，不在 API 启动时跑）：
    python -m app.db_init

设计要点（多活控制）：
- 建表/迁移/系统参数入库只在这里做一次（单一执行者），API 后端只读已供给的库、绝不建表/播种，
  从根上消除多个后端并发建表/播种的竞争与「系统参数取值看谁先播种」的不确定。
- 系统参数的初始值来自本次运行的环境变量（装库时一次性传入），写进 DB 后即以 DB 为唯一来源；
  这些值不需要、也不应长期留在各后端的 .env 里。幂等：可重复跑（以后加列/补默认也跑它）。
"""
from __future__ import annotations


def main() -> int:
    from .storage import db
    from .auth import seed_default_admin

    print("[db_init] 建表 + 迁移 …", flush=True)
    db.initialize()

    print("[db_init] 系统参数入库（从环境变量取初始值，仅本次）…", flush=True)
    written = db.seed_app_settings_from_env()

    print("[db_init] 建默认管理员（若无）…", flush=True)
    seed_default_admin()

    db.mark_provisioned()
    print(f"[db_init] ✅ 供给完成：新写入 {written} 个系统参数；schema_version={db._SCHEMA_VERSION}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
