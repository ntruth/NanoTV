#!/usr/bin/env python3
"""抓取 coscd（萌萌秀）的标签与 COS 作品标题，补充国内 Coser / 网红名单。

数据源是 WordPress REST API：
- /wp-json/wp/v2/tags              标签名大多就是 Coser 艺名
- /wp-json/wp/v2/posts?categories=  COS 作品标题（含「某某 COS 某角色」）

输出：
- raw/coscd_tags.json
- raw/coscd_posts.json
"""

from __future__ import annotations

import json
import os
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
BASE = "https://www.coscd.com/wp-json/wp/v2"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                         "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"}
COS_CATEGORY = 518  # COS作品


def get(url: str, tries: int = 4):
    last = None
    for attempt in range(tries):
        try:
            request = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(request, timeout=40) as response:
                return json.loads(response.read().decode("utf-8"))
        except Exception as error:  # noqa: BLE001 - 网络异常统一重试
            last = error
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"请求失败：{url}（{last}）")


def crawl(path: str, fields: str, extra: str = ""):
    rows = []
    page = 1
    while True:
        try:
            batch = get(f"{BASE}/{path}?per_page=100&page={page}&_fields={fields}{extra}")
        except RuntimeError as error:
            print(f"  {path} 第 {page} 页结束：{error}")
            break
        if not batch:
            break
        rows.extend(batch)
        print(f"  {path} 第 {page} 页：{len(batch)}（累计 {len(rows)}）")
        if len(batch) < 100:
            break
        page += 1
        time.sleep(0.3)
    return rows


def main():
    os.makedirs(RAW, exist_ok=True)
    print("抓取 coscd 标签…")
    tags = [{"id": row["id"], "name": row["name"], "count": row.get("count", 0)}
            for row in crawl("tags", "id,name,count")]
    print("抓取 coscd COS 作品标题…")
    posts = crawl("posts", "id,title,link,tags", extra=f"&categories={COS_CATEGORY}")
    posts = [{"id": row["id"], "title": row["title"]["rendered"], "link": row["link"],
              "tags": row.get("tags", [])} for row in posts]

    json.dump(tags, open(os.path.join(RAW, "coscd_tags.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    json.dump(posts, open(os.path.join(RAW, "coscd_posts.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print(f"完成：标签 {len(tags)} 个，COS 作品 {len(posts)} 篇")


if __name__ == "__main__":
    main()
