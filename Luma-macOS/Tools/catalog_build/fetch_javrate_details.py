#!/usr/bin/env python3
"""抓 JavRate 的演员详情页，补简介 / 生日 / 身高 / 日文名。

页面里的 JSON-LD（schema.org Person）直接给出：
- name            中文名
- alternateName   别名（含日文假名写法）
- description     维基式简介（开头常写「日语：波多野結衣」）
- birthDate / height
- image

输入：raw/javrate_actors_all.json
输出：raw/javrate_actor_details.json {中文名: {...}}
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import re
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
PROXY = os.environ.get("MONO_PROXY", "http://127.0.0.1:8118")
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    "Referer": "https://www.javrate.com/",
}
OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({"http": PROXY, "https": PROXY}))
LDJSON = re.compile(r'<script[^>]*application/ld\+json[^>]*>([\s\S]*?)</script>')
JP_NAME = re.compile(r"日[语語][：:]\s*([^，。；;）)]{2,24})")
KANA = re.compile(r"[\u3040-\u30ff]")
WORKERS = 4
THROTTLE = 0.25


def get(url: str, tries: int = 5) -> str:
    last = None
    for attempt in range(tries):
        try:
            request = urllib.request.Request(url, headers=HEADERS)
            with OPENER.open(request, timeout=60) as response:
                time.sleep(THROTTLE)
                return response.read().decode("utf-8", "ignore")
        except urllib.error.HTTPError as error:
            last = error
            time.sleep((6 if error.code in (403, 429) else 1.5) * (attempt + 1))
        except Exception as error:  # noqa: BLE001
            last = error
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"请求失败：{url}（{last}）")


def parse(html: str):
    person = None
    for block in LDJSON.findall(html):
        try:
            data = json.loads(block.strip())
        except json.JSONDecodeError:
            continue
        candidates = data if isinstance(data, list) else [data]
        for item in candidates:
            if isinstance(item, dict) and item.get("@type") == "Person":
                person = item
                break
        if person:
            break
    if not person:
        return None

    aliases = person.get("alternateName") or []
    if isinstance(aliases, str):
        aliases = [aliases]
    description = (person.get("description") or "").strip()
    japanese = [alias for alias in aliases if KANA.search(alias)]
    match = JP_NAME.search(description)
    if match:
        japanese.append(match.group(1).strip())

    height = None
    height_match = re.search(r"\d+", str(person.get("height") or ""))
    if height_match:
        height = int(height_match.group(0))

    image = person.get("image")
    if isinstance(image, list):
        image = image[0] if image else None

    return {
        "zh": person.get("name"),
        "ja": japanese,
        "aliases": aliases,
        "description": description[:1200] or None,
        "birth_date": person.get("birthDate"),
        "height": height,
        "image": image,
    }


def main():
    rows = json.load(open(os.path.join(RAW, "javrate_actors_all.json"), encoding="utf-8"))
    path = os.path.join(RAW, "javrate_actor_details.json")
    details = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
    todo = [row for row in rows if row["name"] not in details]
    print(f"待抓 {len(todo)} / {len(rows)}")

    def one(row):
        return row["name"], parse(get(row["url"]))

    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = [pool.submit(one, row) for row in todo]
        for index, future in enumerate(concurrent.futures.as_completed(futures), 1):
            try:
                name, info = future.result()
            except RuntimeError as error:
                print(f"  失败：{error}")
                continue
            if info:
                details[name] = info
            if index % 100 == 0:
                json.dump(details, open(path, "w", encoding="utf-8"),
                          ensure_ascii=False, indent=0)
                with_ja = sum(1 for value in details.values() if value["ja"])
                print(f"  {index}/{len(todo)}，已有 {len(details)} 人，带日文名 {with_ja}")
    json.dump(details, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=0)
    print(f"完成：{len(details)} 人")


if __name__ == "__main__":
    main()
