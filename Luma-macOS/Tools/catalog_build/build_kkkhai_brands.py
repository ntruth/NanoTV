#!/usr/bin/env python3
"""从 kkkhai「名站机构」「丝模区」的文章标题里提取机构 / 品牌名。

输入：
- raw/kkkhai_jigou_posts.json  名站机构 73 篇（REST API 抓取，已修补截断）
- raw/kkkhai_simo_posts.json   丝模区 60 篇
输出：
- raw/kkkhai_brand_studios.json
"""

import html
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")

# 这些是题材 / 系列描述，不是机构名。
BLACKLIST = {
    "中国腿模", "细高跟丝足", "制服の女生", "原味妖妖", "学妹加速跑", "萌甜物语",
    "清流", "颜女神", "动感小站", "唐韵", "chloe霏霏霏", "酒酒老师", "Nicole丝足写真",
    "MTZ·美腿志", "72斯", "街拍丝足", "Patreon", "Patreon(韩系)", "Patreon（韩系）",
    "DMM大名模网", "写真", "合集", "全套", "丝袜", "美腿", "足控", "恋足",
    "香柚", "舞蹈生日记", "袜涩", "钻石版", "真实随意", "美腿",
    "ROSI", "ROSI口罩", "ROSI艺学妹", "ROSI10情趣",
}

REGION_MARKERS = (
    ("韩国", "korea"), ("韩系", "korea"), ("(韩)", "korea"), ("[韩]", "korea"),
    ("（韩）", "korea"), ("台湾", "taiwan"), ("台灣", "taiwan"),
    ("香港", "hongkong"), ("HK", "hongkong"),
)


def region_of(title: str) -> str:
    head = title[:40]
    for marker, region in REGION_MARKERS:
        if marker in head:
            return region
    return "china"


def clean(value: str) -> str:
    value = html.unescape(value).strip()
    value = re.sub(r"^\[[^\]]*\]", "", value).strip()
    value = re.sub(r"\[[^\]]*\]", "", value).strip()
    value = re.sub(r"^(名站机构|写真机构|视频机构|经典机构|新兴机构|台湾名站|官方原版|珍藏版?|独家|合集|OL风格)", "", value).strip()
    # 标题里常把「品牌 + 全套 xx 期 / 特色 / 大小」写在一起，只留品牌部分。
    value = re.split(r"\s+(?:全套|特色|作品|合集|高清|视频|大小|含|新收录|新发)", value)[0]
    value = re.split(r"全套\s*\d", value)[0]
    value = re.split(r"[-–—](?:丝制|系列|合集|全套)", value)[0]
    value = re.sub(r"(?:钻石版|白金版|黄金版|完整版)$", "", value).strip()
    value = re.sub(r"(?:写真|视频|套图|作品)$", "", value).strip()
    value = re.sub(r"(?:App|APP)$", "", value).strip()
    if len(value) > 4 and value.endswith("美腿"):
        value = value[:-2].strip()
    value = re.sub(r"^[《<]", "", value)
    value = re.sub(r"[》>]$", "", value)
    return value.strip(" -_·•")


def extract_names(title: str):
    title = html.unescape(title).strip()
    names = []

    # 优先取书名号里的品牌。
    books = re.findall(r"《([^》]+)》", title)
    if books:
        raw = books[0]
    else:
        raw = re.split(r"\s+[–\-—]\s+", title)[0]

    # 括号里的旧名 / 子品牌也一并收进来。
    parentheticals = re.findall(r"[（(]([^（）()]*)[）)]", raw)
    raw = re.sub(r"[（(][^（）()]*[）)]", "", raw)

    candidates = re.split(r"[/／、]", raw)
    for inner in parentheticals:
        # 地区、版本、备注不当作品牌。
        if inner in {"韩", "韩国", "韩系", "台湾", "台灣", "香港"}:
            continue
        if re.fullmatch(r"[\d.]+[GTM]?|4K|高清|新发|双盘|原[^)]*", inner):
            continue
        candidates.extend(re.split(r"[/／、]", inner))

    for candidate in candidates:
        name = clean(candidate)
        if not name or len(name) < 2 or name in BLACKLIST:
            continue
        if name.lower() in {x.lower() for x in BLACKLIST}:
            continue
        if name not in names:
            names.append(name)
    return names


def salvage(path):
    if not os.path.exists(path):
        return []
    text = open(path, encoding="utf-8").read()
    decoder = json.JSONDecoder()
    index = text.find("[") + 1
    posts = []
    while index < len(text):
        while index < len(text) and text[index] in " \n\r\t,":
            index += 1
        if index >= len(text) or text[index] == "]":
            break
        try:
            obj, next_index = decoder.raw_decode(text, index)
        except Exception:
            break
        posts.append(obj)
        index = next_index
    return posts


# 恋足恋物区里以个人名义出作品的模特。
LIANZU_PEOPLE = {"爱月下", "芝士好椰", "小糖果微甜", "初夏女神", "觅芙少女", "安乔乔", "大西瓜爱牙膏"}


def build_lianzu(records, seen):
    path = os.path.join(RAW, "kkkhai_lianzu_titles.txt")
    if not os.path.exists(path):
        return
    people = []
    for line in open(path, encoding="utf-8"):
        title = line.strip()
        if not title:
            continue
        region = region_of(title)
        person = re.search(r"《([^》]+)》", title)
        if person and person.group(1) in LIANZU_PEOPLE:
            people.append({
                "name": person.group(1),
                "aliases": [],
                "region": "china",
                "tags": ["网红"],
                "source": "kkkhai 恋足恋物",
            })
            continue
        for name in extract_names(title):
            if name in LIANZU_PEOPLE:
                continue
            key = name.casefold()
            if key in seen:
                continue
            seen.add(key)
            records.append({
                "name": name,
                "aliases": [],
                "region": region,
                "summary": ("韩国写真 / 模特机构。" if region == "korea"
                            else "台湾写真机构。" if region == "taiwan"
                            else "香港写真机构。" if region == "hongkong"
                            else "华语写真 / 福利姬机构。"),
                "source": "kkkhai 恋足恋物",
            })
    added = {p["name"] for p in people}
    for name in sorted(LIANZU_PEOPLE):
        if name in added:
            continue
        people.append({
            "name": name,
            "aliases": [],
            "region": "china",
            "tags": ["网红"],
            "source": "kkkhai 恋足恋物",
        })
    if people:
        json.dump(people, open(os.path.join(RAW, "kkkhai_lianzu_people.json"), "w",
                               encoding="utf-8"), ensure_ascii=False, indent=1)


def main():
    records = []
    seen = set()
    for file in ("kkkhai_jigou_posts.json", "kkkhai_simo_posts.json"):
        for post in salvage(os.path.join(RAW, file)):
            title = post.get("title", {}).get("rendered", "")
            region = region_of(title)
            for name in extract_names(title):
                key = name.casefold()
                if key in seen:
                    continue
                seen.add(key)
                records.append({
                    "name": name,
                    "aliases": [],
                    "region": region,
                    "summary": ("韩国写真 / 模特机构。" if region == "korea"
                                else "台湾写真机构。" if region == "taiwan"
                                else "香港写真机构。" if region == "hongkong"
                                else "华语写真 / 福利姬机构。"),
                    "source": "kkkhai 名站机构",
                })
    build_lianzu(records, seen)
    json.dump(records, open(os.path.join(RAW, "kkkhai_brand_studios.json"), "w",
                            encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"机构 {len(records)} 个")


if __name__ == "__main__":
    main()
