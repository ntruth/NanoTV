#!/usr/bin/env python3
"""把「五道花坊福利姬列表」与 kkkhai（美女专辑 / 名站机构）整理成增量数据。

输入：
- raw/fukuri_list.txt       五道花坊 wix 页面文本
- raw/kkkhai_mn_posts.json   kkkhai「美女专辑」分类前 72 篇文章（REST API）
输出：
- raw/fukuri_people.json    福利姬名字与别名
- raw/kkkhai_models.json    kkkhai 美女 / 模特名字
- raw/kkkhai_studios.json   名站机构 / 秀人系机构

`build_catalog_db.py` 会把这三份 JSON 合并进 catalog.sqlite。
"""

import html
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")

ORG_TOKENS = {
    "Pr社", "P社", "秀人网", "秀人", "语画界", "爱蜜社", "嗲囡囡", "花漾", "美媛馆",
    "魅妍社", "模范学院", "尤蜜荟", "蜜桃社", "尤物馆", "御女郎", "兔几盟", "薄荷叶",
    "瑞丝馆", "星乐园", "轰趴猫", "爱丝", "波萝社", "糖果画报", "猫萌榜", "模特联盟",
    "影私菀", "优星馆", "美腿宝贝", "异思趣向", "王动", "森萝财团", "大妞范儿",
    "战前女神", "PDL潘多拉", "PDL", "51MODO", "青豆客", "轻兰映画", "风之领域",
    "3Agirl", "兔玩印画", "私拍", "私人定制", "全套", "合集", "视频", "AISS",
    "尤果网", "推女郎", "推女神", "爱尤物", "头条女神", "雅拉伊", "XIUREN", "XIAOYU",
    "IMISS", "FEILIN", "HuaYang", "MyGirl", "MiStar", "MFStar", "YouMi", "MiiTao",
    "YouWu", "DKGirl", "Tukmo", "MintYe", "RUISG", "LeYuan", "PartyCat", "BoLoLi",
    "Ligui", "XingYan", "Huayan", "Candy", "Micat", "Mtmeng", "WingS", "UXING",
    "LEGBABY", "IESS", "WANIMAL", "Leglegs", "QingDouKe", "JVID", "MSLASS",
    "KelaGirls", "MTYH",
}


def clean_tokens(body: str):
    tokens = []
    for part in re.split(r"\s*[+＋]\s*", body):
        part = part.strip().strip("、,，/|")
        if not part or part in ORG_TOKENS:
            continue
        inner = re.findall(r"[（(]([^（）()]*)[）)]", part)
        outer = re.sub(r"[（(][^（）()]*[）)]", "", part).strip()
        for value in [outer] + [x for chunk in inner for x in re.split(r"[|｜/／]", chunk)]:
            value = value.replace("-Pr社", "").replace("-P社", "").strip()
            if value and value not in ORG_TOKENS and len(value) >= 2:
                tokens.append(value)
    return tokens


def build_fukuri():
    people = []
    path = os.path.join(RAW, "fukuri_list.txt")
    if not os.path.exists(path):
        return people
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        match = re.match(r"^【([^】]*)】(.*)$", line)
        if not match:
            continue
        prefix, body = match.group(1), match.group(2).strip()
        tokens = clean_tokens(body)
        if not tokens:
            continue
        people.append({
            "name": tokens[0],
            "aliases": tokens[1:],
            "region": "japan" if "日本" in prefix else "china",
            "tags": ["福利姬"],
            "source": "五道花坊",
        })
    return people


def title_name(title: str) -> str:
    title = html.unescape(title).replace("\u00a0", " ").strip()
    if " – " in title:
        return title.split(" – ")[0].strip()
    for prefix in ("秀人名模", "美女嫩模", "巨乳嫩模", "肥臀嫩模", "嫩模 ", "嫩模", "女神 ", "模特 "):
        if title.startswith(prefix):
            title = title[len(prefix):].strip()
    return re.split(r"全套|合集|全集|写真|高清|视频|\s{2,}|[\[（(，,]", title)[0].strip()


def build_models():
    models = []
    path = os.path.join(RAW, "kkkhai_mn_posts.json")
    if os.path.exists(path):
        for post in json.load(open(path, encoding="utf-8")):
            raw = post["title"]["rendered"]
            name = title_name(raw)
            if not name or len(name) < 2:
                continue
            aliases = []
            for inner in re.findall(r"[（(]([^（）()]*)[）)]", name):
                aliases.extend(x.strip() for x in re.split(r"[|｜/／]", inner) if x.strip())
            name = re.sub(r"[（(][^（）()]*[）)]", "", name).strip()
            if name:
                models.append({"name": name, "aliases": aliases, "region": "china",
                               "tags": ["秀人"], "source": "kkkhai"})

    # 美女专辑第 2 页（offset=72）的 24 条，人工核对过艺名。
    extra = [
        ("晓芃sunny", []), ("卓娅祺", []), ("赵小米", []), ("沈梦瑶", []), ("萌汉药", []),
        ("绮月樱", ["谢芷馨"]), ("心妍小公主", []), ("黄乐然", ["黄樂然", "妮小妖"]),
        ("沈佳熹", []), ("刘奕宁", []), ("琳琳ailin", []), ("轩子兔2兔", []), ("恩一", []),
        ("柳伶绮", ["七宝"]), ("李思宁", []), ("昕大大", []), ("小探戈", []), ("李可可", []),
        ("王瑞儿", []), ("张静燕", []), ("梦小楠小夜猫", []), ("绮里嘉", []),
    ]
    for name, aliases in extra:
        models.append({"name": name, "aliases": aliases, "region": "china",
                       "tags": ["秀人"], "source": "kkkhai"})
    return models


ORGS = [
    ("推女郎", ["TuiGirl", "TuiGirl推女郎"], "china"),
    ("爱尤物", [], "china"),
    ("雅拉伊", ["YALAYI", "YALAYI雅拉伊"], "china"),
    ("头条女神", ["TouTiao", "TouTiao头条女神"], "china"),
    ("尤果网", ["UGirls", "UGirls尤果网"], "china"),
    ("推女神", ["TGOD", "TGOD推女神"], "china"),
    ("XIUREN秀人网", ["XIUREN", "秀人网", "XIUREN秀人"], "china"),
    ("XIAOYU语画界", ["XIAOYU", "语画界"], "china"),
    ("IMISS爱蜜社", ["IMISS", "爱蜜社", "IMiss爱蜜社"], "china"),
    ("FEILIN嗲囡囡", ["FEILIN", "嗲囡囡"], "china"),
    ("HuaYang花漾", ["HuaYang", "花漾"], "china"),
    ("MyGirl美媛馆", ["MyGirl", "美媛馆"], "china"),
    ("MiStar魅妍社", ["MiStar", "魅妍社"], "china"),
    ("MFStar模范学院", ["MFStar", "模范学院"], "china"),
    ("YouMi尤蜜荟", ["YouMi", "尤蜜荟", "尤蜜"], "china"),
    ("MiiTao蜜桃社", ["MiiTao", "蜜桃社"], "china"),
    ("YouWu尤物馆", ["YouWu", "尤物馆"], "china"),
    ("DKGirl御女郎", ["DKGirl", "御女郎"], "china"),
    ("Tukmo兔几盟", ["Tukmo", "兔几盟"], "china"),
    ("MintYe薄荷叶", ["MintYe", "薄荷叶"], "china"),
    ("RUISG瑞丝馆", ["RUISG", "瑞丝馆"], "china"),
    ("LeYuan星乐园", ["LeYuan", "星乐园"], "china"),
    ("PartyCat轰趴猫", ["PartyCat", "轰趴猫"], "china"),
    ("AISS爱丝", ["AISS", "爱丝"], "china"),
    ("BoLoLi波萝社", ["BoLoLi", "波萝社"], "china"),
    ("ROSI写真", ["ROSI"], "china"),
    ("Beautyleg", [], "china"),
    ("MISSLEG蜜丝", ["MISSLEG", "蜜丝"], "china"),
    ("Ligui丽柜", ["Ligui", "丽柜"], "china"),
    ("ARTGRAVIA", [], "korea"),
    ("XingYan星颜社", ["XingYan", "星颜社"], "china"),
    ("Huayan花の颜", ["Huayan", "花颜", "花の颜"], "china"),
    ("Candy糖果画报", ["Candy", "糖果画报"], "china"),
    ("Micat猫萌榜", ["Micat", "猫萌榜"], "china"),
    ("Mtmeng模特联盟", ["Mtmeng", "模特联盟"], "china"),
    ("WingS影私菀", ["WingS", "影私菀"], "china"),
    ("UXING优星馆", ["UXING", "优星馆"], "china"),
    ("LEGBABY美腿宝贝", ["LEGBABY", "美腿宝贝"], "china"),
    ("DDY_Pantyhose", ["DDY"], "china"),
    ("108TV酱", ["108TV"], "china"),
    ("IESS异思趣向", ["IESS"], "china"),
    ("WANIMAL王动", ["WANIMAL"], "china"),
    ("森萝财团", [], "china"),
    ("大妞范儿", [], "china"),
    ("战前女神", [], "china"),
    ("51MODO", [], "china"),
    ("Leglegs美腿骇客", ["Leglegs", "Leghacker美腿骇客", "美腿骇客"], "china"),
    ("QingDouKe青豆客", ["QingDouKe", "青豆客"], "china"),
    ("JVID视频", ["JVID"], "taiwan"),
    ("轻兰映画", [], "china"),
    ("风之领域", [], "china"),
    ("3Agirl女郎", ["3Agirl"], "china"),
    ("兔玩印画", ["兔玩印画", "兔玩映画"], "china"),
    ("台湾写真博览会", [], "taiwan"),
    ("MSLASS梦丝女神", ["MSLASS"], "china"),
    ("KelaGirls克拉女神", ["KelaGirls", "克拉女神"], "china"),
    ("MTYH喵糖映画", ["MTYH", "喵糖映画"], "china"),
    ("丝享家", [], "china"),
    ("盘丝洞PANS", ["PANS", "盘丝洞"], "china"),
    ("丝尚Sityle", ["丝尚", "Sityle"], "china"),
    ("东篱V女郎", [], "china"),
    ("魔镜街拍", [], "china"),
    ("纳丝摄影", [], "china"),
    ("宅急约", [], "china"),
    ("壹吻映画", [], "china"),
    ("Kimoe激萌文化", ["Kimoe"], "china"),
    ("妖精视觉", [], "china"),
    ("妖精社", [], "china"),
    ("丝慕写真", ["丝慕"], "china"),
    ("JKFUN", [], "china"),
]


def build_orgs():
    return [{
        "name": name,
        "aliases": aliases,
        "region": region,
        "summary": ("韩国写真 / 模特机构。" if region == "korea"
                    else "台湾写真机构。" if region == "taiwan"
                    else "华语写真 / 福利姬机构。"),
        "source": "kkkhai",
    } for name, aliases, region in ORGS]


def main():
    people = build_fukuri()
    models = build_models()
    orgs = build_orgs()
    json.dump(people, open(os.path.join(RAW, "fukuri_people.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    json.dump(models, open(os.path.join(RAW, "kkkhai_models.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    json.dump(orgs, open(os.path.join(RAW, "kkkhai_studios.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print(f"福利姬 {len(people)} 位，kkkhai 模特 {len(models)} 位，机构 {len(orgs)} 个")


if __name__ == "__main__":
    main()
