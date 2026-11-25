#!/usr/bin/env python3
"""抓取中文维基 Category:日本AV女優 的条目摘要，补人物简介 / 生日。

之前的 wiki_category_actresses_p1/p2.json 只抓了前 770 个成员，
这里用 cmcontinue 枚举完整分类，再用 extracts 批量取首段。
输出 raw/wiki_actress_bios.json：{title: {summary, birth, url}}。
"""

from __future__ import annotations

import json
import os
import re
import time

import requests

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
PROXY = os.environ.get("MONO_PROXY", "http://127.0.0.1:8118")
API = "https://zh.wikipedia.org/w/api.php"
CATEGORY = "Category:日本AV女優"
HEADERS = {
    "User-Agent": "Luma-Catalog/1.0 (personal media library)",
    "Accept": "application/json",
    "Accept-Language": "zh-CN,zh;q=0.9",
}
SKIP = re.compile(r"(列表|列表|一覽|AV女優|AV事務所|事務所|女優|演員|Category:|模板)")
BIRTH = re.compile(r"(\d{4})年(\d{1,2})月(\d{1,2})日")
JAPANESE = re.compile(r"日[语語][：:]\s*([^，。；;）)]{2,40})")


def get(params):
    for attempt in range(8):
        try:
            response = requests.get(API, params=params,
                                    proxies={"http": PROXY, "https": PROXY},
                                    headers=HEADERS, timeout=45)
            if response.status_code == 429:
                time.sleep(5 * (attempt + 1))
                continue
            response.raise_for_status()
            time.sleep(0.3)
            return response.json()
        except requests.RequestException as error:
            print(f"  重试 {attempt + 1}: {error}")
            time.sleep(3 * (attempt + 1))
    raise RuntimeError("维基接口请求失败")


def category_titles():
    titles = []
    cont = {}
    while True:
        data = get({"action": "query", "list": "categorymembers", "cmtitle": CATEGORY,
                    "cmlimit": "500", "cmnamespace": "0", "format": "json", **cont})
        for member in data.get("query", {}).get("categorymembers", []):
            titles.append(member["title"])
        if "continue" not in data:
            break
        cont = data["continue"]
    result = []
    for title in titles:
        if SKIP.search(title) or len(title) < 2:
            continue
        if title not in result:
            result.append(title)
    return result


def fetch_extracts(titles):
    path = os.path.join(RAW, "wiki_actress_bios.json")
    result = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
    for start in range(0, len(titles), 20):
        batch = [title for title in titles[start: start + 20] if title not in result]
        if not batch:
            continue
        data = get({"action": "query", "prop": "extracts", "explaintext": "1",
                    "exintro": "1", "redirects": "1", "format": "json",
                    "titles": "|".join(batch)})
        for page in data.get("query", {}).get("pages", {}).values():
            title = page.get("title")
            extract = (page.get("extract") or "").strip()
            if not title or not extract:
                continue
            birth = None
            match = BIRTH.search(extract[:200])
            if match:
                year, month, day = (int(part) for part in match.groups())
                if 1940 <= year <= 2007:
                    birth = f"{year:04d}-{month:02d}-{day:02d}"
            japanese = None
            match = JAPANESE.search(extract[:300])
            if match:
                # 「桜空 もも／さくら もも」只取正常写法那一段。
                japanese = re.split(r"[／/、]", match.group(1))[0].strip() or None
            result[title] = {
                "summary": extract[:900],
                "birth": birth,
                "ja": japanese,
                "url": "https://zh.wikipedia.org/wiki/"
                       + requests.utils.quote(title.replace(" ", "_")),
            }
        print(f"  摘要 {min(start + 20, len(titles))}/{len(titles)}", flush=True)
        if start % 100 == 0:
            json.dump(result, open(path, "w", encoding="utf-8"),
                      ensure_ascii=False, indent=1)
    return result


def main():
    titles = category_titles()
    print(f"分类成员 {len(titles)} 个，开始抓摘要…")
    bios = fetch_extracts(titles)
    path = os.path.join(RAW, "wiki_actress_bios.json")
    json.dump(bios, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    with_birth = sum(1 for value in bios.values() if value.get("birth"))
    print(f"完成：{len(bios)} 条摘要（含生日 {with_birth}）→ {path}")


if __name__ == "__main__":
    main()
