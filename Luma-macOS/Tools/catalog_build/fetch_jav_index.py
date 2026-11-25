#!/usr/bin/env python3
"""从 GitHub 上的 Japanese AV actress 索引抓取完整女优名单。

数据源：`LustyStorage/jav-actress` 仓库的 `pages/<页码>/<艺名>.html` 目录结构。
文件名就是艺名（URL 编码），一次 tree 请求即可拿到整份名单（约 1 万条），
不用逐页爬 javbus / javrate。

输出：raw/jav_actress_index.json
`build_catalog_db.py` 会把这份名单并入 actresses（日本地区，只有名字）。

注意：GitHub 未登录 API 每小时 60 次，这里只消耗 1 次。
"""

from __future__ import annotations

import json
import os
import re
import unicodedata
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
TREE = "https://api.github.com/repos/LustyStorage/jav-actress/git/trees/main?recursive=1"

BLACKLIST = {
    "不明", "素人", "女優", "AV女優", "なし", "無名", "匿名", "その他",
}


def fetch_tree():
    request = urllib.request.Request(TREE, headers={
        "User-Agent": "Mozilla/5.0",
        "Accept": "application/vnd.github+json",
    })
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def clean_name(raw: str):
    value = unicodedata.normalize("NFKC", urllib.parse.unquote(raw)).strip()
    value = re.sub(r"\s+", " ", value)
    aliases = []
    for inner in re.findall(r"[（(]([^（）()]*)[）)]", value):
        aliases.extend(x.strip() for x in re.split(r"[、/／|｜]", inner) if x.strip())
    value = re.sub(r"[（(][^（）()]*[）)]", "", value).strip()
    if not value or value in BLACKLIST:
        return None
    if not (2 <= len(value) <= 24):
        return None
    if re.search(r"[\\/:*?\"<>|]", value):
        return None
    return value, [alias for alias in aliases if 2 <= len(alias) <= 24]


def main():
    tree = fetch_tree()
    blobs = tree.get("tree", [])
    seen = {}
    for item in blobs:
        path = item.get("path", "")
        if item.get("type") != "blob" or not re.match(r"^pages/\d+/", path):
            continue
        stem = path.split("/", 2)[2].rsplit(".", 1)[0]
        cleaned = clean_name(stem)
        if not cleaned:
            continue
        name, aliases = cleaned
        if name in seen:
            for alias in aliases:
                if alias not in seen[name]:
                    seen[name].append(alias)
        else:
            seen[name] = aliases

    records = [{
        "name": name,
        "aliases": aliases,
        "region": "japan",
        "tags": [],
        "source": "GitHub 女优索引",
    } for name, aliases in seen.items()]
    records.sort(key=lambda row: row["name"])
    path = os.path.join(RAW, "jav_actress_index.json")
    json.dump(records, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"抓取到 {len(records)} 位女优（含 {sum(len(r['aliases']) for r in records)} 个括号别名）")


if __name__ == "__main__":
    main()
