#!/usr/bin/env python3
"""把 kkkhai 的标签树（post_tag sitemap）整理成人物 / 机构增量数据。

输入：raw/kkkhai_all_tags.json（从 post_tag-sitemap 解码出的标签名）
输出：
- raw/kkkhai_tag_people.json   标签里的模特 / Coser / 网红
- raw/kkkhai_tag_studios.json  标签里的写真机构 / 工作室 / 品牌

标签本身不带分类信息，这里用「机构后缀 + 通用词黑名单」做保守分类：
拿不准的一律留在人物侧，避免把机构当成人名。
"""

import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")

ORG_SUFFIXES = (
    "社", "馆", "館", "网", "網", "学院", "學院", "画报", "畫報", "联盟", "聯盟",
    "摄影", "攝影", "映画", "映畫", "传媒", "傳媒", "文化", "工作室", "俱乐部",
    "俱樂部", "影业", "影業", "影像", "公司", "机构", "機構", "协会", "協會",
    "基地", "中心", "会所", "會所", "阁", "閣", "殿", "坊", "屋", "库", "庫",
    "舍", "厂", "廠", "厂牌", "廠牌", "女郎", "写真", "寫真", "TV", "MODO",
    "Pantyhose", "Legs", "Girl", "Girls", "Star", "Stars", "印象",
)

GENERIC = {
    "视频", "視頻", "合集", "全集", "全套", "私拍", "私人定制", "定制", "众筹", "眾籌",
    "丝袜", "絲襪", "无内", "無內", "口交", "恋足", "戀足", "美腿", "巨乳", "贫乳",
    "貧乳", "白虎", "萝莉", "蘿莉", "学生", "學生", "人妻", "熟女", "护士", "護士",
    "空姐", "女仆", "女僕", "教师", "教師", "秘书", "秘書", "旗袍", "和服", "泳装",
    "泳裝", "福利", "vip福利", "白金版", "黄金版", "黃金版", "钻石版", "鑽石版",
    "完整版", "无码", "無碼", "中字", "高清", "图片", "圖片", "套图", "套圖",
    "原版", "无水印", "無水印", "内购", "內購", "新作", "绝版", "絕版", "稀有",
    "双盘", "雙盤", "单盘", "單盤", "散图", "散圖", "独家", "獨家", "首发", "首發",
    "私房", "写真", "寫真", "网红", "網紅", "cos", "丝模", "絲模", "密圈", "密·圈",
    "国产", "國產", "韩国", "韓國", "日本", "台湾", "台灣", "香港", "大陆", "大陸",
    "欧美", "歐美", "亚洲", "亞洲", "素人", "主播", "模特", "女神", "女郎", "少女",
    "美少女", "小姐姐", "美女", "颜值", "顏值", "身材", "大长腿", "大長腿", "长腿",
    "長腿", "黑丝", "黑絲", "白丝", "白絲", "肉丝", "肉絲", "网袜", "網襪",
    "连裤袜", "連褲襪", "高跟鞋", "制服", "情趣", "睡衣", "内衣", "內衣", "比基尼",
    "泳衣", "舞蹈", "瑜伽", "健身", "运动", "運動", "户外", "戶外", "街拍", "旅拍",
    "酒店", "浴室", "床上", "沙发", "沙發", "厨房", "廚房", "教室", "办公室",
    "辦公室", "医院", "醫院", "女警", "军装", "軍裝", "jk", "汉服", "漢服",
    "洛丽塔", "cosplay", "二次元", "动漫", "動漫", "游戏", "遊戲", "原神",
    "碧蓝航线", "碧藍航線", "明日方舟", "英雄联盟", "英雄聯盟", "王者荣耀",
    "王者榮耀", "视频合集", "pv", "vr", "4k", "8k", "1080p", "2160p",
    "会员", "會員", "付费", "付費", "无修", "無修", "原图", "原圖", "打包",
    "下载", "下載", "在线", "在線", "更新", "最新", "推荐", "推薦", "热门", "熱門",
}

# 没有机构后缀、但明确是品牌的标签。
ORG_KEYWORDS = {
    "aiss", "aiss钻石", "aiss愛絲鑽石版", "aiss爱丝", "aiss爱丝钻石版",
    "missleg蜜丝", "csgirl", "beautyleg", "artgravia", "jvid", "jvid视频",
    "leghacker美腿骇客", "legbaby美腿宝贝", "leglegs美腿骇客", "ddypantyhose",
    "pans写真", "她们印象",
    # 拉丁文写法的机构 / 店铺。
    "tights-shop-hk", "leehee-express", "pure-media",
}

# 出现在人名标签里就说明它其实是题材 / 分类词，不是人。
STRONG_GENERIC_WORDS = [
    "丝袜", "无内", "视频", "合集", "全集", "全套", "私拍", "定制", "众筹",
    "福利", "女神", "美腿", "恋足", "白丝", "黑丝", "肉丝", "高跟", "旗袍",
    "制服", "内购", "原版", "无水印", "白金版", "黄金版", "钻石版", "vip",
    "直播", "模特", "写真", "摄影", "传媒", "映画", "女郎", "套图", "图片", "原图",
    "女团", "车模", "车展", "展会", "明星", "钢管秀", "成人展", "内衣秀", "时装秀",
    "求更新", "跪求", "想要个", "资源", "健美", "情趣", "豹纹", "水果", "双马尾",
    "cosplay", "Cosplay", "素人", "主播", "网红脸", "网图",
    "系列", "网红", "微博", "动漫", "coser", "Coser", "求助", "原片", "爱秀",
    "人气", "@",
]

# 名字里带这些词就当成机构（很多品牌没有「社 / 馆」这类后缀）。
BRAND_KEYWORDS = {
    "xiuren", "tukmo", "aiss", "micat", "ruisg", "dkgirl", "mtmeng", "uxing",
    "wings", "iess", "bololi", "ligui", "xingyan", "huayan", "feilin", "imiss",
    "mistar", "mfstar", "youwu", "miitao", "mintye", "leyuan", "qingdouke",
    "youmi", "ugirls", "51modo", "legbaby", "leglegs", "missleg", "beautyleg",
    "artgravia", "jvid", "pans", "妹有show", "星乐园", "尤果", "推女郎", "语画界",
    "爱蜜社", "嗲囡囡", "美媛馆", "魅妍社", "模范学院", "尤蜜荟", "蜜桃社",
    "尤物馆", "御女郎", "兔几盟", "薄荷叶", "瑞丝馆", "轰趴猫", "爱丝", "波萝社",
    "糖果画报", "猫萌榜", "模特联盟", "影私菀", "优星馆", "美腿宝贝", "异思趣向",
    "森萝财团", "大妞范儿", "战前女神", "潘多拉", "青豆客", "轻兰映画", "风之领域",
    "兔玩印画", "喵糖映画", "星颜社", "秀人网", "丝享家", "盘丝洞", "妖精社",
    "ishow", "iss系列",
}


def pretty(name: str) -> str:
    """标签 slug 里的拉丁字母是小写的，这里把每个词首字母还原成大写。"""
    if not name:
        return name
    name = re.sub(r"(^|[ _\-.])([a-z])",
                  lambda m: m.group(1) + m.group(2).upper(), name)
    return name


def region_of(name: str) -> str:
    if re.search(r"[\uac00-\ud7af]", name):
        return "korea"
    if re.search(r"[\u3040-\u30ff]", name):
        return "japan"
    # 站内的拉丁文标签大多是华语 / 日韩模特的英文艺名，不能直接当欧美。
    return "china"


def is_org(name: str) -> bool:
    lowered = name.lower()
    if lowered in GENERIC or name in GENERIC:
        return False
    # 版本 / 会员等级不是机构。
    if name.endswith("版") and len(name) <= 5:
        return False
    if lowered in {"c0", "c1", "c2", "c3"}:
        return False
    if lowered in ORG_KEYWORDS:
        return True
    if any(keyword in lowered for keyword in BRAND_KEYWORDS):
        return True
    return any(name.endswith(suffix) or lowered.endswith(suffix.lower())
               for suffix in ORG_SUFFIXES)


def is_person(name: str) -> bool:
    lowered = name.lower()
    if not name or lowered in GENERIC:
        return False
    if name.endswith("版") and len(name) <= 5:
        return False
    if lowered in {"c0", "c1", "c2", "c3"}:
        return False
    if lowered in ORG_KEYWORDS:
        return False
    if any(keyword in lowered for keyword in BRAND_KEYWORDS):
        return False
    if any(char in name for char in "【】[]<>《》"):
        return False
    if any(word in name for word in STRONG_GENERIC_WORDS):
        return False
    # 至少要有两个字符（中文两字姓名 / 一个拉丁词）。
    return len(name) >= 2


def load_tag_names():
    """合并旧的标签名单与后来抓到的完整标签表（带 count）。"""
    names = []
    seen = set()
    path = os.path.join(RAW, "kkkhai_all_tags.json")
    if os.path.exists(path):
        for raw in json.load(open(path, encoding="utf-8")):
            if raw and raw not in seen:
                seen.add(raw)
                names.append(raw)
    path = os.path.join(RAW, "kkkhai_tags_full.json")
    if os.path.exists(path):
        for row in json.load(open(path, encoding="utf-8")):
            raw = row.get("name")
            if raw and raw not in seen:
                seen.add(raw)
                names.append(raw)
    return names


def main():
    tags = load_tag_names()
    if not tags:
        print("没有标签数据，先运行 fetch_kkkhai_site.py。")
        return

    people = []
    orgs = []
    seen_people = set()
    seen_orgs = set()
    for raw in tags:
        name = pretty(raw.strip())
        if is_org(name):
            key = name.casefold()
            if key in seen_orgs:
                continue
            seen_orgs.add(key)
            region = region_of(name)
            orgs.append({
                "name": name,
                "aliases": [raw] if raw != name else [],
                "region": region,
                "summary": ("韩国写真 / 模特机构。" if region == "korea"
                            else "日本写真机构。" if region == "japan"
                            else "华语写真 / 福利姬机构。"),
                "source": "kkkhai 标签",
            })
        elif is_person(name):
            key = name.casefold()
            if key in seen_people:
                continue
            seen_people.add(key)
            people.append({
                "name": name,
                "aliases": [raw] if raw != name else [],
                "region": region_of(name),
                "tags": ["网红"],
                "source": "kkkhai 标签",
            })

    json.dump(people, open(os.path.join(RAW, "kkkhai_tag_people.json"), "w",
                           encoding="utf-8"), ensure_ascii=False, indent=1)
    json.dump(orgs, open(os.path.join(RAW, "kkkhai_tag_studios.json"), "w",
                         encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"标签 {len(tags)} 个 → 人物 {len(people)}，机构 {len(orgs)}")
    print("机构示例：" + "、".join(o["name"] for o in orgs[:20]))
    print("人物示例：" + "、".join(p["name"] for p in people[:20]))


if __name__ == "__main__":
    main()
