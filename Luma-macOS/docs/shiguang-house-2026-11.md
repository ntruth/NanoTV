# 拾光屋 · 个人影像足迹架构（重设计）

| 项目 | 内容 |
| --- | --- |
| 版本 | v0.1 |
| 日期 | 2026-11-24 |
| 状态 | 设计稿，不改代码 |
| 前置文档 | [iOS 版可行性报告](luma-ios-feasibility.md)、[模块化与公共抽象建议](modularization-abstraction-2026-11.md)、[多模式内容框架评估](multi-mode-architecture-2026-11.md) |
| 核心结论 | 产品拆成**记忆域**与**内容域**；记忆域用「一个资产表 + 一张来源出现表」承载所有个人影像；手机是只读挂载源，原图默认不落盘、按需流式读取；不接任何云厂商账号 API |

---

## 0. 一句话

拾光屋不是第 6 个侧边栏模块，它是**产品本身**：把一个人散落在系统相册、手机、微信、网盘、网页收藏里的照片与视频，收进同一个可检索、可叙事、可分享的屋。

现有五个模块（图库 / 网络存储 / 网络资源 / 网络影院 / 网络电视）是屋里的**房间**，不是并列功能。重设计要解决的问题不是「再加几个房间」，而是「照片和视频到底存在哪张表里、按什么去重、按什么撤销」。

---

## 1. 现状为什么装不下「足迹」

| 现象 | 代码事实 | 后果 |
| --- | --- | --- |
| 资产没有来源概念 | `assets` 表只有 `filename / content_hash / perceptual_hash`，没有 `source_id` | 无法回答「这张照片是从哪来的」「来源断了怎么撤」 |
| 云盘照片另存一套 | `cloud_assets` 与 `assets` 互不相通，见 [MetadataStore.swift](../Sources/PhotosClone/Services/Library/MetadataStore.swift#L653) | 网盘里的老照片永远进不了主时间线 |
| 只有当前图库能写 | `SourceKind.ownsWriteSession` 仅 `library` 为真 | 所有新来源都被迫伪装成「图库」 |
| 同一张照片多处存在 | 去重靠 `content_hash` 单键 | 只能合并文件，不能记录「它同时出现在微信和 NAS」 |
| 侧边栏层级扁平 | 一级分区只有图库 / 云盘 / 资源 / 影院 / 电视 | 来源一多就只能平铺，语义断裂 |

---

## 2. 设计决策

### D1：产品拆成两个域

判据不是「是照片还是视频」，而是**这条内容属于「我的记忆」还是「可消费的内容」**。

| | 记忆域（Memory） | 内容域（Content） |
| --- | --- | --- |
| 内容 | 系统相册、手机相册、微信图片视频、网页收藏、个人云图库 | 云盘影视文件、网络影院、资源站点、电视直播 |
| 用户动作 | 回看、整理、找回、叙事、分享 | 找片、追剧、看直播 |
| 时间线 | 进主时间线，按拍摄时间 | 不进主时间线 |
| 写入 | Mac 唯一写入 | 只读浏览 |
| 存储 | `assets` + `asset_sources` + 派生表 | 各自现表：`cloud_assets` / `cinema_*` / `catalog_*` / `tv_*` |

这一刀解决了前置文档里的两难：模块化建议说「统一契约、不统一数据库」，但用户诉求是「一个人的照片必须在同一条时间线上」。两者都对——**统一只发生在记忆域内部**，内容域继续各管各的。

### D2：记忆域用「资产 + 出现」两层

不是一张大表管一切，也不是每个来源一套表。

- `assets`：一个文件实体一行，按 `content_hash`（字节级）+ `perceptual_hash`（近似）去重。
- `asset_sources`：一次「出现」一行，记录它在哪个来源、以什么远端 ID、什么时候第一次/最后一次看到。

一张照片同时在 iCloud、微信、NAS 出现时：时间线只显示一次，详情页显示「来自 3 处」。这正是「收拾足迹」的数据基础，也是所有叙事功能（地图、人物、回顾）能跨来源工作的前提。

### D3：Mac 是主机，手机是只读挂载源

沿用 [iOS 可行性报告](luma-ios-feasibility.md) 的结论：Mac 持有图库与写入会话，iPhone / Android 不直接打开图库包、不写 SQLite。

这里要区分两个容易混淆的说法：

| 说法 | 是否成立 | 准确表述 |
| --- | --- | --- |
| Mac 当服务端 | 不成立 | 数据在手机上，必须由手机暴露读取接口；Mac 是**主机（host）**，负责发现、调度、入库、分析与写入 |
| Mac 主导读取 | 成立 | Mac 主动拉取索引、缩略图与按需原图，手机不主动推送 |
| 原图上传到 Mac | 默认不成立 | 原图默认留在手机，只在查看高清、播放视频、编辑导出时经 Range 流式读取 |

好处：撤销栈、去重、转码、人脸与 SigLIP 分析全部原样复用，手机端不需要实现任何业务规则；Mac 端占用只有索引与缩略图。

### D4：不接云厂商账号 API

小米云、华为云没有开放 API，账号抓取既不合规也不稳定。正确路径是**让手机当云的落地端**：用户的小米/华为相册里本来就有云同步下来的内容，MediaStore 能读到的就是全集。只有在「云空间里有、手机相册没有」这一种情况下才需要用户手动导出——这条写进产品说明，不当 bug 处理。

### D5：来源可撤销，资产不陪葬

- 移除一个来源 → 只删该来源的 `asset_sources` 行，`assets` 保持不动。
- 手机上删了照片 → 标记 `asset_sources.deleted_at`，**不级联删除** Mac 上已归档的原图。
- 任何删除都先进可撤销队列，与现有撤销栈一致。

### D6：引用优先，归档可选

纯引用模式有一个无法回避的问题：**手机丢了或坏了，照片就永久没了**，而这恰好与「把记忆收起来」的定位相反。因此原图落盘是用户选项，不是默认行为。

| 模式 | 原图位置 | Mac 占用 | 触发方式 |
| --- | --- | --- | --- |
| **引用**（默认） | 手机 | 索引约 20 MB + 缩略图约 600 MB（10 万条） | 添加手机源即为此模式 |
| **归档** | `originals/<uuid>/` | 等同原图体积 | 用户勾选「收进屋里」，或编辑时自动归档 |

规则：

1. **copy-on-edit**：编辑引用型资产时先取回原图归档，再进入编辑器。否则撤销栈、版本与导出都会依赖手机在线状态。
2. **归档可逆**：删除归档副本只退回引用模式，不删除 `asset_sources`，时间线不塌。
3. **离线语义**：手机不在线时，索引与已缓存缩略图照常展示，高清与播放标记为不可用，不报错。

### D7：手机不在前台就连不上

iOS 不允许后台常驻 HTTP 服务，**手机上的拾光 App 不在前台时，Mac 无法读取该设备**。这是系统限制，不是实现缺陷。Android 可用前台服务（带常驻通知）接近 7×24 在线。

产品上的处理：设备源默认显示「上次在线于 X」，连接时要求用户打开手机 App；不设计后台轮询，也不假装能做到随时在线。

---

## 3. 架构总览

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1100 660" width="100%" role="img" aria-label="拾光屋架构总览：采集层、归一化、记忆域、内容域与叙事层">
  <defs>
    <marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M0,0 L10,5 L0,10 z" fill="#8a8f98"/>
    </marker>
    <linearGradient id="brand" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#F6B45A"/>
      <stop offset="55%" stop-color="#EF7C5B"/>
      <stop offset="100%" stop-color="#8C6BF2"/>
    </linearGradient>
    <style>
      .t { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; fill:#1d2129; }
      .m { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; fill:#6b7280; }
      .ln { stroke:#9aa0aa; stroke-width:1.4; fill:none; marker-end:url(#ah); }
    </style>
  </defs>
  <rect width="1100" height="660" fill="#FCFBF8"/>
  <text x="24" y="34" class="t" font-size="19" font-weight="700">拾光屋：一栋屋，两个域，多路采集</text>

  <!-- 采集层 -->
  <rect x="24" y="56" width="248" height="392" rx="12" fill="#FFF8EC" stroke="#F0D9B4"/>
  <text x="40" y="82" class="t" font-size="13" font-weight="700">采集层（只读）</text>

  <rect x="40" y="96" width="216" height="44" rx="8" fill="#fff" stroke="#EADDC6"/>
  <text x="54" y="116" class="t" font-size="11" font-weight="600">系统「照片」/ iCloud 图库</text>
  <text x="54" y="132" class="m" font-size="10">Photos.sqlite 只读解析</text>

  <rect x="40" y="148" width="216" height="44" rx="8" fill="#fff" stroke="#EADDC6"/>
  <text x="54" y="168" class="t" font-size="11" font-weight="600">手机（只读挂载）</text>
  <text x="54" y="184" class="m" font-size="10">PhotoKit / MediaStore · 原图不落盘</text>

  <rect x="40" y="200" width="216" height="44" rx="8" fill="#fff" stroke="#EADDC6"/>
  <text x="54" y="220" class="t" font-size="11" font-weight="600">微信（macOS 文件层）</text>
  <text x="54" y="236" class="m" font-size="10">容器目录扫描，不解析聊天库</text>

  <rect x="40" y="252" width="216" height="44" rx="8" fill="#fff" stroke="#EADDC6"/>
  <text x="54" y="272" class="t" font-size="11" font-weight="600">网页收藏</text>
  <text x="54" y="288" class="m" font-size="10">分享扩展剪藏，不做站内抓取</text>

  <rect x="40" y="304" width="216" height="44" rx="8" fill="#fff" stroke="#EADDC6"/>
  <text x="54" y="324" class="t" font-size="11" font-weight="600">网盘 / NAS / 本地文件夹</text>
  <text x="54" y="340" class="m" font-size="10">WebDAV · SMB · AList · FSEvents</text>

  <rect x="40" y="372" width="216" height="56" rx="8" fill="#FDF1E4" stroke="#EFD0AE"/>
  <text x="54" y="392" class="t" font-size="11" font-weight="600">统一约束</text>
  <text x="54" y="408" class="m" font-size="10">只读源 · 幂等双键 · 可撤回</text>
  <text x="54" y="422" class="m" font-size="10">原图不复制，按需取</text>

  <!-- 归一化 -->
  <rect x="304" y="56" width="212" height="392" rx="12" fill="#F2F6FF" stroke="#C7D5F0"/>
  <text x="320" y="82" class="t" font-size="13" font-weight="700">归一化管线</text>

  <rect x="320" y="96" width="180" height="40" rx="8" fill="#fff" stroke="#D7E2F7"/>
  <text x="334" y="121" class="t" font-size="11">哈希：sha256 + pHash</text>

  <rect x="320" y="144" width="180" height="40" rx="8" fill="#fff" stroke="#D7E2F7"/>
  <text x="334" y="169" class="t" font-size="11">时间：UTC + 原始时区</text>

  <rect x="320" y="192" width="180" height="40" rx="8" fill="#fff" stroke="#D7E2F7"/>
  <text x="334" y="217" class="t" font-size="11">位置：GPS → 地点</text>

  <rect x="320" y="240" width="180" height="40" rx="8" fill="#fff" stroke="#D7E2F7"/>
  <text x="334" y="265" class="t" font-size="11">缩略图金字塔</text>

  <rect x="320" y="288" width="180" height="40" rx="8" fill="#fff" stroke="#D7E2F7"/>
  <text x="334" y="313" class="t" font-size="11">端侧 AI（人脸/场景/OCR）</text>

  <rect x="320" y="344" width="180" height="58" rx="8" fill="#EAF0FE" stroke="#C7D5F0"/>
  <text x="334" y="366" class="t" font-size="10">全部在 Mac 本机完成</text>
  <text x="334" y="384" class="m" font-size="10">原图与特征不出局域网</text>

  <!-- 记忆域 -->
  <rect x="548" y="56" width="292" height="392" rx="12" fill="#F3F0FF" stroke="#D3C9F7"/>
  <text x="564" y="82" class="t" font-size="13" font-weight="700">记忆域（可写，唯一写入者）</text>

  <rect x="564" y="96" width="260" height="58" rx="8" fill="#fff" stroke="#DCD4F7"/>
  <text x="578" y="118" class="t" font-size="11" font-weight="600">assets</text>
  <text x="578" y="136" class="m" font-size="10">文件实体：content_hash · pHash · 拍摄时间 · GPS</text>

  <rect x="564" y="162" width="260" height="58" rx="8" fill="#fff" stroke="#DCD4F7"/>
  <text x="578" y="184" class="t" font-size="11" font-weight="600">asset_sources（新增）</text>
  <text x="578" y="202" class="m" font-size="10">一次出现：source_id · remote_id · seen_at</text>

  <rect x="564" y="228" width="260" height="50" rx="8" fill="#fff" stroke="#DCD4F7"/>
  <text x="578" y="250" class="t" font-size="11" font-weight="600">people / places / events</text>
  <text x="578" y="267" class="m" font-size="10">由记忆域资产派生，不区分来源</text>

  <rect x="564" y="286" width="260" height="50" rx="8" fill="#fff" stroke="#DCD4F7"/>
  <text x="578" y="308" class="t" font-size="11" font-weight="600">albums / folders / smart albums</text>
  <text x="578" y="325" class="m" font-size="10">用户组织层，可跨来源</text>

  <rect x="564" y="344" width="260" height="58" rx="8" fill="#EDE8FF" stroke="#D3C9F7"/>
  <text x="578" y="366" class="t" font-size="10">一张照片多处出现 → 时间线只一行</text>
  <text x="578" y="384" class="m" font-size="10">详情页显示「来自 iCloud / 微信 / NAS」</text>

  <!-- 叙事层 -->
  <rect x="864" y="56" width="212" height="392" rx="12" fill="#EFFAF5" stroke="#BFE6D4"/>
  <text x="880" y="82" class="t" font-size="13" font-weight="700">叙事输出</text>

  <rect x="880" y="96" width="180" height="38" rx="8" fill="#fff" stroke="#CFEDE0"/>
  <text x="894" y="120" class="t" font-size="11">时间线 / 那年今日</text>

  <rect x="880" y="142" width="180" height="38" rx="8" fill="#fff" stroke="#CFEDE0"/>
  <text x="894" y="166" class="t" font-size="11">足迹地图 / 路线回放</text>

  <rect x="880" y="188" width="180" height="38" rx="8" fill="#fff" stroke="#CFEDE0"/>
  <text x="894" y="212" class="t" font-size="11">人物合辑 / 关系</text>

  <rect x="880" y="234" width="180" height="38" rx="8" fill="#fff" stroke="#CFEDE0"/>
  <text x="894" y="258" class="t" font-size="11">旅行故事 / 回忆影片</text>

  <rect x="880" y="280" width="180" height="38" rx="8" fill="#fff" stroke="#CFEDE0"/>
  <text x="894" y="304" class="t" font-size="11">分享卡片 / 导出</text>

  <rect x="880" y="344" width="180" height="58" rx="8" fill="#E6F7EF" stroke="#BFE6D4"/>
  <text x="894" y="366" class="t" font-size="10">复用现有实现</text>
  <text x="894" y="384" class="m" font-size="10">Footprint / Trips / Memories</text>

  <!-- 内容域 -->
  <rect x="24" y="474" width="1052" height="156" rx="12" fill="#F7F7F9" stroke="#DCDEE5"/>
  <text x="40" y="500" class="t" font-size="13" font-weight="700">内容域（只读浏览，不进记忆时间线）</text>

  <rect x="40" y="516" width="236" height="46" rx="8" fill="#fff" stroke="#E3E5EB"/>
  <text x="54" y="544" class="t" font-size="11">云盘影视文件 · luma_cloud_*</text>

  <rect x="292" y="516" width="236" height="46" rx="8" fill="#fff" stroke="#E3E5EB"/>
  <text x="306" y="544" class="t" font-size="11">网络影院 · cinema_*</text>

  <rect x="544" y="516" width="236" height="46" rx="8" fill="#fff" stroke="#E3E5EB"/>
  <text x="558" y="544" class="t" font-size="11">网络资源 · catalog_*</text>

  <rect x="796" y="516" width="264" height="46" rx="8" fill="#fff" stroke="#E3E5EB"/>
  <text x="810" y="544" class="t" font-size="11">网络电视 · tv_*</text>

  <rect x="40" y="572" width="1020" height="42" rx="8" fill="#EFEFF3" stroke="#DCDEE5"/>
  <text x="56" y="598" class="t" font-size="11">统一的是 SourceDescriptor / ContentCard / PlaybackTarget 三个契约，不是表；内容域的媒体文件不参与记忆域去重</text>

  <!-- 连线 -->
  <path class="ln" d="M272 200 H304"/>
  <path class="ln" d="M272 324 H304"/>
  <path class="ln" d="M516 200 H548"/>
  <path class="ln" d="M840 200 H864"/>
  <path class="ln" d="M272 578 H796" stroke-dasharray="4 4"/>
</svg>
```

---

## 4. 数据模型

### 4.1 新增：`asset_sources`

```sql
CREATE TABLE IF NOT EXISTS asset_sources (
    asset_id     TEXT NOT NULL,          -- 指向 assets.id
    source_id    TEXT NOT NULL,          -- 指向 SourceDescriptor.id，如 device:<uuid>
    remote_id    TEXT NOT NULL,          -- 远端身份：PHAsset.localIdentifier / MediaStore._ID / 相对路径 / URL
    origin_kind  TEXT NOT NULL,          -- systemLibrary | device | wechat | web | cloudMount | folder
    first_seen_at REAL NOT NULL,
    last_seen_at  REAL NOT NULL,
    seen_count    INTEGER NOT NULL DEFAULT 1,
    deleted_at    REAL,                  -- 远端已消失，但本地资产保留
    PRIMARY KEY (source_id, remote_id)
);
CREATE INDEX IF NOT EXISTS idx_asset_sources_asset ON asset_sources(asset_id);
CREATE INDEX IF NOT EXISTS idx_asset_sources_origin ON asset_sources(origin_kind, last_seen_at);
```

设计要点：

- **主键是 `(source_id, remote_id)`**，保证同一来源重复扫描幂等；不是 `asset_id`，因为一个远端条目只对应一个资产，但一个资产可对应多个远端条目。
- `origin_kind` 冗余存一份，用于「按来源筛选时间线」，避免每次 join 源表。
- 不建外键，与现有 `SQLite.swift` 轻量封装保持一致；一致性由 `MetadataStore` 的写入事务保证。

### 4.2 改动：`assets`

现有 `content_hash` / `perceptual_hash` 已经具备（见 [MetadataStore.swift](../Sources/PhotosClone/Services/Library/MetadataStore.swift#L717-L723)），去重基础不动，只补三列：

| 列 | 用途 |
| --- | --- |
| `primary_origin_kind` | 时间线徽标、来源筛选的默认值；多来源时取首次入库来源 |
| `original_location` | `local` / `remote` / `cached`：原图在本地、只在手机、或临时缓存；决定查看高清、播放、编辑是否需要回源 |
| `captured_tz_offset` | 拍摄地时区偏移，跨国旅行时间线修正用 |

### 4.3 为什么不动内容域

`cloud_assets` 里的电影、`cinema_*` 里的影片、`catalog_*` 里的资源条目，都不是「记忆」。它们继续走各自的表和现有的 `ContentCard` 契约。**唯一例外**：用户明确把网盘里的某个照片目录设为「记忆源」时，该目录下的照片走记忆域管线，影视文件仍留在 `cloud_assets`。判定依据是扩展名白名单 + 用户选择的目录语义，不是文件大小。

---

## 5. 来源全景与可行性

| # | 来源 | 通道 | 档位 | 前置条件 | 不承诺 |
| --- | --- | --- | --- | --- | --- |
| 1 | macOS「照片」/ iCloud 图库 | 只读解析 `Photos.sqlite`（已实现）+ PhotoKit 授权 | **A** | 用户开启 iCloud 图库 | 「优化 Mac 存储」下本地无原图时，原图需网络下载 |
| 2 | 本地 / 外置 / NAS 文件夹 | FSEvents + 扩展名与魔数双重识别 | **A** | 目录可读 | — |
| 3 | 网盘照片目录 | 现有 WebDAV / SMB / AList 适配器 | **A** | 挂载在线 | 云端缩略图质量参差，需本地重生成 |
| 4 | iPhone 相册 | 拾光 iOS：PhotoKit 授权 + 增量 change token，作为只读挂载源 | **A** | 同一 Wi-Fi、App 在前台 | 不在前台即不可读；「部分照片」授权需兼容 |
| 5 | Android / 小米 / 华为相册 | 拾光 Android：MediaStore + ContentObserver | **B** | 需处理厂商杀后台；需上架或侧载 | 云空间独有、未回落到手机相册的内容 |
| 6 | 微信（macOS） | 容器目录文件层扫描 | **B** | 完全磁盘访问权限 | 聊天记录正文、发送者映射、加密库解析 |
| 7 | 网页图库 / 云图库官网 | 分享扩展剪藏 | **B** | 用户主动收藏 | 站内批量抓取、绕过防盗链 |
| 8 | 微信（手机端） | 只能「保存到相册」后由手机相册同步 | **C** | 用户手动操作 | 直接读取手机微信沙盒 |

档位定义：**A** 现在就能做；**B** 能做，但需要额外客户端或系统权限；**C** 只能靠用户动作。

关于第 6 项必须说清楚：微信 4.x 起目录结构与早期版本不同，群聊目录名是哈希值，**无法还原「谁在哪发给你」**。拾光只做「文件层导入」，不做聊天记录解析。这条要写进产品说明，避免被当成缺陷。

---

## 6. 侧边栏结构

侧边栏可以膨胀，但要**两级 + 分组**：[SidebarView.swift](../Sources/PhotosClone/Features/Sidebar/SidebarView.swift#L42-L52) 已有 `collapsedSections` 与顶层手风琴（展开一个自动收起其余），这套机制就是为来源增多准备的。

```
图库          当前库 / 链接库
个人足迹      手机相册 / 微信 / 网页收藏 / 个人云图库
存储          云盘 / NAS / 本地文件夹
影视          网络影院 / 网络资源
电视          直播源
```

规则：

1. 一级分区不超过 6 个，且是固定语义，不随来源数量增长。
2. 二级实例可无限增加，超出 8 个时折叠为「更多」。
3. 全局搜索的来源胶囊按 `SourceKind` 生成，不按实例生成，避免胶囊爆炸。
4. 设置页的模块开关**不跟着膨胀**：仍是五个能力开关，足迹源归入「图库」模块——因为它是图库的来源扩容，不是新能力。

---

## 7. 手机挂载源协议

### 7.1 角色划分

一套协议，两个方向，**谁的磁盘上有数据谁当服务端**。需要纠正一个常见说法：Mac 不是服务端，它是发起同步的主机（host）。

| 场景 | 服务端 | 主机 / 客户端 | 数据流向 |
| --- | --- | --- | --- |
| 手机相册挂载到拾光 | 手机 | Mac | Mac 拉索引与缩略图；原图按需 Range 读取，不落盘 |
| iOS 浏览 Mac 图库 | Mac | iOS | iOS 拉查询 / 缩略图 / 原图 |

两者共用同一种 Bonjour 服务类型、同一套配对与令牌，差异只在 `role` 字段。Mac 拉取模式的好处：Mac 端是 `SourceJob`，进度、重试、断点天然复用；手机不用常驻后台轮询。

### 7.2 同步时序

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 980 470" width="100%" role="img" aria-label="手机采集端同步时序：配对、索引增量、缩略图、按需原图">
  <defs>
    <marker id="ar2" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M0,0 L10,5 L0,10 z" fill="#6b7280"/>
    </marker>
    <style>
      .t2 { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; fill:#1d2129; }
      .m2 { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; fill:#6b7280; }
      .a2 { stroke:#6b7280; stroke-width:1.4; fill:none; marker-end:url(#ar2); }
    </style>
  </defs>
  <rect width="980" height="470" fill="#FCFBF8"/>

  <rect x="60" y="24" width="200" height="46" rx="8" fill="#FFF8EC" stroke="#F0D9B4"/>
  <text x="76" y="45" class="t2" font-size="12" font-weight="700">iPhone 采集端</text>
  <text x="76" y="62" class="m2" font-size="10">前台 · Wi-Fi · PhotoKit</text>

  <rect x="390" y="24" width="200" height="46" rx="8" fill="#F2F6FF" stroke="#C7D5F0"/>
  <text x="406" y="45" class="t2" font-size="12" font-weight="700">局域网</text>
  <text x="406" y="62" class="m2" font-size="10">Bonjour · TLS · Token</text>

  <rect x="720" y="24" width="200" height="46" rx="8" fill="#F3F0FF" stroke="#D3C9F7"/>
  <text x="736" y="45" class="t2" font-size="12" font-weight="700">Mac · 拾光</text>
  <text x="736" y="62" class="m2" font-size="10">唯一写入者 · SourceJob</text>

  <line x1="160" y1="70" x2="160" y2="440" stroke="#D9DCE3" stroke-dasharray="4 5"/>
  <line x1="490" y1="70" x2="490" y2="440" stroke="#D9DCE3" stroke-dasharray="4 5"/>
  <line x1="820" y1="70" x2="820" y2="440" stroke="#D9DCE3" stroke-dasharray="4 5"/>

  <text x="60" y="108" class="t2" font-size="11" font-weight="600">1 配对</text>
  <path class="a2" d="M820 104 H160"/>
  <text x="330" y="98" class="m2" font-size="10">二维码：设备公钥 + 一次性码</text>

  <text x="60" y="160" class="t2" font-size="11" font-weight="600">2 版本协商</text>
  <path class="a2" d="M820 156 H160"/>
  <text x="330" y="150" class="m2" font-size="10">GET /v1/known → Mac 回传已有 deviceAssetID 摘要</text>

  <text x="60" y="212" class="t2" font-size="11" font-weight="600">3 索引增量</text>
  <path class="a2" d="M820 208 H160"/>
  <text x="330" y="202" class="m2" font-size="10">GET /v1/changes?since=cursor → 元数据批量返回</text>

  <text x="60" y="264" class="t2" font-size="11" font-weight="600">4 缩略图</text>
  <path class="a2" d="M820 260 H160"/>
  <text x="330" y="254" class="m2" font-size="10">GET /v1/thumbs?ids=… → 128px / 256px 批量</text>

  <text x="60" y="316" class="t2" font-size="11" font-weight="600">5 入库</text>
  <rect x="690" y="290" width="270" height="34" rx="8" fill="#fff" stroke="#D3C9F7"/>
  <text x="704" y="311" class="m2" font-size="10">sha256 去重 → assets + asset_sources</text>

  <text x="60" y="368" class="t2" font-size="11" font-weight="600">6 原图按需</text>
  <path class="a2" d="M820 364 H160"/>
  <text x="300" y="358" class="m2" font-size="10">GET /v1/assets/{id}/original · Range 断点续传</text>

  <rect x="60" y="396" width="860" height="52" rx="8" fill="#EFFAF5" stroke="#BFE6D4"/>
  <text x="76" y="418" class="t2" font-size="10">缩略图随索引推送（否则离线时时间线是空的）；原图默认不落盘，只在查看高清 / 播放 / 编辑导出时经 Range 回源</text>
  <text x="76" y="436" class="m2" font-size="10">删除只标记 asset_sources.deleted_at，不级联删除已归档原图；编辑自动转为归档（copy-on-edit）</text>
</svg>
```

### 7.3 索引负载

单条索引约 200 字节，缩略图 128px 约 6 KB。10 万张首次同步约 620 MB，局域网可接受；之后只传变化集。为控制首次成本，提供「先元数据、后缩略图」两档：元数据跑完就能看到时间线骨架，缩略图在空闲时补齐。

| 接口 | 方向 | 关键字段 |
| --- | --- | --- |
| `GET /v1/hello` | Mac → 手机 | `protocolVersion`、`libraryVersion`、`授权范围` |
| `POST /v1/pair` | Mac → 手机 | 一次性码换长期令牌，绑定设备公钥 |
| `GET /v1/known` | Mac → 手机 | 已知 `deviceAssetID` 摘要，用于跳过已入库项 |
| `GET /v1/changes` | Mac → 手机 | `deviceAssetID`、`sha256`、`pHash`、尺寸、时长、拍摄时间、时区、GPS、Live Photo / 截图 / 连拍标记、相簿名 |
| `GET /v1/thumbs` | Mac → 手机 | 批量缩略图，只请求 Mac 缺的 |
| `GET /v1/assets/{id}/original` | Mac → 手机 | Range 断点续传，用于编辑 / 导出 |

`deviceAssetID` 用 `PHAsset.localIdentifier`（iOS）/ `MediaStore._ID`（Android），在设备内稳定，直接作为 `asset_sources.remote_id`。

---

## 8. 分期

| 阶段 | 内容 | 交付判据 |
| --- | --- | --- |
| P0 记忆域地基 | `asset_sources` 表与迁移；`SourceKind` 扩展；侧边栏两级分组；通用文件夹源（含微信目录） | 同一张照片从 iCloud 与文件夹各导入一次，时间线只出现一行，详情页显示两个来源 |
| P1 手机挂载源 | 配对 + 索引增量 + 缩略图 + 原图按需回源（iOS 优先） | 10 万张元数据同步完成后，Mac 时间线可按年/月浏览且磁盘增量小于 1 GB；原图按需拉取成功率可观测 |
| P2 微信与网页 | 微信文件层专用扫描器；分享扩展剪藏 | 微信导入可预览、可整批撤回；网页收藏能落到指定相簿 |
| P3 叙事闭环 | 足迹地图、人物合辑、年度回顾接入记忆域统一资产；手机「清出空间」 | 新来源的资产无需额外适配即可出现在足迹与回顾里 |

P3 的「清出空间」是唯一的高风险写操作：必须显示「已在 Mac 校验存在」后才允许释放手机本地原件，且默认关闭。

---

## 9. 改动清单

| 文件 | 改动 |
| --- | --- |
| [Source.swift](../Sources/LumaContentCore/Source/Source.swift) | `SourceKind` 增加 `deviceLibrary` / `messaging` / `webArchive` / `personalCloud`；`SourceID` 增加对应构造器；`ContentCapabilities` 增加 `remoteIndex`、`onDemandOriginal` |
| [SourceSession.swift](../Sources/LumaContentCore/Source/SourceSession.swift) | 新增 `SourceRole`（host / agent）；`SourceLifecycle` 增加 `pair()` |
| [MetadataStore.swift](../Sources/PhotosClone/Services/Library/MetadataStore.swift) | 新建 `asset_sources`；`assets` 补三列；迁移保持幂等 |
| [LibraryStore+SourceRegistry.swift](../Sources/PhotosClone/Store/LibraryStore+SourceRegistry.swift) | 足迹源的注册、分组、排序与健康状态 |
| [SidebarView.swift](../Sources/PhotosClone/Features/Sidebar/SidebarView.swift) | 新增「个人足迹」分区，复用现有折叠与手风琴 |
| [AppModules.swift](../Sources/PhotosClone/Features/Settings/AppModules.swift) | 足迹源映射到 `library` 模块，不新增模块开关 |
| [SearchTypes.swift](../Sources/PhotosClone/Services/Search/SearchTypes.swift) | `SearchSourceKind` 增补足迹；胶囊仍按 kind 生成 |
| [IngestService.swift](../Sources/LumaContentCore/Ingest/IngestService.swift) | `IngestRequest.Payload` 增加 `deviceAsset`（远端原图按需） |
| 新增 `Services/Trace/` | `TraceIngestCoordinator`、`FolderTraceScanner`、`WeChatTraceScanner`、`DeviceAgentClient`、`WebClipReceiver` |

不动的部分：`Composition → CinemaLibraryView` 的内容域链路、`SourceJob` 调度骨架、`PerceptualHash` / `FaceClustering` / `SigLIPEngine`。

---

## 10. 与既有设计的一致性

| 既有结论 | 本文的承接 |
| --- | --- |
| iOS 报告：Mac 是唯一写入者与唯一数据源 | D3 沿用，但把「手机上传」改为「只读挂载 + 原图按需回源」；手机是数据提供端，不承担业务规则 |
| 模块化建议：统一发生在契约层，不统一数据库 | D1/D2 限定在记忆域内部；内容域继续分表，契约不变 |
| 多模式评估：`library` 是唯一拥有写入会话的 kind | 不变；足迹源是只读浏览源，经归一化后交给 `library` 写入 |

唯一的实质新增是 `asset_sources`。它把「文件从哪来」从隐含约定变成可查询的数据，这是「收拾足迹」的必要条件。

---

## 11. 红线

1. **只读源**：微信、手机、网盘一律不写回。
2. **原图默认不落盘**：引用模式下 Mac 只留索引与缩略图，原图经 Range 流式读取；只有用户显式归档或编辑时才复制。
3. **端侧 AI**：人脸、场景、OCR、向量全部本机运行，影像不出局域网。
4. **可撤回**：来源移除与远端删除都不级联删资产。
5. **不承诺**：微信聊天记录与发送者、小米 / 华为云账号直连、网站批量抓取。三条写进产品说明。
