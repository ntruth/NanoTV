# 资料库数据体检与补全方案（2026-11）

> 范围：`Resources/Catalog/catalog.sqlite` 与 `Tools/catalog_build/raw`，以及可用于补全的外部数据源。
> 说明：本文只讨论数据与采集，不涉及界面设计。

## 0. 执行清单

| 编号 | 事项 | 状态 |
|---|---|---|
| D0 | 把本方案写入文档 | ✅ 完成 |
| D1 | 扩展 SQLite schema：人物档案字段 / `external_ids` / `person_links` / `person_studios` / `works` 底座 | 待执行 |
| D2 | 现有 raw：补 `hobby`（爱好） | 待执行 |
| D3 | 现有 raw：日文别名 / 读音回填 | 待执行 |
| D4 | 现有 raw：生日精度与坏日期修复 | 待执行 |
| D5 | 现有 raw：三围 / 身高 / 生日补缺 | 待执行 |
| D6 | 国内增强：Coser 作品链接入库 | 待执行 |
| D7 | 国内增强：角色 / IP 标签入库 | 待执行 |
| D8 | 国内增强：模特 ↔ 写真机构关系 | 待执行（现有 raw 证据不足） |
| D9 | 写入 javbus / javrate / zhwiki 等外部 ID 与来源链接 | 待执行 |
| D10 | 重建数据库并核对新增字段 / 关系 / 标签数量 | 待执行 |
| D11 | 外部大盘：R18.dev dump + 作品表 | 待执行（依赖下载/导入） |
| D12 | 外部 API：DMM / FANZA 人物与作品字段 | 待执行（依赖联盟账号） |
| D13 | 日文维基人物信息框批量抓取 | 待执行 |
| D14 | 国内平台：B站 / 微博 / JVID / SWAG | 待执行（依赖抓取策略） |
| D15 | 欧美：IAFD / ThePornDB / FreeOnes | 待执行（依赖账号或代理） |

---

## 1. 现状体检

### 1.1 人物字段覆盖（16,135 人）

| 字段 | 有值 | 覆盖率 |
|---|---:|---:|
| 日文名 | 12,386 | 77% |
| 英文名 | 469 | 3% |
| 生日（含 497 条仅年份） | 6,043 | 37% |
| 年龄 | 3,470 | 22% |
| 身高 | 6,233 | 39% |
| 三围齐全 | 7,063 | 44% |
| 罩杯 | 6,128 | 38% |
| 作品数 | 3,723 | 23% |
| 简介 | 2,788 | 17% |
| 头像 | 7,620 | 47% |
| 别名 | 3,640 人 / 5,914 条 | 23% |
| 标签 | 只有 111 种 | — |
| `description` | 54 条 | ≈0% |

### 1.2 地区断层

| 地区 | 人数 | 生日 | 身高 | 三围 | 作品数 | 头像 | 简介 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 日本 | 13,799 | 6,024 | 6,233 | 7,062 | 3,723 | 7,611 | 2,710 |
| 中国大陆 | 2,187 | 3 | 2 | 1 | 1 | 2 | 22 |
| 韩国 | 111 | 14 | 3 | 2 | 0 | 7 | 54 |
| 欧美 | 25 | 0 | 0 | 0 | 0 | 0 | 1 |
| 台湾 | 11 | 2 | 0 | 0 | 0 | 0 | 1 |
| 香港 | 2 | 0 | 0 | 0 | 0 | 0 | 0 |

### 1.3 资料完整度（9 项：生日/身高/三围/罩杯/作品/简介/头像/标签/别名）

| 地区 | 0–2 项 | 3–5 项 | 6–8 项 | 9 项 |
|---|---:|---:|---:|---:|
| 日本 | **6,797** | 3,347 | 1,957 | 1,698 |
| 中国大陆 | **2,176** | 11 | 0 | 0 |
| 韩国 | 61 | 48 | 2 | 0 |

「纯名字」（无生日/身高/作品/简介/头像）：**7,576 人，占 47%**。

### 1.4 厂商

| 指标 | 数值 |
|---|---:|
| 厂商总数 | 464（片商 272 / 写真机构 188 / 平台 4） |
| 有简介 | 14 |
| 有官网 | 42 |
| 有真实 Logo | 0（现为字母头像） |
| 有英文名 | 216 |
| 有作品数 | 249 |
| 只有名字 | 149 |
| 番号前缀 | 45 条，只覆盖 13 个厂商 |
| 完全没有前缀的厂商 | 456 |

---

## 2. 可补的信息角度

### A. 人物身份与生理信息
日文读音、中文名、英文名、本名、旧艺名、出身地、生日、血型、身高、体重、BWH、罩杯、鞋码、惯用手、趣味/特技。

### B. 职业履历
出道年份/出道作、专属厂牌、所属事务所、活动期间、引退/复归、获奖、年度排名、销量。

### C. 官方与社交
官网、X、Instagram、YouTube、TikTok、微博、B站、小红书、OnlyFans、粉丝俱乐部、粉丝数。

### D. 作品（最大的空白）
番号 / `content_id` / `dvd_id`、日/中/英标题、发行日期、时长、导演、片商、label、系列、题材、出演者、共演、封面、剧照、预告、评分、收藏/想看。

### E. 数据关系
人物 ↔ 事务所；人物 ↔ 厂牌；人物 ↔ 写真机构；人物 ↔ 作品 ↔ 系列 ↔ 题材；人物 ↔ 共演者；人物 ↔ 相似人物；厂商 ↔ 母公司/label/系列。

### F. 多图与媒体
主头像、全身、写真、作品封面、剧照、签名。建议存 URL + 本地按需缓存，不再把 base64 塞进 SQLite（当前 41MB 里 28.9MB 是头像）。

### G. 标签体系
现在只有 111 种且偏主观。需要题材、角色、服装、IP、年代、地区、平台、奖项，并做「规范名 + 中日英别名 + 分类」。

### H. 数据质量与溯源
字段级来源、更新时间、置信度；497 条仅年份生日需要精度字段；地区误判（港台/大陆、华裔欧美）需要复核。

---

## 3. 现有 raw 里还没榨干的东西

| raw 文件 | 内容 | 现状问题 |
|---|---|---|
| `javbus_star_details.json` | 9,535 人的生日/年龄/身高/BWH/罩杯/爱好 | 爱好未入库；匹配现有日文人物可补 1,742 条爱好、161 条三围、117 条身高、93 条生日 |
| `javbus_stars_zh.json` | 53,278 条 star_id → 中文名 | 只当译名，未作为别名/发现字典 |
| `javbus_portraits.json` | 5,804 个头像 URL | 对现有日文人物只能再补 3 张，补不齐 6,188 个无头像的人 |
| `javrate_actor_details.json` | 3,715 人：`ja` 读音列表、别名、简介、图片 | 读音/别名已在合并流程中使用；简介用了 2,336 条 |
| `javbus_name_map.json` | 3,709 条日文名 ↔ 中文名 | 可用于别名与去重 |
| `coscd_people.json` + `coscd_posts.json` | 913 人、3,826 篇作品、1,593 条作品链接、角色/IP 标签 | 只取了名字和套数；作品、链接、IP 标签全丢 |
| `coscd_tags.json` | 碧蓝航线 502、原神 180、2B 123、女仆、旗袍等 | 可建 Coser 的「角色/IP」标签 |
| `kkkhai_tag_studios.json` / `brand_studios.json` | 146 个国内写真机构/品牌 | 未能可靠建立「模特 ↔ 机构」关系 |
| `kkkhai_posts_full.json` | 915 篇作品，带日期/期数/机构 | 只用了名字；日期/期数注意不要当正式统计 |
| `kkkhai_studio_details.json` | 194 个机构的风格/是否收新人 | 未入库 |
| `mms_profiles.json` / `mms_tags.json` | 998 篇长文、4,869 个标签 | 长文多为 AI 水文，不建议；标签可挑角色类 |
| `wikidata_actress_dates.json` / `wiki_actress_bios.json` | 496 条生日/身高、745 条中文维基简介 | 已用，但覆盖面小 |

**P0 结论：**
1. 入 `hobby`（1,742 条）
2. 修生日精度（497 条仅年份）
3. 入 Coser 作品链接与角色/IP 标签
4. 建 `external_ids`（javbus / javrate）
5. 模特↔机构关系现有证据不足，需要新抓机构/模特页

---

## 4. 外部资源清单（按性价比）

### 4.1 R18.dev（作品与 ID 的底座）
- 免费单作品 JSON：`https://r18.dev/videos/vod/movies/detail/-/combined=<id>/json`
- 每周 gzip SQL dump，**CC0**：`https://r18.dev/dumps`
- 约 8.5 万女优（DMM id、日文名、别名、缩略图）；作品含 content_id / dvd_id / 标题 / 发行日期 / 时长 / 导演 / 厂牌 / label / 系列 / 出演者 / 题材 / 封面 / 剧照 / 预告。
- 注意：元数据 CC0，封面/剧照版权不属于 CC0，建议只存 URL。

### 4.2 DMM / FANZA Web API v3（人物档案最权威）
- `ActressSearch`：女优 ID、艺名、读音、BWH、罩杯、身高、生日、血型、趣味、出身地、头像、列表页。
- `ItemList`：作品；`MakerSearch` / `SeriesSearch` / `GenreSearch`：厂牌/系列/题材。
- 需要联盟 `api_id` + `affiliate_id`，有站点审核；图片使用有条款。

### 4.3 JavBus（已有基础）
- 演员页：生日、三围、出道年份、全部出演作品。
- 作品页：番号、封面、发行日期、时长、导演、制作商、发行商、系列、类别、演员、样品图。
- 现有 raw 9,535 人；需要限速/代理。

### 4.4 JavLibrary（评分/想看/看过）
- 演员档案、作品、评分、评论、想看/看过；Cloudflare/403 严重，需要代理。

### 4.5 JavDB（中文资料/评分/标签）
- 演员、作品、评分、标签、海报；需要 cookie / Cloudflare 绕过。

### 4.6 Wikipedia（日文/中文）+ Wikidata
- 日文维基信息框：生年月日、出身地、身高/体重、三围、罩杯、出演期间、专属厂牌、所属事务所、获奖、官方账号。
- Wikidata：P569 生日、P19 出身地、P2048 身高、P2002/P2003/P2397 社交、P856 官网。
- 免费、可引用，适合做可信基线。

### 4.7 经纪公司官网
- T-Powers、C-more、Mine's、Life、Prime、Eightman、Vanquish、Bambi、ALIVE、aina 等。
- 现役最权威：生日、身高、三围、出身地、趣味、官方社交。

### 4.8 日文资料站
- 素人系総合 wiki、AV-Wiki、rank1-media、narrow-deep：生日、三围、出道作、出演本数。
- 适合补老女优；准确性参差，需交叉校验。

### 4.9 欧美
- IAFD：生日、出身地、族裔、身高、体重、活动年份、别名、作品履历、获奖。
- ThePornDB / StashDB：GraphQL + API Token，performer / scene / studio / 图片。
- FreeOnes / Babepedia：资料与社交链接。

### 4.10 华语/台湾平台
- JVID：模特页、作品、写真、视频。
- SWAG：创作者页、作品。
- 无公开 API，HTML 抓取。

### 4.11 国内平台与社交
- B站公开 API：昵称、头像、签名、粉丝数。
- 微博 `m.weibo.cn`：昵称、头像、简介、粉丝。
- 小红书/抖音：签名风控，建议只存主页链接。

### 4.12 国内写真机构
- XIUREN、UGirls、ROSI、AISS、ARTGRAVIA、Beautyleg、DKGirl、GGotBBang、BoLoLi、MFStar、Feilin 等。
- 用于「所属机构」「作品系列」「同机构模特」。

### 4.13 榜单与热度
- FANZA 月间/年间女优榜、作品榜；朝日芸能 SEXY 総選挙；FLASH 排行；月刊 FANZA。
- JavLibrary 想看/看过；JavDB 评分；社交粉丝数。

### 4.14 韩国
- 目前 111 人且多为影视演员；Playboy Korea、Maxim Korea、Instagram、经纪公司。
- 性价比低，建议后置。

---

## 5. 建议的数据结构

```sql
-- 人物档案（在 actresses 上扩列）
hobby, birth_precision, ruby, birthplace, blood_type,
debut_year, agency, status, official_site, popularity

-- 跨站 ID（去重与增量更新的地基）
external_ids(entity_type, entity_id, source, external_id, url)

-- 人物链接（作品 / 主页 / 社交）
person_links(actress_id, source, kind, url, title, published_at)

-- 人物 ↔ 机构
person_studios(actress_id, studio_id, kind, source)

-- 作品
works(id, content_id, dvd_id, code, title_ja, title_zh, title_en,
      release_date, runtime_min, director, studio_id, label, series,
      genres, cover_url, sample_urls, trailer_url, rating, popularity)
work_actresses(work_id, actress_id)

-- 其他
makers / labels / series / genres
social_accounts
images
rankings
relations
field_sources
```

没有 `external_ids` 和 `works`，后续所有补数据都会继续依赖名字模糊匹配，越补越乱。

---

## 6. 优先级路线

### P0（不联网，现有 raw）
- `hobby`、生日精度、Coser 作品链接、角色/IP 标签
- `external_ids`（javbus / javrate）
- 数据质量修复

### P1（外部一手源）
- R18.dev dump → `works` / `makers` / `labels` / `series` / `genres`
- DMM/FANZA API → 读音、血型、趣味、出身地、官方头像
- 日文维基 → 生日、出身地、三围、出道、事务所
- JavLibrary / JavDB → 评分与热度

### P2（区域扩展）
- 国内：B站 / 微博 / JVID / SWAG / 写真机构
- 欧美：IAFD / ThePornDB / FreeOnes
- 韩国：经纪公司 / Instagram

### P3（派生能力）
- 出道周年、引退/复归、专属厂牌时间线
- 同事务所、同机构、共演、相似人物
- 番号 → 本地文件匹配、榜单、趋势

---

## 7. 工程与合规注意

- 不要把作品图片塞进 SQLite；当前 41MB 里 28.9MB 是头像。作品封面/剧照会直接爆安装包。
- 作品表建议单独成库或运行时下载；R18 全量是十万级。
- 图片版权：R18 元数据 CC0，但封面/剧照不是；DMM API 对图片有条款。
- 反爬：JavLibrary/JavDB 有 Cloudflare/403，GitHub IP 被封。
- 社交接口有频率限制和 cookie 要求；小红书/抖音签名风控。
- 去重必须用 external_id + 生日 + 读音/别名；现有 497 条仅年份生日需要精度字段。
- 每个字段记录 source / confidence / updated_at。

---

## 8. 外部来源

- [DMM Web API v3 まとめ（2026）](https://web-dev.fun/posts/2026-05-01-dmm-api/)
- [DMM ActressSearch 可取得字段](https://qiita.com/fabsabsfabsabs/items/e8e3b717dc311ac2176d)
- [R18.dev 免费 JSON / 每周 CC0 dump](https://github.com/the-mskd-dev/Flux/issues/390)
- [R18dev SQL 导入说明](https://github.com/javstash/R18dev_SQL)
- [JavLibrary 爬虫](https://github.com/d68fbe50/JavlibraryCrawler)
- [JavBus 作品字段](https://github.com/fireinrain/javbus_scrapy)
- [JavBus 演员页说明](https://javbus.com.cn/)
- [Javinizer 的 JavDB / JavLibrary / DMM 配置](https://javinizer.gitbook.io/docs/configuration/settings)
- [IAFD 数据结构](https://parse.bot/marketplace/6ea5b8f8-2d07-4bd6-b4e1-ca8faebb3864/iafd-com-api)
- [StashDB / ThePornDB 接入](https://guidelines.stashdb.org/docs/faq_getting-started/stashdb/accessing-stash-boxes/)
- [Bilibili 用户信息 API](https://github.com/pskdje/bilibili-API-collect/blob/main/docs/user/info.md)
- [微博 m.weibo.cn 接口](https://gist.github.com/zmwangx/64af488ca4eed04d8a719c7293e2f0a1)
- [JVID 模特中心](https://www.jvidzh.com/stars.html)
- [日文维基 AV 女优信息框示例](https://ja.wikipedia.org/wiki/JULIA_(AV%E5%A5%B3%E5%84%AA))
- [素人系総合 wiki](https://seesaawiki.jp/w/sougouwiki/d/%BD%F7%CD%A5%A5%DA%A1%BC%A5%B8%B0%EC%CD%F7)
- [日文 AV 女优资料站](https://narrow-deep.car.coocan.jp/other/av/index_a.html)
