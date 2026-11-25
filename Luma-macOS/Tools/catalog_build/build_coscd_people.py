#!/usr/bin/env python3
"""把 coscd 的标签整理成国内 Coser / 网红名单。

输入：raw/coscd_tags.json（标签名基本就是 Coser 艺名）
输出：raw/coscd_people.json

`build_catalog_db.py` 会把它并入 actresses（中国地区，标签 COS / 网红）。
"""

from __future__ import annotations

import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")

GENERIC = {
    "coser", "cosplay", "cos", "cos作品", "cos图包", "cos图集", "cos摄影", "cos写真",
    "原创", "转载", "合集", "图包", "图片", "视频", "写真", "套图", "套图合集",
    "福利", "美图", "资源", "会员", "付费", "无码", "无修", "原图", "高清", "无水印",
    "制服", "丝袜", "黑丝", "白丝", "肉丝", "泳装", "泳衣", "旗袍", "和服", "汉服",
    "jk", "二次元", "动漫", "游戏", "漫画", "同人", "自拍", "私拍", "街拍", "旅拍",
    "少女", "萝莉", "御姐", "女神", "美少女", "小姐姐", "可爱", "性感", "身材",
    "人妻", "学生", "护士", "女仆", "空姐", "教师", "秘书", "兔女郎", "精灵",
    "原创作品", "推特", "微博", "b站", "抖音", "快手", "小红书", "直播",
    "fantia", "patreon", "fanbox", "onlyfans", "twitter", "weibo", "pixiv",
    "摄影", "拍摄", "模特", "网红", "主播", "福利姬", "微密圈", "秀人", "秀人网",
    "美图分享", "图片分享", "套图分享", "资源分享", "持续更新", "美图欣赏", "欣赏",
    "ugirls", "模特图片", "图库", "相册", "预览",
}

# 游戏 / 动漫作品名，不是人名。
FRANCHISE = {
    "2b", "fgo", "fate", "fate/grand order", "fate grand order", "fate/stay night",
    "genshin", "原神", "崩坏", "崩坏3", "崩坏星穹铁道", "星穹铁道", "明日方舟",
    "碧蓝航线", "碧蓝档案", "蔚蓝档案", "少女前线", "无期迷途", "尼尔", "尼尔机械纪元",
    "最终幻想", "ff7", "ff14", "英雄联盟", "lol", "王者荣耀", "赛马娘", "偶像大师",
    "初音未来", "初音", "舰娘", "舰队collection", "艾尔登法环", "死或生", "生化危机",
    "巫师", "守望先锋", "我的世界", "宝可梦", "塞尔达", "火影忍者", "海贼王",
    "死神", "鬼灭之刃", "咒术回战", "间谍过家家", "电锯人", "葬送的芙莉莲",
    "从零开始的异世界生活", "约会大作战", "五等分的新娘", "辉夜大小姐", "龙女仆",
    "魔女之旅", "转生史莱姆", "刀剑神域", "进击的巨人", "东京喰种", "干物妹",
    "路人女主的养成方法", "青春猪头少年", "别当欧尼酱了", "孤独摇滚", "莉可丽丝",
    "更衣人偶坠入爱河", "我推的孩子", "药屋少女的呢喃", "胜利女神", "nikke",
    "少女革命", "eva", "新世纪福音战士", "高达", "火影", "海贼", "龙珠", "圣斗士",
    "奥特曼", "假面骑士", "超级战队", "变形金刚", "漫威", "dc", "迪士尼",
    "王者", "和平精英", "第五人格", "阴阳师", "光遇", "蛋仔派对", "金铲铲",
}

GENERIC_KEYWORDS = (
    "cos", "图包", "图集", "合集", "视频", "写真", "套图", "会员", "资源", "福利",
    "无码", "无修", "原图", "高清", "更新", "分享", "写真集", "作品集", "拍摄",
)
ORG_KEYWORDS = {
    "秀人", "波萝社", "尤果", "推女郎", "语画界", "爱蜜社", "嗲囡囡", "美媛馆",
    "魅妍社", "模范学院", "尤蜜荟", "蜜桃社", "尤物馆", "御女郎", "兔几盟",
    "薄荷叶", "瑞丝馆", "星乐园", "轰趴猫", "爱丝", "糖果画报", "猫萌榜",
    "模特联盟", "影私菀", "优星馆", "美腿宝贝", "异思趣向", "森萝财团",
    "大妞范儿", "战前女神", "潘多拉", "青豆客", "轻兰映画", "风之领域",
    "兔玩印画", "喵糖映画", "星颜社", "丝享家", "盘丝洞", "妖精社", "美图社",
}


SUFFIX = re.compile(r"(完整图|套装图片|图片|图集|写真|套图|合集|视频)$")


def clean_tag(name: str) -> str:
    name = name.strip()
    # 「小仓千代图片」「过期米线线喵套装图片」这类标签去掉尾巴才是艺名。
    for _ in range(3):
        stripped = SUFFIX.sub("", name).strip()
        if stripped == name or len(stripped) < 2:
            break
        name = stripped
    return name


def is_person(name: str, count: int) -> bool:
    lowered = name.strip().lower()
    if not lowered or count <= 0:
        return False
    if lowered in GENERIC or lowered in FRANCHISE:
        return False
    if any(keyword in lowered for keyword in ORG_KEYWORDS):
        return False
    if any(keyword in lowered for keyword in GENERIC_KEYWORDS):
        return False
    if any(char in name for char in "【】[]<>《》@#/\\"):
        return False
    if re.fullmatch(r"[\d\W_]+", name):
        return False
    if re.fullmatch(r"[A-Za-z0-9]{1,2}", name):
        return False
    return 2 <= len(name) <= 24


def region_of(name: str) -> str:
    if re.search(r"[\uac00-\ud7af]", name):
        return "korea"
    if re.search(r"[\u3040-\u30ff]", name):
        return "japan"
    return "china"


def main():
    tags = json.load(open(os.path.join(RAW, "coscd_tags.json"), encoding="utf-8"))
    people = []
    seen = set()
    for row in tags:
        name = clean_tag(row["name"])
        key = name.casefold()
        if key in seen or not is_person(name, row.get("count", 0)):
            continue
        seen.add(key)
        people.append({
            "name": name,
            "aliases": [],
            "region": region_of(name),
            "tags": ["COS", "网红"],
            "source": "coscd 标签",
        })
    json.dump(people, open(os.path.join(RAW, "coscd_people.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print(f"标签 {len(tags)} 个 → 人物 {len(people)} 位")
    print("示例：" + "、".join(p["name"] for p in people[:30]))


if __name__ == "__main__":
    main()
