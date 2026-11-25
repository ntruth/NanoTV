#!/usr/bin/env python3
"""把抓取下来的 javrate「全部AV女優」列表页汇总成 raw/javrate_actors_all.json。

输入：
- 仓库里已有的 raw/javrate_actors_p1..p20.md
- 目录里 WebFetch 保存下来的列表页文本（默认 ~/.trae/work/.trae/toolcall-output）

输出：raw/javrate_actors_all.json（按作品数倒序，URL 去重）

用法：python3 Tools/catalog_build/import_javrate_dump.py [目录]
"""

from __future__ import annotations

import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_catalog_db import RAW, parse_javrate_text  # noqa: E402


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/.trae/work/.trae/toolcall-output")
    seen: dict[str, dict] = {}

    for path in glob.glob(os.path.join(source, "*.txt")) + glob.glob(os.path.join(source, "*.md")):
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if "共找到AV女優" not in text:
            continue
        for record in parse_javrate_text(text):
            seen.setdefault(record["url"], record)

    for path in sorted(glob.glob(os.path.join(RAW, "javrate_actors_p*.md"))):
        for record in parse_javrate_text(open(path, encoding="utf-8").read()):
            seen.setdefault(record["url"], record)

    records = sorted(seen.values(), key=lambda row: (-(row.get("works") or 0), row["name"]))
    out = os.path.join(RAW, "javrate_actors_all.json")
    json.dump(records, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    with_stats = sum(1 for row in records if row.get("height"))
    print(f"整理出 {len(records)} 位女优（有作品数 "
          f"{sum(1 for r in records if r['works'])}，有身高 {with_stats}）→ {out}")


if __name__ == "__main__":
    main()
