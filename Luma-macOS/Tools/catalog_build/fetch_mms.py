#!/usr/bin/env python3
"""抓取 miaomengshe（萌萌社）的标签与文章，补充国内 / 日韩 / 海外 Coser 资料。

站点是 WordPress，REST API 全开放：
- /wp-json/wp/v2/tags        艺名标签（常带「cosplay / 写真」后缀）
- /wp-json/wp/v2/categories  分类（Cosplay / 日韩模特 / 海外Coser / 秀人网写真）
- /wp-json/wp/v2/posts       图集与「某某是谁」资料页

输出：
- raw/mms_tags.json
- raw/mms_categories.json
- raw/mms_posts.json         列表字段（含摘要，不含正文）
- raw/mms_profiles.json      资料页正文（按标题筛出「是谁 / 资料页 / 名称识别」）

各阶段都会落盘，重跑时跳过已完成的部分；资料页按篇追加，中断也不丢进度。
"""

from __future__ import annotations

import json
import os
import re
import socket
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
BASE = "https://www.miaomengshe.com/wp-json/wp/v2"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                         "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"}
PROFILE = re.compile(r"(是谁|资料页|名称识别|资料整理|外文名|中外文名|代表作品)")
SOCKET_TIMEOUT = 25


def get(url: str, tries: int = 3):
    last = None
    for attempt in range(tries):
        try:
            request = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(request, timeout=SOCKET_TIMEOUT) as response:
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
            print(f"  {path} 第 {page} 页结束：{error}", flush=True)
            break
        if not batch:
            break
        rows.extend(batch)
        print(f"  {path} 第 {page} 页：{len(batch)}（累计 {len(rows)}）", flush=True)
        if len(batch) < 100:
            break
        page += 1
        time.sleep(0.2)
    return rows


def save(name: str, rows):
    json.dump(rows, open(os.path.join(RAW, name), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)


def load(name: str):
    path = os.path.join(RAW, name)
    return json.load(open(path, encoding="utf-8")) if os.path.exists(path) else None


def main():
    os.makedirs(RAW, exist_ok=True)
    socket.setdefaulttimeout(SOCKET_TIMEOUT)

    tags = load("mms_tags.json")
    if tags is None:
        print("抓取 miaomengshe 标签…", flush=True)
        tags = [{"id": row["id"], "name": row["name"], "count": row.get("count", 0),
                 "link": row.get("link")}
                for row in crawl("tags", "id,name,count,link")]
        save("mms_tags.json", tags)
    print(f"标签 {len(tags)} 个", flush=True)

    categories = load("mms_categories.json")
    if categories is None:
        print("抓取分类…", flush=True)
        categories = crawl("categories", "id,name,count,slug")
        save("mms_categories.json", categories)

    posts = load("mms_posts.json")
    if posts is None:
        print("抓取文章列表…", flush=True)
        posts = crawl("posts", "id,title,link,tags,categories,excerpt")
        posts = [{"id": row["id"], "title": row["title"]["rendered"], "link": row["link"],
                  "tags": row.get("tags", []), "categories": row.get("categories", []),
                  "excerpt": re.sub(r"<[^>]+>", "",
                                    row.get("excerpt", {}).get("rendered", "")).strip()}
                 for row in posts]
        save("mms_posts.json", posts)
    print(f"文章 {len(posts)} 篇，分类 {len(categories)} 个", flush=True)

    profiles = load("mms_profiles.json") or []
    done = {profile["id"] for profile in profiles}
    targets = [post for post in posts if PROFILE.search(post["title"])
               and post["id"] not in done]
    print(f"资料页待抓 {len(targets)} / 已抓 {len(profiles)}", flush=True)
    for index, post in enumerate(targets, 1):
        try:
            row = get(f"{BASE}/posts/{post['id']}?_fields=id,title,link,content")
        except RuntimeError as error:
            print(f"  正文失败 {post['id']}：{error}", flush=True)
            continue
        html = row.get("content", {}).get("rendered", "")
        text = re.sub(r"<script[\s\S]*?</script>|<style[\s\S]*?</style>", " ", html)
        text = re.sub(r"<[^>]+>", "\n", text)
        lines = [line.strip() for line in text.splitlines()]
        profiles.append({"id": post["id"], "title": post["title"], "link": post["link"],
                         "tags": post["tags"], "categories": post["categories"],
                         "text": "\n".join(line for line in lines if line)})
        if index % 5 == 0:
            save("mms_profiles.json", profiles)
            print(f"  资料页 {len(profiles)}：{post['title'][:36]}", flush=True)
        time.sleep(0.15)

    save("mms_profiles.json", profiles)
    print(f"完成：标签 {len(tags)} 个，分类 {len(categories)} 个，"
          f"文章 {len(posts)} 篇，资料页 {len(profiles)} 篇", flush=True)


if __name__ == "__main__":
    main()
