#!/usr/bin/env python3
"""合并 JavRate / JavBus 的女优名单，生成「日文名 → 中文译名」对照表。

数据：
- raw/javbus_stars_zh.json        JavBus 女优列表（star_id → 日文名）
- raw/javrate_actor_details.json  JavRate 演员详情（中文名、别名、日文名、简介）
- raw/jav_actress_index.json      GitHub 日本女优索引（需要补资料的日文名）

输出：
- raw/javbus_name_map.json  [{ja, zh, star_id}]
- raw/javbus_star_ids.json  需要抓 JavBus 演员页的 star_id 列表
"""

from __future__ import annotations

import csv
import json
import os
import re

from build_catalog_db import normalize_all

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
PAREN = re.compile(r"[（(]([^）)]{2,30})[）)]")
KANA = re.compile(r"[\u3040-\u30ff]")


def variants(name: str):
    """「めぐり（藤浦めぐ）」同时索引全称、括号外、括号内。"""
    result = [name]
    outside = PAREN.sub("", name).strip()
    if outside:
        result.append(outside)
    result.extend(PAREN.findall(name))
    return result


def extra_japanese(description: str | None):
    """只认简介里明确写的「日语：波多野結衣」，不再从正文里抓假名片段。"""
    head = (description or "")[:80]
    match = re.search(r"日[语語][：:]\s*([^，。；;）)\s]{2,20})", head)
    return [match.group(1)] if match else []


# 名字里不会出现的字：一旦命中就是正文句子被截断成了「名字」。
PROSE = re.compile(r"(是|為|位|的|年|月|日|歲|岁|女優|演員|出生|出道|作品|出演|自述|擁有|还是|還是)")
NAME_RE = re.compile(r"^[\u3040-\u30ff\u4e00-\u9fffA-Za-z][\u3040-\u30ff\u4e00-\u9fffA-Za-z・ー ]{1,19}$")


def valid_name(value: str | None):
    value = (value or "").strip()
    # 「山手梨愛やまてりあYamateRia」这种假名后直接拼罗马字的写法，砍掉罗马字部分。
    value = re.sub(r"(?<=[\u3040-\u30ff\u4e00-\u9fff])[A-Za-z]+$", "", value).strip()
    if not value or not NAME_RE.fullmatch(value) or PROSE.search(value):
        return None
    return value


def clean_japanese(value: str):
    """「希崎ジェシカ、きざきじぇしか」只取前面那一段；正文句子直接丢弃。"""
    for part in re.split(r"[／/、，,；;]+", value):
        cleaned = valid_name(part)
        if cleaned:
            return cleaned
    return None


def pick_primary(japanese, zh: str):
    """优先选与中文名共用汉字最多的写法，其次带假名的，最后选较短的（避免正文截断）。

    如果一个候选字都对不上、而中文名本身就含假名（如「藤咲エレン」），
    说明中文名就是日文原名，直接用中文名。
    """
    candidates = [name for name in japanese if valid_name(name)]
    if not candidates:
        return valid_name(zh) if KANA.search(zh or "") else None

    def score(name: str):
        shared = len({char for char in name if char in zh})
        return (shared, bool(KANA.search(name)), -len(name))

    best = max(candidates, key=score)
    if score(best)[0] == 0 and KANA.search(zh or ""):
        return valid_name(zh)
    return best


def main():
    stars = json.load(open(os.path.join(RAW, "javbus_stars_zh.json"), encoding="utf-8"))
    details = json.load(open(os.path.join(RAW, "javrate_actor_details.json"), encoding="utf-8"))
    index = json.load(open(os.path.join(RAW, "jav_actress_index.json"), encoding="utf-8"))

    # 1) 日文名（含「藤浦めぐ」这类括号别名）→ star_id。
    star_names = []
    for star_id, name in stars.items():
        for variant in variants(name):
            star_names.append((star_id, variant))
    keys = normalize_all([variant for _, variant in star_names])
    star_key = {}
    for (star_id, _), key in zip(star_names, keys):
        star_key.setdefault(key, star_id)

    # 2) JavRate 详情里的「中文名 ↔ 日文名」。
    rows = []
    for zh, info in details.items():
        japanese = [clean_japanese(ja) for ja in (info.get("ja") or [])]
        japanese.extend(extra_japanese(info.get("description")))
        japanese = [ja for ja in dict.fromkeys(japanese) if ja]
        rows.append((zh, japanese, pick_primary(japanese, zh)))

    flattened = [ja for _, japanese, _ in rows for ja in japanese]
    flat_keys = normalize_all(flattened)
    keys_by_zh = {}
    cursor = 0
    for zh, japanese, _ in rows:
        keys_by_zh[zh] = flat_keys[cursor: cursor + len(japanese)]
        cursor += len(japanese)
    zh_keys = dict(zip([zh for zh, _, _ in rows], normalize_all([zh for zh, _, _ in rows])))

    mapping = []
    seen_star = set()
    seen_zh = set()
    for zh, japanese, primary in rows:
        keys = keys_by_zh[zh]
        star_id = next((star_key[k] for k in keys if k in star_key), None) \
            or star_key.get(zh_keys[zh])
        if star_id and star_id in seen_star:
            continue
        if zh_keys[zh] in seen_zh:
            continue

        candidates = list(japanese)
        if star_id:
            # JavBus 演员页标题是这位 star 自己的写法，作为候选参与打分，
            # 但不会压过人家长时间使用的正式艺名（如 深田えいみ vs 天海こころ）。
            official = clean_japanese(PAREN.sub("", stars.get(star_id) or "").strip())
            if official and official not in candidates:
                candidates.append(official)
        display = pick_primary(candidates, zh)

        if star_id:
            seen_star.add(star_id)
        if zh_keys[zh]:
            seen_zh.add(zh_keys[zh])
        mapping.append({"ja": display, "zh": zh, "star_id": star_id})

    # 3) GitHub 索引里能对上 JavBus 的日文名，收集 star_id 去抓演员页。
    index_names = [row["name"] for row in index if row.get("name")]
    index_keys = normalize_all(index_names)
    wanted = {entry["star_id"] for entry in mapping if entry["star_id"]}
    matched = 0
    for key in index_keys:
        star_id = star_key.get(key)
        if star_id:
            wanted.add(star_id)
            matched += 1
    # JavRate 已经有三围的人不用再抓 JavBus 演员页。
    wanted -= {entry["star_id"] for entry in mapping if entry["star_id"]}

    json.dump(mapping, open(os.path.join(RAW, "javbus_name_map.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=0)
    json.dump(sorted(wanted), open(os.path.join(RAW, "javbus_star_ids.json"), "w",
                                   encoding="utf-8"), ensure_ascii=False, indent=0)

    with_ja = sum(1 for entry in mapping if entry["ja"])
    with_star = sum(1 for entry in mapping if entry["star_id"])

    # 人工可读的对照表（UTF-8 BOM，Excel / Numbers 直接打开不乱码）。
    csv_path = os.path.join(RAW, "javbus_name_map.csv")
    with open(csv_path, "w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["日文名", "中文译名", "JavBus 演员页"])
        for entry in sorted(mapping, key=lambda row: row["zh"]):
            writer.writerow([
                entry["ja"] or "",
                entry["zh"],
                f"https://www.javbus.com/star/{entry['star_id']}" if entry["star_id"] else "",
            ])
    print(f"对照表已写入 {csv_path}")

    print(f"JavBus 列表 {len(stars)} 人；译名对 {len(mapping)} 条"
          f"（含日文名 {with_ja}，能定位演员页 {with_star}）")
    print(f"GitHub 索引 {len(index_names)} 人，命中 JavBus {matched} 人；"
          f"需要抓演员页 {len(wanted)} 个")


if __name__ == "__main__":
    main()
