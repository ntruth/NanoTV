#!/usr/bin/env python3
"""把 kkkhai 全站文章整理成人物 / 机构的详细资料。

输入：
- raw/kkkhai_posts_full.json  fetch_kkkhai_site.py 抓的全站文章（含简介与合集目录统计）
- raw/kkkhai_tags_full.json   标签（标签名往往就是模特艺名）

输出：
- raw/kkkhai_people_details.json  人物：套数 / 体积 / 最近更新 / 简介 / 别名 / 出处
- raw/kkkhai_studio_details.json  机构：期数 / 简介 / 出处

`build_catalog_db.py` 会把这两份资料按名字合并进已有记录，缺资料的人直接补字段。
"""

from __future__ import annotations

import html
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")

# 人物分类：网红Cos / 美女专辑 / 众筹私拍 / 密·圈。
PERSON_CATS = {
    457: ("COS", ["COS", "网红"]),
    2: ("秀人", ["秀人"]),
    1: ("众筹私拍", ["众筹私拍", "网红"]),
    817: ("微密圈", ["微密圈", "网红"]),
}
# 机构分类：名站机构 / 丝模区 / 恋足恋物 / 秀人合集。
STUDIO_CATS = {
    4: ("名站机构", True),
    456: ("丝模区", False),
    458: ("恋足恋物", False),
    3: ("秀人合集", False),
    196: ("秀人合集", False),
    195: ("秀人合集", False),
}

REGION_MARK = {"韩": "korea", "日": "japan", "台": "taiwan", "港": "hongkong"}
GENERIC_TAGS = {
    "视频", "合集", "丝袜", "丝袜无内", "秀人", "微密圈", "新发", "套图", "写真",
    "福利", "美女", "模特", "网红", "COS", "cos", "漫画", "无内", "美腿",
}
SUFFIX = re.compile(r"(内购私拍|内购|私拍|合集|全套|视频|套图|新发|未删减)$")

STYLE_LABEL = {
    "COS": "COS 网红",
    "秀人": "秀人模特",
    "众筹私拍": "私拍网红",
    "微密圈": "微密圈网红",
}

# 已知机构名：标题里同名的一律按机构处理，不当成人名收录。
STUDIOS: set[str] = set()

# 明显不是人名的写法：图包标题、含规格数字、机构后缀。
BAD_NAME = re.compile(r"[\[\]【】《》<>]|网盘|下载|合集|全套|系列|作品|目录|期|套|"
                      r"水印|慎下|介意|视频|直播|vip|VIP|付费|绝版|女团|车模|车展|"
                      r"展会|明星|钢管秀|成人展|内衣秀|时装秀|\d{2,}|^\d")
ORG_TAIL = ("社", "馆", "网", "映画", "印画", "摄影", "工作室", "机构", "学院",
            "传媒", "文化", "画报", "系列", "联盟", "公司", "会社", "事务所",
            "视觉", "影像", "映象", "写真", "图社")


def known_studio_names() -> set[str]:
    names: set[str] = set()
    for file in ("kkkhai_studios.json", "kkkhai_tag_studios.json", "kkkhai_brand_studios.json"):
        path = os.path.join(RAW, file)
        if not os.path.exists(path):
            continue
        for row in load(file):
            for name in [row.get("name"), *row.get("aliases", [])]:
                if name:
                    names.add(name.casefold())
    return names


def load(name):
    with open(os.path.join(RAW, name), encoding="utf-8") as handle:
        return json.load(handle)


def clean_text(value: str) -> str:
    value = html.unescape(value or "")
    return re.sub(r"\s+", " ", value).strip()


def title_name(title: str) -> tuple[str, list[str], str | None]:
    """标题 → (主名字, 括号里的别名, 地区标记)。"""
    text = clean_text(title)
    text = re.sub(r"^\[[^\]]*\]\s*", "", text)
    text = re.split(r"\s+[–—\-]\s+", text)[0].strip()
    region = None
    aliases = []
    for inner in re.findall(r"[（(]([^（）()]*)[）)]", text):
        inner = inner.strip()
        if inner in REGION_MARK:
            region = REGION_MARK[inner]
        elif inner and inner not in ("新发", "合集", "全套", "无码", "无水印"):
            aliases.extend(x.strip() for x in re.split(r"[|｜/／、]", inner) if x.strip())
    text = re.sub(r"[（(][^（）()]*[）)]", "", text).strip()
    if text.endswith("(韩)") or text.endswith("（韩）"):
        region = "korea"
    text = re.sub(r"^(合集|全站合集|全站)[\s·:：]*", "", text).strip()
    return text, aliases, region


def parse_count(title: str) -> int | None:
    values = [int(v) for v in re.findall(r"(\d+)\s*[套期]", title)]
    span = re.findall(r"(\d+)\s*-\s*(\d+)\s*期", title)
    for _, end in span:
        values.append(int(end))
    return max(values) if values else None


def parse_size(title: str) -> str | None:
    match = re.search(r"(\d+(?:\.\d+)?)\s*([GMT])B?", title)
    if not match:
        return None
    return f"{match.group(1)}{match.group(2)}"


def parse_latest(post) -> str | None:
    match = re.search(r"(20\d{2})[.\-/](\d{1,2})(?!\d)", post["title"])
    if match and 1 <= int(match.group(2)) <= 12:
        return f"{match.group(1)}.{int(match.group(2))}"
    if post.get("catalog_latest"):
        year = (post.get("modified") or post.get("date") or "")[:4] or "2026"
        month = post["catalog_latest"].split(".")[0]
        return f"{year}.{int(month)}"
    modified = post.get("modified") or post.get("date")
    if modified:
        return modified[:7].replace("-", ".")
    return None


def looks_like_catalog(text: str) -> bool:
    """正文第一段如果全是目录条目，就不能当简介。"""
    return bool(re.search(r"^\d{3}(?!\d)|\[MP4|\[\d+\s*[PpMmVv]|NO\.\s*\d", text or ""))


def intro_aliases(intro: str) -> list[str]:
    values = []
    for pattern in (
        r"最新名字叫[:：]?\s*([^，。；;、\s]{2,20})",
        r"现在叫[:：]?\s*([^，。；;、\s]{2,20})",
        r"改名[:：]?\s*([^，。；;、\s]{2,20})",
        r"又名[:：]?\s*([^，。；;、\s]{2,20})",
        r"也叫[:：]?\s*([^，。；;、\s]{2,20})",
        r"原名[:：]?\s*([^，。；;、\s]{2,20})",
        r"别名[:：]?\s*([^，。；;、\s]{2,20})",
    ):
        values.extend(re.findall(pattern, intro))
    head = re.match(r"^([^，。；;]{2,60}?)(?:都是|均是|其实是)", intro)
    if head:
        for token in re.split(r"[、/／]", head.group(1)):
            token = token.strip()
            if 2 <= len(token) <= 18:
                values.append(token)
    result = []
    for value in values:
        value = value.strip("：: ")
        if value and value not in result:
            result.append(value)
    return result


def normalize_tag(name: str) -> str:
    name = clean_text(name)
    return SUFFIX.sub("", name).strip() or name


def valid_person(name: str) -> bool:
    name = name.strip()
    if not (2 <= len(name) <= 24):
        return False
    if BAD_NAME.search(name):
        return False
    if name.endswith(ORG_TAIL):
        return False
    # 「c1」这类纯字母数字的短代号不是艺名。
    if re.fullmatch(r"[A-Za-z0-9]{1,2}", name):
        return False
    return name.casefold() not in STUDIOS


def intro_leading_name(intro: str) -> str | None:
    """有些帖子标题全是「含 vip 视频」之类，正文开头才是艺名。"""
    match = re.match(
        r"^[（(]?([\u4e00-\u9fa5A-Za-z][\u4e00-\u9fa5A-Za-z0-9_\- ]{1,11}?)"
        r"(?:作品|的写真|的套图|是|，|,)",
        intro or "",
    )
    if not match:
        return None
    candidate = match.group(1).strip()
    return candidate if valid_person(candidate) else None


def infer_region(names: list[str], markers: list[str], intro: str = "") -> str:
    for marker in markers:
        if marker in REGION_MARK:
            return REGION_MARK[marker]
    joined = " ".join(names)
    if re.search(r"[가-힣]", joined):
        return "korea"
    if re.search(r"[ぁ-んァ-ヶ]", joined):
        return "japan"
    head = intro[:40]
    for key, region in (("日本", "japan"), ("韩国", "korea"), ("韓国", "korea"),
                        ("台湾", "taiwan"), ("香港", "hongkong")):
        if key in head:
            return region
    return "china"


def person_groups(posts, tags):
    usable_tags = {
        tag["id"]: normalize_tag(tag["name"])
        for tag in tags
        if tag["count"] < 25 and tag["name"] not in GENERIC_TAGS
    }
    groups: dict[str, dict] = {}
    for post in posts:
        cats = set(post["categories"])
        category = next((cid for cid in PERSON_CATS if cid in cats), None)
        if category is None:
            continue
        style, style_tags = PERSON_CATS[category]
        name, aliases, marker = title_name(post["title"])
        if not name or len(name) < 2:
            continue
        tag_names = [usable_tags[tid] for tid in post["tags"] if tid in usable_tags]
        key = f"tag:{post['tags'][0]}" if tag_names and post["tags"] else f"name:{name.casefold()}"
        group = groups.setdefault(key, {
            "names": [], "aliases": [], "markers": [], "styles": set(), "style_tags": set(),
            "counts": [], "sizes": [], "latests": [], "intros": [], "links": {}, "posts": 0,
        })
        for candidate in [name, *aliases, *tag_names]:
            candidate = candidate.strip()
            if candidate and candidate not in group["names"]:
                group["names"].append(candidate)
        if marker:
            group["markers"].append(marker)
        group["styles"].add(style)
        group["style_tags"].update(style_tags)
        # 标题里写的总套数通常比目录里当前列出的条目更接近合集实际数量。
        count = max(post.get("catalog_count") or 0, parse_count(post["title"]) or 0)
        if count:
            group["counts"].append(count)
        size = parse_size(post["title"])
        if size:
            group["sizes"].append(size)
        latest = parse_latest(post)
        if latest:
            group["latests"].append(latest)
        if post.get("intro"):
            group["intros"].append(post["intro"])
        group["links"][post["link"]] = max(count, group["links"].get(post["link"], 0))
        group["posts"] += 1
    return groups


def size_value(text: str) -> float:
    number = float(re.sub(r"[^\d.]", "", text) or 0)
    return number * (1024 if text.upper().endswith("T") else 1)


def compose_person(key, group):
    names = []
    for name in group["names"]:
        name = re.sub(r"\s+\d{1,2}$", "", name).strip()
        if valid_person(name) and name not in names:
            names.append(name)
    intro = max(group["intros"], key=len) if group["intros"] else ""
    if looks_like_catalog(intro):
        intro = ""
    if not names:
        leading = intro_leading_name(intro)
        if not leading:
            return None
        names = [leading]
    primary = names[0]
    best_link = max(group["links"].items(), key=lambda kv: kv[1])[0] if group["links"] else None
    count = max(group["counts"]) if group["counts"] else None
    latest = max(group["latests"]) if group["latests"] else None
    size = max(group["sizes"], key=size_value) if group["sizes"] else None
    region = infer_region(names, group["markers"], intro)
    region_title = {"china": "中国大陆", "japan": "日本", "korea": "韩国",
                    "taiwan": "台湾", "hongkong": "香港"}.get(region, "中国大陆")
    labels = [STYLE_LABEL.get(name, name) for name in sorted(group["styles"])]
    description = f"{region_title} · {' / '.join(labels)}"
    # 「收录 N 套 · 11.7G · 更新至 2021.08」是采集站自己的快照，不作为人物资料。
    summary = intro.strip() or None
    aliases = [name for name in names[1:] if name != primary]
    return {
        "key": key,
        "name": primary,
        "aliases": aliases,
        "region": region,
        "tags": sorted(group["style_tags"]),
        "work_count": None,
        "summary": summary[:600] if summary else None,
        "description": description,
        "source_url": best_link,
        "updated_at": None,
        "source": "kkkhai 人物",
    }


def studio_groups(posts, tags):
    groups: dict[str, dict] = {}
    for post in posts:
        cats = set(post["categories"])
        category = next((cid for cid in STUDIO_CATS if cid in cats), None)
        if category is None:
            continue
        style, allow_new = STUDIO_CATS[category]
        title = clean_text(post["title"])
        bracket = re.search(r"《([^》]+)》", title)
        if bracket:
            name = bracket.group(1).strip()
        else:
            name, _, _ = title_name(title)
        if not name or len(name) < 2:
            continue
        group = groups.setdefault(name.casefold(), {
            "name": name, "names": [], "style": style, "allow_new": allow_new,
            "counts": [], "sizes": [], "latests": [], "intros": [], "links": {},
        })
        if name not in group["names"]:
            group["names"].append(name)
        count = max(post.get("catalog_count") or 0, parse_count(title) or 0)
        if count:
            group["counts"].append(count)
        size = parse_size(title)
        if size:
            group["sizes"].append(size)
        latest = parse_latest(post)
        if latest:
            group["latests"].append(latest)
        if post.get("intro"):
            group["intros"].append(post["intro"])
        group["links"][post["link"]] = max(count, group["links"].get(post["link"], 0))
    return groups


def compose_studio(group):
    count = max(group["counts"]) if group["counts"] else None
    size = max(group["sizes"], key=size_value) if group["sizes"] else None
    latest = max(group["latests"]) if group["latests"] else None
    intro = max(group["intros"], key=len) if group["intros"] else ""
    if looks_like_catalog(intro) or group["style"] == "秀人合集":
        intro = ""
    # 站内「收录 N 期 · 体积 · 更新至」同样是快照，不写进机构简介。
    summary = intro.strip() or None
    best_link = max(group["links"].items(), key=lambda kv: kv[1])[0] if group["links"] else None
    return {
        "name": group["names"][0],
        "aliases": group["names"][1:],
        "work_count": None,
        "summary": summary[:600] if summary else None,
        "source_url": best_link,
        "allow_new": group["allow_new"],
        "style": group["style"],
        "updated_at": None,
        "source": "kkkhai 机构",
    }


def main():
    posts = load("kkkhai_posts_full.json")
    tags = load("kkkhai_tags_full.json")
    STUDIOS.update(known_studio_names())

    people = []
    for key, group in person_groups(posts, tags).items():
        record = compose_person(key, group)
        if record:
            people.append(record)

    studios = []
    for group in studio_groups(posts, tags).values():
        record = compose_studio(group)
        if record:
            studios.append(record)

    people.sort(key=lambda r: -(r.get("work_count") or 0))
    studios.sort(key=lambda r: -(r.get("work_count") or 0))
    json.dump(people, open(os.path.join(RAW, "kkkhai_people_details.json"), "w",
                           encoding="utf-8"), ensure_ascii=False, indent=1)
    json.dump(studios, open(os.path.join(RAW, "kkkhai_studio_details.json"), "w",
                            encoding="utf-8"), ensure_ascii=False, indent=1)
    with_summary = sum(1 for p in people if p.get("summary"))
    print(f"人物 {len(people)} 位（含资料 {with_summary}），机构 {len(studios)} 个")
    for record in people[:8]:
        print(f"  {record['name']}｜{record['description']}｜{record['work_count']}"
              f"｜{(record['summary'] or '')[:60]}")


if __name__ == "__main__":
    main()
