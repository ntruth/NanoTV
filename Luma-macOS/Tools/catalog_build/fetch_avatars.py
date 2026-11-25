#!/usr/bin/env python3
"""下载演员头像，裁成 96×96 JPEG，base64 存进 raw/avatar_images.json。

数据源是 catalog.sqlite 里已有的 image_url（JavRate / JavBus）。
JavBus 图床需要 Referer，统一带上来源站点的根地址。
"""

from __future__ import annotations

import base64
import concurrent.futures
import io
import json
import os
import sqlite3
import time
import urllib.parse

import requests
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
DB = os.path.join(ROOT, "Resources", "Catalog", "catalog.sqlite")
OUT = os.path.join(RAW, "avatar_images.json")
PROXY = os.environ.get("MONO_PROXY", "http://127.0.0.1:8118")
SIZE = 96
QUALITY = 72
WORKERS = 6
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
    "Accept": "image/avif,image/webp,image/*,*/*;q=0.8",
}
PROXIES = {"http": PROXY, "https": PROXY}


def encode(url: str) -> str | None:
    for attempt in range(3):
        try:
            # 每个请求独立连接：复用 Session 时 JavBus 图床的连接容易卡死。
            parsed = urllib.parse.urlparse(url)
            headers = dict(HEADERS)
            # JavBus 图床没有 Referer 会直接 403。
            headers["Referer"] = f"{parsed.scheme}://{parsed.netloc}/"
            response = requests.get(url, proxies=PROXIES, headers=headers, timeout=20)
            if response.status_code == 404:
                return None
            if response.status_code in (401, 403):
                # 403 多半是 Referer 不对，重试一次仍失败就放弃。
                if attempt >= 1:
                    return None
                time.sleep(1)
                continue
            if response.status_code != 200:
                time.sleep(2 + 3 * attempt)
                continue
            source = Image.open(io.BytesIO(response.content))
            source = source.convert("RGB")
            width, height = source.size
            side = min(width, height)
            source = source.crop(((width - side) // 2, (height - side) // 2,
                                  (width + side) // 2, (height + side) // 2))
            source = source.resize((SIZE, SIZE), Image.LANCZOS)
            buffer = io.BytesIO()
            source.save(buffer, format="JPEG", quality=QUALITY, optimize=True)
            return base64.b64encode(buffer.getvalue()).decode("ascii")
        except Exception:  # noqa: BLE001 - 单张失败直接跳过
            time.sleep(1.5 * (attempt + 1))
    return None


def main():
    connection = sqlite3.connect(DB)
    urls = [row[0] for row in connection.execute(
        "select distinct image_url from actresses "
        "where image_url is not null and image_url != ''")]
    urls += [row[0] for row in connection.execute(
        "select distinct logo_url from studios "
        "where logo_url is not null and logo_url != ''")]
    images = json.load(open(OUT, encoding="utf-8")) if os.path.exists(OUT) else {}
    # 上次失败（None）的也重试一次：主要是被 JavBus 图床限流的那批。
    todo = [url for url in urls if not images.get(url)]
    print(f"头像待下载 {len(todo)} / {len(urls)}（已有 {len(images)}）", flush=True)

    started = time.time()
    ok = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = {pool.submit(encode, url): url for url in todo}
        for index, future in enumerate(concurrent.futures.as_completed(futures), 1):
            url = futures[future]
            data = future.result()
            images[url] = data
            if data:
                ok += 1
            if index % 200 == 0:
                json.dump(images, open(OUT, "w", encoding="utf-8"), ensure_ascii=False)
                elapsed = max(time.time() - started, 1)
                print(f"  {index}/{len(todo)} 成功 {ok}｜{index / elapsed:.1f} 个/秒",
                      flush=True)
    json.dump(images, open(OUT, "w", encoding="utf-8"), ensure_ascii=False)
    total = sum(1 for value in images.values() if value)
    size_mb = os.path.getsize(OUT) / 1_000_000
    print(f"完成：{len(images)} 个头像，其中有效 {total}，文件 {size_mb:.1f} MB")


if __name__ == "__main__":
    main()
