#!/usr/bin/env python3
"""通过本机 MonoProxy 抓取 javbus 的女优列表与演员页。

javbus 有年龄门（/doc/driver-verify.php 的交通法规题），通过后服务端下发
`dv=1` 一年的 cookie；本机代理 127.0.0.1:8118 已可直连。

用法：
- python3 fetch_javbus.py lists    抓中文 / 日文两份女优列表（~1066 页 × 2）
- python3 fetch_javbus.py details  抓 raw/javbus_star_ids.json 里列的演员页
                                  可加 --limit N 只试跑 N 个

输出：
- raw/javbus_stars_zh.json       {star_id: 日文名}
- raw/javbus_stars_ja.json       {star_id: 日文名}（仅 --both）
- raw/javbus_star_details.json   {star_id: {birthday, age, height, cup, ...}}
                                 没有资料的演员页记为 {"empty": true}，不再重复抓。
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import re
import sys
import threading
import time

import requests

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
BASE = "https://www.javbus.com"
PROXY = os.environ.get("MONO_PROXY", "http://127.0.0.1:8118")
COOKIE = os.environ.get("JAVBUS_COOKIE", "dv=1")
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9",
    "Referer": BASE + "/",
    "Cookie": COOKIE,
    "Connection": "keep-alive",
}
CARD = re.compile(
    r'<a[^>]+class="avatar-box[^"]*"[^>]+href="[^"]*/star/([a-z0-9]+)"[\s\S]{0,400}?'
    r"<span[^>]*>([^<]+)</span>")
FIELD = re.compile(r"<p>(生日|年齡|身高|罩杯|胸圍|腰圍|臀圍|愛好):\s*([^<]*)</p>")
WORKERS = 4
THROTTLE = 0.35     # 每个线程成功请求后的间隔；429 时指数退避
EMPTY = {"empty": True}

_local = threading.local()


class NotFound(Exception):
    """页面不存在（列表翻到底）。"""


def worker_session() -> requests.Session:
    session = getattr(_local, "session", None)
    if session is None:
        session = requests.Session()
        session.proxies.update({"http": PROXY, "https": PROXY})
        session.headers.update(HEADERS)
        _local.session = session
    return session


def get(url: str, tries: int = 6) -> str:
    last = None
    for attempt in range(tries):
        try:
            response = worker_session().get(url, timeout=30)
            if "driver-verify" in response.url:
                raise RuntimeError("年龄门失效，请先在浏览器通过验证并更新 JAVBUS_COOKIE")
            if response.status_code == 404:
                raise NotFound(url)
            if response.status_code == 429:
                last = "429"
                time.sleep(8 + 4 * attempt)
                continue
            response.raise_for_status()
            time.sleep(THROTTLE)
            return response.text
        except NotFound:
            raise
        except requests.RequestException as error:
            last = error
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"请求失败：{url}（{last}）")


def page_count() -> int:
    low, high = 1, 2000
    while low < high:
        middle = (low + high + 1) // 2
        try:
            html = get(f"{BASE}/actresses/{middle}")
        except NotFound:
            high = middle - 1
            continue
        if "avatar-box" in html:
            low = middle
        else:
            high = middle - 1
    return low


def crawl_list(language: str, last: int) -> dict:
    prefix = f"{BASE}/{language}/actresses" if language else f"{BASE}/actresses"

    def one(page: int):
        try:
            html = get(f"{prefix}/{page}")
        except NotFound:
            return {}
        return dict(CARD.findall(html))

    result = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = {pool.submit(one, page): page for page in range(1, last + 1)}
        for index, future in enumerate(concurrent.futures.as_completed(futures), 1):
            page = futures[future]
            try:
                rows = future.result()
            except RuntimeError as error:
                print(f"  第 {page} 页失败：{error}")
                continue
            result.update(rows)
            if index % 100 == 0:
                print(f"  {language or 'zh'} 第 {index}/{last} 页，累计 {len(result)} 人")
    return result


def parse_details(html: str):
    fields = {key: value.strip() for key, value in FIELD.findall(html)}
    if not fields:
        return None

    def number(key):
        match = re.search(r"\d+", fields.get(key, ""))
        return int(match.group(0)) if match else None

    birthday = fields.get("生日") or ""
    return {
        "birthday": birthday if re.fullmatch(r"\d{4}-\d{2}-\d{2}", birthday) else None,
        "age": number("年齡"),
        "height": number("身高"),
        "cup": (fields.get("罩杯") or "").strip() or None,
        "bust": number("胸圍"),
        "waist": number("腰圍"),
        "hips": number("臀圍"),
        "hobby": fields.get("愛好") or None,
    }


def crawl_details(limit: int | None = None):
    ids = json.load(open(os.path.join(RAW, "javbus_star_ids.json"), encoding="utf-8"))
    path = os.path.join(RAW, "javbus_star_details.json")
    details = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
    todo = [star for star in ids if star not in details]
    if limit:
        todo = todo[:limit]
    print(f"演员页待抓 {len(todo)} / {len(ids)}（已有记录 {len(details)}）", flush=True)

    started = time.time()
    saved = 0
    empty = 0
    failed = 0

    def one(star: str):
        try:
            return star, parse_details(get(f"{BASE}/star/{star}"))
        except NotFound:
            return star, None

    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = [pool.submit(one, star) for star in todo]
        for index, future in enumerate(concurrent.futures.as_completed(futures), 1):
            try:
                star, info = future.result()
            except RuntimeError as error:
                failed += 1
                print(f"  失败：{error}", flush=True)
                continue
            if info:
                details[star] = info
                saved += 1
            else:
                details[star] = EMPTY
                empty += 1
            if index % 100 == 0:
                json.dump(details, open(path, "w", encoding="utf-8"),
                          ensure_ascii=False, indent=0)
                elapsed = max(time.time() - started, 1)
                print(f"  {index}/{len(todo)} 有资料 {saved} 无资料 {empty} 失败 {failed}"
                      f"｜{index / elapsed:.2f} 个/秒", flush=True)
    json.dump(details, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=0)
    real = sum(1 for value in details.values() if value is not EMPTY and not value.get("empty"))
    print(f"完成：记录 {len(details)} 个演员页，其中有资料 {real}，空页面 {len(details) - real}")


def crawl_portraits(limit: int | None = None):
    """检查演员页头像 /pics/actress/{star_id}_a.jpg 是否存在。

    有资料的演员页约 88% 有头像，全部演员页只有 38%，所以必须逐个探活，
    不能按 URL 规则硬拼。
    """
    ids = json.load(open(os.path.join(RAW, "portrait_candidates.json"), encoding="utf-8"))
    path = os.path.join(RAW, "javbus_portraits.json")
    portraits = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
    todo = [star for star in ids if star not in portraits]
    if limit:
        todo = todo[:limit]
    print(f"头像待检查 {len(todo)} / {len(ids)}（已有记录 {len(portraits)}）", flush=True)

    started = time.time()
    found = 0

    def one(star: str):
        url = f"{BASE}/pics/actress/{star}_a.jpg"
        try:
            response = worker_session().head(url, timeout=20)
            return star, url if response.status_code == 200 else None
        except requests.RequestException:
            return star, None

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(one, star) for star in todo]
        for index, future in enumerate(concurrent.futures.as_completed(futures), 1):
            star, url = future.result()
            portraits[star] = url
            if url:
                found += 1
            if index % 500 == 0:
                json.dump(portraits, open(path, "w", encoding="utf-8"),
                          ensure_ascii=False, indent=0)
                elapsed = max(time.time() - started, 1)
                print(f"  {index}/{len(todo)} 有头像 {found}｜{index / elapsed:.1f} 个/秒",
                      flush=True)
    json.dump(portraits, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=0)
    total = sum(1 for value in portraits.values() if value)
    print(f"完成：检查 {len(portraits)} 个演员页，有头像 {total}")


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "lists"
    os.makedirs(RAW, exist_ok=True)
    if action == "portraits":
        limit = None
        if "--limit" in sys.argv:
            limit = int(sys.argv[sys.argv.index("--limit") + 1])
        crawl_portraits(limit)
        return
    if action == "details":
        limit = None
        if "--limit" in sys.argv:
            limit = int(sys.argv[sys.argv.index("--limit") + 1])
        crawl_details(limit)
        return
    last = page_count()
    print(f"女优列表共 {last} 页，开始抓取…")
    zh = crawl_list("", last)
    ja = zh
    if "--both" in sys.argv:
        # 实测两个语言版本的列表都是日文原名，需要时再抓一份做校验。
        ja = crawl_list("ja", last)
    json.dump(zh, open(os.path.join(RAW, "javbus_stars_zh.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=0)
    if ja is not zh:
        json.dump(ja, open(os.path.join(RAW, "javbus_stars_ja.json"), "w", encoding="utf-8"),
                  ensure_ascii=False, indent=0)
    print(f"完成：日文名 {len(zh)} 个")


if __name__ == "__main__":
    main()
