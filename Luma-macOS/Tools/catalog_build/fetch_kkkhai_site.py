#!/usr/bin/env python3
"""抓取 kkkhai 全站文章与标签，供人物 / 机构资料补全使用。

只依赖 WordPress REST API：
- /wp-json/wp/v2/posts  全部分类（cos / 秀人 / 微密圈 / 众筹私拍 / 丝模 …）
- /wp-json/wp/v2/tags   标签（很多标签就是模特艺名，可当规范写法）

每篇文章会解析出：
- title          标题（含「全套 64 套 / 97.1G / 2026.11」这类统计）
- intro          正文第一段简介（很多作者会写「某某，最新名字叫…」）
- catalog_count  「合集目录」里的条目数（等于已收录套数）
- catalog_latest 目录里最新一条的日期

输出（离线构建脚本只读这两份 JSON）：
- raw/kkkhai_posts_full.json
- raw/kkkhai_tags_full.json
"""

from __future__ import annotations

import html
import json
import os
import re
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
BASE = "https://www.kkkhai.org/wp-json/wp/v2"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                         "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"}
FIELDS = "id,title,date,modified,link,categories,tags,content"

SKIP_LINE = re.compile(
    r"合集目录|预览图|包内原图|无水印|持续更新|解压密码|下载|网盘|会员|VIP"
    r"|本系收录|作品列表|收录[:：]|水印|介意|慎下"
)
DATE_MARK = re.compile(r"^\[(\d{1,2})[.\-/](\d{1,2})\]\s*$")
# 目录条目：带编号 / 日期 / 图包规格的行，不能当成简介。
ENTRY_LINE = re.compile(r"^\[\d|NO\.\s*\d|^\d{1,3}\s*[:：]|\d+\s*[Pp]\s*[-–—]?\s*\d+\s*[MmGg]"
                        r"|^\d{3}(?!\d)|^\d{3}\s*[\[（(《]")


def get_json(url: str, tries: int = 4):
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


def text_of(value: str) -> str:
    value = html.unescape(value or "")
    value = re.sub(r"<br\s*/?>", "\n", value)
    value = re.sub(r"</p>", "\n", value)
    value = re.sub(r"<[^>]+>", "", value)
    value = value.replace("\u00a0", " ")
    return value


def parse_content(content: str):
    """从正文里取简介与合集目录统计。"""
    text = text_of(content)
    lines = [line.strip() for line in text.splitlines()]
    lines = [line for line in lines if line]

    intro_lines = []
    for line in lines:
        if SKIP_LINE.search(line) or DATE_MARK.match(line) or ENTRY_LINE.search(line):
            break
        if len(line) < 6:
            continue
        intro_lines.append(line)
        if len("".join(intro_lines)) > 220:
            break
    intro = " ".join(intro_lines).strip()
    intro = re.sub(r"\s+", " ", intro)[:240]

    count = 0
    latest = None
    for index, line in enumerate(lines):
        match = DATE_MARK.match(line)
        if not match:
            continue
        count += 1
        if latest is None:
            latest = f"{int(match.group(1))}.{int(match.group(2))}"
    if count < 3:
        # 有些合集用「[2026.11.13]」整段日期。
        full = re.findall(r"\[(20\d{2})[.\-/](\d{1,2})[.\-/](\d{1,2})\]", text)
        if len(full) >= 3:
            count = len(full)
            year, month, _ = full[0]
            latest = f"{year}.{int(month)}"
    return intro, count, latest


def crawl_posts():
    posts = []
    page = 1
    while True:
        url = (f"{BASE}/posts?per_page=100&page={page}&orderby=date&order=desc"
               f"&_fields={FIELDS}")
        try:
            batch = get_json(url)
        except RuntimeError as error:
            # 超过最后一页时 WP 返回 400，正常结束。
            print(f"  第 {page} 页结束：{error}")
            break
        if not batch:
            break
        for post in batch:
            intro, count, latest = parse_content(post.get("content", {}).get("rendered", ""))
            posts.append({
                "id": post["id"],
                "title": text_of(post["title"]["rendered"]).strip(),
                "date": post.get("date"),
                "modified": post.get("modified"),
                "link": post.get("link"),
                "categories": post.get("categories", []),
                "tags": post.get("tags", []),
                "intro": intro,
                "catalog_count": count,
                "catalog_latest": latest,
            })
        print(f"  文章第 {page} 页：{len(batch)} 篇（累计 {len(posts)}）")
        if len(batch) < 100:
            break
        page += 1
        time.sleep(0.3)
    return posts


def crawl_tags():
    tags = []
    page = 1
    while True:
        url = f"{BASE}/tags?per_page=100&page={page}&_fields=id,name,slug,count"
        try:
            batch = get_json(url)
        except RuntimeError as error:
            print(f"  标签第 {page} 页结束：{error}")
            break
        if not batch:
            break
        for tag in batch:
            tags.append({
                "id": tag["id"],
                "name": html.unescape(tag["name"]),
                "slug": tag["slug"],
                "count": tag.get("count", 0),
            })
        print(f"  标签第 {page} 页：{len(batch)} 个（累计 {len(tags)}）")
        if len(batch) < 100:
            break
        page += 1
        time.sleep(0.3)
    return tags


def main():
    os.makedirs(RAW, exist_ok=True)
    print("抓取文章…")
    posts = crawl_posts()
    print("抓取标签…")
    tags = crawl_tags()
    json.dump(posts, open(os.path.join(RAW, "kkkhai_posts_full.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    json.dump(tags, open(os.path.join(RAW, "kkkhai_tags_full.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print(f"完成：文章 {len(posts)} 篇，标签 {len(tags)} 个")


if __name__ == "__main__":
    main()
