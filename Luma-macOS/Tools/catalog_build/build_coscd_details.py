#!/usr/bin/env python3
"""把 coscd 的标签 + 作品标题整理成国内 Coser / 网红名单与作品数。

输入：
- raw/coscd_tags.json   标签（id / name / count / link）
- raw/coscd_posts.json  COS 作品（title / link / tags）

输出：
- raw/coscd_people.json        人物（含作品数、标签页链接）
- raw/coscd_people_extra.json  只出现在作品标题里的新艺名

两条互补的归属逻辑：
1. 作品 tags 里命中人物标签 —— 最可靠；
2. 标题扫描已知艺名 —— 补上没打人物标签的老文章
   （「少女前线弥音音COS」先剥掉作品名再取剩下的艺名）。

同一个人的多个标签（神楽坂真 / 神楽坂真冬、过期米线 / 过期米线线喵）
按「前缀 + 归一化」合并到作品数最多的那个写法。
"""

from __future__ import annotations

import html
import json
import os
import re
import unicodedata
from collections import Counter

from build_coscd_people import clean_tag, is_person

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")

MARKERS = re.compile(r"(?i)cosplay|cos|《|》|｜|\||：|:|；|;|,|，|[（(]|[)）]|\s+")
TITLE_NOISE = re.compile(
    r"(?:高清写真特辑|精品摄影作品赏析|作品介绍|作品赏析|照片|图片|图集|合集|"
    r"写真|视频|作品|赏析|介绍|演绎|正片|\d+\s*[PpVv].*)$"
)
LEADING_NOISE = re.compile(r"^(?:赏析|作品介绍|高清|图片|图集|写真|视频|特辑|合集)+")
SEPARATORS = re.compile(r"[\s_\-·.]+")
LATIN_NAME = re.compile(r"^[A-Za-z0-9 .'\-]+$")

# 标题里常见、但肯定不是艺名的碎片。
EXTRA_GENERIC = {
    "系列", "作品及个人资料", "个人资料", "资料", "图集", "图片", "作品", "视频",
    "合集", "套图", "写真", "正片", "预览", "介绍", "赏析", "模特", "coser", "Coser",
    "颜值", "天花板", "特辑", "专题", "更新", "完整版", "全套", "美图", "美女",
}


def norm_key(name: str) -> str:
    value = unicodedata.normalize("NFKC", name).casefold()
    return SEPARATORS.sub("", value)


def clean_title(raw: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", raw)).strip()


def region_of(name: str) -> str:
    if re.search(r"[\uac00-\ud7af]", name):
        return "korea"
    if re.search(r"[\u3040-\u30ff]", name):
        return "japan"
    return "china"


def build_people(tags):
    """标签 → 人物，并把同一人的截断写法并到作品数最多的写法。"""
    entries = {}
    for tag in tags:
        name = clean_tag(tag["name"])
        if not is_person(name, tag.get("count", 0)):
            continue
        key = norm_key(name)
        current = entries.get(key)
        if current is None or tag.get("count", 0) > current["count"]:
            entries[key] = {"name": name, "count": tag.get("count", 0),
                            "link": tag.get("link")}

    # 前缀合并：一个名字是另一个名字的开头，且长度 >= 3
    # （避免「奶桃 / 奶桃桃」这类其实是两个人的情况）。
    parent = {key: key for key in entries}

    def find(key):
        while parent[key] != key:
            parent[key] = parent[parent[key]]
            key = parent[key]
        return key

    keys = list(entries)
    for short in keys:
        if len(entries[short]["name"]) < 3:
            continue
        for long in keys:
            if short != long and entries[long]["name"].startswith(entries[short]["name"]):
                roots = {find(short), find(long)}
                parent[max(roots)] = min(roots)

    groups = {}
    for key in keys:
        groups.setdefault(find(key), []).append(entries[key])

    people = []
    alias_of = {}          # 任意标签写法 → 最终主名字
    all_tag_names = set()
    for members in groups.values():
        members.sort(key=lambda item: (-item["count"], -len(item["name"])))
        main = members[0]
        aliases = [member["name"] for member in members[1:]
                   if member["name"] != main["name"]]
        for member in members:
            all_tag_names.add(member["name"])
            alias_of[member["name"]] = main["name"]
            alias_of[norm_key(member["name"])] = main["name"]
        people.append({
            "name": main["name"],
            "aliases": aliases,
            "region": region_of(main["name"]),
            "tags": ["COS", "网红"],
            "source": "coscd 标签",
            "source_url": main["link"],
        })
    return people, alias_of, all_tag_names


def work_tag_names(post, by_id, alias_of):
    result = []
    for tag_id in post.get("tags", []):
        tag = by_id.get(tag_id)
        if not tag:
            continue
        name = clean_tag(tag["name"])
        if name in alias_of:
            continue
        result.append(name)
    return sorted(result, key=len, reverse=True)


def title_segments(post, by_id, alias_of):
    """标题去掉作品名后剩下的候选片段。"""
    text = clean_title(post["title"])
    for work in work_tag_names(post, by_id, alias_of):
        if len(work) >= 2:
            text = text.replace(work, " ")
    segments = []
    for piece in MARKERS.split(text):
        piece = piece.strip(" -_·【】[]。.!！?？")
        piece = LEADING_NOISE.sub("", piece)
        piece = TITLE_NOISE.sub("", piece).strip(" -_·")
        if piece:
            segments.append(piece)
    return segments


def title_artist_piece(post, by_id, alias_of):
    """标题里「艺人」所在的片段：作品名之后、「COS / 《」之前。"""
    pieces = title_segments(post, by_id, alias_of)
    return pieces[0] if pieces else ""


def main():
    tags = json.load(open(os.path.join(RAW, "coscd_tags.json"), encoding="utf-8"))
    posts = json.load(open(os.path.join(RAW, "coscd_posts.json"), encoding="utf-8"))
    by_id = {tag["id"]: tag for tag in tags}
    people, alias_of, all_tag_names = build_people(tags)

    # 长的优先，避免「Sally」抢在「Sally Dorasnow」前面。
    known = sorted(all_tag_names, key=len, reverse=True)
    canonicals = sorted({person["name"] for person in people}, key=len, reverse=True)

    def latin_boundary(name, text):
        if not LATIN_NAME.match(name):
            return True
        start = text.find(name)
        while start >= 0:
            before = text[start - 1] if start > 0 else " "
            after = text[start + len(name)] if start + len(name) < len(text) else " "
            if not (before.isascii() and before.isalnum()) and \
               not (after.isascii() and after.isalnum()):
                return True
            start = text.find(name, start + 1)
        return False

    def names_in_title(title):
        found = []
        spans = []
        for name in known:
            start = title.find(name)
            while start >= 0:
                end = start + len(name)
                if not any(start < s_end and s_start < end for s_start, s_end in spans) \
                        and latin_boundary(name, title):
                    spans.append((start, end))
                    found.append(name)
                    break
                start = title.find(name, start + 1)
        # 标题里写的是简称（弥音音 / 千阳），标签是全长（弥音音ww / 千阳快起床）。
        for name in canonicals:
            if len(name) < 4 or name in found:
                continue
            for size in range(len(name) - 1, max(2, len(name) - 4), -1):
                short = name[:size]
                if len(short) >= 3 and short in title:
                    found.append(name)
                    break
        return found

    works = Counter()
    links = {}
    for post in posts:
        names = set()
        for tag_id in post.get("tags", []):
            tag = by_id.get(tag_id)
            if not tag:
                continue
            name = clean_tag(tag["name"])
            if name in alias_of:
                names.add(alias_of[name])
        if not names:
            title = clean_title(post["title"])
            names.update(alias_of.get(name, name) for name in names_in_title(title))
        for name in names:
            works[name] += 1
            links.setdefault(name, []).append(post["link"])

    for person in people:
        count = works.get(person["name"], 0)
        if not count:
            # 有标签但一篇作品都没命中时，退回标签自带的篇数。
            count = next((tag.get("count", 0) for tag in tags
                          if clean_tag(tag["name"]) == person["name"]), 0)
        person["work_count"] = count
        if person["name"] in links:
            person["links"] = links[person["name"]][:8]

    # 标题里出现、但标签完全没收录的艺名。
    # 角色名 / 作品名在站内也是标签，这里用全部标签名（含非人物标签）做排除。
    other_tags = {clean_tag(tag["name"]) for tag in tags} - set(all_tag_names)
    candidates = Counter()
    for post in posts:
        title = clean_title(post["title"])
        # 标题里已经有已知艺名时，剩下的片段多半是角色名 / 作品名。
        if names_in_title(title):
            continue
        segment = title_artist_piece(post, by_id, alias_of)
        if not segment:
            continue
        if segment in alias_of or segment in other_tags:
            continue
        if norm_key(segment) in alias_of or segment in EXTRA_GENERIC:
            continue
        if not is_person(segment, 2):
            continue
        if any(segment in name for name in canonicals):
            continue
        candidates[segment] += 1
    extras = [{
        "name": name,
        "aliases": [],
        "region": region_of(name),
        "tags": ["COS", "网红"],
        "source": "coscd 作品标题",
        "work_count": count,
    } for name, count in candidates.most_common() if count >= 2]

    people.sort(key=lambda item: (-item["work_count"], item["name"]))
    json.dump(people, open(os.path.join(RAW, "coscd_people.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    json.dump(extras, open(os.path.join(RAW, "coscd_people_extra.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)

    with_works = sum(1 for person in people if person["work_count"])
    print(f"人物 {len(people)} 位（有作品 {with_works} 位），标题新增 {len(extras)} 位")
    print("作品最多：" + "、".join(f"{p['name']}({p['work_count']})" for p in people[:15]))
    print("标题新增：" + "、".join(f"{p['name']}({p['work_count']})" for p in extras[:20]))


if __name__ == "__main__":
    main()
