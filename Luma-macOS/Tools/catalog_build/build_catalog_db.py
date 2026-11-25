#!/usr/bin/env python3
"""把抓取到的维基 / Wikidata / javrate 数据合并成 App 内置的 catalog.sqlite。

数据来源（全部存放在 Tools/catalog_build/raw，抓取脚本之外不再联网）：
- wiki_category_actresses_p1/p2.json  zh.wikipedia Category:日本AV女優 的成员
- wikidata_actresses_zhwiki.json      有中文维基条目的 AV 女优结构化字段
- wikidata_region_actresses.json      韩国 / 台湾 / 香港 / 中国大陆的成人演员
- javrate_actors_pN.md                javrate 女优列表（年龄、身高、三围、罩杯、标签、作品数）
- javrate_issuers.tsv                 javrate 出品厂列表
- wiki_studios_extracts_1/2.json      zh.wikipedia Category:日本色情片公司 的简介
- fukuri_people.json                  五道花坊福利姬列表
- kkkhai_models.json                  kkkhai 美女专辑 / 秀人模特
- kkkhai_studios.json                 kkkhai 名站机构 / 秀人系机构
- kkkhai_people_details.json          kkkhai 全站文章整理出的人物资料（套数 / 简介 / 别名 / 出处）
- kkkhai_studio_details.json          kkkhai 全站文章整理出的机构资料
- jav_actress_index.json              GitHub jav-actress 索引（约 1 万位日本女优名单）
- coscd_people.json                   coscd（萌萌秀）Coser / 网红名单与作品数
- coscd_people_extra.json             coscd 作品标题里补充的新艺名
- mms_people.json                     miaomengshe（萌萌社）Coser 名单与资料页简介
- javbus_name_map.json                JavBus / JavRate 的「日文名 → 中文译名」对照
- javrate_actor_details.json          JavRate 演员详情（简介 / 生日 / 身高 / 头像）

输出：Resources/Catalog/catalog.sqlite（提交进仓库，打包时拷进 App）。
"""

from __future__ import annotations

import base64
import colorsys
import hashlib
import html
import io
import json
import os
import re
import sqlite3
import subprocess
import sys
import unicodedata
import urllib.parse
from collections import Counter
from datetime import date, datetime

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # 没装 Pillow 时跳过厂牌字母头像
    Image = None

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "catalog_build", "raw")
OUT_DIR = os.path.join(ROOT, "Resources", "Catalog")
OUT = os.path.join(OUT_DIR, "catalog.sqlite")
NORMALIZER = os.path.join(ROOT, "Tools", "catalog_build", "t2s.swift")
BUILD_DATE = date.today().isoformat()

# ---------------------------------------------------------------- 静态词典

# 旧版 catalog-names.json 里的人工种子：来源站点不一定收录，但标题里常出现。
CURATED = {
    "japan": [
        "波多野结衣", "三上悠亚", "深田咏美", "桥本有菜", "高桥圣子", "相泽南",
        "桃乃木香奈", "河北彩花", "樱空桃", "明里紬", "神宫寺奈绪", "篠田优",
        "冲宫奈美", "龙川遥", "葵司", "星美梨香", "铃村爱里", "白石茉莉奈",
        "上原亚衣", "吉泽明步", "苍井空", "泷泽萝拉", "宇都宫紫苑",
        "阿部乃美久", "小岛南", "天海翼", "初音实", "希崎杰西卡",
        "松本菜奈实", "二阶堂梦", "樱井莉亚", "水野朝阳", "夏目娜娜", "柚木提娜",
        "大槻响", "小仓由菜", "七泽米亚", "凉森玲梦", "樱井真央", "石原希望",
        "本庄铃", "天使萌", "椎名空", "明日花绮罗", "麻美由真", "美谷朱里",
        "枫可怜", "八木奈奈", "山岸逢花", "冲田杏梨", "大岛优香", "石川澪",
        "小凑四叶", "纱仓真菜", "古川伊织", "桃谷绘里香", "辰巳唯",
        "莲实克蕾雅", "神咲诗织", "葵玲奈", "高桥由真", "相川结",
        "篠原未来", "星野娜美", "小川阿佐美", "西野翔", "宇佐美舞",
        "北条麻妃", "泽村玲子", "松岛枫",
    ],
    "korea": ["李采潭", "韩世雅", "姜艺彬"],
    "taiwan": ["吴梦梦"],
    "hongkong": ["玩偶姐姐", "HongKongDoll"],
    "china": ["刘玥", "June Liu"],
    "western": [
        "Lana Rhoades", "Riley Reid", "Mia Melano", "Angela White", "Abella Danger",
        "Brandi Love", "Cory Chase", "Lisa Ann", "Ava Addams", "Autumn Falls",
        "Gabbie Carter", "Jia Lissa", "Little Caprice", "Stacy Cruz", "Lena Paul",
        "Kendra Sunderland", "Mia Khalifa", "Tori Black", "Sasha Grey", "Riley Steele",
        "Nancy A", "Kelly Collins",
    ],
}

REGION_TITLES = {
    "japan": "日本",
    "korea": "韩国",
    "taiwan": "台湾",
    "hongkong": "香港",
    "china": "中国大陆",
    "western": "欧美",
}

COUNTRY_REGION = {
    "日本": "japan", "大韩民国": "korea", "韩国": "korea", "韓國": "korea",
    "中華民國": "taiwan", "台湾": "taiwan", "臺灣": "taiwan",
    "中华人民共和国": "china", "中国": "china", "中國": "china",
    "英屬香港": "hongkong", "香港": "hongkong", "Hong Kong": "hongkong",
    "美國": "western", "美国": "western", "英國": "western", "英国": "western",
    "加拿大": "western", "加拿大": "western", "法國": "western", "法国": "western",
    "德國": "western", "德国": "western", "意大利": "western", "西班牙": "western",
    "俄羅斯": "western", "俄罗斯": "western", "巴西": "western",
    "澳大利亞": "western", "澳大利亚": "western",
}

TAIWAN_STUDIOS = {"SWAG", "JVID", "PsychopornTW", "MODEL ME 模密", "MODEL ME",
                  "SOLEXIGHT", "台湾Limerence", "台湾写真博览会"}
CHINA_STUDIOS = {
    "麻豆传媒", "麻豆傳媒", "果冻传媒", "果凍傳媒", "天美传媒", "天美傳媒",
    "星空传媒", "星空傳媒", "精东影业", "精東影業", "蜜桃传媒", "蜜桃影像",
    "大象传媒", "乌鸦传媒", "烏鴉傳媒", "皇家华人", "皇家華人", "糖心Vlog",
    "91制片厂", "91製品厰", "兔子先生", "星空无限传媒", "星空無限傳媒",
    "乐播传媒", "樂播傳媒", "猫爪影像", "貓爪影像", "开心鬼传媒", "開心鬼傳媒",
    "迷你传媒", "迷你傳媒", "光夜蝶", "香料视觉", "香料視覺", "哈姆 MEDIA",
    "三和软体", "三和軟體", "性梦者", "性夢者", "黄金乳房", "黃金乳房",
    "辣椒原创", "辣椒原創", "涂鸦日本", "塗鴉日本", "叮叮映画", "叮叮映畫",
    "五次元", "萌眼社", "爱豆传媒", "愛豆傳媒", "杏吧", "抖阴", "抖陰",
    "91CM", "91cm", "糖心vlog", "麻豆", "麻豆映画", "麻豆映畫",
    "扣扣传媒", "扣扣傳媒", "果冻", "果凍", "天美", "精东", "精東",
}
KOREA_STUDIOS = {"Leehee-Express", "Leehee Express", "Pure Media", "Pure-Media", "SeeShe"}
WESTERN_STUDIOS = {
    "Vixen", "Blacked", "Tushy", "Brazzers", "Reality Kings", "Naughty America",
    "Mofos", "TeamSkeet", "Digital Playground", "Pure Taboo", "Girlsway",
    "Evil Angel", "Private", "X-Art", "Jules Jordan",
}

# 同一厂牌的常见写法：先登记别名，后面的记录就会并进来。
STUDIO_ALIASES = {
    "麻豆传媒": ["麻豆傳媒", "麻豆", "Madou Media"],
    "精东影业": ["精東影業", "精东", "JDS"],
    "果冻传媒": ["果凍傳媒", "果冻"],
    "天美传媒": ["天美傳媒", "天美"],
    "乌鸦传媒": ["烏鴉傳媒", "乌鸦"],
    "皇家华人": ["皇家華人"],
    "蜜桃传媒": ["蜜桃傳媒"],
    "大象传媒": ["大象傳媒"],
    "糖心Vlog": ["糖心vlog", "糖心"],
    "91制片厂": ["91製品厰", "91制品厂"],
    "扣扣传媒": ["扣扣傳媒", "KouKou Media"],
    "麻豆映画": ["麻豆映畫"],
    "JVID": ["JVID视频"],
    "MODEL ME 模密": ["MODEL ME", "模密"],
    "MSLASS梦丝女神": ["MSLASSS梦丝女神"],
    "Pure Media": ["Pure-Media", "PURE MEDIA"],
    "Leehee-Express": ["Leehee Express"],
}

# 明确不是厂牌的采集站标题。
JUNK_STUDIOS = {"及4K", "学妹校园寝室丝短袜美脚", "新日本AV女優名錄"}

# 流媒体 / 内容平台，和制作厂牌分开标注。
PLATFORM_STUDIOS = {"SWAG", "JVID", "Patreon", "熊猫TV", "OnlyFans", "Fansly", "ManyVids"}

# 头部厂牌的官方站：只收地址稳定、已核对可访问的（2026-11 验证）。
STUDIO_WEBSITES = {
    # 日本
    "S1": "https://s1s1s1.com/",
    "MOODYZ": "https://moodyz.com/",
    "IDEA POCKET": "https://ideapocket.com/",
    "PRESTIGE": "https://www.prestige-av.com/",
    "MADONNA": "https://madonna-av.com/",
    "FALENO TUBE": "https://faleno.jp/",
    "SOD": "https://www.sod.co.jp/",
    "MUTEKI": "https://muteki.jp/",
    "ATTACKERS": "https://attackers.net/",
    "WANZ FACTORY": "https://wanz-factory.com/",
    "E-BODY": "https://e-body.jp/",
    "MAX-A": "https://www.max-a.co.jp/",
    "ALICE JAPAN": "https://www.alicejapan.co.jp/",
    "DOGMA": "https://www.dogma.co.jp/",
    "一本道": "https://www.1pondo.tv/",
    "HEYZO": "https://www.heyzo.com/",
    "S-CUTE": "https://www.s-cute.com/",
    "妄想族": "https://www.mousouzoku-av.com/",
    "桃太郎映像": "https://momotaro.co.jp/",
    "DASDAS": "https://dasdas.jp/",
    "FITCH": "https://fitch-av.com/",
    "VENUS": "https://venus-av.com/",
    "OPPAI": "https://oppai-av.com/",
    "PLANETPLUS": "https://www.planetplus.jp/",
    "WAAP GROUP": "https://www.waap.co.jp/",
    # 台湾 / 华语
    "SWAG": "https://swag.live/",
    "JVID": "https://www.jvid.com/",
    # 欧美
    "Vixen": "https://www.vixen.com/",
    "Blacked": "https://www.blacked.com/",
    "Tushy": "https://www.tushy.com/",
    "Brazzers": "https://www.brazzers.com/",
    "Reality Kings": "https://www.realitykings.com/",
    "Naughty America": "https://www.naughtyamerica.com/",
    "Mofos": "https://www.mofos.com/",
    "TeamSkeet": "https://www.teamskeet.com/",
    "Digital Playground": "https://www.digitalplayground.com/",
    "Pure Taboo": "https://www.puretaboo.com/",
    "Girlsway": "https://www.girlsway.com/",
    "Evil Angel": "https://www.evilangel.com/",
    "Private": "https://www.private.com/",
    "X-Art": "https://www.x-art.com/",
    "Jules Jordan": "https://www.julesjordan.com/",
}

# 番号前缀 → 厂牌。
CODE_MAKERS = {
    "SSIS": "S1", "SONE": "S1", "SSNI": "S1", "SNIS": "S1", "STARS": "S1", "TEK": "MUTEKI",
    "MIDV": "MOODYZ", "MIDE": "MOODYZ", "MIDD": "MOODYZ", "MIAA": "MOODYZ",
    "MIRD": "MOODYZ", "MIAB": "MOODYZ", "MIMK": "MOODYZ",
    "IPX": "IDEA POCKET", "IPZ": "IDEA POCKET", "IPTD": "IDEA POCKET",
    "IDBD": "IDEA POCKET", "SUPD": "IDEA POCKET", "IPSD": "IDEA POCKET", "IPIT": "IDEA POCKET",
    "ABP": "PRESTIGE", "ABW": "PRESTIGE", "ABS": "PRESTIGE", "ABF": "PRESTIGE",
    "JUL": "Madonna", "JUC": "Madonna", "JUX": "Madonna", "JUR": "Madonna", "JUQ": "Madonna",
    "FSDSS": "FALENO", "FNS": "FALENO", "FSD": "FALENO",
    "JUFE": "Fitch",
    "HND": "本中",
    "ADN": "Attackers", "ATID": "Attackers", "SSPD": "Attackers",
    "EBOD": "E-BODY",
    "WAAA": "Wanz Factory",
    "SDDE": "SOD", "SDMU": "SOD", "STAR": "SOD", "START": "SOD",
    "MUKD": "MUTEKI", "MUTEKI": "MUTEKI",
}

BLACKLIST_NAMES = {
    "AV女優", "AV女优", "AV事務所", "AV事务所", "AV", "AV idol", "AV Idol",
    "AV女優一覧", "AV女优列表", "日本AV女優", "日本AV女优", "AV女演员列表",
    "女優", "女优", "演员", "演員",
}

# 中文维基「日本色情片公司」条目里摘出的简介，给详情页的片商档案用。
STUDIO_SUMMARIES = {
    "一本道": "一家在美国注册的日本成人影片制造商，以出品无码影片为卖点，并提供线上付费下载，2001 年开始营运。",
    "E-BODY": "日本 E-BODY 发行的系列成人影视，2007 年 12 月发行首部作品，多以单体女优出演。",
    "H.m.p": "h.m.p 株式会社（原名芳友舍），创业于 1981 年，是日本成人影片制造商，公司位于东京都文京区。",
    "Alice Japan": "Alice Japan 株式会社，成立于 1986 年 4 月 4 日，是 Japan Home Video（JHV）旗下的成人影片制造商。",
    "IdeaPocket": "日本的 AV 片商，以开发单体女优为主；原本是北都集团下的部门，后来独立成公司。",
    "Dogma": "创业于 2001 年的日本 AV 片商，以单体女优为主，公司位于东京都港区。",
    "Attackers": "创业于 1996 年的日本 AV 片商，作品以 SM 与凌辱题材为导向。",
    "Aurora Project": "创业于 2005 年的日本 AV 片商，以单体女优为主，作品偏向凌辱题材。",
    "Cross": "创业于 2005 年的日本 AV 片商，以单体女优为主，是北都集团的外部公司。",
    "Dream Ticket": "日本 AV 片商，以单体女优为主，公司位于东京都新宿区。",
    "CA集團": "日本最大的成人视频制造商之一，总部位于东京都港区，又称 Outvision，旗下包括 DMM.com。",
    "1113工房": "日本的成人录像企业，主要出版恋物癖与粉丝向作品，简称「1113」或「工房」。",
    "Allpro": "日本的 AV 片商与事务所，集团旗下包含 allcreate、lezule 与 FALENO 等部门。",
    "Das!": "创业于 2007 年的日本 AV 片商，Outvision 成员，早期以凌辱题材为主，后扩展多种类别。",
    "九鬼": "日本成人影片制造商，1977 年设立，KUKI 为其最著名品牌，1983 年正式参与 AV 制作。",
    "Madonna": "创业于 2003 年的日本 AV 片商，隶属北都集团，以熟女与人妻题材为主。",
    "KM Produce": "创业于 2002 年的日本 AV 片商，缩写 KMP，以单体女优为主，总部位于东京都目黑区。",
    "馬克思兄弟": "创业于 1998 年的日本 AV 片商，以单体女优为主，2004 年后委托北都集团销售。",
    "Max-A": "日本成人影片制造商，曾拥有高树玛利亚、苍井空、吉泽明步、Rio 等知名女优。",
    "妄想族": "建立于 2006 年 4 月的成人影片制造商集团，为 CA 集团旗下制造厂，与 DMM 签订销售委托契约。",
    "日本家庭录影公司": "Japan Home Video（JHV），成立于 1984 年 5 月，制作与发行视频，旗下有 Alice Japan。",
    "本中": "创立于 2010 年 12 月的日本 AV 片商，是 CA 集团的内部制造商，名称取自「本物中出」的简称。",
    "水晶映像": "日本色情片制作公司，成立于 1984 年，办公室位于东京都丰岛区。",
    "溜池GORO": "日本 AV 片商，2003 年 12 月以 MOODYZ 内部企划起步，2006 年 2 月独立，作品以熟女与人妻为主。",
    "隼": "创业于 1992 年 3 月 16 日的日本 AV 片商，公司位于东京都墨田区，主要以开发单体女优为主。",
    "馬克斯集團": "日本的 AV 事务所与旗下公司，也负责成人影片生产，依年龄分为 MARKS JAPAN、Five Promotion、BARDOT 三家公司管理。",
    # 中文维基有明确条目，按原文收录，不自行补写。
    "麻豆传媒": "麻豆传媒是一家华语色情片制作与发行公司，在美国加州注册，服务器设于美国。",
    "SWAG": "台湾影音串流平台，2016 年 8 月由黄立成创办，前身为 17LIVE 旗下副品牌；2017 年 5 月起转型为独立成人创作平台，以直播、私讯与自制成人影片为主。",
}


# ---------------------------------------------------------------- 工具

def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def strip_disambiguation(title: str) -> str:
    return re.sub(r"\s*[（(][^（）()]*[）)]\s*$", "", title).strip()


def clean_name(value: str) -> str:
    value = urllib.parse.unquote(value).replace("_", " ").strip()
    return strip_disambiguation(value)


def normalize_all(names):
    """用 Foundation 的繁简转换生成合并键（与 App 运行时一致）。"""
    if not names:
        return []
    payload = "\n".join(names).encode("utf-8")
    result = subprocess.run(
        ["swift", NORMALIZER], input=payload, stdout=subprocess.PIPE, check=True
    )
    converted = json.loads(result.stdout.decode("utf-8"))
    # Foundation 只处理繁简，不处理日文新字体；补一层常见异体字，
    # 让「三上悠亜 / 三上悠亚」「桜空もも / 樱空桃」这类写法合并成同一个人。
    # 再去掉大小写、全半角、空白与标点的差异，和 App 里的 normalize 保持一致，
    # 「Leehee Express / Leehee-Express」这类写法才会合并。
    return [merge_key(value.translate(JP_VARIANTS)) for value in converted]


def simplify_all(names):
    """繁体 → 简体的显示写法（不做去标点 / 小写化）。"""
    if not names:
        return []
    payload = "\n".join(names).encode("utf-8")
    result = subprocess.run(
        ["swift", NORMALIZER], input=payload, stdout=subprocess.PIPE, check=True
    )
    return json.loads(result.stdout.decode("utf-8"))


def merge_key(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).casefold()
    return "".join(ch for ch in value
                   if not ch.isspace() and unicodedata.category(ch)[0] not in "PZS")


def studio_summary(name: str) -> str | None:
    """维基摘录的厂牌简介：大小写 / 空格 / 繁简不同也能对上。"""
    if name in STUDIO_SUMMARIES:
        return STUDIO_SUMMARIES[name]
    key = merge_key(name.translate(JP_VARIANTS))
    for candidate, summary in STUDIO_SUMMARIES.items():
        if merge_key(candidate.translate(JP_VARIANTS)) == key:
            return summary
    return None


# 常见日文新字体 / 异体字 → 简体中文写法（只用于合并键，不改显示名）。
JP_VARIANTS = str.maketrans({
    "亜": "亚", "亞": "亚", "絵": "绘", "繪": "绘", "沢": "泽", "澤": "泽",
    "桜": "樱", "櫻": "樱", "髙": "高", "徳": "德", "恵": "惠", "歩": "步",
    "実": "实", "穂": "穗", "涙": "泪", "涼": "凉", "瀬": "濑", "篠": "筱",
    "岡": "冈", "廣": "广", "濱": "滨", "浜": "滨", "邊": "边", "齋": "斋",
    "塩": "盐", "増": "增", "蔵": "藏", "黒": "黑", "眞": "真", "恆": "恒",
    "遥": "遥", "遙": "遥", "邉": "边", "鹽": "盐",
})

# ---------------------------------------------------------------- 名字清洗

# 这些字出现在名字里，基本都是正文句子被截断成了「名字」。
PROSE_NAME = re.compile(
    r"(是|為|位|的|年|月|日|歲|岁|女優|演員|出生|出道|作品|出演|自述|擁有|还是|還是|个人|個人|资料|資料)")
PERSON_RE = re.compile(
    r"^[\u3040-\u30ff\u4e00-\u9fffA-Za-z][\u3040-\u30ff\u4e00-\u9fffA-Za-z・ー ]{1,19}$")
ALIAS_BLOCK = re.compile(r"[&，。：；、／/]")
GENERIC_NAMES = {
    "秀人", "微密圈", "美图", "福利", "套图", "写真", "圖集", "图集", "模特",
    "coser", "cosplay", "网红", "微博", "抖音", "快手", "美人", "女优", "女優",
    "演员", "演員", "模特儿", "模特兒", "av女优", "av女優", "av actress",
    # 平台名经常被采集站当成别名，不能作为合并键。
    "斗鱼", "虎牙", "b站", "小红书", "哔哩哔哩", "微信", "公众号", "微店",
    "onlyfans", "patreon", "twitter", "instagram", "tiktok", "youtube",
    "twitch", "telegram", "fantia", "fanbox", "fansly", "manyvids", "afdian",
}
GENERIC_KEYS = {merge_key(name.translate(JP_VARIANTS)) for name in GENERIC_NAMES}


def clean_person_name(value):
    """过滤从简介里截出来的「名字」（如「一心えりか是位天真無邪的」）。"""
    value = (value or "").strip()
    # 假名后直接拼罗马字的写法，砍掉罗马字部分。
    value = re.sub(r"(?<=[\u3040-\u30ff\u4e00-\u9fff])[A-Za-z]+$", "", value).strip()
    if not value or not PERSON_RE.fullmatch(value) or PROSE_NAME.search(value):
        return None
    return value


def clean_alias(value):
    """别名要能当名字用：去掉「A&B」「陆萱萱&安然」这类合并标题和站点名。"""
    value = (value or "").strip()
    if not value or len(value) > 20:
        return None
    if ALIAS_BLOCK.search(value) or PROSE_NAME.search(value):
        return None
    if value.casefold() in GENERIC_NAMES:
        return None
    # 「越南」「香港」这类地区词经常被当成别名塞进来，不是名字。
    if merge_key(value.translate(JP_VARIANTS)) in REGION_WORD_KEYS:
        return None
    return value


def domestic_alias_ok(primary, alias):
    """国内数据的别名里常混进「相关推荐」的其他人名。

    只接受与主名共享 2 个字符以上的写法，或纯拉丁 / 含假名的另一种写法。
    """
    if not alias:
        return False
    primary_key = merge_key((primary or "").translate(JP_VARIANTS))
    alias_key = merge_key(alias.translate(JP_VARIANTS))
    if not alias_key or alias_key == primary_key:
        return False
    if alias_key in GENERIC_KEYS:
        return False
    if len(set(alias_key) & set(primary_key)) >= 2:
        return True
    if re.fullmatch(r"[a-z0-9 .'\-]+", alias_key):
        return True
    return bool(re.search(r"[\u3040-\u30ff]", alias_key))


# 采集站自己的「收录 55 套 · 11.7G · 更新至 2021.08」是站内快照，不是人物属性。
SITE_STAT = re.compile(
    r"\s*[·•]?\s*(?:收录\s*\d+\s*[套期部集]|[0-9]+(?:\.[0-9]+)?\s*[GMT]B?"
    r"|更新至\s*\d{4}(?:[.\-/]\d{1,2})?)\s*",
    re.I)
SITE_STAT_SOURCES = ("kkkhai", "coscd", "miaomengshe", "fukuri", "五道花坊")


def has_site_stats(source: str | None) -> bool:
    lowered = (source or "").lower()
    return any(token in lowered for token in SITE_STAT_SOURCES)


def clean_site_summary(value):
    """去掉站内套数 / 体积 / 更新时间这些瞬时数据。"""
    if not value:
        return None
    cleaned = SITE_STAT.sub(" ", value)
    cleaned = re.sub(r"\s*[·•]\s*$", "", cleaned)
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip()
    return cleaned or None


# ---------------------------------------------------------------- 国内条目清洗

DOMESTIC_REGIONS = {"china", "taiwan", "hongkong"}

REGION_WORD_KEYS = {
    merge_key(name) for name in (
        "中国", "中国大陆", "大陆", "台湾", "台灣", "香港", "澳门", "澳門",
        "韩国", "韓國", "日本", "美国", "美國", "越南", "泰国", "泰國",
        "新加坡", "马来西亚", "馬來西亞", "欧美", "歐美", "日本模特", "韩国模特")
}

# 采集站的人物名常把页面标题当成名字：「Cazi姬纪 视觉导读」「白袜袜格罗丫外文名」。
NAME_TAIL_JUNK = re.compile(
    r"\s*(?:视觉导读|外文名|个人资料|个人主页|个人|资料|介绍|档案|简介|图片|"
    r"B站|b站|微博主页|微博|跨语言|资料页|公开|角色|代表|平台|名称写法.*)$")
NAME_HEAD_PLATFORM = re.compile(
    r"^\s*(?:抖音|微博|B站|b站|斗鱼|快手|小红书|微密圈)\s*[·:：]?\s*")
NAME_TAIL_COUNT = re.compile(r"\s*\d+\s*[套期部集]$")
# 以这些词结尾的基本是列表页 / 资源包标题，不是人物名。
NAME_TAIL_LIST = re.compile(r"(作品|图集|合集|套图|资源|视频|图片|目录|专题|排行榜|推荐)$")
CJK_CHAR = r"[\u4e00-\u9fff]"


def clean_domestic_name(value):
    """去掉国内采集站标题带出来的后缀（「Cazi姬纪 视觉导读」→「Cazi姬纪」）。"""
    name = (value or "").strip()
    if not name:
        return None
    while True:
        cleaned = NAME_TAIL_JUNK.sub("", name).strip()
        cleaned = NAME_TAIL_COUNT.sub("", cleaned).strip()
        cleaned = NAME_HEAD_PLATFORM.sub("", cleaned).strip()
        if cleaned == name:
            break
        name = cleaned
    # r蠢沫沫 / w黑米粥w 这类为了规避搜索加的前后单字母。
    name = re.sub(rf"^[A-Za-z](?={CJK_CHAR})", "", name)
    name = re.sub(rf"(?<={CJK_CHAR})[A-Za-z]$", "", name)
    return name.strip() or None


def split_parenthetical(value):
    """「小泉学姐吖(次屁啦)」→ 主名 + 括号里的别名。"""
    match = re.match(r"^(.*?)\s*[（(]([^（）()]{1,20})[）)]\s*$", value or "")
    if match and match.group(1).strip():
        return match.group(1).strip(), match.group(2).strip()
    return (value or "").strip(), None


def domestic_variants(key):
    """同一个人常见的写法差异：英文前后缀、结尾重复字母。"""
    variants = set()
    if not key:
        return variants
    stripped = re.sub(rf"(?<={CJK_CHAR})[a-z]{{1,10}}$", "", key)
    if len(stripped) >= 3 and stripped != key:
        variants.add(stripped)
    match = re.match(rf"^([a-z]{{3,12}})({CJK_CHAR}{{3,}}.*)$", key)
    if match:
        variants.add(match.group(2))
    stripped = re.sub(rf"^[a-z](?={CJK_CHAR})", "", key)
    if len(stripped) >= 3 and stripped != key:
        variants.add(stripped)
    stripped = re.sub(rf"(?<={CJK_CHAR})[a-z]{{1,2}}$", "", key)
    if len(stripped) >= 3 and stripped != key:
        variants.add(stripped)
    return variants


# 国内站点的简介大多是 AI 水文 / 主观测评 / 资源说明，只保留能核实的事实。
SUMMARY_NOISE = (
    "给人的第一印象", "第一印象是", "公开资料", "现有资料", "当前资料", "当前可确认",
    "可以确认", "已确认", "资料边界", "本页", "这一节", "不额外", "不补写",
    "不宜自行臆测", "未经证实", "值得优先关注", "更值得先看", "读者", "检索",
    "名称识别", "资料整理", "名称对应", "跨语言", "罗马音", "写法", "构成本页",
    "这一昵称", "这一名称", "作为公开作品", "进行查看", "暂未确认", "目前暂无",
    "需要以公开信息", "理论上", "可能存在的", "统一把", "视为同一人物",
    "资料里没有明确写到", "暂时不当成确定信息", "仅采用已出现", "不额外扩展",
    "当前未有可靠资料", "资料很少", "资料不足", "公开内容", "这一中文名",
    "外文名", "日文名", "身份线索", "称谓", "识别", "整理",
)
SUMMARY_SUBJECTIVE = (
    "颜值", "脸蛋", "长相", "身材", "胸部", "美胸", "大腿", "长腿", "美腿", "腿型",
    "PS", "p图", "照骗", "真颜", "好看", "漂亮", "甜美", "可爱", "性感", "诱惑",
    "极品", "一流", "中规中矩", "养眼", "御姐", "萝莉", "婴儿肥", "真家伙", "冲击力",
    "审美", "恐怖", "奇葩", "夸张", "魂牵梦绕", "妹子", "小姐姐", "福利多", "诱人",
    "香艳", "很美", "好美", "挺美", "很萌", "好萌", "作品感觉", "观感", "看吧",
    "据说", "估计", "绅士", "妹纸", "小清纯", "精品", "壁纸", "老人", "人气",
    "未公开", "公开信源", "信息记录", "核心在于", "自称", "小仙女", "川妹", "嫩模",
    "美女", "评鉴", "火出圈", "页面提示", "个人空间", "画面适应能力",
)
SUMMARY_RESOURCE = (
    "合集", "套图", "私拍", "众筹", "资源", "下载", "流出", "收录", "拿到", "发出来",
    "包里", "更新", "图包", "图集", "视频", "图片", "付费", "VIP", "会员", "福利",
    "作品质量", "作品数量", "绝版", "下架",
)
SUMMARY_FACTS = (
    "出生于", "生于", "来自", "毕业于", "现居", "定居", "创立", "成立", "担任",
    "签约", "获得", "发行", "参演", "活跃于", "职业", "本名", "抖音号", "粉丝",
    "微博", "B站", "Instagram", "YouTube", "年出生",
)
SUMMARY_YEAR = re.compile(r"\d{4}\s*年")


def clean_domestic_summary(value):
    """国内人物简介：删掉 AI 水文、主观测评与资源说明，只留事实型描述。"""
    text = clean_site_summary(value)
    if not text:
        return None
    if any(token in text for token in SUMMARY_NOISE):
        return None
    if any(token in text for token in SUMMARY_SUBJECTIVE):
        return None
    if not (any(token in text for token in SUMMARY_FACTS) or SUMMARY_YEAR.search(text)):
        return None
    if any(token in text for token in SUMMARY_RESOURCE):
        return None
    return text


def summary_for(value, region):
    if region in DOMESTIC_REGIONS:
        return clean_domestic_summary(value)
    return clean_site_summary(value)


def normalize_birth(value):
    """Wikidata 年份精度会写成 YYYY-01-01，别把它当成真实生日。"""
    if not value:
        return None
    text = str(value)[:10]
    match = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", text)
    if not match:
        return text if re.fullmatch(r"\d{4}", text) else None
    year, month, day = match.groups()
    if month == "01" and day == "01":
        return year
    return f"{year}-{month}-{day}"


def region_from_country(label: str | None) -> str | None:
    if not label:
        return None
    return COUNTRY_REGION.get(label.strip())


def region_from_tags(tags) -> str | None:
    joined = " ".join(tags or [])
    if "中國人" in joined or "中国人" in joined:
        return "china"
    if "台灣人" in joined or "台湾人" in joined:
        return "taiwan"
    if "韓國人" in joined or "韩国人" in joined:
        return "korea"
    if "香港人" in joined:
        return "hongkong"
    return None


# ---------------------------------------------------------------- 女优

class Actress:
    def __init__(self, name):
        self.names = [name]
        self.region = None
        self.birth_date = None
        self.age = None
        self.age_asof = None
        self.height = None
        self.bust = None
        self.waist = None
        self.hips = None
        self.cup = None
        self.work_count = None
        self.tags = []
        self.summary = None
        self.description = None
        self.image_url = None
        self.source_url = None
        self.sources = set()
        self.name_ja = None
        self.name_en = None

    def add_name(self, value):
        value = (value or "").strip()
        if value and value not in self.names:
            self.names.append(value)


JAVRATE_ACTOR = re.compile(
    r"### \[ (.+?) \]\((https://www\.javrate\.com/actor/detail/[0-9a-f-]+\.html)\)"
)
JAVRATE_ITEM = re.compile(r"\[ ([^\]]*?) \]\(https://www\.javrate\.com/actor/detail/[^)]+\)")


def parse_javrate_text(text):
    """解析 javrate「全部AV女優」列表页（markdown）里的条目。"""
    result = []
    matches = list(JAVRATE_ACTOR.finditer(text))
    for index, match in enumerate(matches):
        block = text[match.end(): matches[index + 1].start() if index + 1 < len(matches) else len(text)]
        record = {
            "name": match.group(1).strip(),
            "url": match.group(2),
            "works": None,
            "age": None,
            "height": None,
            "bust": None,
            "waist": None,
            "hips": None,
            "cup": None,
            "tags": [],
        }
        for value in JAVRATE_ITEM.findall(block):
            value = value.strip()
            works = re.fullmatch(r"(\d+)部AV", value)
            body = re.fullmatch(
                r"(\d+)\s*歲\s*(\d+)\s*cm\s*(\d+)-(\d+)-(\d+)\s*\|\s*([A-Z])\s*罩杯",
                value,
            )
            if works:
                record["works"] = int(works.group(1))
            elif body:
                record["age"] = int(body.group(1))
                record["height"] = int(body.group(2))
                record["bust"] = int(body.group(3))
                record["waist"] = int(body.group(4))
                record["hips"] = int(body.group(5))
                record["cup"] = body.group(6)
            elif value and value not in ("crown  HOT",):
                record["tags"] = [part for part in re.split(r"\s{2,}", value) if part]
        result.append(record)
    return result


def parse_javrate_actors():
    result = []
    for name in sorted(os.listdir(RAW)):
        if not (name.startswith("javrate_actors_p") and name.endswith(".md")):
            continue
        text = open(os.path.join(RAW, name), encoding="utf-8").read()
        result.extend(parse_javrate_text(text))
    # 后来补抓的 100 多页列表统一存在这份 JSON 里。
    for extra in ("javrate_actors_all.json", "javrate_actors_tail.json"):
        extra_path = os.path.join(RAW, extra)
        if os.path.exists(extra_path):
            result.extend(load_json(extra_path))
    return result


def parse_wiki_category():
    names = []
    for file in ("wiki_category_actresses_p1.json", "wiki_category_actresses_p2.json"):
        root = load_json(os.path.join(RAW, file))
        for member in root.get("query", {}).get("categorymembers", []):
            title = member.get("title", "")
            if not title or member.get("ns", 0) != 0:
                continue
            names.append(clean_name(title))
    return names


def parse_wikidata(file):
    path = os.path.join(RAW, file)
    if not os.path.exists(path):
        return []
    root = load_json(path)
    if isinstance(root, list):
        # 抓取时被截断的 SPARQL 结果已经提前整理成扁平 JSON。
        rows = [{key: {"value": value} for key, value in row.items() if value}
                for row in root]
    else:
        rows = root.get("results", {}).get("bindings", [])
    result = []
    for row in rows:
        def value(key):
            item = row.get(key)
            return item.get("value") if item else None

        zh = value("zhLabel")
        ja = value("jaLabel")
        en = value("enLabel")
        wiki = value("zhwiki")
        title = None
        if wiki and "/wiki/" in wiki:
            title = clean_name(wiki.split("/wiki/", 1)[1])
        name = zh or title or ja or en
        if not name:
            continue
        birth = normalize_birth(value("birth") or "")
        height = value("height")
        try:
            height = int(float(height)) if height else None
        except ValueError:
            height = None
        image = value("image")
        if image and image.startswith("http://"):
            image = "https://" + image[len("http://"):]
        result.append({
            "title": title,
            "name": name,
            "zh": zh,
            "ja": ja,
            "en": en,
            "birth": birth,
            "height": height,
            "region": region_from_country(value("countryLabel")),
            "image": image,
            "description": value("descr"),
            "source_url": wiki,
        })
    return result


def blank_actress(name):
    return {
        "name": name,
        "names": [],
        "region": None,
        "birth_date": None,
        "age": None,
        "age_asof": None,
        "height": None,
        "bust": None,
        "waist": None,
        "hips": None,
        "cup": None,
        "work_count": None,
        "tags": [],
        "summary": None,
        "description": None,
        "image": None,
        "source_url": None,
        "sources": set(),
        "name_ja": None,
        "name_en": None,
        "hobby": None,
        "birth_precision": None,
        "ruby": None,
        "birthplace": None,
        "blood_type": None,
        "debut_year": None,
        "agency": None,
        "status": None,
        "official_site": None,
    }


def blank_studio(name):
    return {
        "name": name,
        "names": [],
        "region": None,
        "kind": None,
        "work_count": None,
        "summary": None,
        "website": None,
        "source_url": None,
        "sources": set(),
    }


def detail_names(detail):
    names = detail.get("names")
    if names:
        return [detail["name"], *[name for name in names if name != detail["name"]]]
    return [detail["name"], *detail.get("aliases", [])]


def apply_actress_details(merged, name_keys, details):
    """把 kkkhai 文章资料合并进已有记录；没有记录的人补成新条目。"""
    # 先把别名过滤干净：国内站点的别名里常混进别人的名字。
    prepared = []
    for detail in details:
        primary = detail.get("name") or ""
        if not primary:
            continue
        region = detail.get("region")
        names = [primary]
        for name in detail_names(detail)[1:]:
            cleaned = clean_alias(name)
            if not cleaned:
                continue
            if region in DOMESTIC_REGIONS and not domestic_alias_ok(primary, cleaned):
                continue
            if cleaned not in names:
                names.append(cleaned)
        prepared.append((detail, names))

    flat = [name for _, names in prepared for name in names]
    normalized = normalize_all(flat) if flat else []
    cursor = 0
    added = 0
    for detail, names in prepared:
        keys = normalized[cursor: cursor + len(names)]
        cursor += len(names)
        key = next((name_keys[k] for k in keys if name_keys.get(k) in merged), None)
        if key is None:
            if detail.get("require_existing"):
                continue
            key = keys[0] if keys else None
            if not key or key in merged:
                continue
            merged[key] = blank_actress(detail["name"])
            added += 1
        target = merged[key]
        for position, candidate_key in enumerate(keys):
            # 2 字以内的别名太通用（「斗鱼」「二佐」），不当作合并键。
            if position and (len(candidate_key) < 3 or candidate_key in GENERIC_KEYS):
                continue
            name_keys.setdefault(candidate_key, key)
        for candidate in names:
            if candidate and candidate not in target["names"]:
                target["names"].append(candidate)
        # 标签里常是小写英文（fish / haneame），文章标题里的写法更好看。
        if target["name"].casefold() == detail["name"].casefold():
            target["name"] = detail["name"]
        for candidate in names:
            japanese = clean_person_name(candidate)
            if target.get("name_ja") is None and japanese and re.search(r"[ぁ-んァ-ヶ]", japanese):
                target["name_ja"] = japanese
            if target.get("name_en") is None and re.fullmatch(r"[A-Za-z0-9 .'\-]+", candidate or ""):
                target["name_en"] = candidate
        if not target.get("region") and detail.get("region"):
            target["region"] = detail["region"]
        elif (detail.get("region") and target.get("region") in ("western", "china")
              and detail["region"] != target["region"]):
            # 旧版按「拉丁字母即欧美」或默认「中国大陆」猜的地区，
            # 遇到文章里更可靠的判断（日文假名 / 韩文 / 明确标注）就用它。
            target["region"] = detail["region"]
        site_stats = has_site_stats(detail.get("source"))
        region = target.get("region") or detail.get("region")
        for field in ("summary", "description", "source_url", "image",
                      "birth_date", "height", "bust", "waist", "hips", "cup", "hobby"):
            value = detail.get(field)
            if field in ("summary", "description"):
                value = summary_for(value, region)
            if target.get(field) is None and value is not None:
                target[field] = value
        japanese = clean_person_name(detail.get("name_ja"))
        if target.get("name_ja") is None and japanese:
            target["name_ja"] = japanese
        if detail.get("work_count") is not None and not site_stats:
            target["work_count"] = max(target.get("work_count") or 0, detail["work_count"])
        for tag in detail.get("tags", []):
            if tag not in target["tags"]:
                target["tags"].append(tag)
        target["sources"].add(detail.get("source", "kkkhai 人物"))
    return added


def javbus_detail_rows():
    """JavBus 演员页（生日 / 身高 / 三围 / 罩杯）→ 详情记录。"""
    details_path = os.path.join(RAW, "javbus_star_details.json")
    if not os.path.exists(details_path):
        return []
    details = load_json(details_path)
    stars_path = os.path.join(RAW, "javbus_stars_zh.json")
    stars = load_json(stars_path) if os.path.exists(stars_path) else {}
    map_path = os.path.join(RAW, "javbus_name_map.json")
    mapping = load_json(map_path) if os.path.exists(map_path) else []

    names_by_star: dict[str, list[str]] = {}
    for entry in mapping:
        star_id = entry.get("star_id")
        if not star_id:
            continue
        bucket = names_by_star.setdefault(star_id, [])
        for name in (entry.get("zh"), entry.get("ja")):
            if name and name not in bucket:
                bucket.append(name)
    for star_id, name in stars.items():
        bucket = names_by_star.setdefault(star_id, [])
        if name not in bucket:
            bucket.append(name)

    rows = []
    for star_id, info in details.items():
        if info.get("empty"):      # 演员页没有任何资料字段，抓取时已标记过
            continue
        names = names_by_star.get(star_id) or []
        if not names:
            continue
        rows.append({
            "name": names[0],
            "names": names[1:],
            "birth_date": info.get("birthday"),
            "height": info.get("height"),
            "bust": info.get("bust"),
            "waist": info.get("waist"),
            "hips": info.get("hips"),
            "cup": info.get("cup"),
            "hobby": info.get("hobby"),
            "source_url": f"https://www.javbus.com/star/{star_id}",
            "region": "japan",
            "source": "javbus 演员页",
        })
    return rows


def javbus_star_rows(name_keys):
    """JavBus 演员页的日文名（+ 已探活头像），只补给已有记录。

    portrait_candidates.json 是按名字匹配出来的 star_id 清单，
    所以这里的 star 名就是该演员的日文写法，可以补 name_ja。
    """
    stars_path = os.path.join(RAW, "javbus_stars_zh.json")
    candidates_path = os.path.join(RAW, "portrait_candidates.json")
    if not os.path.exists(stars_path) or not os.path.exists(candidates_path):
        return []
    stars = load_json(stars_path)
    portraits_path = os.path.join(RAW, "javbus_portraits.json")
    portraits = load_json(portraits_path) if os.path.exists(portraits_path) else {}
    rows = []
    for star_id in load_json(candidates_path):
        name = stars.get(star_id)
        if not name:
            continue
        base = re.sub(r"\s*[（(][^）)]*[）)]\s*$", "", name).strip() or name
        japanese = clean_person_name(base)
        row = {
            "name": base,
            "names": [name] if name != base else [],
            "name_ja": japanese,
            "region": "japan",
            "source": "javbus 演员页",
            "require_existing": True,
        }
        url = portraits.get(star_id)
        if url:
            row["image"] = url
        rows.append(row)
    return rows


def wiki_bio_rows():
    """中文维基条目首段 → 人物简介 / 生日。"""
    path = os.path.join(RAW, "wiki_actress_bios.json")
    if not os.path.exists(path):
        return []
    rows = []
    for title, info in load_json(path).items():
        name = strip_disambiguation(title)
        names = [title] if title != name else []
        japanese = clean_person_name(info.get("ja"))
        if japanese and japanese not in names:
            names.append(japanese)
        rows.append({
            "name": name,
            "names": names,
            "summary": info.get("summary"),
            "birth_date": info.get("birth"),
            "source_url": info.get("url"),
            "region": "japan",
            "source": "中文维基",
        })
    return rows


def javrate_detail_rows():
    """JavRate 演员详情 → apply_actress_details 的输入格式。"""
    details_path = os.path.join(RAW, "javrate_actor_details.json")
    if not os.path.exists(details_path):
        return []
    details = load_json(details_path)
    actors_path = os.path.join(RAW, "javrate_actors_all.json")
    actors = {row["name"]: row for row in load_json(actors_path)} \
        if os.path.exists(actors_path) else {}
    rows = []
    for name, info in details.items():
        base = actors.get(name, {})
        rows.append({
            "name": name,
            "names": info.get("ja") or [],
            "summary": info.get("description"),
            "birth_date": info.get("birth_date"),
            "height": info.get("height"),
            "image": info.get("image"),
            "source_url": base.get("url"),
            "work_count": base.get("works"),
            "region": "japan",
            "source": "javrate 详情",
        })
    return rows


def apply_studio_details(merged, name_keys, details):
    """机构同理：只补空字段，不覆盖中文维基的简介。"""
    prepared = []
    for detail in details:
        name, extra, region = split_studio_names(detail.get("name") or "")
        name = clean_studio_name(name)
        if not name:
            continue
        entry = dict(detail)
        entry["name"] = name
        entry["aliases"] = [*detail.get("aliases", []), *extra]
        if region and not entry.get("region"):
            entry["region"] = region
        entry["summary"] = clean_studio_summary(detail.get("summary"), detail.get("source"))
        prepared.append(entry)
    details = prepared

    flat = [name for detail in details for name in detail_names(detail)]
    normalized = normalize_all(flat) if flat else []
    cursor = 0
    added = 0
    for detail in details:
        names = detail_names(detail)
        keys = normalized[cursor: cursor + len(names)]
        cursor += len(names)
        key = next((name_keys[k] for k in keys if name_keys.get(k) in merged), None)
        if key is None:
            if not detail.get("allow_new"):
                continue
            key = keys[0] if keys else None
            if not key or key in merged:
                continue
            merged[key] = blank_studio(detail["name"])
            merged[key]["region"] = "china"
            added += 1
        target = merged[key]
        for candidate_key in keys:
            name_keys.setdefault(candidate_key, key)
        for candidate in names:
            if candidate and candidate not in target["names"]:
                target["names"].append(candidate)
        if not target.get("region"):
            target["region"] = "china"
        summary = clean_studio_summary(detail.get("summary"), detail.get("source"))
        if target.get("summary") is None and summary:
            target["summary"] = summary
        if detail.get("work_count") is not None and not has_site_stats(detail.get("source")):
            target["work_count"] = max(target.get("work_count") or 0, detail["work_count"])
        if target.get("source_url") is None and detail.get("source_url"):
            target["source_url"] = detail["source_url"]
        target["sources"].add(detail.get("source", "kkkhai 机构"))
    return added


def merge_records(target, other):
    """把 other 的资料并入 target（只补空字段）。"""
    for name in other.get("names", []):
        if name and name not in target["names"]:
            target["names"].append(name)
    for field in ("birth_date", "height", "bust", "waist", "hips", "cup", "summary",
                  "description", "image", "source_url", "name_ja", "name_en", "hobby"):
        if target.get(field) is None and other.get(field) is not None:
            target[field] = other[field]
    if other.get("age") is not None and target.get("age") is None:
        target["age"] = other["age"]
        target["age_asof"] = other.get("age_asof")
    if other.get("work_count") is not None:
        target["work_count"] = max(target.get("work_count") or 0, other["work_count"])
    for tag in other.get("tags", []):
        if tag not in target["tags"]:
            target["tags"].append(tag)
    target["sources"].update(other.get("sources", set()))


def record_score(target):
    fields = ("birth_date", "height", "bust", "waist", "hips", "cup", "summary",
              "description", "image", "source_url", "work_count", "name_ja", "name_en",
              "hobby")
    return (sum(1 for field in fields if target.get(field) is not None)
            + len(target.get("names", [])) + len(target.get("tags", [])))


def consolidate_actresses(merged, name_keys):
    """最后一次按「主名 / 日文名」收敛重复条目。

    合并阶段的资料是分批进来的，晚到的别名会让同一个人先落成两条记录
    （如「希崎洁西卡」和「希崎ジェシカ」）。这里用保守规则再收一次：
    - 只按主名、日文名合并，不按英文名 / 别名合并（别名污染多）；
    - 只认假名名、或 3 字以上汉字名，2 字中文名和纯拉丁名不参与；
    - 地区、生日、日文名有冲突的一律不合并。
    """
    keys = list(merged.keys())
    items = [merged[key] for key in keys]
    primary = normalize_all([record.get("name") or "" for record in items])
    japanese = normalize_all([record.get("name_ja") or "" for record in items])

    parent = list(range(len(items)))

    def find(index):
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    def union(left, right):
        left_root, right_root = find(left), find(right)
        if left_root != right_root:
            parent[right_root] = left_root

    owner = {}
    for index in range(len(items)):
        for key in (primary[index], japanese[index]):
            if not key or key in GENERIC_KEYS:
                continue
            has_kana = bool(re.search(r"[\u3040-\u30ff]", key))
            has_cjk = bool(re.search(r"[\u4e00-\u9fff]", key))
            if not has_kana and not (has_cjk and len(key) >= 3):
                continue
            if key in owner:
                union(owner[key], index)
            else:
                owner[key] = index

    groups: dict[int, list[int]] = {}
    for index in range(len(items)):
        groups.setdefault(find(index), []).append(index)

    report = []
    for members in groups.values():
        if not (2 <= len(members) <= 5):
            continue
        regions = {items[index]["region"] for index in members if items[index].get("region")}
        births = {items[index]["birth_date"] for index in members
                  if items[index].get("birth_date")}
        japans = sorted({japanese[index] for index in members if japanese[index]}, key=len)
        same_japanese = bool(japans) and all(japans[0] in other for other in japans[1:])
        has_kana = any(re.search(r"[\u3040-\u30ff]", value) for value in japans)
        # 同名同姓的日文名基本就是同一个人；只有中文名相同时，生日不一致就不合并。
        conflict = len(regions) > 1 or (len(japans) > 1 and not same_japanese)
        if not conflict and len(births) > 1 and not (same_japanese and has_kana):
            conflict = True
        if conflict:
            report.append({"skipped": [items[index]["name"] for index in members]})
            continue

        survivor = max(members, key=lambda index: record_score(items[index]))
        target = items[survivor]
        for index in members:
            if index == survivor:
                continue
            merge_records(target, items[index])
            dead = keys[index]
            for candidate_key, value in list(name_keys.items()):
                if value == dead:
                    name_keys[candidate_key] = keys[survivor]
            merged.pop(dead, None)
            report.append({"keep": target["name"], "merged": items[index]["name"],
                           "region": target.get("region")})

    if report:
        path = os.path.join(RAW, "merge_report.json")
        json.dump(report, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    merged_count = sum(1 for row in report if "merged" in row)
    print(f"  重复条目收敛 {merged_count} 条（跳过 {len(report) - merged_count} 组冲突）")
    return report


def merge_domestic_variants(merged, name_keys):
    """国内同一人常有多种写法（英文前后缀、结尾重复字母、标题后缀）。

    只在同一地区之间按「变体键」收敛；日本条目仍走 consolidate_actresses。
    变体键至少 3 个字，避免「软软」「喵喵」这类通用昵称把两个人并到一起。
    """
    keys = [key for key, target in merged.items()
            if target.get("region") in DOMESTIC_REGIONS]
    if not keys:
        return

    groups: dict[str, set[str]] = {}
    for key in keys:
        target = merged[key]
        variants = set()
        for index, name in enumerate([target["name"], *target.get("names", [])]):
            if not name:
                continue
            # 2 字以内的别名太通用（「果儿」「学妹」），不参与归并。
            if index > 0 and len(name) < 3:
                continue
            cleaned = clean_domestic_name(name) or name
            base = merge_key(cleaned.translate(JP_VARIANTS))
            if len(base) < 3:
                continue
            variants.add(base)
            variants |= domestic_variants(base)
        for variant in variants:
            groups.setdefault(variant, set()).add(key)

    parent = {key: key for key in keys}

    def find(key):
        while parent[key] != key:
            parent[key] = parent[parent[key]]
            key = parent[key]
        return key

    def union(left, right):
        left_region = merged[left].get("region")
        right_region = merged[right].get("region")
        # 「中国大陆」常是采集站的默认猜测，可以并进港台条目；港台之间不互并。
        if left_region != right_region and "china" not in (left_region, right_region):
            return
        left, right = find(left), find(right)
        if left != right:
            parent[right] = left

    for members in groups.values():
        if len(members) < 2:
            continue
        regions = {merged[key].get("region") for key in members}
        # 只有两个不同的「非默认地区」（如台湾 + 香港）才判为冲突。
        if len(regions - {"china"}) > 1:
            continue
        ordered = sorted(members)
        for key in ordered[1:]:
            union(ordered[0], key)

    # 「橙子喵」/「橙子喵酱」、「Kitaro」/「Kitaro_绮太郎」这类长短写法。
    # 短名至少 3 个汉字或 4 个字符；后缀只收够具体的写法。
    key_list = list(parent)
    for short in key_list:
        short_cjk = len(re.findall(CJK_CHAR, short))
        if short_cjk < 3 and len(short) < 4:
            continue
        for long_key in key_list:
            if short == long_key or len(short) >= len(long_key):
                continue
            if len(long_key) - len(short) > 5:
                continue
            prefix = long_key.startswith(short)
            suffix = long_key.endswith(short) and (
                short_cjk >= 4
                or (short_cjk == 0 and len(short) >= 5))
            if prefix or suffix:
                union(short, long_key)

    clusters: dict[str, list[str]] = {}
    for key in keys:
        clusters.setdefault(find(key), []).append(key)

    merged_count = 0
    for members in clusters.values():
        if not (2 <= len(members) <= 8):
            continue
        survivor = max(members, key=lambda key: record_score(merged[key]))
        target = merged[survivor]
        # 「中国大陆」只是默认猜测：并进港台条目时以港台为准。
        if target.get("region") == "china":
            specific = next((merged[key]["region"] for key in members
                             if merged[key].get("region") not in (None, "china")), None)
            if specific:
                target["region"] = specific
        for key in members:
            if key == survivor:
                continue
            merge_records(target, merged[key])
            for candidate_key, value in list(name_keys.items()):
                if value == key:
                    name_keys[candidate_key] = survivor
            merged.pop(key, None)
            merged_count += 1
    if merged_count:
        print(f"  国内重名收敛 {merged_count} 条")


def prune_conflicting_aliases(merged):
    """去掉「别人的本名」混进来的别名。

    JavRate 的 alternateName 偶尔会把同一页上另一位演员的名字写进别名
    （深田咏美 → 天衣みつ）。只要该别名是另一条记录的主名、且两边生日不同，
    就认定是串了数据，删掉这条别名。
    """
    owners = {}
    for key, target in merged.items():
        for name in (target.get("name"), target.get("name_ja")):
            if name:
                owners.setdefault(name, []).append((key, target.get("birth_date")))

    removed = 0
    for key, target in merged.items():
        birth = target.get("birth_date")
        if not birth:
            continue
        kept = []
        for name in target.get("names", []):
            clash = any(other_key != key and other_birth and other_birth != birth
                        for other_key, other_birth in owners.get(name, []))
            if clash:
                removed += 1
            else:
                kept.append(name)
        target["names"] = kept
    if removed:
        print(f"  清理串行别名 {removed} 条")


CUP_RE = re.compile(r"^[A-O]$")
JUNK_NAME = re.compile(r"(【[^】]*】|ai女优|ai女優)", re.I)
CODE_NAME = re.compile(r"^[A-Z]{2,6}[-_]?\d{2,5}$")
JUNK_PERSON_NAMES = {"学妹校园寝室丝短袜美脚"}


def sanitize_actress(target):
    """修掉明显不可能的数值，宁缺毋滥。"""
    height = target.get("height")
    if height is not None and not (130 <= height <= 200):
        target["height"] = None
    birth = (target.get("birth_date") or "").strip()
    target["birth_precision"] = None
    if re.fullmatch(r"\d{4}", birth):
        year = int(birth)
        if 1940 <= year <= date.today().year:
            target["birth_date"] = birth
            target["birth_precision"] = "year"
        else:
            target["birth_date"] = None
    elif re.fullmatch(r"\d{4}-\d{2}-\d{2}", birth):
        try:
            parsed = datetime.strptime(birth, "%Y-%m-%d").date()
        except ValueError:
            parsed = None
        if parsed and 1940 <= parsed.year <= date.today().year:
            target["birth_date"] = birth
            target["birth_precision"] = "day"
        else:
            target["birth_date"] = None
    elif birth:
        target["birth_date"] = None
    age = target.get("age")
    if age is not None and not (15 <= age <= 70):
        target["age"] = None
        target["age_asof"] = None
    for field in ("bust", "waist", "hips"):
        value = target.get(field)
        if value is not None and not (40 <= value <= 160):
            target[field] = None
    if target.get("bust") and target.get("waist") and target["bust"] < target["waist"]:
        target["waist"] = None
    cup = target.get("cup")
    if cup and not CUP_RE.fullmatch(cup.strip().upper()):
        target["cup"] = None


def is_junk_person(name: str) -> bool:
    value = (name or "").strip()
    if not value:
        return True
    if JUNK_NAME.search(value) or CODE_NAME.fullmatch(value):
        return True
    if value in JUNK_PERSON_NAMES or value.startswith("#"):
        return True
    # 采集站标签页：「index|某某|人物主名」「跨语言名称识别」都不是人物。
    if "|" in value or value.startswith("index") or value.endswith("识别"):
        return True
    # 「全部作品」「投稿作品」「唐兴作品」这类页面标题不是人物。
    if NAME_TAIL_LIST.search(value):
        return True
    if merge_key(value.translate(JP_VARIANTS)) in GENERIC_KEYS:
        return True
    return False


def clean_domestic_target(key, target, owners):
    """国内条目收尾：名字去标题后缀、别名去通用词、简介只留事实。"""
    base, parenthetical = split_parenthetical(target["name"])
    cleaned = clean_domestic_name(base)
    if cleaned:
        target["name"] = cleaned
    names = []
    extras = [parenthetical] if parenthetical else []
    for name in target.get("names", []):
        base, extra = split_parenthetical(name)
        cleaned = clean_domestic_name(base)
        if cleaned and cleaned not in names:
            names.append(cleaned)
        if extra:
            extras.append(extra)
    for extra in extras:
        alias = clean_alias(extra)
        if alias and alias not in names:
            names.append(alias)
    if target["name"] not in names:
        names.insert(0, target["name"])
    # 2 字以内的别名太通用（「果儿」「学妹」），删掉避免误匹配。
    names = [name for name in names
             if name == target["name"] or (len(name) >= 3 and clean_alias(name))]
    target["names"] = names
    # 主名优先用「中文 + 英文」的完整写法（阿薰kaOri 优于 阿薰），
    # 并避开「雪晴Astra雷电将军」这类作品标题式的长尾。
    display_junk = re.compile(r"(微密圈|平台|资源|图集|写真|合集|系列|作品|角色|公开|代表|跨语言)")
    usable = [name for name in names if not display_junk.search(name)]
    mixed = [name for name in usable
             if re.search(CJK_CHAR, name) and re.search(r"[A-Za-z]", name)]
    cjk_only = [name for name in usable if re.fullmatch(rf"{CJK_CHAR}{{2,}}", name)]
    candidates = mixed + [name for name in cjk_only if name not in mixed]
    if not candidates:
        candidates = usable
    # 「hongkongdoll玩偶姐姐」这类英文前缀 + 已有中文名，展示时用中文名。
    def wrapped_by_latin(name):
        for other in candidates:
            if other == name or not re.fullmatch(rf"{CJK_CHAR}{{2,}}", other):
                continue
            if name.endswith(other) or name.startswith(other):
                extra = name[:-len(other)] if name.endswith(other) else name[len(other):]
                if extra and re.fullmatch(r"[A-Za-z0-9 .'\-]+", extra):
                    return True
        return False

    candidates = [name for name in candidates if not wrapped_by_latin(name)] or candidates
    prefixes = [name for name in candidates
                if any(other != name and len(other) > len(name) and other.startswith(name)
                       for other in candidates)]
    pool = prefixes or candidates
    if pool:
        target["name"] = max(pool,
                             key=lambda name: (sum(1 for char in name if char.isupper()),
                                               len(name)))

    target["summary"] = clean_domestic_summary(target.get("summary"))
    target["description"] = clean_domestic_summary(target.get("description"))
    summary = target.get("summary")
    if not summary:
        return
    # 简介开头的主体名是另一个人 → 串数据，整条简介丢弃。
    head = re.split(r"[，。；：、,.;:！？!?\s]", summary, maxsplit=1)[0]
    own = {merge_key(name.translate(JP_VARIANTS)) for name in names}
    for length in range(3, min(len(head), 12) + 1):
        prefix = merge_key(head[:length].translate(JP_VARIANTS))
        if prefix in own:
            break
        other = owners.get(prefix)
        if other and other != key:
            target["summary"] = None
            return


def finalize_actresses(merged):
    """收尾：国内条目清洗，再剔除 AI 生成 / 番号式条目与不可能的身高、生日、三围。"""
    owners = {}
    for key, target in merged.items():
        for name in [target.get("name"), *target.get("names", [])]:
            if name:
                owners.setdefault(merge_key(name.translate(JP_VARIANTS)), key)

    removed = 0
    for key in list(merged.keys()):
        target = merged[key]
        if is_junk_person(target["name"]):
            name = next((name for name in target.get("names", [])
                         if name and not is_junk_person(name)), None)
            if name:
                target["name"] = name
            else:
                merged.pop(key)
                removed += 1
                continue
        if target.get("region") in DOMESTIC_REGIONS:
            clean_domestic_target(key, target, owners)
        sanitize_actress(target)
    if removed:
        print(f"  剔除无效人物 {removed} 条")


def build_actresses(studio_keys=None):
    studio_keys = studio_keys or set()
    records = []

    # 0) JavBus / JavRate 的「日文名 → 中文译名」对照：先放进来，
    #    后面维基 / javrate / GitHub 索引里的日文名与中文名都会并到同一条记录。
    javbus_map = []
    name_map_path = os.path.join(RAW, "javbus_name_map.json")
    if os.path.exists(name_map_path):
        javbus_map = [row for row in load_json(name_map_path) if row.get("zh")]
        # JavRate 的中文名是繁体，展示时转成简体；繁体写法留作别名。
        simplified = simplify_all([row["zh"] for row in javbus_map])
        for row, display in zip(javbus_map, simplified):
            # Foundation 的繁简转换不认日文新字体（亜 / 桜），补一层异体字表。
            display = display.translate(JP_VARIANTS)
            japanese = clean_person_name(row.get("ja"))
            star_id = row.get("star_id")
            names = [japanese] if japanese else []
            if display != row["zh"]:
                names.append(row["zh"])
            records.append({
                "name": display,
                "names": names,
                "name_ja": japanese,
                "region": "japan",
                "source_url": (f"https://www.javbus.com/star/{star_id}"
                               if star_id else None),
                "sources": {"javbus 译名" if star_id else "javrate 译名"},
            })

    # 1) 中文维基分类的标题：作为名字兜底，缺资料也至少能识别。
    for name in parse_wiki_category():
        if name in BLACKLIST_NAMES or "列表" in name or "一覽" in name or "名录" in name:
            continue
        records.append({"name": name, "region": "japan", "sources": {"中文维基分类"}})

    # 2) Wikidata（有中文维基条目）：出生日期与身高。
    dates_path = os.path.join(RAW, "wikidata_actress_dates.json")
    if os.path.exists(dates_path):
        for row in load_json(dates_path):
            records.append({
                "name": row["title"],
                "region": "japan",
                "birth_date": normalize_birth(row.get("birth")),
                "height": row.get("height"),
                "sources": {"Wikidata"},
            })

    # 3) 韩国 / 台湾 / 香港 / 中国大陆的成人演员。
    for row in parse_wikidata("wikidata_region_actresses.json"):
        names = [row["name"], row["title"], row["zh"], row["ja"], row["en"]]
        records.append({
            "name": row["name"],
            "names": [n for n in names if n],
            "region": row["region"],
            "birth_date": row["birth"],
            "height": row["height"],
            "image": row["image"],
            "description": row["description"],
            "source_url": row["source_url"],
            "sources": {"Wikidata"},
        })

    # 4) javrate 列表：年龄、三围、罩杯、标签、作品数。
    for row in parse_javrate_actors():
        region = region_from_tags(row["tags"]) or "japan"
        records.append({
            "name": row["name"],
            "region": region,
            "age": row["age"],
            "age_asof": BUILD_DATE if row["age"] else None,
            "height": row["height"],
            "bust": row["bust"],
            "waist": row["waist"],
            "hips": row["hips"],
            "cup": row["cup"],
            "work_count": row["works"],
            "tags": row["tags"],
            "source_url": row["url"],
            "sources": {"javrate"},
        })

    # 5) 人工种子（含各地区常被站点写进标题的名字）。
    for region, names in CURATED.items():
        for name in names:
            records.append({"name": name, "region": region, "sources": {"内置词典"}})

    # 6) 五道花坊福利姬 / kkkhai 秀人与模特 / coscd、miaomengshe 的 Coser
    #    / GitHub 日本女优总索引。
    for file in ("fukuri_people.json", "kkkhai_models.json", "kkkhai_tag_people.json",
                 "kkkhai_lianzu_people.json", "coscd_people.json", "coscd_people_extra.json",
                 "mms_people.json", "jav_actress_index.json"):
        path = os.path.join(RAW, file)
        if not os.path.exists(path):
            continue
        for row in load_json(path):
            raw_name = (row.get("name") or "").strip()
            if not raw_name:
                continue
            region = row.get("region", "china")
            name = raw_name
            if region in DOMESTIC_REGIONS:
                name = clean_domestic_name(raw_name)
                if not name:
                    continue
            # 标签分类难免把品牌当成人名：只要同名的机构已经存在，就按机构处理。
            if merge_key(name.translate(JP_VARIANTS)) in studio_keys:
                continue
            if is_junk_person(name):
                continue
            source = row.get("source", "内置资料库")
            # 采集站内的「收录 N 套 / 体积 / 更新至」是站内快照，不作为人物资料。
            site_stats = has_site_stats(source)
            aliases = []
            for alias in row.get("aliases", []):
                if region in DOMESTIC_REGIONS:
                    alias = clean_domestic_name(alias)
                alias = clean_alias(alias)
                if region in DOMESTIC_REGIONS and not domestic_alias_ok(name, alias):
                    continue
                if alias and alias != name and alias not in aliases:
                    aliases.append(alias)
            records.append({
                "name": name,
                "names": aliases,
                "region": region,
                "work_count": None if site_stats else row.get("work_count"),
                "source_url": row.get("source_url"),
                "description": summary_for(row.get("description"), region),
                "summary": summary_for(row.get("summary"), region),
                "tags": row.get("tags", []),
                "sources": {source},
            })

    # 合并：归一化后的名字相同的记录视为同一个人。
    flat_names = []
    for record in records:
        flat_names.append(record["name"])
        flat_names.extend(record.get("names", []))
    normalized = normalize_all(flat_names)

    merged: dict[str, dict] = {}
    name_keys: dict[str, str] = {}
    cursor = 0
    for record in records:
        keys = normalized[cursor: cursor + 1 + len(record.get("names", []))]
        cursor += 1 + len(record.get("names", []))
        key = keys[0]
        target = merged.get(key)
        if target is None:
            # 译名对照可能已经把这个写法挂在另一条记录下（例如日文名先登记、
            # 之后才遇到同一人的中文名），这时直接并进去。
            for candidate_key in keys:
                existing = name_keys.get(candidate_key)
                if existing is not None and existing in merged:
                    key = existing
                    target = merged[key]
                    break
        if target is None:
            target = blank_actress(record["name"])
            merged[key] = target
        for position, candidate_key in enumerate(keys):
            # 2 字以内的别名太通用（「斗鱼」），不当作合并键。
            if position and (len(candidate_key) < 3 or candidate_key in GENERIC_KEYS):
                continue
            name_keys.setdefault(candidate_key, key)
        for candidate in [record["name"], *record.get("names", [])]:
            if candidate and candidate not in target["names"]:
                target["names"].append(candidate)
        if not target.get("region") and record.get("region"):
            target["region"] = record["region"]
        for field in ("birth_date", "height", "bust", "waist", "hips", "cup",
                      "work_count", "image", "source_url", "description", "summary",
                      "name_ja", "name_en"):
            if target.get(field) is None and record.get(field) is not None:
                target[field] = record[field]
        if record.get("age") is not None and target.get("age") is None:
            target["age"] = record["age"]
            target["age_asof"] = record.get("age_asof")
        if record.get("work_count") is not None:
            target["work_count"] = max(target.get("work_count") or 0, record["work_count"])
        if record.get("tags"):
            for tag in record["tags"]:
                if tag not in target["tags"]:
                    target["tags"].append(tag)
        target["sources"].update(record.get("sources", set()))

    # 主名字：优先使用与归一化键一致的写法（通常是简体），
    # 同一组里有多个时选大写字母更多、更完整的写法（雨波_HaneAme 优于雨波haneame）。
    def display_score(name):
        return (sum(1 for char in name if char.isupper()), len(name))

    for key, target in merged.items():
        matches = [candidate for candidate in target["names"]
                   if merge_key(candidate.translate(JP_VARIANTS)) == key]
        if matches:
            target["name"] = max(matches, key=display_score)
        elif target["names"]:
            target["name"] = target["names"][0]
        if not target.get("region"):
            target["region"] = "japan"
        # 日文名 / 英文名从别名里挑：含假名或全拉丁的优先。
        for name in target["names"]:
            japanese = clean_person_name(name)
            if target["name_ja"] is None and japanese and re.search(r"[ぁ-んァ-ヶ]", japanese):
                target["name_ja"] = japanese
            if target["name_en"] is None and re.fullmatch(r"[A-Za-z0-9 .'\-]+", name):
                target["name_en"] = name

    # kkkhai 全站文章整理出的资料：补简介 / 套数 / 别名 / 出处，也补上没收录过的模特。
    # 放在主名字之后，标题里的正规写法（Fish / HaneAme）不会被小写标签名覆盖。
    details_path = os.path.join(RAW, "kkkhai_people_details.json")
    if os.path.exists(details_path):
        added = apply_actress_details(merged, name_keys, load_json(details_path))
        print(f"  kkkhai 人物资料新增 {added} 位")

    # 中文维基摘要：百科式简介 + 生日，优先于第三方站点的简介。
    wiki_bios = wiki_bio_rows()
    if wiki_bios:
        apply_actress_details(merged, name_keys, wiki_bios)
        print(f"  中文维基摘要补全 {len(wiki_bios)} 位")

    # JavRate 演员详情：维基式简介、生日、身高、头像。
    javrate_details = javrate_detail_rows()
    if javrate_details:
        apply_actress_details(merged, name_keys, javrate_details)
        print(f"  javrate 人物资料补全 {len(javrate_details)} 位")

    # JavBus 演员页：补生日 / 身高 / 三围 / 罩杯。
    javbus_details = javbus_detail_rows()
    if javbus_details:
        apply_actress_details(merged, name_keys, javbus_details)
        print(f"  javbus 演员页补全 {len(javbus_details)} 位")

    # JavBus 演员页的日文名 / 头像：只补给已有记录（JavRate 头像优先）。
    star_rows = javbus_star_rows(name_keys)
    if star_rows:
        apply_actress_details(merged, name_keys, star_rows)
        print(f"  javbus 日文名 / 头像候选 {len(star_rows)} 位")

    # 最后再收敛一次：晚到的别名 / 资料会把同一个人拆成两条记录。
    consolidate_actresses(merged, name_keys)
    merge_domestic_variants(merged, name_keys)
    prune_conflicting_aliases(merged)
    finalize_actresses(merged)
    return list(merged.values())


# ---------------------------------------------------------------- 厂牌

def parse_wiki_studios():
    result = {}
    for file in ("wiki_studios_extracts_1.json", "wiki_studios_extracts_2.json"):
        path = os.path.join(RAW, file)
        if not os.path.exists(path):
            continue
        root = load_json(path)
        for page in root.get("query", {}).get("pages", {}).values():
            if page.get("ns") != 0:
                continue
            title = page.get("title", "")
            extract = (page.get("extract") or "").strip()
            if not title or not extract:
                continue
            name = strip_disambiguation(title)
            entry = result.setdefault(name, {"names": [], "summary": None})
            if title not in entry["names"]:
                entry["names"].append(title)
            if not entry["summary"]:
                entry["summary"] = extract
    return result


def classify_studio(name: str) -> str:
    lowered = name.lower()
    if name in TAIWAN_STUDIOS or lowered in {n.lower() for n in TAIWAN_STUDIOS}:
        return "taiwan"
    if name in KOREA_STUDIOS or lowered in {n.lower() for n in KOREA_STUDIOS}:
        return "korea"
    if name in CHINA_STUDIOS or lowered in {n.lower() for n in CHINA_STUDIOS}:
        return "china"
    if name in WESTERN_STUDIOS or lowered in {n.lower() for n in WESTERN_STUDIOS}:
        return "western"
    return "japan"


STUDIO_TEMPLATE_SUMMARY = re.compile(
    r"^(华语|華語|韩国|韓國|台湾|台灣|日本|欧美|歐美|香港|澳門|澳门|大陆|中國|中国)[^。]{0,12}机构。?$")
STUDIO_SUMMARY_NOISE = (
    "本站", "点评", "合集", "流出", "资源", "整理", "收藏", "收集", "拿到", "发出来",
    "更新", "这几期", "作品不多", "作品也", "作品还", "作品少", "很普通", "不介绍",
    "颜值", "身材", "妹子", "漂亮", "好看", "诱惑", "高清", "原片", "特别版",
    "原班人马", "替代品", "估且看之", "完全可以当成", "风格也是", "作品看基本",
)
STUDIO_JUNK_NAME = re.compile(
    r"(带视频|大小\s*[\d.]+|，|,|\d+\s*[GMT]B|全套|打包|合集)")
STUDIO_NAME_SUFFIX = re.compile(r"\s*(?:高清视频|视频|高清|模特)$")
STUDIO_DISPLAY_PENALTY = re.compile(r"(钻石版|钻石|系列|全套|高清|版)$")


def clean_studio_name(value):
    """去掉「视频」这类后缀，并拦下资源包标题。"""
    name = (value or "").strip()
    if not name or len(name) > 24 or name in JUNK_STUDIOS:
        return None
    if STUDIO_JUNK_NAME.search(name):
        return None
    name = STUDIO_NAME_SUFFIX.sub("", name).strip()
    return name or None


def split_studio_names(value):
    """「TGOD推女神/QingDouKe青豆客」「SeeShe[韩]」拆成主名 + 别名 / 地区。"""
    region = None
    name = (value or "").strip()
    bracket = re.search(r"[\[【(（]\s*(韩|韓|日|台|港|中|美)\s*[\]】)）]$", name)
    if bracket:
        region = {"韩": "korea", "韓": "korea", "日": "japan", "台": "taiwan",
                  "港": "hongkong", "中": "china", "美": "western"}[bracket.group(1)]
        name = name[:bracket.start()].strip()
    aliases = []
    parenthetical = re.match(r"^(.*?)[（(]([^（）()]{1,20})[）)]$", name)
    if parenthetical:
        name = parenthetical.group(1).strip()
        alias = re.sub(r"^原", "", parenthetical.group(2).strip())
        if alias:
            aliases.append(alias)
    parts = [part.strip() for part in re.split(r"[/／]", name) if part.strip()]
    if parts:
        name = parts[0]
        aliases.extend(parts[1:])
    return name, aliases, region


def clean_studio_summary(value, source=None):
    """采集站的模板简介与主观点评都不算简介。"""
    if source and "kkkhai" in source.lower():
        return None
    text = clean_site_summary(value)
    if not text:
        return None
    if STUDIO_TEMPLATE_SUMMARY.fullmatch(text):
        return None
    if any(token in text for token in STUDIO_SUMMARY_NOISE):
        return None
    return text


# 「素人」「人妻」这类通用词不能当成厂牌缩写，否则会把不同系列并成一家。
STUDIO_GENERIC_WORDS = {
    "素人", "素人娘", "人妻", "人妻素人", "痴汉", "痴女", "熟女", "美少女",
    "女优", "女優", "单体", "企划",
}


def studio_variants(key):
    variants = {key}
    # 厂牌后缀的英文写法可以更短（「盘丝PANS」→「盘丝」），2 个字也收。
    stripped = re.sub(rf"(?<={CJK_CHAR})[a-z]{{1,10}}$", "", key)
    if len(stripped) >= 2 and stripped != key and stripped not in STUDIO_GENERIC_WORDS:
        variants.add(stripped)
    stripped = re.sub(r"(?:视频|高清)$", "", key)
    if stripped != key and len(stripped) >= 2:
        variants.add(stripped)
    variants |= {variant for variant in domestic_variants(key) if len(variant) >= 2}
    return variants


def studio_kind(studio):
    """按数据来源区分厂牌类型：片商 / 写真机构 / 平台。"""
    if studio.get("name") in PLATFORM_STUDIOS:
        return "platform"
    sources = " ".join(studio.get("sources", []))
    if "javrate" in sources or "中文维基" in sources:
        return "studio"
    if "kkkhai" in sources:
        return "photo"
    if studio.get("work_count"):
        return "studio"
    return "studio"


def studio_website(name):
    """头部厂牌的官方站：大小写 / 空格不同也能对上。"""
    if name in STUDIO_WEBSITES:
        return STUDIO_WEBSITES[name]
    key = merge_key(name.translate(JP_VARIANTS))
    for candidate, url in STUDIO_WEBSITES.items():
        if merge_key(candidate.translate(JP_VARIANTS)) == key:
            return url
    return None


def merge_studio_variants(studios):
    """把同一厂牌的多种写法并成一条，并挑一个干净的展示名。"""
    index: dict[str, set[int]] = {}
    # 前后缀合并只从「主名」派生，避免 2 字别名（「麻豆」「尤蜜」）把子品牌吞进来。
    primary_keys: set[str] = set()
    for position, studio in enumerate(studios):
        for order, name in enumerate([studio["name"], *studio.get("names", [])]):
            cleaned = clean_studio_name(name)
            if not cleaned:
                continue
            base = merge_key(cleaned.translate(JP_VARIANTS))
            if len(base) < 2:
                continue
            for variant in studio_variants(base):
                if len(variant) >= 2:
                    index.setdefault(variant, set()).add(position)
                    if order == 0:
                        primary_keys.add(variant)

    parent = list(range(len(studios)))

    def find(value):
        while parent[value] != value:
            parent[value] = parent[parent[value]]
            value = parent[value]
        return value

    def union(left, right):
        left, right = find(left), find(right)
        if left != right:
            parent[right] = left

    for members in index.values():
        if len(members) > 1:
            ordered = sorted(members)
            for value in ordered[1:]:
                union(ordered[0], value)

    # 「盘丝」/「盘丝洞」这类前后缀差异：短的至少要 2 个汉字或 4 个字符。
    specific = [key for key in primary_keys
                if (len(re.findall(CJK_CHAR, key)) >= 2 or len(key) >= 4)
                and key not in STUDIO_GENERIC_WORDS]
    for short in specific:
        for long_key in specific:
            if short == long_key or len(short) >= len(long_key):
                continue
            if len(long_key) - len(short) > 4:
                continue
            prefix = long_key.startswith(short)
            # 后缀只收 3 字以上的，避免「蜜丝」并到「尤蜜丝」。
            suffix = (long_key.endswith(short)
                      and len(re.findall(CJK_CHAR, short)) >= 3)
            if not (prefix or suffix):
                continue
            for left in index[short]:
                for right in index[long_key]:
                    union(left, right)

    clusters: dict[int, list[int]] = {}
    for position in range(len(studios)):
        clusters.setdefault(find(position), []).append(position)

    result = []
    for members in clusters.values():
        survivor = max(
            members,
            key=lambda pos: (
                studios[pos].get("work_count") or 0,
                len(studios[pos].get("names", [])),
                1 if studios[pos].get("summary") else 0,
            ))
        target = studios[survivor]
        for position in members:
            if position == survivor:
                continue
            other = studios[position]
            for name in [other["name"], *other.get("names", [])]:
                if name and name not in target["names"]:
                    target["names"].append(name)
            if target.get("region") == "china" and other.get("region") not in (None, "china"):
                target["region"] = other["region"]
            for field in ("work_count", "summary", "source_url", "website"):
                if target.get(field) is None and other.get(field) is not None:
                    target[field] = other[field]
            if other.get("work_count") is not None:
                target["work_count"] = max(target.get("work_count") or 0, other["work_count"])
            target["sources"].update(other.get("sources", set()))
        result.append(target)

    for studio in result:
        names = []
        for name in [studio["name"], *studio.get("names", [])]:
            cleaned = clean_studio_name(name)
            if cleaned and cleaned not in names:
                names.append(cleaned)
        if not names:
            continue
        canonical = [name for name in names if name in STUDIO_ALIASES]
        usable = [name for name in names if not STUDIO_DISPLAY_PENALTY.search(name)]
        pool = usable or names
        if canonical:
            display = max(canonical, key=len)
        else:
            mixed = [name for name in pool
                     if re.search(CJK_CHAR, name) and re.search(r"[A-Za-z]", name)]
            candidates = mixed or pool
            # 大写字母越多越接近官方写法（AISS爱丝 优于 aiss爱丝）。
            display = max(candidates,
                          key=lambda name: (sum(1 for char in name if char.isupper()), len(name)))
        studio["name"] = display
        studio["names"] = [display, *[name for name in names if name != display]]

    # 国内厂牌统一简体展示；一次批量转换，并保留英文大小写。
    domestic = [index for index, studio in enumerate(result)
                if studio.get("region") in DOMESTIC_REGIONS and studio.get("name")]
    if domestic:
        originals = [result[index]["name"] for index in domestic]
        simplified = simplify_all(originals)
        for index, original, converted in zip(domestic, originals, simplified):
            converted = converted.translate(JP_VARIANTS)
            if len(converted) == len(original):
                converted = "".join(
                    before if before.isascii() else after
                    for before, after in zip(original, converted))
            if not converted:
                continue
            result[index]["names"] = [converted, *[name for name in result[index]["names"]
                                                   if name != original]]
            result[index]["name"] = converted
    for studio in result:
        studio["kind"] = studio_kind(studio)
        if not studio.get("website"):
            studio["website"] = studio_website(studio["name"])
    return [studio for studio in result if studio.get("name")]


def build_studios():
    records = []

    # 先登记标准写法与别名，后面的记录遇到别名会并进来。
    for name, aliases in STUDIO_ALIASES.items():
        records.append({
            "name": name,
            "names": aliases,
            "region": classify_studio(name),
            "summary": studio_summary(name),
            "sources": {"内置词典"},
        })

    for name, entry in parse_wiki_studios().items():
        cleaned = clean_studio_name(name)
        if not cleaned:
            continue
        records.append({
            "name": cleaned,
            "names": [alias for alias in entry["names"] if alias != name],
            "summary": entry["summary"],
            "region": "japan",
            "sources": {"中文维基"},
        })

    for line in open(os.path.join(RAW, "javrate_issuers.tsv"), encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if not parts or not parts[0].strip():
            continue
        name, aliases, region = split_studio_names(parts[0].strip())
        name = clean_studio_name(name)
        if not name:
            continue
        try:
            works = int(parts[1]) if len(parts) > 1 else None
        except ValueError:
            works = None
        records.append({
            "name": name,
            "names": aliases,
            "region": region or classify_studio(name),
            "work_count": works,
            "summary": studio_summary(name),
            "sources": {"javrate"},
        })

    legacy = [
        "S1", "MOODYZ", "IDEA POCKET", "PRESTIGE", "Madonna", "FALENO", "Fitch",
        "本中", "Attackers", "MUTEKI", "E-Body", "Wanz Factory", "SOD", "S-Cute",
        "Max-A", "KMP", "溜池ゴロー", "マドンナ",
        "麻豆传媒", "果冻传媒", "天美传媒", "星空传媒", "精东影业", "蜜桃传媒",
        "大象传媒", "乌鸦传媒", "皇家华人", "糖心Vlog", "91制片厂", "蜜桃影像",
        "兔子先生", "扣扣传媒", "麻豆映画", "SWAG", "JVID", "91CM",
        "Vixen", "Blacked", "Tushy", "Brazzers", "Reality Kings", "Naughty America",
        "Mofos", "TeamSkeet", "Digital Playground", "Pure Taboo", "Girlsway",
        "Evil Angel", "Private", "X-Art", "Jules Jordan",
    ]
    for name in legacy:
        records.append({"name": name, "region": classify_studio(name),
                        "summary": studio_summary(name),
                        "sources": {"内置词典"}})

    # 名站机构 / 秀人系机构（来自 kkkhai 导航与标签）。
    for file in ("kkkhai_studios.json", "kkkhai_tag_studios.json", "kkkhai_brand_studios.json"):
        extra_path = os.path.join(RAW, file)
        if not os.path.exists(extra_path):
            continue
        for row in load_json(extra_path):
            raw_name = (row.get("name") or "").strip()
            if not raw_name:
                continue
            name, aliases, region = split_studio_names(raw_name)
            name = clean_studio_name(name)
            if not name:
                continue
            records.append({
                "name": name,
                "names": [alias for alias in [*row.get("aliases", []), *aliases]
                          if clean_studio_name(alias)],
                "region": region or row.get("region", "china"),
                "summary": clean_studio_summary(row.get("summary"), row.get("source")),
                "sources": {row.get("source", "kkkhai")},
            })

    flat = []
    for record in records:
        flat.append(record["name"])
        flat.extend(record.get("names", []))
    normalized = normalize_all(flat)

    merged: dict[str, dict] = {}
    name_keys: dict[str, str] = {}
    cursor = 0
    for record in records:
        keys = normalized[cursor: cursor + 1 + len(record.get("names", []))]
        cursor += 1 + len(record.get("names", []))
        key = keys[0]
        target = merged.get(key)
        if target is None:
            for candidate_key in keys:
                existing = name_keys.get(candidate_key)
                if existing is not None and existing in merged:
                    key = existing
                    target = merged[key]
                    break
        if target is None:
            target = blank_studio(record["name"])
            merged[key] = target
        for candidate_key in keys:
            name_keys.setdefault(candidate_key, key)
        for candidate in [record["name"], *record.get("names", [])]:
            if candidate and candidate not in target["names"]:
                target["names"].append(candidate)
        if not target.get("region") and record.get("region"):
            target["region"] = record["region"]
        elif target.get("region") == "china" and record.get("region") not in (None, "china"):
            target["region"] = record["region"]
        for field in ("work_count", "summary", "source_url", "website"):
            if target.get(field) is None and record.get(field) is not None:
                target[field] = record[field]
        if record.get("work_count") is not None:
            target["work_count"] = max(target.get("work_count") or 0, record["work_count"])
        target["sources"].update(record.get("sources", set()))

    # kkkhai 文章里的机构期数 / 简介。
    details_path = os.path.join(RAW, "kkkhai_studio_details.json")
    if os.path.exists(details_path):
        added = apply_studio_details(merged, name_keys, load_json(details_path))
        print(f"  kkkhai 机构资料新增 {added} 个")
    return merge_studio_variants(list(merged.values()))


# ---------------------------------------------------------------- 头像

AVATARS: dict[str, str] = {}
STUDIO_AVATAR_CACHE: dict[str, str | None] = {}
STUDIO_FONTS = ("/System/Library/Fonts/PingFang.ttc",
                "/System/Library/Fonts/Hiragino Sans GB.ttc",
                "/System/Library/Fonts/STHeiti Medium.ttc")


def load_avatars():
    """raw/avatar_images.json：{image_url: base64}，由 fetch_avatars.py 生成。"""
    global AVATARS
    path = os.path.join(RAW, "avatar_images.json")
    AVATARS = load_json(path) if os.path.exists(path) else {}
    valid = sum(1 for value in AVATARS.values() if value)
    if valid:
        print(f"  头像 base64 {valid} 张")


def studio_initials(name: str) -> str:
    latin = re.findall(r"[A-Za-z0-9]+", name)
    if latin and not re.search(r"[\u4e00-\u9fff\u3040-\u30ff]", name):
        if len(latin) >= 2:
            return (latin[0][0] + latin[1][0]).upper()
        word = latin[0]
        return (word[:2] if len(word) <= 3 else word[0]).upper()
    cjk = re.findall(r"[\u4e00-\u9fff\u3040-\u30ff]", name)
    return "".join(cjk[:2]) or name[:2]


def studio_avatar(name: str) -> str | None:
    """厂牌没有公开 logo，生成一张品牌字母头像（同名字永远同色）。"""
    if Image is None:
        return None
    if name in STUDIO_AVATAR_CACHE:
        return STUDIO_AVATAR_CACHE[name]
    seed = int(hashlib.md5(name.encode("utf-8")).hexdigest()[:8], 16)
    hue = (seed % 360) / 360
    top = tuple(int(channel * 255) for channel in colorsys.hsv_to_rgb(hue, 0.52, 0.90))
    bottom = tuple(int(channel * 255)
                   for channel in colorsys.hsv_to_rgb((hue + 0.04) % 1, 0.70, 0.62))
    image = Image.new("RGB", (96, 96))
    draw = ImageDraw.Draw(image)
    for y in range(96):
        ratio = y / 95
        draw.line([(0, y), (96, y)],
                  fill=tuple(int(top[i] + (bottom[i] - top[i]) * ratio) for i in range(3)))
    text = studio_initials(name)
    font = None
    for path in STUDIO_FONTS:
        if os.path.exists(path):
            try:
                font = ImageFont.truetype(path, 44 if len(text) > 1 else 52)
                break
            except OSError:
                continue
    if font is None:
        font = ImageFont.load_default()
    box = draw.textbbox((0, 0), text, font=font)
    draw.text(((96 - (box[2] - box[0])) / 2 - box[0],
               (96 - (box[3] - box[1])) / 2 - box[1]),
              text, font=font, fill=(255, 255, 255))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    data = base64.b64encode(buffer.getvalue()).decode("ascii")
    STUDIO_AVATAR_CACHE[name] = data
    return data


# ---------------------------------------------------------------- 国内作品与标签

# 采集站的泛化标签不是资料，丢；角色/IP/服装/主题标签才是可用的丰富度。
COS_GENERIC_TAGS = {
    "coser", "cosplay", "cos作品", "cos图包", "cos图集", "cos", "cos写真",
    "美图欣赏", "图集", "写真", "网红", "美女", "福利", "资源", "合集",
}
COS_TAG_BLOCK = ("私拍", "内购", "全集", "合集", "视频", "资源", "套图",
                 "无码", "流出", "付费", "众筹", "更新", "新发")


def _record_name_keys(record):
    keys = set()
    for name in [record.get("name"), *record.get("names", [])]:
        if name:
            key = merge_key(name.translate(JP_VARIANTS))
            if key:
                keys.add(key)
    return keys


def _clean_post_title(value):
    title = html.unescape((value or "").strip())
    if not title:
        return None
    title = title.replace("［", "[").replace("］", "]")
    # 标题里的体积 / 期数 / 更新日期是采集站的瞬时信息，不进作品标题。
    title = re.sub(r"\[[^\]]*(?:\d+(?:\.\d+)?\s*G|期|套|更新|新发)[^\]]*\]?", "", title)
    title = re.sub(r"\[[^\]]*(?:\d+\s*[Pp]|MB|GB|订阅|Partme)[^\]]*\]?",
                   "", title, flags=re.IGNORECASE)
    title = re.sub(r"\[[^\]]*(?:Fantia|Patreon|Partme|Perohub)[^\]]*\]?",
                   "", title, flags=re.IGNORECASE)
    title = re.sub(r"[（(][^）)]*(?:\d+(?:\.\d+)?\s*G|期|套|更新)[^）)]*[）)]", "", title)
    title = re.sub(r"\s*\b(?:Fantia|Patreon|Partme|Perohub)\b.*$", "", title,
                   flags=re.IGNORECASE)
    title = re.sub(r"\s*(?:会员)?订阅(?:合集)?\s*(?:[-–—]\s*)?(?:cos)?作品及?个人资料介绍.*$",
                   "", title, flags=re.IGNORECASE)
    title = re.sub(r"\s*(?:会员)?订阅合集.*$", "", title, flags=re.IGNORECASE)
    title = re.sub(r"\s*[-–—]?\s*(?:cos)?作品及?个人资料介绍.*$", "", title,
                   flags=re.IGNORECASE)
    title = re.sub(r"\s*[-–—]?\s*微密圈.*$", "", title)
    title = re.sub(r"\s*[-–—]?\s*(?:vip)?收费.*$", "", title, flags=re.IGNORECASE)
    title = re.sub(r"\s*\d{4}\s*年\s*\d{1,2}\s*月\s*(?:订阅|新作|更新).*$", "", title)
    title = re.sub(r"\s*[–-]\s*(?:全套|内购|私拍|合集).*$", "", title)
    title = re.sub(r"^\s*\[[^\]]{1,10}\]\s*", "", title)
    title = re.sub(r"\[[^\]]*$", "", title)
    title = re.sub(r"\[[^\]]*\]", "", title)
    title = re.sub(r"[\s\[\]（）()]+$", "", title)
    title = re.sub(r"\s+", " ", title)
    title = title.strip(" -–—")
    if not title or any(word in title for word in ("个人资料介绍", "会员订阅", "订阅合集", "微密圈")):
        return None
    return title


def enrich_domestic_posts(actresses):
    """把 coscd / kkkhai 的文章变成人物作品链接与角色/IP 标签。

    只动国内条目：现有 raw 里的这两个站都是华语 Coser / 写真。
    返回 (作品链接行, 新增标签数)；标签在写库前合并，链接写库后按名字解析成 id。
    """
    by_name: dict[str, dict] = {}
    for record in actresses:
        if record.get("region") not in DOMESTIC_REGIONS:
            continue
        for name in [record.get("name"), *record.get("names", [])]:
            if not name:
                continue
            key = merge_key(name.translate(JP_VARIANTS))
            if key:
                by_name.setdefault(key, record)
    all_person_keys = set()
    for record in actresses:
        all_person_keys |= _record_name_keys(record)

    def find_record(raw_name):
        for candidate in (raw_name, clean_domestic_name(raw_name or "")):
            if not candidate:
                continue
            key = merge_key(candidate.translate(JP_VARIANTS))
            record = by_name.get(key)
            if record:
                return record
        return None

    links: list[dict] = []
    added_tags = 0

    # 1) coscd：作品页链接 + 作品标签（碧蓝航线 / 原神 / 2B / 女仆…）。
    people_path = os.path.join(RAW, "coscd_people.json")
    posts_path = os.path.join(RAW, "coscd_posts.json")
    tags_path = os.path.join(RAW, "coscd_tags.json")
    if (os.path.exists(people_path) and os.path.exists(posts_path)
            and os.path.exists(tags_path)):
        tag_names = {tag["id"]: tag.get("name") for tag in load_json(tags_path)}
        posts = load_json(posts_path)
        post_by_link = {post.get("link"): post for post in posts if post.get("link")}
        for person in load_json(people_path):
            record = find_record(person.get("name") or "")
            if not record:
                continue
            own_keys = _record_name_keys(record)
            tag_counts = Counter()
            for url in person.get("links") or []:
                if not url:
                    continue
                post = post_by_link.get(url)
                links.append({
                    "name": record["name"],
                    "region": record.get("region"),
                    "source": "coscd",
                    "kind": "work",
                    "url": url,
                    "title": _clean_post_title((post or {}).get("title")),
                    "published_at": None,
                })
                for tag_id in (post or {}).get("tags") or []:
                    tag = tag_names.get(tag_id)
                    if tag:
                        tag_counts[tag] += 1
            picked = 0
            for tag, _count in tag_counts.most_common():
                if picked >= 8:
                    break
                text = (tag or "").strip()
                if len(text) < 2 or len(text) > 24:
                    continue
                if text.casefold() in COS_GENERIC_TAGS:
                    continue
                if any(block in text for block in COS_TAG_BLOCK):
                    continue
                key = merge_key(text.translate(JP_VARIANTS))
                if not key or key in all_person_keys:
                    continue
                # 「蠢沫沫cos」这类是本人名字的变体，不是角色标签。
                if any(key.startswith(own) or own.startswith(key)
                       for own in own_keys if len(own) >= 2):
                    continue
                if text in record.get("tags", []):
                    continue
                record.setdefault("tags", []).append(text)
                added_tags += 1
                picked += 1

    # 2) kkkhai：文章标题/日期作为作品链接（人物由文章 tag 定位）。
    tags_full_path = os.path.join(RAW, "kkkhai_tags_full.json")
    posts_full_path = os.path.join(RAW, "kkkhai_posts_full.json")
    if os.path.exists(tags_full_path) and os.path.exists(posts_full_path):
        tag_names = {tag["id"]: tag.get("name") for tag in load_json(tags_full_path)}
        for post in load_json(posts_full_path):
            matched = None
            for tag_id in post.get("tags") or []:
                name = tag_names.get(tag_id)
                if name:
                    matched = find_record(name)
                    if matched:
                        break
            if not matched:
                continue
            url = post.get("link")
            if not url:
                continue
            published = (post.get("date") or "")[:10]
            links.append({
                "name": matched["name"],
                "region": matched.get("region"),
                "source": "kkkhai",
                "kind": "work",
                "url": url,
                "title": _clean_post_title(post.get("title")),
                "published_at": published if re.fullmatch(r"\d{4}-\d{2}-\d{2}", published) else None,
            })

    # 去重：同一人物同一来源同一 URL 只留一条。
    seen = set()
    unique = []
    for row in links:
        key = (row["name"], row["region"], row["source"], row["url"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(row)
    return unique, added_tags


# ---------------------------------------------------------------- 写库

SCHEMA = """
PRAGMA user_version = 3;
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE actresses (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    name_ja TEXT,
    name_en TEXT,
    aliases TEXT NOT NULL DEFAULT '[]',
    region TEXT NOT NULL DEFAULT 'japan',
    birth_date TEXT,
    birth_precision TEXT,
    age INTEGER,
    age_asof TEXT,
    height_cm INTEGER,
    bust INTEGER,
    waist INTEGER,
    hips INTEGER,
    cup TEXT,
    hobby TEXT,
    ruby TEXT,
    birthplace TEXT,
    blood_type TEXT,
    debut_year INTEGER,
    agency TEXT,
    status TEXT,
    official_site TEXT,
    work_count INTEGER,
    tags TEXT NOT NULL DEFAULT '[]',
    summary TEXT,
    description TEXT,
    image_url TEXT,
    avatar_base64 TEXT,
    source_url TEXT,
    source TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL
);
CREATE INDEX idx_actresses_name ON actresses(name);
CREATE INDEX idx_actresses_region ON actresses(region);
CREATE TABLE studios (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    name_en TEXT,
    aliases TEXT NOT NULL DEFAULT '[]',
    region TEXT NOT NULL DEFAULT 'japan',
    kind TEXT,
    founded_year INTEGER,
    parent_name TEXT,
    status TEXT,
    work_count INTEGER,
    summary TEXT,
    logo_url TEXT,
    avatar_base64 TEXT,
    website TEXT,
    source_url TEXT,
    source TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL
);
CREATE INDEX idx_studios_name ON studios(name);
CREATE INDEX idx_studios_region ON studios(region);
CREATE TABLE code_makers (
    prefix TEXT PRIMARY KEY,
    studio_name TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT ''
);

-- 跨站 ID：去重、增量更新、避免继续靠名字模糊匹配。
CREATE TABLE external_ids (
    entity_type TEXT NOT NULL,
    entity_id INTEGER NOT NULL,
    source TEXT NOT NULL,
    external_id TEXT NOT NULL,
    url TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (entity_type, entity_id, source)
);
CREATE INDEX idx_external_lookup ON external_ids(source, external_id);

-- 人物主页 / 作品 / 社交链接。
CREATE TABLE person_links (
    id INTEGER PRIMARY KEY,
    actress_id INTEGER NOT NULL,
    source TEXT NOT NULL,
    kind TEXT NOT NULL,
    url TEXT NOT NULL,
    title TEXT,
    published_at TEXT,
    UNIQUE (actress_id, source, url)
);
CREATE INDEX idx_person_links_actress ON person_links(actress_id);

-- 人物与机构（事务所 / 写真机构 / 专属厂牌）的关系。
CREATE TABLE person_studios (
    actress_id INTEGER NOT NULL,
    studio_id INTEGER NOT NULL,
    kind TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (actress_id, studio_id, kind)
);

-- 作品底座：等 R18 / DMM / JavBus 数据导入后直接填。
CREATE TABLE works (
    id INTEGER PRIMARY KEY,
    content_id TEXT,
    dvd_id TEXT,
    code TEXT,
    kind TEXT,
    title_ja TEXT,
    title_zh TEXT,
    title_en TEXT,
    release_date TEXT,
    runtime_min INTEGER,
    director TEXT,
    studio_id INTEGER,
    label TEXT,
    series TEXT,
    genres TEXT NOT NULL DEFAULT '[]',
    cover_url TEXT,
    sample_urls TEXT NOT NULL DEFAULT '[]',
    trailer_url TEXT,
    source_url TEXT UNIQUE,
    rating REAL,
    popularity INTEGER,
    source TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL
);
CREATE INDEX idx_works_code ON works(code);
CREATE INDEX idx_works_release ON works(release_date);
CREATE TABLE work_actresses (
    work_id INTEGER NOT NULL,
    actress_id INTEGER NOT NULL,
    PRIMARY KEY (work_id, actress_id)
);
"""


def write_enrichment(connection, link_rows):
    """写库后：按名字解析 id，落人物作品链接、主页链接与跨站 ID。"""
    rows = connection.execute("SELECT id, name, region, aliases FROM actresses").fetchall()
    name_ids: dict[str, set[tuple[int, str]]] = {}
    for rid, name, region, aliases_json in rows:
        names = [name]
        try:
            names.extend(json.loads(aliases_json or "[]"))
        except (ValueError, TypeError):
            pass
        for candidate in names:
            key = merge_key((candidate or "").translate(JP_VARIANTS))
            if key:
                name_ids.setdefault(key, set()).add((rid, region or "japan"))

    def resolve(name, region=None):
        key = merge_key((name or "").translate(JP_VARIANTS))
        ids = set(name_ids.get(key) or ())
        if region:
            filtered = {item for item in ids if item[1] == region}
            if filtered:
                ids = filtered
        if len(ids) == 1:
            return next(iter(ids))[0]
        return None

    added_links = 0
    added_ids = 0
    added_works = 0

    def add_link(rid, source, kind, url, title=None, published=None):
        nonlocal added_links
        if not rid or not url:
            return
        cursor = connection.execute(
            """INSERT OR IGNORE INTO person_links
               (actress_id, source, kind, url, title, published_at)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (rid, source, kind, url, title, published))
        if cursor.rowcount:
            added_links += 1

    def add_external(rid, source, external_id, url=None):
        nonlocal added_ids
        if not rid or not external_id:
            return
        cursor = connection.execute(
            """INSERT OR IGNORE INTO external_ids
               (entity_type, entity_id, source, external_id, url, updated_at)
               VALUES ('person', ?, ?, ?, ?, ?)""",
            (rid, source, str(external_id), url, BUILD_DATE))
        if cursor.rowcount:
            added_ids += 1

    # 1) 本轮从 coscd / kkkhai 文章整理出的作品链接。
    for row in link_rows:
        rid = resolve(row.get("name"), row.get("region"))
        add_link(rid, row.get("source") or "unknown", row.get("kind") or "work",
                 row.get("url"), row.get("title"), row.get("published_at"))
        # 国内套图/写真也进 works 底座：没有番号，但有标题、来源和人物关系。
        if rid and row.get("kind") == "work" and row.get("url") and row.get("title"):
            source = row.get("source") or "unknown"
            cursor = connection.execute(
                """INSERT OR IGNORE INTO works
                   (kind, title_zh, release_date, source, source_url, updated_at)
                   VALUES ('photo', ?, ?, ?, ?, ?)""",
                (row.get("title"), row.get("published_at"), source,
                 row.get("url"), BUILD_DATE))
            if cursor.rowcount:
                added_works += 1
                work_id = cursor.lastrowid
            else:
                found = connection.execute(
                    "SELECT id FROM works WHERE source_url = ?", (row.get("url"),)).fetchone()
                work_id = found[0] if found else None
            if work_id:
                connection.execute(
                    "INSERT OR IGNORE INTO work_actresses (work_id, actress_id) VALUES (?, ?)",
                    (work_id, rid))

    # 2) JavBus：star_id 同时作为跨站 ID 与演员页链接。
    stars_map_path = os.path.join(RAW, "javbus_name_map.json")
    stars_zh_path = os.path.join(RAW, "javbus_stars_zh.json")
    star_names: dict[str, set[str]] = {}
    if os.path.exists(stars_map_path):
        for entry in load_json(stars_map_path):
            star_id = entry.get("star_id")
            if not star_id:
                continue
            bucket = star_names.setdefault(star_id, set())
            for name in (entry.get("zh"), entry.get("ja")):
                if name:
                    bucket.add(name)
    if os.path.exists(stars_zh_path):
        for star_id, name in load_json(stars_zh_path).items():
            if name:
                star_names.setdefault(star_id, set()).add(name)
    for star_id, names in star_names.items():
        ids = {rid for rid in (resolve(name) for name in names) if rid}
        if len(ids) != 1:
            continue
        rid = ids.pop()
        url = f"https://www.javbus.com/star/{star_id}"
        add_external(rid, "javbus", star_id, url)
        add_link(rid, "javbus", "profile", url, "JavBus 演员页")

    # 3) JavRate：详情页 uuid + 主页链接。
    actors_path = os.path.join(RAW, "javrate_actors_all.json")
    if os.path.exists(actors_path):
        for row in load_json(actors_path):
            name = row.get("name")
            url = row.get("url")
            rid = resolve(name)
            if not rid or not url:
                continue
            match = re.search(r"/detail/([0-9a-fA-F-]{8,})\.html", url)
            if match:
                add_external(rid, "javrate", match.group(1), url)
            add_link(rid, "javrate", "profile", url, "JavRate 演员页")

    # 4) 中文维基：条目名 + 链接。
    bios_path = os.path.join(RAW, "wiki_actress_bios.json")
    if os.path.exists(bios_path):
        for name, info in load_json(bios_path).items():
            url = (info or {}).get("url")
            rid = resolve(name)
            if not rid or not url:
                continue
            add_external(rid, "zhwiki", name, url)
            add_link(rid, "zhwiki", "profile", url, info.get("ja") or name)

    return added_links, added_ids, added_works


def write_database(actresses, studios, link_rows, coser_tag_count):
    os.makedirs(OUT_DIR, exist_ok=True)
    load_avatars()
    if os.path.exists(OUT):
        os.remove(OUT)
    connection = sqlite3.connect(OUT)
    connection.executescript(SCHEMA)
    connection.executemany(
        """INSERT INTO actresses
           (name, name_ja, name_en, aliases, region, birth_date, birth_precision,
            age, age_asof, height_cm, bust, waist, hips, cup, hobby, ruby,
            birthplace, blood_type, debut_year, agency, status, official_site,
            work_count, tags, summary, description, image_url, avatar_base64,
            source_url, source, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        [
            (
                a["name"], a.get("name_ja"), a.get("name_en"),
                json.dumps([n for n in a["names"] if n != a["name"]], ensure_ascii=False),
                a.get("region") or "japan",
                a.get("birth_date"), a.get("birth_precision"),
                a.get("age"), a.get("age_asof"),
                a.get("height"), a.get("bust"), a.get("waist"), a.get("hips"),
                a.get("cup"), a.get("hobby"), a.get("ruby"), a.get("birthplace"),
                a.get("blood_type"), a.get("debut_year"), a.get("agency"),
                a.get("status"), a.get("official_site"),
                a.get("work_count"),
                json.dumps(a.get("tags", []), ensure_ascii=False),
                a.get("summary"), a.get("description"),
                a.get("image"), AVATARS.get(a.get("image") or ""),
                a.get("source_url"),
                "+".join(sorted(a.get("sources", []))), BUILD_DATE,
            )
            for a in actresses
        ],
    )
    connection.executemany(
        """INSERT INTO studios
           (name, name_en, aliases, region, kind, work_count, summary, logo_url,
            avatar_base64, website, source_url, source, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        [
            (
                s["name"],
                s["name"] if s["name"].isascii() else None,
                json.dumps(s["names"][1:], ensure_ascii=False),
                s.get("region") or "japan",
                s.get("kind") or "studio",
                s.get("work_count"), s.get("summary"), None,
                studio_avatar(s["name"]),
                s.get("website"),
                s.get("source_url"),
                "+".join(sorted(s.get("sources", []))), BUILD_DATE,
            )
            for s in studios
        ],
    )
    connection.executemany(
        "INSERT OR REPLACE INTO code_makers (prefix, studio_name, source) VALUES (?, ?, ?)",
        [(prefix, maker, "内置词典") for prefix, maker in CODE_MAKERS.items()],
    )
    link_count, external_count, works_count = write_enrichment(connection, link_rows)
    connection.executemany(
        "INSERT INTO meta (key, value) VALUES (?, ?)",
        [
            ("version", "3"),
            ("built_at", BUILD_DATE),
            ("actress_count", str(len(actresses))),
            ("studio_count", str(len(studios))),
            ("code_maker_count", str(len(CODE_MAKERS))),
            ("hobby_count", str(sum(1 for a in actresses if a.get("hobby")))),
            ("person_link_count", str(link_count)),
            ("external_id_count", str(external_count)),
            ("works_count", str(works_count)),
            ("coser_tag_count", str(coser_tag_count)),
            ("sources", "zh.wikipedia / wikidata / javrate / javbus / kkkhai / coscd"),
        ],
    )
    connection.commit()
    connection.execute("VACUUM")
    connection.close()

    print(f"已生成 {OUT}")
    print(f"女优 {len(actresses)} 位，厂牌 {len(studios)} 个，番号前缀 {len(CODE_MAKERS)} 条")
    print(f"  人物链接 {link_count} 条，跨站 ID {external_count} 条，作品 {works_count} 条，Coser 标签 {coser_tag_count} 条")
    regions = {}
    for a in actresses:
        regions[a.get("region") or "japan"] = regions.get(a.get("region") or "japan", 0) + 1
    print("地区分布：" + "，".join(f"{REGION_TITLES.get(k, k)} {v}" for k, v in sorted(regions.items())))


def main():
    studios = build_studios()
    studio_keys = set()
    for studio in studios:
        for name in [studio["name"], *studio.get("names", [])]:
            if name:
                studio_keys.add(merge_key(name.translate(JP_VARIANTS)))
    actresses = build_actresses(studio_keys)
    link_rows, coser_tag_count = enrich_domestic_posts(actresses)
    print(f"  国内作品链接 {len(link_rows)} 条，角色/IP 标签 {coser_tag_count} 条")
    write_database(actresses, studios, link_rows, coser_tag_count)


if __name__ == "__main__":
    main()
