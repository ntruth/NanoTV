#!/usr/bin/env python3
"""把 miaomengshe 的标签与资料页整理成 Coser 名单（含简介）。

输入：
- raw/mms_tags.json      艺名标签（常带「cosplay / 写真 / 图集」后缀，需要剥掉）
- raw/mms_posts.json     图集文章
- raw/mms_profiles.json  「某某是谁 / 资料页」的正文

输出：
- raw/mms_people.json    人物（含简介、作品数、资料页链接）

资料页正文是站点自己整理的公开资料，简介取「X 是谁」下第一段；
作品数优先用正文里写的「本站记录了 N 套」，否则用标签篇数合计。
"""

from __future__ import annotations

import json
import os
import re
import unicodedata

from build_coscd_people import is_person

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")

SUFFIX = re.compile(
    r"(?i)\s*(cosplay|cos|写真|寫真|图集|圖集|套图|套圖|图片|圖片|视频|視頻|"
    r"造型|是谁|資料|资料|简介|簡介|资料页|人物资料|作品整理|作品|合集|"
    r"tuji|xiezhentuji|xiezhen|tupian|shipin|ziyuan|photos?|set)$"
)
BLOCKED = ("是谁", "资料", "資料", "简介", "簡介", "图集", "圖集", "图片", "圖片",
           "作品", "写真", "寫真", "cosplay", "预览", "預覽", "最新", "目录", "目錄")
# 站点把分类 / 题材也做成了标签，这些不是人名。
CJK_BLOCK = ("模特", "博主", "角色扮演", "二次元", "动漫", "别名", "艺人", "演员",
             "摄影", "图库", "名站", "合集", "系列", "日韩", "海外", "亚洲", "欧美",
             "国产", "韩国", "日本", "台湾", "香港", "大陆", "女优", "福利", "网红",
             "丽柜", "美图", "导航", "首页", "分类", "标签", "全部", "更多", "会员",
             "模拍")
LATIN_BLOCK = ("model", "models", "coser", "cosplay", "blogger", "idol", "studio",
               "photographer", "actor", "actress", "alias", "aliases", "profile",
               "tag", "tags", "girl", "star")
SEPARATORS = re.compile(r"[\s_\-·.]+")
NAME_CUT = re.compile(
    r"\s*(?:是谁|是谁？|海外|外文名|中文名|常用别名|资料页|资料简介|名称识别|"
    r"作品线索|代表作品|作品资料|cosplay|Cosplay|overseas|Overseas)"
)
PAREN = re.compile(r"[（(]([^）)]{1,24})[）)]")
QUOTE_LINE = re.compile(r"[“\"]([^”\"]{2,80})[”\"]\s*(?:是|，是)")
CHINESE_NUM = {"一": 1, "两": 2, "二": 2, "三": 3, "四": 4, "五": 5,
               "六": 6, "七": 7, "八": 8, "九": 9, "十": 10}

REGION_WORDS = (
    ("korea", ("韩国", "韩语", "首尔", "한국")),
    ("japan", ("日本", "日语", "东京", "大阪")),
    ("western", ("美国", "俄罗斯", "乌克兰", "法国", "德国", "英国", "意大利",
                 "西班牙", "巴西", "欧美", "白俄罗斯")),
    ("china", ("抖音", "微博", "小红书", "快手", "B站", "哔哩哔哩", "中国大陆", "国内")),
)


def norm_key(name: str) -> str:
    value = unicodedata.normalize("NFKC", name).casefold()
    return SEPARATORS.sub("", value)


def clean_tag(name: str) -> str:
    name = name.strip()
    for _ in range(3):
        stripped = SUFFIX.sub("", name).strip(" -_·")
        if stripped == name or len(stripped) < 2:
            break
        name = stripped
    return name


def usable(name: str, count: int) -> bool:
    if not is_person(name, count):
        return False
    if any(word in name for word in BLOCKED):
        return False
    if any(word in name for word in CJK_BLOCK):
        return False
    lowered = name.casefold()
    for word in LATIN_BLOCK:
        if re.search(rf"(?<![a-z0-9]){re.escape(word)}(?![a-z0-9])", lowered):
            return False
    return True


def profile_name(title: str):
    aliases = [alias.strip() for alias in PAREN.findall(title)
               if alias.strip() and not re.search(r"Coser|资料|作品|写真", alias)]
    text = PAREN.sub("", title)
    name = NAME_CUT.split(text)[0].strip(" -·_：:？?")
    name = re.sub(r"(资料与|资料|简介|人物|作品与|作品|写真|图集|最新)+$", "", name).strip()
    return name, aliases


def region_of(name: str, text: str) -> str:
    if re.search(r"[\uac00-\ud7af]", name):
        return "korea"
    if re.search(r"[\u3040-\u30ff]", name):
        return "japan"
    for region, words in REGION_WORDS:
        if any(word in text for word in words):
            return region
    return "china"


def profile_description(text: str, name: str):
    for line in text.splitlines():
        line = line.strip()
        if len(line) < 20 or "。" not in line or name not in line:
            continue
        if re.search(r"海外|名称识别|资料页|资料整理|作品整理|预览|目录|延伸阅读|下载", line):
            continue
        if not re.search(r"(是|活跃|创作|模特|Coser|博主)", line):
            continue
        line = re.sub(r"^[“‘\"]|[”’\"]$", "", line)
        sentences = re.split(r"(?<=。)", line)
        return "".join(sentences[:2]).strip()[:180]
    return None


def profile_works(text: str):
    """只认正文里明确写的「本站记录了 N 套」；NO.xxx 是站内总目录编号，不是个人套数。"""
    written = re.search(r"本站记录了[^。]{0,30}?([0-9]+|[一两二三四五六七八九十]+)\s*套", text)
    if not written:
        return 0
    token = written.group(1)
    return int(token) if token.isdigit() else CHINESE_NUM.get(token, 0)


def main():
    tags = json.load(open(os.path.join(RAW, "mms_tags.json"), encoding="utf-8"))
    posts = json.load(open(os.path.join(RAW, "mms_posts.json"), encoding="utf-8"))
    profiles_path = os.path.join(RAW, "mms_profiles.json")
    profiles = json.load(open(profiles_path, encoding="utf-8")) \
        if os.path.exists(profiles_path) else []

    # 1) 标签 → 人物；「02uiii cosplay / 02uiii 写真」这类变体合到同一人。
    groups = {}
    for tag in tags:
        name = clean_tag(tag["name"])
        if not usable(name, tag.get("count", 0)):
            continue
        key = norm_key(name)
        entry = groups.setdefault(key, {"name": name, "aliases": [], "count": 0,
                                       "link": tag.get("link")})
        if tag.get("count", 0) > entry["count"]:
            entry["name"] = name
            entry["link"] = tag.get("link") or entry["link"]
        entry["count"] += tag.get("count", 0)
        if tag["name"] not in (entry["name"],) and len(tag["name"]) <= 24:
            entry["aliases"].append(tag["name"])

    # 2) 资料页：补简介 / 别名 / 作品数 / 出处。
    profile_by_key = {}
    for profile in profiles:
        name, aliases = profile_name(profile["title"])
        if not usable(name, 2):
            continue
        key = norm_key(name)
        text = profile.get("text", "")
        profile_by_key[key] = {
            "name": name,
            "aliases": aliases,
            "description": profile_description(text, name),
            "work_count": profile_works(text),
            "source_url": profile["link"],
            "region": region_of(name, name + "\n" + text[:600]),
        }

    people = []
    used_profiles = set()
    for key, entry in groups.items():
        profile = profile_by_key.get(key)
        aliases = [alias for alias in entry["aliases"] if norm_key(alias) == key]
        work_count = min(entry["count"], 1216)
        item = {
            "name": entry["name"],
            "aliases": aliases,
            "region": "china",
            "tags": ["COS", "网红"],
            "source": "miaomengshe 标签",
            "work_count": work_count,
            "source_url": entry["link"],
        }
        if profile:
            used_profiles.add(key)
            item["name"] = profile["name"] or item["name"]
            item["aliases"] = list(dict.fromkeys(item["aliases"] + profile["aliases"]))
            item["region"] = profile["region"]
            item["source"] = "miaomengshe 标签+资料页"
            item["work_count"] = min(1216, max(work_count, profile["work_count"]))
            item["source_url"] = profile["source_url"] or item["source_url"]
            if profile["description"]:
                item["summary"] = profile["description"]
        people.append(item)

    # 只有资料页、没有标签的人也要收。
    for key, profile in profile_by_key.items():
        if key in used_profiles:
            continue
        people.append({
            "name": profile["name"],
            "aliases": profile["aliases"],
            "region": profile["region"],
            "tags": ["COS", "网红"],
            "source": "miaomengshe 资料页",
            "work_count": profile["work_count"],
            "source_url": profile["source_url"],
            "summary": profile["description"],
        })

    people.sort(key=lambda item: (-item["work_count"], item["name"]))
    json.dump(people, open(os.path.join(RAW, "mms_people.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)

    with_bio = sum(1 for person in people if person.get("summary"))
    print(f"人物 {len(people)} 位（有简介 {with_bio} 位，资料页 {len(profiles)} 篇）")
    print("作品最多：" + "、".join(f"{p['name']}({p['work_count']})" for p in people[:15]))
    print("有简介示例：" + "、".join(
        f"{p['name']}：{p['summary'][:24]}" for p in people if p.get("summary"))[:400])


if __name__ == "__main__":
    main()
