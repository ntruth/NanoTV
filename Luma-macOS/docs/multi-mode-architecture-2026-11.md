# 多模式内容框架评估与公共抽象方案

**主题：图库 / 网络云盘 / 网络资源 / 网络影院 / 网络电视的统一扩展能力**

| 项目 | 内容 |
| --- | --- |
| 版本 | v0.1 |
| 日期 | 2026-11-22 |
| 状态 | 现状评估与方案建议，未改动代码 |
| 适用范围 | macOS 拾光（Luma）内容浏览、源接入与播放链路 |
| 结论 | 现有框架“能加功能”，但不是“插件式可加”。新增影院站点源和电视直播源前，需要先补 3 个底座：统一源描述、统一播放目标、播放内核的直播模式 |

---

## 0. 结论摘要

1. **前三种模式已经完整落地，影院是“文件型影院”，电视完全缺失。**
   - 图库：本地图库 + 只读系统图库。
   - 网络云盘：挂载、扫描、索引、浏览、播放、云端影院均已具备。
   - 网络资源：13 个站点适配器、分类、详情、分集、续看、跨源聚合均已具备。
   - 网络影院：已有“本地 / 网盘视频文件 + TMDB/豆瓣/TVDB 刮削”的影院，但**还不能接入电影源、电影网站或 JSON 片源**。
   - 网络电视：代码中没有任何 M3U / XMLTV / IPTV / 直播频道模型，属于从零新增。

2. **框架的主要问题不是“不能扩展”，而是“扩展需要改中心代码”。**
   当前用一个 60+ case 的 `SidebarItem` 枚举驱动侧边栏、内容页、标题、命令可用性和查询范围。新增一个模式或一类源，需要在至少 4 处中心 switch 里补分支，属于“开闭原则”层面的结构性负债。

3. **播放链路是最需要先抽象的部分。**
   [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L2643-L2665) 在播放器内部用 `catalogPlaybackContext` / `photo.isCloud` / 本地文件三分支解析片源；网络资源还通过“虚拟 PhotoItem + 旁路字典”接入。电视直播会变成第四、第五种分支，继续叠加不可控。

4. **播放内核目前是 VOD 假设，不是“能播 HLS 就等于支持直播”。**
   [PlaybackSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackSession.swift#L303-L355) 的续播、片头片尾、剩余 5 分钟预热、每 10 秒写进度都以 `duration > 0` 为前提。直播流没有有限时长，现有逻辑会退化为“不写进度、不预热”，但界面仍会显示进度条、续播入口和片尾行为，属于“能出画面但不可用”。

5. **可公共抽象的收益很高，但不应强推“万物皆 PhotoItem”。**
   照片的 EXIF、相簿、编辑、人物语义太重，电视直播频道不适合塞进 `PhotoItem`。正确做法是抽出**跨模式的展示模型与播放模型**，让 `PhotoItem`、`CinemaEntry`、`CatalogItem` 继续做各自领域的模型，通过适配器接入。

6. **建议先做 P0 底座，再做电视 MVP，最后做在线影院。**
   P0 不改现有界面行为：统一播放目标与解析器、播放模式（VOD / Live）、源注册表与侧边栏描述符。P1 用 M3U + HLS 直播 + 收藏/最近打通电视；P2 再把电影网站 / 片源配置接进影院。

---

## 1. 现状盘点

### 1.1 五种模式的代码落点

| 产品模式 | 现有实现 | 侧边栏入口 | 状态模型 | 内容视图 | 播放链路 |
| --- | --- | --- | --- | --- | --- |
| 图库模式 | 自建图库 + 系统照片图库（只读） | `.library`、`.systemLibrary` 等 | `LibraryStore` 主状态 | `GalleryView` 时间轴 / 网格 | 本地文件，`LibraryPaths.sourceURL` |
| 网络云盘模式 | SMB / WebDAV / 阿里云盘 / 百度 / 夸克 / 115 | `.cloudMount(UUID)` | `CloudBrowserModel` + 云索引表 | `CloudViews` + 复用照片网格 | `CloudService.stream` → 本地 HLS / 直连 |
| 网络资源模式 | 13 个站点适配器 | `.catalogSource(UUID)` | `CatalogBrowserModel` | `CatalogChannelView` / `CatalogDetailView` | `CatalogProvider.stream` → 虚拟分集 |
| 网络影院模式 | 本地 / 网盘视频文件 + 刮削 | `.cinema`、`.cloudCinema(UUID)` | `LibraryStore+Cinema` 的 `cinemaIndexes` | `CinemaLibraryView` | `openCinema` → 查看器 |
| 网络电视模式 | 无 | 无 | 无 | 无 | 无 |

### 1.2 现状结构图

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 620" width="100%" role="img" aria-label="现状五种模式与共享层">
  <defs>
    <marker id="a1" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">
      <path d="M0,0 L0,6 L9,3 z" fill="#8a8f98"/>
    </marker>
    <marker id="a2" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">
      <path d="M0,0 L0,6 L9,3 z" fill="#d9534f"/>
    </marker>
    <style>
      .t { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; fill:#1d2129; }
      .m { fill:#6b7280; }
      .line { stroke:#8a8f98; stroke-width:1.2; fill:none; marker-end:url(#a1); }
      .redline { stroke:#d9534f; stroke-width:1.4; fill:none; stroke-dasharray:5 4; marker-end:url(#a2); }
    </style>
  </defs>

  <text x="24" y="30" class="t" font-size="19" font-weight="700">现状：五种产品模式与共享层</text>
  <text x="24" y="52" class="t m" font-size="12">模式本身已有实现，但入口、导航、标题与播放解析都集中在少数中心文件里</text>

  <!-- 五个模式 -->
  <rect x="20" y="72" width="200" height="116" rx="10" fill="#f2f6ff" stroke="#bfd0f5"/>
  <text x="36" y="98" class="t" font-size="14" font-weight="700">图库模式</text>
  <text x="36" y="120" class="t" font-size="11">本地图库 / 系统图库</text>
  <text x="36" y="140" class="t" font-size="11">LibraryStore</text>
  <text x="36" y="160" class="t" font-size="11">GalleryView 时间轴</text>
  <text x="36" y="178" class="t" font-size="11" fill="#2f7d4f">状态：完整</text>

  <rect x="236" y="72" width="200" height="116" rx="10" fill="#f2fbf7" stroke="#b9e3cf"/>
  <text x="252" y="98" class="t" font-size="14" font-weight="700">网络云盘模式</text>
  <text x="252" y="120" class="t" font-size="11">CloudMount / 扫描索引</text>
  <text x="252" y="140" class="t" font-size="11">CloudBrowserModel</text>
  <text x="252" y="160" class="t" font-size="11">CloudViews + 照片网格</text>
  <text x="252" y="178" class="t" font-size="11" fill="#2f7d4f">状态：完整</text>

  <rect x="452" y="72" width="200" height="116" rx="10" fill="#fff9f0" stroke="#f0d7ae"/>
  <text x="468" y="98" class="t" font-size="14" font-weight="700">网络资源模式</text>
  <text x="468" y="120" class="t" font-size="11">CatalogSource + 13 适配器</text>
  <text x="468" y="140" class="t" font-size="11">CatalogBrowserModel</text>
  <text x="468" y="160" class="t" font-size="11">CatalogChannelView</text>
  <text x="468" y="178" class="t" font-size="11" fill="#2f7d4f">状态：完整</text>

  <rect x="668" y="72" width="200" height="116" rx="10" fill="#f8f4ff" stroke="#ddd0f2"/>
  <text x="684" y="98" class="t" font-size="14" font-weight="700">网络影院模式</text>
  <text x="684" y="120" class="t" font-size="11">本地 / 网盘文件 + 刮削</text>
  <text x="684" y="140" class="t" font-size="11">cinemaIndexes</text>
  <text x="684" y="160" class="t" font-size="11">CinemaLibraryView</text>
  <text x="684" y="178" class="t" font-size="11" fill="#a16207">状态：仅文件型</text>

  <rect x="884" y="72" width="216" height="116" rx="10" fill="#fff5f5" stroke="#e9a3a3" stroke-dasharray="6 4"/>
  <text x="900" y="98" class="t" font-size="14" font-weight="700">网络电视模式</text>
  <text x="900" y="120" class="t" font-size="11">直播源 / 频道 / EPG</text>
  <text x="900" y="140" class="t" font-size="11">无模型、无视图、无播放</text>
  <text x="900" y="160" class="t" font-size="11">M3U / XMLTV 均未出现</text>
  <text x="900" y="178" class="t" font-size="11" fill="#c0392b">状态：缺失</text>

  <!-- 统一外壳 -->
  <rect x="20" y="226" width="1080" height="118" rx="12" fill="#ffffff" stroke="#d8dce3"/>
  <text x="36" y="252" class="t" font-size="13" font-weight="700">统一外壳：新增模式必须经过的中心代码</text>

  <rect x="36" y="268" width="244" height="56" rx="8" fill="#fbfcfe" stroke="#e3e7ee"/>
  <text x="50" y="290" class="t" font-size="11" font-weight="600">SidebarItem</text>
  <text x="50" y="309" class="t" font-size="10" fill="#6b7280">60+ case 的扁平枚举</text>

  <rect x="296" y="268" width="244" height="56" rx="8" fill="#fbfcfe" stroke="#e3e7ee"/>
  <text x="310" y="290" class="t" font-size="11" font-weight="600">SidebarView</text>
  <text x="310" y="309" class="t" font-size="10" fill="#6b7280">云盘 / 资源分区硬编码</text>

  <rect x="556" y="268" width="244" height="56" rx="8" fill="#fbfcfe" stroke="#e3e7ee"/>
  <text x="570" y="290" class="t" font-size="11" font-weight="600">GalleryView</text>
  <text x="570" y="309" class="t" font-size="10" fill="#6b7280">40+ 分支的内容页 switch</text>

  <rect x="816" y="268" width="268" height="56" rx="8" fill="#fbfcfe" stroke="#e3e7ee"/>
  <text x="830" y="290" class="t" font-size="11" font-weight="600">sidebarTitle / 命令可用性</text>
  <text x="830" y="309" class="t" font-size="10" fill="#6b7280">标题、搜索、菜单各自 switch</text>

  <!-- 模式到外壳的箭头 -->
  <path d="M120,188 L120,226" class="line"/>
  <path d="M336,188 L336,226" class="line"/>
  <path d="M552,188 L552,226" class="line"/>
  <path d="M768,188 L768,226" class="line"/>
  <path d="M992,188 L992,226" class="redline"/>

  <!-- 共享内容层 -->
  <rect x="20" y="378" width="1080" height="100" rx="12" fill="#ffffff" stroke="#d8dce3"/>
  <text x="36" y="402" class="t" font-size="13" font-weight="700">共享内容与状态</text>

  <rect x="36" y="416" width="330" height="46" rx="8" fill="#f7f8fa" stroke="#e3e7ee"/>
  <text x="50" y="444" class="t" font-size="11">PhotoItem / MediaKind：跨模式复用的媒体项</text>

  <rect x="382" y="416" width="330" height="46" rx="8" fill="#f7f8fa" stroke="#e3e7ee"/>
  <text x="396" y="444" class="t" font-size="11">LibraryStore + CloudBrowserModel + CatalogBrowserModel</text>

  <rect x="728" y="416" width="356" height="46" rx="8" fill="#f7f8fa" stroke="#e3e7ee"/>
  <text x="742" y="444" class="t" font-size="11">持久化：主库 SQLite / catalog_* 表 / 设置 JSON</text>

  <path d="M552,344 L552,378" class="line"/>
  <path d="M552,478 L552,510" class="line"/>

  <!-- 播放层 -->
  <rect x="20" y="510" width="1080" height="94" rx="12" fill="#fffdf8" stroke="#ecd9b0"/>
  <text x="36" y="534" class="t" font-size="13" font-weight="700">播放层：VOD 假设 + 三分支解析</text>

  <rect x="36" y="546" width="300" height="42" rx="8" fill="#ffffff" stroke="#e8dcc4"/>
  <text x="50" y="572" class="t" font-size="11">PlaybackCore：时间轴 / 续播 / 片尾 / 预热</text>

  <rect x="352" y="546" width="390" height="42" rx="8" fill="#ffffff" stroke="#e8dcc4"/>
  <text x="366" y="572" class="t" font-size="11">VideoPlayback.resolveSource：本地 / 云盘 / 网络资源</text>

  <rect x="758" y="546" width="326" height="42" rx="8" fill="#ffffff" stroke="#e8dcc4"/>
  <text x="772" y="572" class="t" font-size="11">Player UI：进度条 / 续播 / 自动下一集</text>

  <text x="20" y="616" class="t" font-size="10" fill="#c0392b">红色虚线：电视模式没有任何现存落点；新增模式需同时改枚举、侧边栏、内容页、标题与命令。</text>
</svg>
```

### 1.3 关键扩展点与现状

| 扩展点 | 现状代码 | 评价 |
| --- | --- | --- |
| 侧边栏条目 | [Models.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/Models.swift#L458-L591) 的 `SidebarItem` | 60+ case，所有模式共用；新增模式必须改这里 |
| 内容页分发 | [GalleryView.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Gallery/GalleryView.swift#L1343-L1449) | 一个大 switch；新模式必须补分支 |
| 标题与范围判断 | [LibraryStore+Query.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Query.swift#L10-L110) | 标题 switch；`isCloudScope` 等布尔判断散落 |
| 导航 | [LibraryStore+Organize.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Organize.swift#L10-L29) | `navigate(to:)` 里硬编码云盘 / 资源的打开动作 |
| 侧边栏分区 | [SidebarView.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Sidebar/SidebarView.swift#L1311-L1447) | `cloudSection` / `catalogSection` 各自手写；电视需要再加一段 |
| 云盘状态 | [CloudBrowserModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/CloudBrowserModel.swift#L5-L44) | 已从 god object 拆出，方向正确 |
| 网络资源状态 | [CatalogBrowserModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/CatalogBrowserModel.swift#L9-L75) | 同上，且持久化与 UI 分离较好 |
| 站点适配器 | [CatalogClient.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Catalog/CatalogClient.swift#L14-L57) | 全仓最成熟的 provider 抽象，可直接作为电视模板 |
| 播放目标解析 | [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L2643-L2665) | 硬编码三分支，是最大耦合点 |
| 网络资源播放接入 | [LibraryStore+Catalog.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Catalog.swift#L84-L126) | 用虚拟 `PhotoItem` + 旁路字典接入查看器 |
| 影院刮削源 | [CinemaMetadataSource.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Cinema/CinemaMetadataSource.swift#L4-L13) | 小而清晰的协议，可继续复用 |
| 影院作用域 | [CinemaModels.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/CinemaModels.swift#L51-L54) | 只有 `local` / `mount`，与文件扫描强绑定 |
| 播放内核 | [PlaybackCore](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackSession.swift#L303-L355) | 无 SwiftUI 依赖，边界干净；缺直播模式 |

---

## 2. 框架是否合理

### 2.1 做对的地方

1. **播放内核与 UI 分离。**
   `PlaybackCore` 只依赖 Foundation / AVFoundation / AVKit，缓存目录、二进制路径、日志、进度都通过注入完成。这为新增直播模式提供了最低风险的改造面。

2. **站点适配器已经有可复制的协议。**
   `CatalogProvider` 把分类、首页、详情、搜索、分集直链、封面解密、排序能力收在一个协议里，13 个站点各自实现，界面层不感知具体站点。这是整个仓库里最值得复用的扩展模式。

3. **云盘与网络资源的状态模型已经从 `LibraryStore` 拆出。**
   `CloudBrowserModel`、`CatalogBrowserModel` 各自持有自己的加载、错误、缓存与任务，避免所有模式的状态继续堆进一个类。

4. **`PhotoItem` 承担了“跨模式可显示媒体项”的角色。**
   照片网格、查看器、右键菜单能同时服务本地、系统图库、云盘，说明这个模型在“静态媒体浏览”上成立。

5. **持久化已经有分层基础。**
   网络资源有 `CatalogDatabase`（主库里的 `catalog_*` 表）；云盘索引有 `cloud_index_*` 表；影院按作用域存设置 JSON。新增电视可以沿用这个分层，而不是再发明一套文件格式。

### 2.2 对影院与电视的具体阻碍

| # | 阻碍 | 代码证据 | 影响 | 优先级 |
| --- | --- | --- | --- | --- |
| 1 | 入口枚举与 4 处中心 switch | `SidebarItem`、`GalleryView`、`sidebarTitle`、命令可用性 | 每加一种模式都要改多处，容易漏分支 | P0 |
| 2 | 没有统一的“源”概念 | `CloudMount`、`CatalogSource`、`SystemLibraryRef` 各存各的 | 无法用一套界面/流程接入电视源与电影源 | P0 |
| 3 | 播放源解析硬编码 | `resolveSource` 三分支 | 电视直播会变成第四种分支，且无法测试 | P0 |
| 4 | 网络资源用虚拟 PhotoItem 旁路 | [LibraryStore+Catalog.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Catalog.swift#L84-L126) | 能跑，但语义错误；电视/影院若照抄会放大技术债 | P1 |
| 5 | 影院与文件扫描强绑定 | `CinemaScope` 仅 `local` / `mount`；`CinemaFile` 依赖 `photoID` 和云端字段 | 无法直接承载“电影网站条目” | P1 |
| 6 | 播放内核无直播语义 | `duration > 0` 才写进度、预热、跳片头片尾 | 直播能出画面，但进度条、续播、片尾行为都不对 | P0 |
| 7 | 侧边栏分区手写 | `cloudSection`、`catalogSection` | 电视要再加一段重复代码 | P1 |
| 8 | 持久化写法分散 | 云盘挂载在设置 JSON；资源在主库 `catalog_*`；影院按 scope 存 JSON | 电视源、频道、EPG 需要再选一套；不利于统一备份/清理 | P1 |
| 9 | 云盘能力用 switch 调度 | [CloudService](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Cloud/CloudProviders.swift#L914-L949) 的 `list/stream/delete` | 新增网盘类型要改多处；但当前 6 种足够稳定，不是最急 | P2 |
| 10 | 侧边栏/内容页缺少能力位 | 所有条目默认展示同一套工具栏与操作 | 电视频道页会看到“导出/编辑/评分”等无意义按钮 | P1 |

### 2.3 支持性判断

| 能力 | 图库 | 云盘 | 网络资源 | 网络影院（在线源） | 网络电视 |
| --- | --- | --- | --- | --- | --- |
| 侧边栏可加入口 | 已具备 | 已具备 | 已具备 | 已具备 | 需新增分区 |
| 内容展示 | 已具备 | 已具备 | 已具备 | 可复用海报墙 | 需频道列表 / 节目单 |
| 搜索 | 已具备 | 已具备 | 已具备 | 可复用 | 需频道名搜索 |
| VOD 播放 | 已具备 | 已具备 | 已具备 | 可复用 | 不适用 |
| 直播播放 | 不适用 | 不适用 | 不适用 | 不适用 | 缺失 |
| 播放进度 | 已具备 | 已具备 | 已具备 | 可复用 | 不适用（直播） |
| 元数据/海报缓存 | 已具备 | 已具备 | 已具备 | 可复用 | 需频道台标缓存 |
| 统一源管理 | 缺失 | 缺失 | 缺失 | 缺失 | 缺失 |

**判断：框架合理但不足以“低成本支持后两个模式”。** 不推翻现有实现，补三层抽象即可。

---

## 3. 可公共抽象清单

### 3.1 建议抽象的 9 个对象

| 抽象 | 当前对应物 | 共同点 | 建议 | 优先级 |
| --- | --- | --- | --- | --- |
| `SourceRecord` / `SourceDescriptor` | `CloudMount`、`CatalogSource`、`SystemLibraryRef`、未来的 `TVSource` | 都是“某个来源的配置 + 名称 + 类型 + 能力” | 统一注册、排序、启用、删除；配置体保留各自 Codable 负载 | P0 |
| `SourceCapabilities` | `CloudKind.supportsWrite`、`CatalogProvider.supportedSorts`、`CloudScope.usesDedicatedView` | 决定界面显示哪些入口/工具栏 | 用 OptionSet 描述 browse / search / vod / live / epg / write 等能力 | P0 |
| `PlaybackTarget` | `PhotoItem` + `CatalogPlaybackContext` + `CinemaPlaybackEntry` + 云盘 `cloudPath` | 播放器最终只需要“哪个源、哪一项、VOD 还是直播” | 播放器只认 `PlaybackTarget`，不再认具体业务模型 | P0 |
| `ResolvedStream` | `CatalogStream`、`CloudStreamResource`、本地 URL 三元组 | `url + headers + 容器 + 是否 HLS` | 统一解析结果；签名直链不落库 | P0 |
| `PlaybackMode` / `PlaybackCapabilities` | 无 | 区分 VOD 与 Live、是否可 seek、是否有下一集 | 放入 `PlaybackCore`，由播放器与 UI 共同消费 | P0 |
| `ContentCard` / `ContentDetail` / `ContentPage` | `CatalogItem`、`CinemaEntry`、频道条目 | 海报墙/详情页需要的展示字段 | 只做“展示适配层”，不替换领域模型 | P1 |
| `PlaybackProgressStore` | 影院设置 JSON + `catalog_progress` 表 + 查看记录 | 都是“源 + 条目 + 集 + 秒数” | 统一读写接口，按源分区；电视默认不写 | P1 |
| `SidebarSectionDescriptor` | `cloudSection` / `catalogSection` 手写 | 分区标题、入口、空态、排序 | 由源注册表生成侧边栏分区 | P1 |
| `RequestProfile` | `CatalogSource.userAgent/referer`、云盘 headers、SMB/TLS 设置 | 请求头、Referer、UA、自签证书 | 统一注入到播放器与下载器 | P1 |

### 3.2 抽象边界：哪些不要强推

| 对象 | 不建议统一的原因 | 建议做法 |
| --- | --- | --- |
| `PhotoItem` | 承载 EXIF、相簿、编辑、人物、连拍等照片语义；电视直播频道不需要 | 保留；新增 `ContentCard` 做展示适配 |
| `CinemaEntry` | 依赖 `CinemaFile` / `photoID` / 刮削结果；在线电影没有本地文件 | 保留；新增 `MovieProvider` 适配器，影院视图消费统一卡片 |
| `CatalogItem` | 站点条目字段少、天然适合列表；与照片语义不同 | 保留；通过 `CatalogMovieAdapter` 接入影院 |
| `CloudKind` switch | 6 种云盘已稳定，改协议收益有限 | P2 再考虑 `CloudDriveProvider`，先不阻塞电视/影院 |
| 动态插件加载 | macOS 应用内动态加载第三方代码有签名与安全成本 | 不做；源适配器编译期内置，配置外置 |

### 3.3 关键协议草图

以下只定义边界，不涉及具体实现。

```swift
// 1. 源的持久化描述：只描述“是什么”，不绑定具体能力实现。
struct SourceRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: SourceKind          // library / systemLibrary / cloudMount / catalogSite / movieFeed / iptv
    var name: String
    var payload: Data             // 各自的 Codable 配置（CloudMount / CatalogSource / TVSource）
    var isEnabled: Bool
    var sortIndex: Int
}

struct SourceCapabilities: OptionSet, Codable {
    let rawValue: Int
    static let browseTree   = SourceCapabilities(rawValue: 1 << 0)
    static let categories   = SourceCapabilities(rawValue: 1 << 1)
    static let search       = SourceCapabilities(rawValue: 1 << 2)
    static let vodPlayback  = SourceCapabilities(rawValue: 1 << 3)
    static let livePlayback = SourceCapabilities(rawValue: 1 << 4)
    static let epg          = SourceCapabilities(rawValue: 1 << 5)
    static let writeBack    = SourceCapabilities(rawValue: 1 << 6)
}

// 2. 播放目标：播放器唯一认识的输入。
struct PlaybackTarget: Identifiable, Hashable {
    enum Storage: Hashable {
        case localFile(URL)
        case remote(URL, RequestProfile)
        case provided(SourceID, itemID: String, episodeID: String?)
    }
    var id: UUID
    var storage: Storage
    var mode: PlaybackMode          // .vod / .live
    var title: String
    var artworkURL: String?
    var durationHint: Double?
    var capabilities: PlaybackCapabilities
}

// 3. 解析后的真实流：短时效，不落库。
struct ResolvedStream {
    var url: URL
    var headers: [String: String]
    var isHLS: Bool
    var mode: PlaybackMode
    var tlsTrust: Bool
}

protocol PlaybackResolving {
    func resolve(_ target: PlaybackTarget) async throws -> ResolvedStream
}

// 4. 播放模式进入内核，而不是只存在于 UI。
enum PlaybackMode { case vod, live }

struct PlaybackCapabilities: OptionSet {
    let rawValue: Int
    static let seek         = PlaybackCapabilities(rawValue: 1 << 0)
    static let nextEpisode  = PlaybackCapabilities(rawValue: 1 << 1)
    static let resume       = PlaybackCapabilities(rawValue: 1 << 2)
    static let subtitle     = PlaybackCapabilities(rawValue: 1 << 3)
    static let catchup      = PlaybackCapabilities(rawValue: 1 << 4)
}
```

内容源协议建议“小协议 + 能力位”，而不是再造一个巨型协议：

```swift
protocol BrowseProvider {
    func home(_ context: SourceContext) async throws -> ContentPage
    func collections(_ context: SourceContext) async throws -> [ContentCollection]
    func page(_ context: SourceContext,
              collection: ContentCollection.ID,
              cursor: PageCursor?) async throws -> ContentPage
    func detail(_ context: SourceContext, ref: ContentRef) async throws -> ContentDetail
    func search(_ context: SourceContext, query: String) async throws -> ContentPage
}

protocol EPGProvider {
    func channels(_ context: SourceContext) async throws -> [TVChannel]
    func programmes(_ context: SourceContext, from: Date, to: Date) async throws -> [EPGProgramme]
}
```

> 命名注意：现有 `CatalogProvider.channels` 指的是“站点二级分类”，不是电视频道。抽象时必须把两者分开（`collections` / `groups` 与 `channels`），否则后续阅读会持续混淆。

---

## 4. 目标架构

### 4.1 分层图

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 640" width="100%" role="img" aria-label="目标分层架构">
  <defs>
    <marker id="b1" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">
      <path d="M0,0 L0,6 L9,3 z" fill="#8a8f98"/>
    </marker>
    <style>
      .t { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; fill:#1d2129; }
      .m { fill:#6b7280; }
      .line { stroke:#8a8f98; stroke-width:1.2; fill:none; marker-end:url(#b1); }
    </style>
  </defs>

  <text x="24" y="30" class="t" font-size="19" font-weight="700">目标：源可注册、内容可归一、播放可分 VOD / Live</text>

  <!-- 入口层 -->
  <rect x="20" y="56" width="1080" height="64" rx="10" fill="#f7f9fd" stroke="#d7dff0"/>
  <text x="36" y="82" class="t" font-size="12" font-weight="700">入口层</text>
  <rect x="130" y="68" width="120" height="38" rx="7" fill="#fff" stroke="#e1e6ef"/><text x="158" y="92" class="t" font-size="11">图库</text>
  <rect x="262" y="68" width="140" height="38" rx="7" fill="#fff" stroke="#e1e6ef"/><text x="300" y="92" class="t" font-size="11">网络云盘</text>
  <rect x="414" y="68" width="140" height="38" rx="7" fill="#fff" stroke="#e1e6ef"/><text x="452" y="92" class="t" font-size="11">网络资源</text>
  <rect x="566" y="68" width="160" height="38" rx="7" fill="#fff" stroke="#e1e6ef"/><text x="604" y="92" class="t" font-size="11">网络影院</text>
  <rect x="738" y="68" width="160" height="38" rx="7" fill="#fff5f5" stroke="#e9a3a3" stroke-dasharray="5 3"/><text x="776" y="92" class="t" font-size="11">网络电视</text>
  <rect x="910" y="68" width="174" height="38" rx="7" fill="#fff" stroke="#e1e6ef"/><text x="930" y="92" class="t" font-size="11">侧边栏 / 全局搜索</text>

  <path d="M560,120 L560,146" class="line"/>

  <!-- 注册层 -->
  <rect x="20" y="146" width="1080" height="74" rx="10" fill="#f2f6ff" stroke="#bfd0f5"/>
  <text x="36" y="172" class="t" font-size="12" font-weight="700">源注册层</text>
  <rect x="150" y="156" width="230" height="48" rx="7" fill="#fff" stroke="#d7e2f7"/>
  <text x="166" y="176" class="t" font-size="11" font-weight="600">SourceRecord</text>
  <text x="166" y="194" class="t m" font-size="10">配置负载 + 启用 + 排序</text>
  <rect x="394" y="156" width="230" height="48" rx="7" fill="#fff" stroke="#d7e2f7"/>
  <text x="410" y="176" class="t" font-size="11" font-weight="600">SourceCapabilities</text>
  <text x="410" y="194" class="t m" font-size="10">决定入口、工具栏与播放能力</text>
  <rect x="638" y="156" width="230" height="48" rx="7" fill="#fff" stroke="#d7e2f7"/>
  <text x="654" y="176" class="t" font-size="11" font-weight="600">SourceRegistry</text>
  <text x="654" y="194" class="t m" font-size="10">kind + payload → Provider</text>
  <rect x="882" y="156" width="202" height="48" rx="7" fill="#fff" stroke="#d7e2f7"/>
  <text x="898" y="176" class="t" font-size="11" font-weight="600">SidebarSection</text>
  <text x="898" y="194" class="t m" font-size="10">分区由注册表生成</text>

  <path d="M560,220 L560,246" class="line"/>

  <!-- Provider 层 -->
  <rect x="20" y="246" width="1080" height="86" rx="10" fill="#f2fbf7" stroke="#b9e3cf"/>
  <text x="36" y="272" class="t" font-size="12" font-weight="700">Provider 层（编译期内置，配置外置）</text>
  <rect x="150" y="258" width="172" height="58" rx="7" fill="#fff" stroke="#cfe9dc"/>
  <text x="164" y="280" class="t" font-size="11" font-weight="600">LibrarySource</text>
  <text x="164" y="298" class="t m" font-size="10">本地 / 系统图库</text>
  <rect x="336" y="258" width="172" height="58" rx="7" fill="#fff" stroke="#cfe9dc"/>
  <text x="350" y="280" class="t" font-size="11" font-weight="600">CloudDriveSource</text>
  <text x="350" y="298" class="t m" font-size="10">SMB / WebDAV / 网盘</text>
  <rect x="522" y="258" width="172" height="58" rx="7" fill="#fff" stroke="#cfe9dc"/>
  <text x="536" y="280" class="t" font-size="11" font-weight="600">SiteCatalogSource</text>
  <text x="536" y="298" class="t m" font-size="10">现有 CatalogProvider</text>
  <rect x="708" y="258" width="172" height="58" rx="7" fill="#fff" stroke="#cfe9dc"/>
  <text x="722" y="280" class="t" font-size="11" font-weight="600">MovieFeedSource</text>
  <text x="722" y="298" class="t m" font-size="10">电影源 / JSON 片源</text>
  <rect x="894" y="258" width="190" height="58" rx="7" fill="#fff5f5" stroke="#e9a3a3"/>
  <text x="908" y="280" class="t" font-size="11" font-weight="600">IPTVSource（新增）</text>
  <text x="908" y="298" class="t m" font-size="10">M3U / Xtream / XMLTV</text>

  <path d="M560,332 L560,358" class="line"/>

  <!-- 内容层 -->
  <rect x="20" y="358" width="1080" height="78" rx="10" fill="#fff9f0" stroke="#f0d7ae"/>
  <text x="36" y="384" class="t" font-size="12" font-weight="700">归一化内容层</text>
  <rect x="150" y="368" width="190" height="52" rx="7" fill="#fff" stroke="#f0dfc2"/>
  <text x="164" y="390" class="t" font-size="11" font-weight="600">ContentPage / Card</text>
  <text x="164" y="408" class="t m" font-size="10">海报、标题、角标</text>
  <rect x="354" y="368" width="190" height="52" rx="7" fill="#fff" stroke="#f0dfc2"/>
  <text x="368" y="390" class="t" font-size="11" font-weight="600">ContentDetail</text>
  <text x="368" y="408" class="t m" font-size="10">简介、分集、播放选项</text>
  <rect x="558" y="368" width="190" height="52" rx="7" fill="#fff" stroke="#f0dfc2"/>
  <text x="572" y="390" class="t" font-size="11" font-weight="600">PlaybackTarget</text>
  <text x="572" y="408" class="t m" font-size="10">源 + 条目 + VOD/Live</text>
  <rect x="762" y="368" width="192" height="52" rx="7" fill="#fff" stroke="#f0dfc2"/>
  <text x="776" y="390" class="t" font-size="11" font-weight="600">TVChannel / EPG</text>
  <text x="776" y="408" class="t m" font-size="10">频道、分组、节目单</text>
  <rect x="968" y="368" width="116" height="52" rx="7" fill="#fff" stroke="#f0dfc2"/>
  <text x="982" y="390" class="t" font-size="11" font-weight="600">适配器</text>
  <text x="982" y="408" class="t m" font-size="10">旧模型 → 新模型</text>

  <path d="M560,436 L560,462" class="line"/>

  <!-- 播放层 -->
  <rect x="20" y="462" width="1080" height="80" rx="10" fill="#f8f4ff" stroke="#ddd0f2"/>
  <text x="36" y="488" class="t" font-size="12" font-weight="700">播放层</text>
  <rect x="150" y="472" width="250" height="54" rx="7" fill="#fff" stroke="#e4d9f3"/>
  <text x="164" y="494" class="t" font-size="11" font-weight="600">PlaybackResolver</text>
  <text x="164" y="512" class="t m" font-size="10">本地 / 云端 / provider 统一解析</text>
  <rect x="414" y="472" width="250" height="54" rx="7" fill="#fff" stroke="#e4d9f3"/>
  <text x="428" y="494" class="t" font-size="11" font-weight="600">PlaybackCore</text>
  <text x="428" y="512" class="t m" font-size="10">VOD：时间轴 / 续播 / 下一集</text>
  <rect x="678" y="472" width="210" height="54" rx="7" fill="#fff" stroke="#e4d9f3"/>
  <text x="692" y="494" class="t" font-size="11" font-weight="600">Live Mode</text>
  <text x="692" y="512" class="t m" font-size="10">直播沿 / 重连 / 失败切换</text>
  <rect x="902" y="472" width="182" height="54" rx="7" fill="#fff" stroke="#e4d9f3"/>
  <text x="916" y="494" class="t" font-size="11" font-weight="600">Player UI</text>
  <text x="916" y="512" class="t m" font-size="10">按能力隐藏控件</text>

  <path d="M560,542 L560,568" class="line"/>

  <!-- 存储层 -->
  <rect x="20" y="568" width="1080" height="56" rx="10" fill="#ffffff" stroke="#d8dce3"/>
  <text x="36" y="600" class="t" font-size="12" font-weight="700">存储层</text>
  <text x="150" y="600" class="t" font-size="11">SourceStore（源与配置）</text>
  <text x="380" y="600" class="t" font-size="11">PlaybackProgressStore（按源分区）</text>
  <text x="650" y="600" class="t" font-size="11">ArtworkCache（海报 / 台标）</text>
  <text x="870" y="600" class="t" font-size="11">EPGCache（带过期）</text>
</svg>
```

### 4.2 设计要点

1. **源注册表只负责“有哪些源”，不负责“源怎么工作”。**
   `SourceRecord` 是持久化 DTO；`SourceRegistry` 根据 `kind + payload` 构造运行时 Provider。这样侧边栏、全局搜索、设置页都能用同一份源列表。

2. **播放器只接受 `PlaybackTarget`。**
   本地文件、云盘直链、站点分集、直播频道都归一成“目标 + 懒解析”。播放器不再知道 `CatalogPlaybackContext` 或 `photo.isCloud`。

3. **短时效直链在解析层解决，不进入持久化。**
   现有网络资源已经遵循“播放地址不落盘”，抽象后继续保持；缓存只存海报、元数据、进度与 EPG。

4. **能力位驱动界面，而不是模式枚举驱动界面。**
   电视频道页不出现“编辑照片/评分/导出”的原因，是它的源能力里没有 `writeBack`、`vodPlayback`，而不是在视图里再写 `if sidebarItem == .tv`。

5. **旧模型做适配器，不强行重写。**
   `CinemaEntry → ContentCard`、`CatalogItem → ContentCard`、`PhotoItem → ContentCard`。影院和资源页可以逐步迁移，避免一次性改动 3000 行视图。

---

## 5. 网络影院方案

### 5.1 当前边界

现有影院的数据流是：

```text
本地目录 / 网盘索引 → 视频文件候选 → 文件名解析 → TMDB / 豆瓣 / TVDB 刮削 → CinemaEntry → CinemaLibraryView → 查看器播放
```

证据：

- 影院作用域只有 `local` 与 `mount(UUID)`，见 [CinemaModels.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/CinemaModels.swift#L51-L54)。
- 影院条目必须带 `CinemaFile`（含 `photoID`、云盘挂载 ID、云路径），见 [CinemaModels.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/CinemaModels.swift#L525-L649)。
- 影院索引按作用域存在设置 JSON 中，见 [LibraryStore+Cinema.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Cinema.swift#L79-L139)。

因此，**“电影网站/电影源”不是现有影院的自然扩展，而是第二类内容来源**。

### 5.2 需要区分的两类电影源

| 类型 | 提供什么 | 播放来自哪里 | 例子 |
| --- | --- | --- | --- |
| 片库型（已有） | 本地 / 网盘视频文件 | 文件本身 | 本地影院、网盘影院 |
| 元数据型 | 海报、简介、年份、评分、演职员 | 本地 / 网盘文件 | TMDB、豆瓣、TVDB |
| 站点型（新增） | 条目列表、详情、分集、播放页 | 站点直链 | 现有网络资源站点 |
| 片源配置型（新增） | JSON 片源、分类、播放列表 | 配置内的直链或解析规则 | TVBox / FongMi 风格配置 |
| 混合型 | 元数据来自 A，播放来自 B | 网盘 / 本地 / 站点 | “豆瓣想看 + 网盘已有文件” |

**关键设计：把“元数据来源”和“播放来源”拆开。** 同一部电影可以元数据来自 TMDB、播放来自网盘；也可以全部来自一个站点。否则“电影源”会被错误地等同于“播放源”。

### 5.3 建议模型

```swift
struct MovieShelf: Identifiable {
    var id: String
    var title: String
    var kind: ShelfKind          // 最近添加 / 继续观看 / 分类 / 榜单
}

struct MovieCard: Identifiable, Hashable {
    var ref: ContentRef          // sourceID + itemID
    var title: String
    var year: Int?
    var posterURL: String?
    var rating: Double?
    var badges: [String]         // 4K / HDR / 已看 / 更新中
}

struct MovieDetail {
    var card: MovieCard
    var overview: String?
    var facts: [(String, String)]
    var episodes: [MovieEpisode]
    var playbackOptions: [MoviePlaybackOption]
}

struct MoviePlaybackOption {
    var title: String            // “网盘原片”“站点线路 1”
    var target: PlaybackTarget
}
```

协议：

```swift
protocol MovieProvider {
    var descriptor: SourceDescriptor { get }
    func shelves(_ context: SourceContext) async throws -> [MovieShelf]
    func page(_ context: SourceContext, shelf: String, cursor: PageCursor?) async throws -> ContentPage
    func detail(_ context: SourceContext, ref: ContentRef) async throws -> MovieDetail
    func search(_ context: SourceContext, query: String) async throws -> ContentPage
}
```

适配器：

- `LocalCinemaMovieProvider`：把现有 `cinemaIndexes` 包装成货架与卡片，不改刮削逻辑。
- `CloudCinemaMovieProvider`：按网盘挂载包装现有云端影院。
- `CatalogMovieProvider`：复用 `CatalogProvider`，把分类/首页/详情/分集映射成电影货架。
- `JSONFeedMovieProvider`：读取片源配置，生成分类与播放地址。
- `MetadataOnlyMovieProvider`：只提供元数据，播放选项由网盘/本地匹配结果补齐。

### 5.4 与现有影院的整合方式

推荐：

1. `CinemaLibraryView` 的数据来源改成一个 `MovieLibraryModel`，内部按当前选择聚合多个 `MovieProvider`。
2. `CinemaScope` 扩展为 `local` / `mount(UUID)` / `online(SourceID)`，或进一步改成 `CinemaScopeID`，避免每加一种就改枚举。
3. 现有 `CinemaEntry` 保留，作为本地/网盘的适配结果；在线条目不再伪造 `CinemaFile`。
4. 详情页统一展示“播放线路”：网盘原片、站点线路、本地文件，一个电影多个来源时让用户选。

不推荐：

- 把在线条目塞进 `CinemaFile`（`photoID`、`cloudMountID` 都无意义）。
- 再复制一份 `CinemaEntry` 给在线源（会出现两套详情、两套进度、两套海报缓存）。
- 直接让影院页依赖 `CatalogBrowserModel`（会把两个模式的状态耦合在一起）。

### 5.5 风险

| 风险 | 说明 | 处理 |
| --- | --- | --- |
| 站点结构变化 | HTML 解析随时可能失效 | 沿用 `CatalogProvider` 的错误分类与快照兜底 |
| 播放地址短时效 | 直链会过期 | 每次播放前懒解析，不落库 |
| 同一电影多源重复 | 站点、网盘、本地各一份 | 用 `imdbID / tmdbID / doubanID / title+year` 生成 `MovieIdentityKey`，聚合“播放线路” |
| 元数据冲突 | 站点标题与 TMDB 不一致 | 元数据源优先级可配置；保留原始标题 |
| 版权与内容合规 | 第三方站点内容由用户配置 | 沿用现有网络资源的“用户显式启用”策略，不做内置推荐 |

---

## 6. 网络电视方案

### 6.1 输入源

| 输入 | 说明 | 解析器 |
| --- | --- | --- |
| M3U / M3U8 播放列表 | 最常见直播源格式，含 `#EXTINF`、`group-title`、`tvg-id`、`tvg-logo` | `M3UPlaylistParser` |
| 本地 M3U 文件 | 用户下载的播放列表 | 同上 |
| Xtream Codes | 账号 + 密码换取频道与 EPG | `XtreamProvider`（可选） |
| XMLTV | 节目单，按 `tvg-id` 对齐频道 | `XMLTVParser` |
| 单频道直链 | 用户手动添加一个 HLS / FLV 地址 | `SingleChannelProvider` |

M3U 解析需要保留：

- `tvg-id`：EPG 对齐键；缺失时用 `name + url` 的稳定哈希。
- `group-title`：频道分组（央视 / 卫视 / 地方 / 体育 / 电影…）。
- `tvg-logo`：台标，进入图片缓存。
- 同名频道多线路：同一 `tvg-id` 下保留多个 URL，播放失败时切换。
- `#EXTVLCOPT` / `#KODIPROP`：UA、Referer、Cookie 等请求头。

### 6.2 数据模型

```swift
struct TVSource: Codable, Identifiable {
    var id: UUID
    var name: String
    var playlistURL: String?
    var playlistPath: String?
    var epgURL: String?
    var requestProfile: RequestProfile
    var isEnabled: Bool
}

struct TVChannel: Identifiable, Hashable {
    var id: String              // tvg-id 优先；否则稳定哈希
    var name: String
    var group: String?
    var logoURL: String?
    var streamURLs: [String]    // 多线路，按顺序失败切换
    var catchup: String?        // 回看模板（可选）
}

struct EPGProgramme: Identifiable, Hashable {
    var channelID: String
    var title: String
    var start: Date
    var end: Date
    var description: String?
}
```

### 6.3 播放链路

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 480" width="100%" role="img" aria-label="网络电视数据与播放链路">
  <defs>
    <marker id="c1" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">
      <path d="M0,0 L0,6 L9,3 z" fill="#8a8f98"/>
    </marker>
    <marker id="c2" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">
      <path d="M0,0 L0,6 L9,3 z" fill="#d9534f"/>
    </marker>
    <style>
      .t { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; fill:#1d2129; }
      .m { fill:#6b7280; }
      .line { stroke:#8a8f98; stroke-width:1.3; fill:none; marker-end:url(#c1); }
      .red { stroke:#d9534f; stroke-width:1.3; fill:none; stroke-dasharray:5 4; marker-end:url(#c2); }
    </style>
  </defs>

  <text x="24" y="30" class="t" font-size="18" font-weight="700">网络电视：从播放列表到直播画面</text>

  <!-- 数据源 -->
  <rect x="20" y="58" width="200" height="96" rx="9" fill="#fff5f5" stroke="#e9a3a3"/>
  <text x="34" y="82" class="t" font-size="12" font-weight="700">直播源</text>
  <text x="34" y="104" class="t" font-size="10">M3U / M3U8 URL</text>
  <text x="34" y="122" class="t" font-size="10">本地 M3U 文件</text>
  <text x="34" y="140" class="t" font-size="10">Xtream Codes（可选）</text>

  <rect x="20" y="178" width="200" height="72" rx="9" fill="#f7f9fd" stroke="#d7dff0"/>
  <text x="34" y="202" class="t" font-size="12" font-weight="700">节目单</text>
  <text x="34" y="224" class="t" font-size="10">XMLTV URL / 文件</text>
  <text x="34" y="242" class="t" font-size="10">按 tvg-id 对齐频道</text>

  <!-- 解析层 -->
  <rect x="270" y="58" width="200" height="96" rx="9" fill="#ffffff" stroke="#d8dce3"/>
  <text x="284" y="82" class="t" font-size="12" font-weight="700">M3UPlaylistParser</text>
  <text x="284" y="104" class="t" font-size="10">分组 / 台标 / 线路</text>
  <text x="284" y="122" class="t" font-size="10">请求头 / 多 URL</text>
  <text x="284" y="140" class="t" font-size="10">稳定频道 ID</text>

  <rect x="270" y="178" width="200" height="72" rx="9" fill="#ffffff" stroke="#d8dce3"/>
  <text x="284" y="202" class="t" font-size="12" font-weight="700">XMLTVParser</text>
  <text x="284" y="224" class="t" font-size="10">节目开始 / 结束</text>
  <text x="284" y="242" class="t" font-size="10">标题 / 简介</text>

  <path d="M220,106 L270,106" class="line"/>
  <path d="M220,214 L270,214" class="line"/>

  <!-- 存储与状态 -->
  <rect x="520" y="58" width="220" height="192" rx="9" fill="#f2fbf7" stroke="#b9e3cf"/>
  <text x="534" y="82" class="t" font-size="12" font-weight="700">TVSourceStore / EPGStore</text>
  <text x="534" y="106" class="t" font-size="10">频道与分组缓存</text>
  <text x="534" y="126" class="t" font-size="10">节目单缓存（带过期）</text>
  <text x="534" y="146" class="t" font-size="10">收藏 / 最近观看</text>
  <text x="534" y="166" class="t" font-size="10">台标图片缓存</text>
  <text x="534" y="192" class="t m" font-size="10">不写入 assets / cloud_index</text>
  <text x="534" y="210" class="t m" font-size="10">凭据放 Keychain</text>
  <text x="534" y="232" class="t m" font-size="10">URL 中的 token 不写日志</text>

  <path d="M470,106 L520,106" class="line"/>
  <path d="M470,214 L520,214" class="line"/>

  <!-- 视图 -->
  <rect x="790" y="58" width="310" height="192" rx="9" fill="#fff9f0" stroke="#f0d7ae"/>
  <text x="804" y="82" class="t" font-size="12" font-weight="700">TVBrowserModel + 频道视图</text>
  <text x="804" y="106" class="t" font-size="10">按分组懒加载频道</text>
  <text x="804" y="126" class="t" font-size="10">现在 / 下一档节目</text>
  <text x="804" y="146" class="t" font-size="10">收藏、最近、频道号</text>
  <text x="804" y="166" class="t" font-size="10">键盘上下切台、全屏电视墙</text>
  <text x="804" y="192" class="t m" font-size="10">能力位控制：无编辑 / 无评分 / 无导出</text>

  <path d="M740,154 L790,154" class="line"/>

  <!-- 播放解析 -->
  <rect x="520" y="286" width="580" height="82" rx="9" fill="#f8f4ff" stroke="#ddd0f2"/>
  <text x="534" y="310" class="t" font-size="12" font-weight="700">StreamResolver</text>
  <text x="534" y="332" class="t" font-size="10">线路失败切换：同一频道多个 URL 依次尝试</text>
  <text x="534" y="350" class="t" font-size="10">请求头 / Referer / UA / 自签证书</text>

  <rect x="270" y="286" width="200" height="82" rx="9" fill="#ffffff" stroke="#d8dce3"/>
  <text x="284" y="310" class="t" font-size="12" font-weight="700">协议分流</text>
  <text x="284" y="332" class="t" font-size="10">HLS：AVPlayer 直连</text>
  <text x="284" y="350" class="t" font-size="10">FLV / TS / RTMP：ffmpeg</text>

  <path d="M520,326 L470,326" class="line"/>
  <path d="M790,250 L700,286" class="line"/>

  <!-- 播放 -->
  <rect x="20" y="286" width="200" height="82" rx="9" fill="#fffdf8" stroke="#ecd9b0"/>
  <text x="34" y="310" class="t" font-size="12" font-weight="700">PlaybackCore · Live</text>
  <text x="34" y="332" class="t" font-size="10">无时长 / 无续播 / 无片尾</text>
  <text x="34" y="350" class="t" font-size="10">重连 / 缓冲 / 直播沿</text>

  <path d="M270,326 L220,326" class="line"/>

  <!-- UI -->
  <rect x="20" y="402" width="1080" height="54" rx="9" fill="#ffffff" stroke="#d8dce3"/>
  <text x="34" y="426" class="t" font-size="12" font-weight="700">播放器 UI</text>
  <text x="140" y="426" class="t" font-size="11">LIVE 标识</text>
  <text x="260" y="426" class="t" font-size="11">隐藏进度条 / 续播 / 下一集</text>
  <text x="520" y="426" class="t" font-size="11">频道上下切换</text>
  <text x="690" y="426" class="t" font-size="11">EPG 当前节目浮层</text>
  <text x="880" y="426" class="t" font-size="11">失败提示与重试</text>

  <path d="M120,368 L120,402" class="line"/>
  <path d="M560,368 L560,402" class="red"/>
</svg>
```

### 6.4 协议支持矩阵

| 协议 | AVPlayer 原生 | 现有能力 | 结论 |
| --- | --- | --- | --- |
| HLS（m3u8） | 支持，含直播 | 已有 HLS 直连分支，见 [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L2333-L2360) | 可直接用于电视 MVP |
| HTTP-FLV | 不支持 | 有 ffmpeg 与 VOD 转封装 | 需新增“直播复用到本地 HLS”会话 |
| MPEG-TS（HTTP） | 不支持 | 有 ffmpeg 与 VOD 转封装 | 同上 |
| RTMP | 不支持 | 无 | ffmpeg 拉流后转 HLS |
| RTSP | 不支持 | 无 | ffmpeg 拉流后转 HLS |
| UDP / 组播 | 不支持 | 无 | ffmpeg 拉流后转 HLS，需网络权限与超时策略 |
| DRM（FairPlay / Widevine） | 部分 | 无 | 不做；电视源先按无 DRM 处理 |

**结论：电视 MVP 只支持 HLS 即可先上线。** FLV/TS/RTMP 作为第二阶段，用新的 `LiveRemuxSession` 处理；不要复用 VOD 的 `VideoStreamSession` 参数模型（它的 `StreamRequest` 以起止秒数为核心，见 [StreamPlanner.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/StreamPlanner.swift#L12-L102)）。

### 6.5 播放内核的最小改造

| 改造 | 目的 | 影响面 |
| --- | --- | --- |
| `PlaybackMode` 进入 `VideoPlayerModel.load` / `PlaybackSession` | 区分 VOD 与 Live | 内核 API 增参，默认 `.vod`，旧调用不变 |
| `VideoPlayerModel.isLive` | UI 隐藏进度条、续播、下一集 | Player UI 读一个布尔值 |
| `PlaybackSession` 直播分支 | 跳过续播、片头片尾、剩余 5 分钟预热、进度写回 | 只在 `duration <= 0` 或 `mode == .live` 时走 |
| 重连策略 | 直播断流自动重试、线路切换 | 新增 `LiveRetryPolicy`，不影响 VOD |
| 直播沿 | 只保留“回到直播”按钮 | UI 可选，MVP 可不做 |
| `LiveRemuxSession`（P1.5） | FLV / TS / RTMP 转本地 HLS | 新增文件，不改 VOD 会话 |

### 6.6 界面与性能

- 侧边栏新增“网络电视”分区：源列表 → 分组 → 频道。不要把频道直接铺平（几千个频道会拖慢侧边栏）。
- 频道列表用 `LazyVStack`；分组默认收起；台标懒加载并落图片缓存。
- 节目单只在展开分组或打开频道时加载，按 `tvg-id` 建索引；不要在主线程解析几十 MB 的 XMLTV。
- 频道搜索只搜名称、分组、别名，不搜节目单。
- 播放页：上下键切台、回车全屏、Esc 退出；不显示评分、编辑、导出、添加到相簿等照片操作。
- 收藏与最近：只记录频道 ID 与时间，不需要播放进度；重看直播不续播。

### 6.7 存储与安全

| 数据 | 位置 | 说明 |
| --- | --- | --- |
| 电视源配置 | 主库新增 `tv_sources` 表或 `SourceStore` 的 `tv` 分区 | 与云盘/资源一起进入图库备份 |
| 频道缓存 | `tv_channels`（可按源 + 版本失效） | 播放列表更新后替换 |
| 节目单缓存 | `tv_epg`（按频道 + 日期） | 带 `expiresAt`，过期重拉 |
| 台标 | 图片缓存目录 | 按 URL 哈希，LRU 淘汰 |
| 账号密码 / token | Keychain | 严禁写 UserDefaults 或日志 |
| 播放 URL | 不落库 | 含 token 的 URL 只在内存中存在 |

---

## 7. 落地路线

### P0：底座（不改现有界面行为）

| 工作项 | 产出 | 涉及文件 |
| --- | --- | --- |
| 播放目标与解析器 | `PlaybackTarget`、`ResolvedStream`、`PlaybackResolver` | 新增 `Sources/PhotosClone/Domain/PlaybackTarget.swift` 等 |
| 播放模式 | `PlaybackMode` 进入内核与播放器 | `Sources/PlaybackCore/PlaybackSession.swift`、`VideoPlayerModel.swift` |
| 源描述与注册表骨架 | `SourceRecord`、`SourceKind`、`SourceRegistry` | 新增 `Sources/PhotosClone/Domain/MediaSource.swift` |
| 现有链路适配 | 本地 / 云盘 / 网络资源继续走原实现，但输出统一 `ResolvedStream` | `VideoPlayback.resolveSource`、`LibraryStore+Catalog`、`LibraryStore+Cloud` |
| 侧边栏描述符（可选） | 先给云盘/资源分区套一层描述结构 | `SidebarView` |

**退出标准：** 现有三种模式的浏览、播放、续看行为不变；`resolveSource` 不再直接分支到业务模型。

### P1：网络电视 MVP

| 工作项 | 产出 |
| --- | --- |
| TV 领域模型 | `TVSource`、`TVChannel`、`EPGProgramme` |
| M3U 解析 | URL / 本地文件、分组、台标、多线路、请求头 |
| 直播播放 | HLS 直连 + `PlaybackMode.live` + 重连 |
| 电视浏览 | 源列表、分组、频道列表、搜索、收藏、最近 |
| 侧边栏 | 新增“网络电视”分区，由源注册表生成 |
| 存储 | `tv_sources` / `tv_channels`，Keychain 存凭据 |

**退出标准：** 导入一个 M3U 源，能按分组浏览 1000+ 频道、播放 HLS、切换频道、重启后保留源与收藏；播放页不出现照片操作。

### P1.5：EPG 与更多协议

- XMLTV 节目单、现在/下一档、频道节目单浮层。
- `LiveRemuxSession`：HTTP-FLV / TS / RTMP 转本地 HLS。
- 线路失败自动切换与重连提示。

### P2：在线影院

| 工作项 | 产出 |
| --- | --- |
| 影院统一模型 | `MovieCard`、`MovieDetail`、`MoviePlaybackOption` |
| 适配器 | 本地影院、网盘影院、`CatalogProvider`、JSON 片源 |
| 影院作用域 | `CinemaScope` 支持在线源 |
| 详情整合 | 一个电影多条播放线路；去重键 |
| 进度统一 | 影院/站点/网盘共用 `PlaybackProgressStore` |

**退出标准：** 同一部电影可以来自站点或网盘；详情页可选线路；影院页不伪造 `CinemaFile`；进度与续看正常。

### P3：收敛（可选）

- 侧边栏从 `SidebarItem` 大枚举迁移到 `Mode + SourceScope + CollectionScope`。
- 云盘 `CloudService` switch 收敛为 `CloudDriveProvider`。
- 资源/影院/电视共用源设置向导外壳。
- 统一海报/台标图片缓存协议。

---

## 8. 验收与反模式

### 8.1 架构验收

1. 新增一种“内容源类型”时，`GalleryView`、`sidebarTitle`、命令可用性三处**不需要新增分支**。
2. `VideoPlayback` 不再出现 `catalogPlaybackContext` / `photo.isCloud` / 本地文件三分支，只调用一次 `resolve`。
3. 电视直播播放时，进度条、续播、片尾、自动下一集、字幕自动匹配全部不出现。
4. 任何源的签名直链都不会进入数据库或日志。
5. 现有网络资源的 13 个站点无需改动业务代码即可继续工作。

### 8.2 明确不做

- 不把直播频道塞进 `PhotoItem`。
- 不为在线影院复制一套 `CinemaEntry`。
- 不做动态插件加载与远程代码执行。
- 不做 DRM（FairPlay / Widevine）破解或绕过。
- 不为了“统一”重写 `CinemaLibraryView`、`CatalogChannelView` 的视觉层。

---

## 9. 附录：代码索引

| 主题 | 位置 |
| --- | --- |
| 模式枚举 | [Models.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/Models.swift#L458-L591) |
| 照片/视频统一模型 | [Models.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/Models.swift#L126-L299) |
| 内容页分发 | [GalleryView.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Gallery/GalleryView.swift#L1343-L1449) |
| 标题与范围 | [LibraryStore+Query.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Query.swift#L10-L110) |
| 导航动作 | [LibraryStore+Organize.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Organize.swift#L10-L29) |
| 云盘状态 | [CloudBrowserModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/CloudBrowserModel.swift#L5-L44) |
| 云盘统一调度 | [CloudProviders.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Cloud/CloudProviders.swift#L914-L949) |
| 云盘扫描 | [CloudScanner.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Cloud/CloudScanner.swift#L5-L59) |
| 网络资源状态 | [CatalogBrowserModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/CatalogBrowserModel.swift#L9-L75) |
| 站点协议 | [CatalogClient.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Catalog/CatalogClient.swift#L14-L57) |
| 站点工厂 | [CatalogClient.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Catalog/CatalogClient.swift#L59-L96) |
| 资源条目与直链 | [CatalogModels.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/CatalogModels.swift#L160-L285) |
| 资源持久化 | [CatalogStore.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Catalog/CatalogStore.swift#L1-L34) |
| 资源播放接入 | [LibraryStore+Catalog.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Catalog.swift#L84-L126) |
| 影院作用域 | [CinemaModels.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/CinemaModels.swift#L51-L54) |
| 影院条目 | [CinemaModels.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/CinemaModels.swift#L525-L649) |
| 影院刮削协议 | [CinemaMetadataSource.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Cinema/CinemaMetadataSource.swift#L4-L13) |
| 影院索引与作用域 | [LibraryStore+Cinema.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Cinema.swift#L79-L139) |
| 播放源解析 | [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L2643-L2665) |
| HLS 直连 | [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L2333-L2360) |
| 播放钩子 | [LibraryStore+PlaybackHooks.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+PlaybackHooks.swift#L1-L101) |
| 播放进度与片尾 | [PlaybackSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackSession.swift#L303-L355) |
| VOD 转封装参数 | [StreamPlanner.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/StreamPlanner.swift#L12-L102) |
| 侧边栏网络分区 | [SidebarView.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Sidebar/SidebarView.swift#L1311-L1447) |
| 云/资源模型注入 | [PhotosCloneApp.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/App/PhotosCloneApp.swift#L48-L59) |
