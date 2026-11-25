# 拾光 Luma · 代码开发文档

> 本文按**当前仓库的真实目录与常量**编写，文中每个文件名、表名、阈值都能在源码里直接核对。
> 规范类硬约束以 [AGENTS.md](../AGENTS.md) 为准；本文负责「地图 + 机制」，AGENTS.md 负责「规矩 + 边界」。
> 两者冲突时以 AGENTS.md 为准，并在同一次改动里同步两份。

---

## 0. 先看这里：这份文档怎么用

| 你想做的事 | 看哪一节 |
| --- | --- |
| 找某个界面的代码 | §4 目录清册 → `Features/<模块>/` |
| 找某个状态 / 方法 | §4.6 `Store/` + §6 状态与数据流 |
| 新增一张表、一次查询 | §8 数据层 + §9 分页常量 |
| 改搜索 | §10 搜索 |
| 改播放器 | §14 播放内核 |
| 打包 / 签名 / 排查构建 | §18 构建与发布 + §21 排错 |

**同步规则**：新增或移动文件后，必须同时更新 §4 清册与 AGENTS.md 的「文件职责」表；否则下一个人（或 Agent）会照着过期路径找你根本不存在的东西。这是本项目最容易被忽略的一条。

---

## 1. 硬约束

- Swift 5.9 / SwiftPM，最低 **macOS 14**，零第三方依赖。
- 链接的系统库只有三个：`libsqlite3`、`NetFS`、`Photos`（见 `Package.swift` 的 `linkerSettings`）。
- UI 全部 SwiftUI；只有需要系统面板或图片桥接时才 `import AppKit`（`NSOpenPanel` / `NSSavePanel` / `NSWorkspace` / `NSImage`）。
- 不使用 `.xcassets`。图标是 `Resources/AppIcon.icns`，源图 `Resources/icon_1024.png`，由 `Tools/make_icon.swift` 生成后 `iconutil` 打包。
- 界面文案与代码注释统一简体中文。
- 产物固定为仓库根目录 `Luma.app`（可执行文件 `Luma`，bundle id `com.baymax.luma`，显示名「拾光」）。
- `LumaCore` / `PlaybackCore` / `LumaContentCore` 三个库**不得** import SwiftUI / AppKit。

---

## 2. 仓库根清单（实际）

```
photos/
├── Package.swift              # 6 个 target，唯一产物 Luma
├── build.sh                   # 组装 Luma.app（支持 preview / PACKAGE / NOTARIZE）
├── README.md                  # 对外的产品介绍
├── AGENTS.md                  # 开发规范（硬约束、文件职责、权限矩阵、行数上限）
├── CHANGELOG.md
├── .gitignore
├── Resources/                 # 随包资源，见 §2.1
├── Sources/                   # 四个 target 的源码，见 §4
├── Tests/                     # 两个可执行断言 target
├── Tools/                     # 构建 / 素材 / 资料库脚本，见 §2.2
├── Vendor/                    # 构建时下载的 ffmpeg，不入库
├── docs/                      # 本文档 + 产品 / UI 文档 + 设计底稿
├── website/                   # 官网与手册（index.html / manual.html + PDF）
├── Luma.app                   # 构建产物
└── Luma-2.0.0-macOS-dev.zip   # 本地开发包，不是源码的一部分
```

### 2.1 `Resources/`

| 路径 | 内容 |
| --- | --- |
| `Info.plist` | bundle 元信息：`com.baymax.luma`、显示名「拾光」、`LSMinimumSystemVersion 14.0`、`photoslibrary` 文档类型、相册 / 局域网权限说明 |
| `AppIcon.icns` · `icon_1024.png` | 应用图标 |
| `Luma.entitlements` | 正式签名用的权限（仅 `CODESIGN_IDENTITY` 分支使用） |
| `PrivacyInfo.xcprivacy` | 隐私清单 |
| `CloudIcons/` | `aliyun.png` `baidu.png` `quark.png` `pan115.png`，网盘品牌图标 |
| `Catalog/catalog.sqlite` | 内置资料库：演员 / 片商 / 标签 / 头像，详情页与标题识别直接读，不联网 |
| `Models/YOLO11n/` | Core ML 目标检测模型 |
| `Models/Places/world-cities.json` | 离线城市库 |
| `Models/SigLIP2Assets/` | 场景识别的文本塔与词表（tokenizer 三个 bin + `tags.json` + `tag_embeddings.bin`） |
| `Models/manifest.json` · `NOTICE.txt` | 模型清单与许可 |
| `NSFW.mlmodel` · `NSFW-LICENSE.txt` | 内容分级模型与其许可 |

### 2.2 `Tools/`

| 文件 | 用途 |
| --- | --- |
| `catalog_build/` | 资料库流水线：`fetch_*.py` 抓取、`build_*.py` 归一化、`build_catalog_db.py` 生成 `Resources/Catalog/catalog.sqlite`、`t2s.swift` 简繁转换 |
| `make_icon.swift` | 画 1024 图标 |
| `brand_hero_gif.py` | 生成 README 顶部的品牌动图 `docs/assets/brand-hero.gif` |
| `bundle_ffmpeg.py` | 整理 ffmpeg 运行时依赖 |
| `make_vendor_runtime.sh` | 从本机 Homebrew 生成 `Vendor/ffmpeg-dv`（ffmpeg-full + libplacebo + MoltenVK + 全部 dylib） |
| `avplayer_probe.swift` · `media_matrix.py` | 片源能力探测与媒体矩阵实验 |
| `playback_log_report.py` | 播放日志归因报告 |
| `quick_app.sh` | 快速重启辅助脚本 |

`Vendor/` 下的 `ffmpeg/`、`ffmpeg-dv/` 都是 `build.sh` 现场生成或下载的，不进版本库。

---

## 3. 六个 target

`Package.swift` 只有 1 个 product（`Luma` 可执行文件），另外 2 个是可执行检查器。

| target | 类型 | 路径 | 依赖 | 备注 |
| --- | --- | --- | --- | --- |
| `Luma` | executable | `Sources/Luma` | `LumaCore` `PlaybackCore` `LumaContentCore` | 链接 sqlite3 / NetFS / Photos |
| `LumaCore` | library | `Sources/LumaCore` | — | 纯算法，无 UI、无 IO |
| `PlaybackCore` | library | `Sources/PlaybackCore` | — | 仅 Foundation + AVFoundation + AVKit |
| `LumaContentCore` | library | `Sources/LumaContentCore` | `LumaCore` `PlaybackCore` | 只有契约，没有实现 |
| `LumaCoreChecks` | executable | `Tests/LumaCoreChecks` | `LumaCore` `PlaybackCore` | 命令行断言 |
| `LumaContentChecks` | executable | `Tests/LumaContentChecks` | `LumaContentCore` `PlaybackCore` | 命令行断言 |

---

## 4. `Sources/Luma` 目录清册

7 个一级目录：`App` / `Components` / `Domain` / `Features` / `Services` / `Store` / `Support`。
下面按目录列全部文件——**新增文件就加在这里**。

### 4.1 `App/`（5）

```
AboutWindowView.swift      LibraryPickerView.swift   LibrarySetupView.swift
LumaApp.swift              RootView.swift
```

- `LumaApp`：`@main`、窗口与菜单、启动流程（是否进建库引导 / 选库面板）。
- `RootView`：主界面骨架、覆盖层（查看器 / 搜索 / 播放器）的门禁；`store.needsLibrarySetup` 为真时直接渲染 `LibrarySetupView`。

### 4.2 `Components/`（5）

```
AnimatedImageView.swift   Components.swift          PhotoCell.swift
PhotoMarqueeSelection.swift                        PhotoThumbnailView.swift
```

- `PhotoThumbnailView` / `PhotoThumbnailLoader` 是全应用**唯一**取缩略图的入口；`ThumbnailPurpose` 四种：`.grid(maxPixel:)` `.cover(_:)` `.filmstrip(_:)` `.preview(_:)`。
- `PhotoGrids.swift` 不在这个目录，在 `Features/Gallery/`。

### 4.3 `Domain/`（29，纯模型，无 IO）

```
AIAgentModels            BeautyRecommendation    CacheRecords
CatalogDiscoveryModels   CatalogModels           CinemaModels
CloudInsight             CloudModels             CloudWizardModels
Duplicates               ExportOptions           FavoritesDigest
ImportTypes              LibraryHealth           LibraryVault
Models                   NetworkCinemaModels     PersonInsight
PhotoQuery               PhotoTags               PlaceInsight
RevisitInsight           SceneTags               SearchQuery
SmartAlbum               SystemQuery             TVEPGModels
TVModels                 VideoHub
```

- `Models.swift`：`SidebarItem`（`library` / `cloudMount(UUID)` / `iptv` …）、`PhotoItem` 等基础模型。
- `PhotoQuery` / `SystemQuery` / `SearchQuery`：三个可下推的查询描述，分别对应自建库、系统图库、搜索。
- `SourceKind`（`library` / `cloudMount` / `cinemaFeed` / `catalogSite` / `iptv`）定义在 `Sources/LumaContentCore/Source/Source.swift`，不在本目录。
- `CatalogProviderKind.supportsNetworkCinema` 在 `CatalogModels.swift`，决定一个资源站是「网络影院」还是「网络资源」。

### 4.4 `Features/`（21 个子目录，144 个文件）

```
AI/            AIAssistantView
Catalog/       CatalogAvatarView · CatalogCalendarView · CatalogChannelComponents
               CatalogChannelView · CatalogDetailView · CatalogFollowingView
               CatalogHistoryView · CatalogHubView · CatalogPalette
               CatalogPersonProfileView · CatalogPlaylistViews · CatalogPlaylistsView
               CatalogRankingView · CatalogResourceConsole · CatalogSidebarRow
               CatalogSourceEditorSheet · CatalogSourcesOverviewView
               CatalogTalentLibraryView · CatalogWizardView
Cinema/        CinemaArtworkPicker · CinemaCardViews · CinemaDetailSupport
               CinemaDetailView · CinemaLibraryView · CinemaLibraryView+CardMode
               CinemaLibraryView+Folders · CinemaLibraryView+List
               CinemaLibraryView+Shelves · CinemaLibraryView+States
               CinemaLibraryView+Wall · CinemaMatchSheet · CinemaPanels
               CinemaPersonViews · CinemaPosterCards · CinemaSeriesDetailView
               CinemaSheets · CinemaShelfViews · CinemaToolbarConsole
               CinemaTrailerOverlay
Cloud/         CloudBrandIcon · CloudStoragesCinemaView · CloudStoragesHub
               CloudStoragesPhotosView · CloudViews · CloudWizard
               CloudWizard+AList · CloudWizard+Cookie · CloudWizard+OAuth
               CloudWizard+SMB · CloudWizard+WebDAV
Collections/   CollectionAlbumComponents · CollectionOverviewViews · CollectionsView
               FavoritesDigestView · KeywordGalleryView · LibraryHubView
               SystemCollectionsView · TripStoryView
Compression/   PhotoCompression
Editor/        EditAdvanced · EditPoster · EditPro · EditState+Beauty
               EditStudio · PhotoEditor
Gallery/       DeleteConfirmView · DuplicatesView · GalleryChrome
               GalleryView · GalleryView+Chrome · GalleryView+Content
               GalleryView+Keyboard · GalleryView+ModuleReadout
               GalleryView+VideoHub · PhotoGrids · SearchResultsPage
               TimelineOverviewView
Import/        ImportView
Maps/          FootprintPlaybackView · MapCanvas · MapPlaceGridView
               PhotoMapView · PlaceDetailView · PlaceStatisticsView
NetworkCinema/ NetworkCinemaDetailView · NetworkCinemaHubPages
               NetworkCinemaHubView · NetworkCinemaPersonView
               NetworkCinemaSidebarRow
Organize/      BatchChangeView · BeautyRecommendView · ExportOptionsView
               LibraryHealthView · OrganizeStudioView · SmartAlbumEditorView
People/        PeopleLocalView · PersonInsightViews · PersonMapPanel
Revisit/       RevisitView
Search/        SearchPanel
Settings/      AboutBrandHeroView · AppModules · AppSettings
               CinemaSettingsSection · LocalModelsSettingsSection
               ProductizationSettingsView · SettingsKeys · SettingsModels
               SettingsView · ShortcutSettingsView · VaultSettingsView
Shared/        LumaStateViews · ModuleReadoutBar · SourceErrorView
               SourceJobStatusBar · SourceTransferMenu
Sidebar/       CloudMountDetailView · CloudMountSidebarRow · NamePromptSheet
               SidebarDropSupport · SidebarSectionComponents
               SidebarStateStorage · SidebarView · SourceSidebarRow
               SystemFolderOrganizeSheet · SystemToolsSheet
TV/            TVBrand · TVHubView · TVRecordingsPanel · TVSourceWizardView
               TVTimeRingStage
Videos/        VideoHoverPreview · VideoHubView
Viewer/        FilmstripView · InfoPanelView · PhotoViewer · ShortcutHelpView
               SlideshowView · TVChannelActions · TVPlaybackOverlay
               VideoPlayback · VideoPlaybackUI · VideoScrubThumbnails
```

分工要点：

- `Gallery/` 是图库主界面：`GalleryView` 是容器（网格 / 工具栏 / 拖放 / 框选），`+Content` `+Chrome` `+Keyboard` `+ModuleReadout` `+VideoHub` 是它的扩展；`PhotoGrids` 是四种网格布局；`SearchResultsPage` 是搜索结果页（虽然叫 Search，但它属于图库页）。
- `Viewer/` 同时承载图片查看器与视频播放界面：`PhotoViewer`、`FilmstripView`、`InfoPanelView`、`SlideshowView` 是图片侧；`VideoPlayback` / `VideoPlaybackUI` / `VideoScrubThumbnails` / `TVPlaybackOverlay` 是视频侧。
- `Catalog/` = 网络资源（站点聚合、海报墙、详情、演员、片单、追更）；`NetworkCinema/` = 网络影院（影视源聚合）；两者数据源同类但页面不同，不要互相引用视图。
- `Settings/AppModules.swift` 定义 `AppModule` 的 5 个模块（`library` / `cloud` / `catalog` / `television` / `cinema`），控制侧边栏入口、搜索来源与文案；关闭模块不删数据。

### 4.5 `Services/`（18 个子目录，147 个文件）

```
AI/           AIImageEncoder · AIKeychain · AILibraryCinemaTools · AILibraryContext
              AILibraryTVTools · AILibraryTools · AIProviderClient
              AIToolProvider · LocalRuntimeScanner
App/          Diagnostics · UpdateChecker
Catalog/      AvgleCatalogProvider · AvpleCatalogProvider · CatalogArtworkCache
              CatalogArtworkMemory · CatalogClient · CatalogCrypto
              CatalogDatabase · CatalogMaintenance · CatalogNameDictionary
              CatalogNameParser · CatalogPersonInfoService
              CatalogSnapshotStore · CatalogStore · FoFoCatalogProvider
              FoFoCloudflareGate · HuangguoAddressResolver
              HuangguoCatalogProvider · IKanPPCatalogProvider
              IYFCatalogProvider · JavClCatalogProvider · JavGGCatalogProvider
              MacCMSCatalogProvider · MadouCatalogProvider · MissavCatalogProvider
              NinetyOneCatalogProvider · NinetyOnePornaCatalogProvider
              QuanjiCatalogProvider · RouHLSProxy · RouVideoCatalogProvider
              ShiseCatalogProvider · WebCatalogSupport · XszCatalogProvider
Cinema/       AssrtSubtitleClient · CinemaArtworkCache · CinemaIntroDetector
              CinemaIntroOnline · CinemaKeychain · CinemaMetadataSource
              CinemaNFO · CinemaScraper · DoubanClient · DoubanTrailerClient
              NetworkCinemaSnapshotStore · OpenSubtitlesClient
              SubtitleProviderService · TMDBClient · TVDBClient
Cloud/        AliyunCookieAuth · CloudEXIF · CloudProviders · CloudScanner
              CloudSecretStore · CloudSupport · JPEGMetadata · Pan115Drive
              QuarkDrive · SMBClient · WebDAVClient · WebDAVResourceLoader
Compression/  PhotoCompressor
Import/       ImportService
Library/      LibraryPaths · LibraryVaultService · LocalCinemaWatcher
              MetadataStore · MetadataStore+CloudIndex
              MetadataStore+DerivedCache · MetadataStore+Query
              SQLite · SystemIndex · SystemIndex+Direct
              SystemIndex+DirectQuery · SystemIndex+DirectSets
              SystemIndex+Metadata · SystemIndex+Query
              SystemPhotosLibrary
Media/        ArtworkCache · FFmpegPrewarm · ImageLoader · ImageTransform
              LivePhotoSupport · ObjectDetector · PersonAvatarLoader
              PersonPalette · PhotoBeauty · PhotoHasher · PhotoIntelligence
              PhotoKitBridge · PhotoKitThumbnailProvider · PhotoQuality
              RawSupport · SigLIPEngine · SigLIPTokenizer
              ThumbnailFileIndex · VideoSupport
Memories/     Memories · MemoryExporter · Trips
Models/       ModelInstaller · ModelManifest · ModelRegistry
People/       FaceClustering
Places/       PlaceSupport · WorldCityIndex
Playback/     PlaybackSourceResolver · SourcePlaybackProgressStore
Search/       LibrarySearchCrossLibrary · SearchCenter · SearchProviders
              SearchSessionStore · SearchTypes
Shared/       CinemaMetadataEnricher · ContentRepositories
              EnrichedContentRepository · KeychainAccess
              LibraryIngestService · LumaKeychainVault
              NetworkCinemaMetadataEnricher · SnapshottedContentRepository
              SourceContentCache · SourceErrorMapper · SourceSessions
              SourceTransfer
TV/           IPTVService · TVCatchupURL · TVClipRecorder · TVDatabase
              TVEPGService · TVLogoCache · TVPreviewCache · TVReminderCenter
Video/        DisplayModeMatcher · EmbeddedSubtitleLoader · NowPlayingCenter
              PlaybackCoreBridge · SubtitleLoader
```

边界：

- `Library/` 是数据层；`Media/` 是解码与视觉计算；`Cloud/` 是协议；`Catalog/` 是资源站抓取；`Cinema/` 是刮削与字幕；`TV/` 是 IPTV；`Video/` 是播放器的 App 侧胶水（把 `PlaybackCore` 接到 UI 与系统能力）。
- `Services/Shared/KeychainAccess.swift` 是全应用唯一直接调用 Security.framework 的地方；`LumaKeychainVault` 在其上做统一凭据保险库。
- `Services/App/UpdateChecker` 是唯一对外网络访问（GitHub Releases）；`Diagnostics` 生成不含照片与凭据的诊断报告。

### 4.6 `Store/`（58 个文件，其中 49 个 `LibraryStore+*` 扩展）

```
LibraryStore.swift
LibraryStore+AIAgent            LibraryStore+AICinemaTools
LibraryStore+AINetworkCinemaTools                      LibraryStore+AITools
LibraryStore+AliyunCookie       LibraryStore+Beauty
LibraryStore+Burst              LibraryStore+Catalog
LibraryStore+Cinema             LibraryStore+CinemaBrowse
LibraryStore+CinemaDetail       LibraryStore+CinemaFiles
LibraryStore+Cloud              LibraryStore+CloudCache
LibraryStore+CloudInfo          LibraryStore+CloudInsight
LibraryStore+CloudLocal         LibraryStore+CloudSnapshot
LibraryStore+CompressionExport  LibraryStore+Deletion
LibraryStore+EditorStyle        LibraryStore+Favorites
LibraryStore+Hashing            LibraryStore+Health
LibraryStore+Import             LibraryStore+Intelligence
LibraryStore+Maintenance        LibraryStore+Metadata
LibraryStore+Organize           LibraryStore+Paging
LibraryStore+Pan115             LibraryStore+People
LibraryStore+PlaybackHooks      LibraryStore+Quark
LibraryStore+Query              LibraryStore+Revisit
LibraryStore+SearchBridge       LibraryStore+Selection
LibraryStore+SourceJobs         LibraryStore+SourceRegistry
LibraryStore+Stacking           LibraryStore+SystemAlbums
LibraryStore+SystemCache        LibraryStore+SystemImport
LibraryStore+SystemLibrary      LibraryStore+TV
LibraryStore+Undo               LibraryStore+Vault
LibraryStore+VideoHub           LibraryStore+Viewer
```

独立状态对象（各自 `ObservableObject`，避免一张照片的选择触发整页重算）：

```
CatalogBrowserModel · CatalogBrowserModel+Discovery · CloudBrowserModel
IPTVBrowserModel · NetworkCinemaModel · SelectionModel
SourceHubModel · ViewerModel
```

**扩展的硬规矩**：存储属性只能写在 `LibraryStore.swift`（Swift 的 extension 不能声明存储属性）；新领域一律新建 `LibraryStore+Xxx.swift`，不要塞回主文件。

### 4.7 `Support/`（8）

```
DragSupport · KeyboardMonitor · LumaDesign · PhotoPicker
PrintSupport · ShortcutCatalog · ViewSupport · WindowAccessor
```

- `LumaDesign.swift`：设计 token（`LumaBrand` 六色、间距、圆角、材质）。
- `ShortcutCatalog`：快捷键清单与帮助页数据源；`KeyboardMonitor`：全局按键监听。

---

## 5. 分层与依赖方向

```
Luma (SwiftUI / AppKit / Store / Services)
 ├─ LumaContentCore  ── PlaybackCore ── LumaCore
 └─ LumaCore
```

- 依赖只向下。UI 不直接 import `PlaybackCore` 的内部类型，统一走 `Services/Video/PlaybackCoreBridge`。
- `PlaybackCore` 不碰文件路径、不写日志、不读 UserDefaults：缓存目录、ffmpeg 路径、日志与进度落盘由 App 注入。
- `LumaContentCore` 只有契约：`Source` / `SourceSession` / `Content` / `PlaybackContract` / `PlaybackCoordinator` / `ContentSnapshot` / `SourceRevision` / `SourceJob` / `CommandPolicy` / `HTTPTransport` / `SourceError` / `M3U` / `IngestService`。
- 具体源实现留在 `Luma/Services/*`，不要往 `LumaContentCore` 里加协议实现。

---

## 6. 状态与数据流

```
SwiftUI View ──读 @Published / 调方法──▶ LibraryStore(@MainActor) ──▶ MetadataStore(Luma.sqlite)
      │                                        │
      │                                        └──▶ LibraryPaths（本地文件）
      └── PhotoThumbnailView ◀── ImageLoader ◀── LibraryPaths / CloudPaths / 网络
```

- **唯一状态源**：`LibraryStore`（`@MainActor` + `ObservableObject`，见 `Store/LibraryStore.swift`）。
- 视图不持有照片 / 相簿数组，不自己开数据库、不自己拼路径；总数用 `store.visibleCount` / `visibleVideoCount`，不要用 `visiblePhotos.count`（分页窗口下两者不同）。
- 视图 → Store 单向调用；Store 不持有任何 View。跨视图通信用 `@Published` 状态（`viewerID`、`showLibraryPicker`、`pendingLibraryOpen`、`needsLibrarySetup` 等）。
- 唯一落盘入口：元数据走 `MetadataStore`（由 `LibraryStore.save()` 触发）；文件走 `LibraryPaths` / `CloudPaths` 提供的 URL，且只允许在 Store / `ImportService` / `ImageLoader` 里做。
- 唯一路径入口：`LibraryPaths`（本地与图库内缓存）、`CloudPaths`（`Services/Cloud/CloudSupport.swift`，网盘缓存）。视图层不得拼路径。

### 6.1 设置作用域

| 作用域 | 存放 | 例子 |
| --- | --- | --- |
| App 级 | `UserDefaults`（`Features/Settings/AppSettings`） | 默认网格密度、动效、诊断开关 |
| 图库级 | 当前图库 `Luma/database/Luma.sqlite` 的 `settings` 表 | 外观 / 强调色、视图状态、导入选项、缓存预算、系统图库连接、网盘挂载、AI 配置与对话、影院与电视开关 |

`AppSettings` 持有 `libraryReader` / `libraryWriter` 两个闭包（由 `LibraryStore` 注入）：有图库时读写 `settings` 表，没有图库时退回 `UserDefaults`。切库由 `reloadPerLibraryState()` 整体重读，所以主题会跟着图库变。

新增设置项先判断作用域：跟图库走的写 `settings` 表，跟 App 走的写 `AppSettings`。

---

## 7. 图库文件布局与迁移

```
My.photoslibrary/                     # 官方库的情况
├── database/Photos.sqlite            # Apple 的库（只读）
├── originals/ · resources/           # Apple 的原图与派生图（只读）
├── scopes/cloudsharing/              # 共享相簿
└── Luma/                             # 拾光的旁挂数据，一律写这里
    ├── database/Luma.sqlite          # 自建库的元数据 + 图库级 settings
    ├── originals/                    # 自建库原图
    ├── resources/derivatives         # 自建库缩略图与派生图
    ├── resources/renders             # 编辑结果
    ├── resources/transcodes          # 转码产物
    ├── resources/backups             # 备份（Vault）
    ├── resources/presets.json        # 用户编辑预设（跟库走）
    ├── resources/luts/               # 导入的 3D LUT
    ├── resources/catalog/            # 网络资源的源、续看、片单、更新日历
    ├── resources/tv/Television.sqlite# 网络电视源与频道
    ├── resources/tv/playlists/       # 复制进库的 M3U
    ├── resources/system-cache/       # 系统图库扫描结果 + import-manifest.json
    ├── cloud/thumbs/                 # 网盘缩略图
    ├── tv-logos/ · tv-previews/      # 台标与预览图
    └── source-snapshots/             # 网络源内容快照
```

**刻意不放在图库里的两处**（都落在 `~/Library/Application Support/Luma/resources/`）：

- `system-thumbs/`：系统图库的格子小图。图库常在外置盘上，为每个格子往同一块盘写小文件会拖慢滚动。
- `system-index/SystemIndex-<hash>.sqlite`：系统图库的只读索引库，按图库路径哈希命名，可以同时缓存多个系统图库。

迁移与定位规则：

- 当前图库的真源是 `Application Support/Luma/ContainerPath.txt`（`LibraryPaths.bootstrapFile`）；最近图库记录在 `UserDefaults["settings.recentLibraries"]`（`LibraryPaths.recentLibrariesKey`）。
- 只有 `LibraryPaths.requiresLibrarySetup` 为假才允许创建数据；`needsLibrarySetup == true` 时 `LibraryStore` 不打开 `MetadataStore`，`RootView` 用 `LibrarySetupView` 挡住界面。
- 切库必须走 `LibraryStore.activateLibrary(_:)`（`LibraryStore+SystemLibrary.swift`），不要手搬文件。
- 旧版 `private/com.lijialong.photosclone/` 与摊在库根的数据由 `LibraryPaths.migrateSidecarToLibraryRootIfNeeded` 幂等上移；旧库路径 / 旧文件名由 `existingMetadataFile(in:)` 兼容读取。
- **迁移 SQLite 禁止直接搬 `-wal` / `-shm`**：先把三件套复制到临时目录、`wal_checkpoint(TRUNCATE)` 合并，再只搬主库文件。`LibraryPaths.migrateMetadataFileIfNeeded` 已经这么做，不要另写一套。
- 官方库的缩略图优先复用 `resources/derivatives/<首字符>/<UUID>_1_105_c.jpeg`（视频是 `_1_102_o.jpeg`），共享相簿走 `scopes/cloudsharing/...`，缺失才生成到 `system-thumbs/`。

---

## 8. 数据层

项目里有 4 个 SQLite，职责完全分开：

| 库 | 位置 | 谁写 |
| --- | --- | --- |
| `Luma.sqlite` | 图库内 `Luma/database/` | `MetadataStore`（自建库元数据、系统库识别缓存、网盘缓存、影院条目、图库级设置） |
| `Television.sqlite` | 图库内 `Luma/resources/tv/` | `TVDatabase` |
| `SystemIndex-<hash>.sqlite` | `Application Support/Luma/resources/system-index/` | `SystemIndex`（系统图库只读索引） |
| `catalog.sqlite` | `Resources/Catalog/`（只读内置） | `CatalogDatabase` 读取 |

### 8.1 `MetadataStore` 的表（16）

```
assets  folders  albums  album_assets  settings
people  person_assets  scanned_faces
asset_analysis  asset_overlays
system_analysis  derived_reports
cloud_assets  cloud_people  cloud_person_assets
cinema_entries
```

| 表 | 用途 |
| --- | --- |
| `assets` | 自建库媒体：文件名、原始文件名、时间、大小、相机 / 镜头、GPS、时长、宽高、哈希等 |
| `folders` / `albums` / `album_assets` | 文件夹、相簿、相簿关系（含手动排序） |
| `settings` | 图库级键值：视图状态、连接、主题、AI 配置… |
| `people` / `person_assets` / `scanned_faces` | 人物、人物照片、已扫描人脸 |
| `asset_analysis` | 端侧识别结果（场景、OCR、特征） |
| `asset_overlays` | 拾光补充元数据：收藏、隐藏、关键词、标题等，不改 Apple 的表 |
| `system_analysis` | 系统图库识别缓存，按 `library_path` 分区 |
| `derived_reports` | 派生报告缓存（体检、美化、收藏摘要），按范围 key + signature |
| `cloud_assets` / `cloud_people` / `cloud_person_assets` | 网盘 EXIF、识别、特征、查看记录、人物，按 `mount_id + path` |
| `cinema_entries` | 本地 / 网盘影院刮削条目 |

`MetadataStore+CloudIndex` 另建 3 张网盘目录索引表：`cloud_index_folders`、`cloud_index_assets`、`cloud_index_state`（各自带 parent / captured 索引）。

主要索引：`assets` 的 `captured_at`、`added_at`、`deleted_at`、`content_hash`、`rating`，四个「live」组合索引（captured / added / size / title + id），`album_assets(album_id)` 与 `(asset_id)`，`system_analysis(library_path)`，`cloud_assets(mount_id)`。

### 8.2 `TVDatabase` 的表（3）

`tv_playlists`、`tv_channels`（带 `idx_tv_channels_source(playlist_id, position)`）、`tv_settings`。

### 8.3 写入纪律

- 元数据写入统一走 `LibraryStore.save()`，业务代码不直接开 SQLite。
- 任何缓存都必须带失效条件：系统库用 `systemCacheSignature`（`Photos.sqlite` 大小 + 修改时间），网盘用远端文件大小，断开挂载时 `purgeCloudAssets`。
- 查询构建器 `PhotoQuery`：范围 / 筛选 / 关键词 / 排序 / 评分 / 旗标 / 色标全部下推 `MetadataStore+Query`。

### 8.4 `SystemIndex` 的两种模式

| 模式 | 入口 | 行为 |
| --- | --- | --- |
| 直连 | `SystemIndex.openDirect` | 只读连 `Photos.sqlite`，实时查询；`+DirectQuery` 出 SQL，`+DirectSets` 处理连拍 / 相簿 / 人物 / 导入会话 |
| 索引 | `SystemIndex` + `system-index` 缓存 | 把关键字段同步到本机索引库，查询走 `SystemIndex+Query`；签名变化即重建 |

- 相簿 / 文件夹 / 人物是纯元数据，先由 `albumMetadata` / `peopleMetadata` 读出来展示，扫描完成后再替换。
- 拾光补充数据以 overlay 合并展示；**绝不写 Apple 的表**。真实编辑 / 删除 / 相簿写回只能经 `PhotoKitBridge`。
- 直连模式的日期条件必须直接比较 `ZDATECREATED`（Core Data 秒）；写成表达式会失去 Apple 的日期索引（实测 0.37s → 66s）。

---

## 9. 查询、分页与渲染

| 常量 | 值 | 位置 |
| --- | --- | --- |
| `LibraryStore.windowThreshold` | 5000 | `LibraryStore.swift` |
| `LibraryStore.windowPageSize` | 600 | `LibraryStore.swift` |
| `LibraryStore.systemStreamDisplayLimit` | 40 000 | `LibraryStore+SystemLibrary.swift` |
| `GalleryView.systemRenderLimit` | 1200（每次 +1200） | `GalleryView.swift` / `+Content` |
| `LibraryStore.thumbnailPrewarmLimit` | 300 | `LibraryStore+Organize.swift` |
| `LibraryStore.cloudPeoplePageSize` | 300 | `LibraryStore+CloudInfo.swift` |
| `LibraryStore.largeVideoBytes` | 300 MB | `LibraryStore+Health.swift` |

- 本地图库超过 5000 张且处于「所有照片」网格时启用分页窗口：范围 / 筛选 / 排序下推 SQL，`visiblePhotos` 只持已加载窗口，每页 600。
- 窗口按查询指纹 `query.key` 失效重建；`systemQueryCache` 缓存 `SystemQuery` 与其 key，避免 SwiftUI body 反复拼长 SQL。
- 全量操作用 `index.allIDs(query)` 只取 UUID，再 `photos(ids:)` 每 500 张一批取回。
- 系统图库网格先渲染 1200 张，滚动到底再加 1200（`systemRenderLimit += 1_200`）；索引构建期间用 `systemStreamDisplayLimit` 缓冲先显示。
- 打开相簿 / 文件夹时 `prewarmOpenedCollection` 预热前 300 张**快速层**缩略图。
- 视图层禁止对整库 `filter` / `sorted`；百万级库的 `LIKE '%x%'` 无法走索引，必须放后台任务并接受较慢（这是"结果完整"的代价）。

---

## 10. 搜索

```
搜索框 / ⌘F
  └─ SearchCenter（防抖 260ms；六来源并发；结果流式落地；同词复用）
       └─ SearchProviders.makeAll
            ├─ LibrarySearchProvider        当前库 + 其它已接入图库（跨库只读）
            ├─ CloudSearchProvider          cloud_index_assets / folders
            ├─ CinemaSearchProvider         本地 / 网盘影院索引
            ├─ NetworkCinemaSearchProvider  影视源并发检索
            ├─ TelevisionSearchProvider     频道 + EPG 节目
            └─ CatalogSearchProvider        资源站统一检索
```

- `SearchSection` = 命中数组 + `kindCounts` + `total`；`SearchHitKind` 7 种：`photo` `video` `album` `folder` `person` `scene` `place`。
- **任何来源都不做条数截断**：去掉所有 `prefix(limit)` 与 channelBudget，命中多少返回多少。展示与速度可以优化，但结果必须完整。
- 图库命中字段：文件名 / 原始文件名 / 标题 / 相机镜头 / 地名 / 官方关键词（`ZKEYWORD`）/ 端侧场景标签与 OCR。
- 系统图库把关键词与 AI/OCR 命中换算成资产 UUID，作为该 token 的 OR 条件并入 SQL（`SystemQuery.tokenKeywordIDs`）。
- 关键词查询走 `SystemIndex.nativeKeywordAssetIDs`：先筛小表 `ZKEYWORD` 拿到 PK，再按 PK 关联 `Z_1KEYWORDS` / `ZADDITIONALASSETATTRIBUTES` / `ZASSET`；`limit == 0` 时不拼 LIMIT（整表 join 要 7 秒，先筛小表 0.03 秒）。
- **当前模块不含图库数据时的坑**：浏览网络影院 / 电视 / 资源时，`store` 里没有图库内容（`sidebarItem` 不在系统图库范围、`photos` 为空）。所以 `storeServesLibrary = store.isSystemScope || !store.isNativeContainer`；为假时当前图库也改走只读直连，否则图库来源永远 0 命中。
- 系统图库分页窗口是异步装填的：搜索词一变先清空再跑 SQL。统计前必须 `waitForSystemWindow(store:)`（最多 2.5s，120ms 轮询），否则大库上会瞬间得到「图库 0」并被会话缓存住。
- 跨库打开：`openSearchResultInLibrary(path:pending:)` → 切 / 连目标库 → `consumePendingLibraryOpenIfReady()` 在原查看器打开（`Store/LibraryStore+SearchBridge.swift`）。
- 会话缓存：`SearchSessionStore` 以「关键词 + 来源集合」为键保留最近 **4** 轮，返回搜索页不重跑。
- 已知性能债：文件名与关键词是 `LIKE` 全表扫描。后续可建 FTS 表提速，但不得改变「结果完整」的语义。

---

## 11. 源与模块

- `AppModule`（`Features/Settings/AppModules.swift`）5 个：`library` `cloud` `catalog` `television` `cinema`。每个模块带标题、副标题、关闭说明、SF Symbol、双色渐变、`UserDefaults` key、对应 `SourceKind`。图库模块始终开启。
- `SourceKind`（`Sources/LumaContentCore/Source/Source.swift`）5 种：`library` `cloudMount` `cinemaFeed` `catalogSite` `iptv`。
- `SourceDescriptor` 是侧边栏统一行模型（`Store/LibraryStore+SourceRegistry.swift`）；新增来源 = 新增 provider + 注册表条目 + 能力位，不改侧边栏结构。
- 归类看 `CatalogProviderKind.supportsNetworkCinema`（`maccms` / `fofo` / `ikanpp` / `iyf`）：它们只进「网络影院」，不再在「网络资源」重复出现；网盘里的影片随「网络存储」，不算影院模块。
- 侧边栏分区：拾光 / 系统图库 / 网络存储。当前库本身就是官方库（`isNativeContainer`）时，主分区直接展示该库结构。

---

## 12. 权限与写入边界

| 范围 | 读 | 改元数据 / 删除 / 编辑 | 上传 / 重命名 / 新建文件夹 |
| --- | --- | --- | --- |
| 自建图库 | ✅ | ✅ | ✅ |
| 官方库作为**当前图库** | ✅ | 补充元数据写 `asset_overlays`；编辑 / 删除 / 相簿写回经 PhotoKit | ❌ |
| 官方库作为**额外连接**（只读） | ✅ | ❌ | ❌ |
| WebDAV | ✅ | ❌ | ✅ |
| SMB | ✅ | ❌ | ❌ |
| 阿里云盘 / 百度 / 夸克 / 115 | ✅ | ❌ | ❌ |

- 系统图库写入前必须 `prepareSystemLibraryWrite()`（权限 + 样本校验），且 `canWriteSystemOriginals` / `canDeleteSystemPhotos` / `canManageSystemAlbums` 为真。
- 禁止用 SQL 改 `Photos.sqlite`；禁止对额外连接的系统库做真实写入。

---

## 13. 网络、影视与直播

- 网盘：`CloudProviders` + `SMBClient` / `WebDAVClient` / `AliyunCookieAuth` / `Pan115Drive` / `QuarkDrive`；密钥在 `CloudSecretStore`（转调 `LumaKeychainVault`）。
- EXIF：SMB 直读挂载文件；WebDAV 用 `Range: bytes=0-262143`；官方网盘用直链 + Range。结果写 `cloud_assets` 并回填目录缓存（`CloudScanner` / `MetadataStore+CloudIndex`）。
- 资源站：`Services/Catalog/*CatalogProvider`（苹果 CMS、FoFo、爱看、爱壹帆、黄果、MissAV、JavCI、JavGG、麻豆、91 系、视色、AVple、Avgle、全集、肉等），统一经 `CatalogClient` / `CatalogDatabase` / `CatalogSnapshotStore`；海报缓存 `CatalogArtworkCache`（内存层 `CatalogArtworkMemory`）；标题识别走 `CatalogNameParser` + `CatalogNameDictionary`。
- 影院：`CinemaScraper` + `TMDBClient` / `DoubanClient` / `TVDBClient` / `AssrtSubtitleClient` / `OpenSubtitlesClient`，结果落 `cinema_entries` 与 `NetworkCinemaSnapshotStore`。
- 电视：`IPTVService` + `TVDatabase` + `TVEPGService` + `TVCatchupURL` + `TVReminderCenter` + `TVClipRecorder`。

---

## 14. 播放内核（`Sources/PlaybackCore`，23 个文件）

| 文件 | 职责 |
| --- | --- |
| `VideoPlayerModel` | 播放器门面：状态、seek、字幕、音轨、倍速、进度 |
| `PlaybackSession` · `VideoStreamSession` | 会话、边下边播、断流重建 |
| `StreamPlanner` · `SeekPlanner` · `HTTPByteRange` · `RemoteRangeSource` | 片源计划：直连 / Range / HLS |
| `LocalHLSServer` · `PlaybackCache` · `BufferAdaptationState` · `BufferProfile` | 本地 HLS、缓存与缓冲策略 |
| `TranscodeProfile` · `PlaybackFilters` · `BluraySource` · `VideoFraming` · `PlaybackOutputOptions` | 转码、HDR 映射、蓝光、画幅、输出 |
| `SubtitleCore` · `SubtitlePreference` | 字幕解析与偏好 |
| `PlaybackTimeline` · `PlaybackHooks` · `PlaybackEnvironment` · `PlaybackMode` · `PlaybackModels` | 时间轴、钩子、环境注入、模式与模型 |

- **逐级加速**：`VideoPlayerModel.seekStep(_:base:isRepeat:)`，倍率 `seekAccelSteps = [1, 2, 3, 4, 6, 8]`；同方向且间隔 < 1.2s 才升级，换向或停顿 1.2s 回到 1×；单步上限 600s（10 分钟）；`isRepeat` 时限频 0.12s。
- **按住重复**：UI 侧 `HoldRepeatGesture`（`Features/Viewer/VideoPlayback.swift`）按下立刻执行一次，然后每 0.30s 一次，间隔每拍减 20ms，降到 0.14s 后匀速。阈值与内核的倍率阶梯是两套机制：UI 决定「多久点一次」，内核决定「这次点多大一步」。
- 4K50/60 `hev1` 直连不可解码时自动改走重编码，避免「有声音没画面」。
- 内置 ffmpeg 由 `build.sh` 提供（优先 `Vendor/ffmpeg-dv`：ffmpeg-full + libplacebo + MoltenVK，支持杜比视界 Profile 5；否则静态包带 zscale + tonemap），运行时可回退系统 ffmpeg。
- 按片源帧率匹配显示器刷新率：`Services/Video/DisplayModeMatcher`。

---

## 15. 缩略图与缓存

- 唯一入口 `ImageLoader`；`PhotoThumbnailView(photo:purpose:)` 只选档位（`.grid` / `.cover` / `.filmstrip` / `.preview`），禁止视图里另写解码顺序。
- 三级内存池：`cache` 384MB（网格缩略图）、`fullCache` 512MB、`displayCache` 192MB。
- 并发自适应 `ThumbnailPrefetchTuner`：按实测「读盘 + 解码」EWMA 调并发——≤18ms 用 4 路、>18ms 用 3 路、>45ms 用 2 路；单批上限 160 / 120 / 80 张。机械盘与网络盘上自动缩小，避免抢可见格子的 IO。
- 显示层预取另有 `DisplayPrefetchLimiter`（上限 2 个并发）与 `ThumbnailGenerationGate`（同文件去重）。
- `cacheKey` 含 `editVersion`；编辑保存后必须 `ImageLoader.invalidate`。
- 不得把 `NSImage` 放进 `PhotoItem` 或任何 `Codable` 模型。

---

## 16. 端侧智能与助手

- 识别：`Services/Media/PhotoIntelligence`（Vision 分类 / OCR / 特征）、`SigLIPEngine` / `SigLIPTokenizer`、`ObjectDetector`、`PhotoQuality`、`PhotoBeauty`；模型由 `ModelInstaller` / `ModelManifest` / `ModelRegistry` 管理。
- 人物：`FaceClustering` 聚类，`LibraryStore+People` 编排；`PersonPalette` / `PersonAvatarLoader` 管头像与色调。
- 编排层 `LibraryStore+Intelligence` 只做调度，不直接发 Vision 请求。
- 助手：配置与对话是**图库级**数据；API Key 只进钥匙串（`AIKeychain` → `LumaKeychainVault`）；请求只经 `AIProviderClient`；提示词只由 `AILibraryContext` 组装。
- 工具定义在 `Services/AI/AILibraryTools`（含 `AILibraryCinemaTools` / `AILibraryTVTools`），执行在 `LibraryStore+AITools` / `+AICinemaTools` / `+AINetworkCinemaTools`；所有写操作先确认，失败结果必须回传模型。

---

## 17. 并发与性能守则

- UI 与状态 `@MainActor`；扫码、索引、哈希、解码、网络在 `Task.detached` / 后台队列，完成后回主线程写状态。
- body 里只读派生值；查询 key、日期格式化、大数组排序在 Store 层缓存。
- 长任务可取消，并进任务中心（`SourceJob*` / `LibraryStore+SourceJobs`）。
- 视图里禁止：整库 `filter` / `sorted`、拼 SQL、解码原图、为系统图库复制原图。
- 单文件 2000 行是硬上限；超了先按职责拆（见 AGENTS.md）。

---

## 18. 构建、预览与发布

```sh
./build.sh              # release 构建 → Luma.app
./build.sh debug        # debug 构建
./build.sh preview      # 增量编译 + 只替换可执行文件 + 重启 App
swift run LumaCoreChecks
swift run LumaContentChecks
```

`build.sh` 的实际行为（按执行顺序）：

1. `swift build -c <config> --product Luma`。
2. 删除旧 `Luma.app`，重建 `Contents/MacOS` 与 `Contents/Resources`，拷贝可执行文件、`Info.plist`、`PkgInfo`。
3. 拷贝 `AppIcon.icns`、`PrivacyInfo.xcprivacy`、`CloudIcons/*.png`、`Catalog/*.sqlite`、`Models/*`。
4. ffmpeg：优先复制 `Vendor/ffmpeg-dv/{bin,lib}`（缺失则先跑 `Tools/make_vendor_runtime.sh` 现场生成），并附 `FFmpeg-VERSIONS.txt` 与 GPL `FFmpeg-NOTICE.txt`；没有 dv 运行时才下载静态 `ffmpeg` / `ffprobe` 到 `Vendor/ffmpeg` 并拷进 `Contents/Resources/bin/`。
5. 签名：**先签内嵌 dylib，再签 ffmpeg / ffprobe，最后签外层 App**（hardened runtime 不允许未签名的嵌套可执行文件）。
6. 可选打包与公证。

签名分支（容易误解，按源码为准）：

| 条件 | 实际签名 |
| --- | --- |
| 设置了 `CODESIGN_IDENTITY` | `codesign --force --deep --options runtime --timestamp --entitlements Resources/Luma.entitlements`，用你的开发者证书 |
| 未设置，但 `ensure_local_signing` 成功 | 固定本地自签身份 **`Luma Local Dev`**，证书在 `~/Library/Keychains/LumaDev.keychain-db`。这样重编译不会因为身份（=二进制哈希）变化而反复弹钥匙串授权 |
| 以上都失败 | ad-hoc（`codesign --sign -`） |

| 环境变量 | 作用 |
| --- | --- |
| `PACKAGE=1` | 额外生成 `Luma-<CFBundleShortVersionString>-macOS.zip`（`ditto -c -k --keepParent`） |
| `NOTARIZE=1` | 需要 `APPLE_ID` / `TEAM_ID` / `APP_PASSWORD`，`notarytool submit --wait` 后 `stapler staple` |

`preview` 分支只做 `swift build -c release -Xswiftc -no-whole-module-optimization --product Luma`，把二进制覆盖到 `Luma.app/Contents/MacOS/Luma`，然后 `quit` + `open` 重启。它**不复制资源、不签名、不下载 ffmpeg**——改了 `Resources/` 或签名相关的东西必须跑完整构建。

版本号真源是 `Resources/Info.plist`：当前 `CFBundleShortVersionString 1.2.1`、`CFBundleVersion 7`。

**两个已知的坑**：

- `build.sh` 里 `Models/` 的排除条件是目录名 `SigLIP2`，而仓库里的实际目录叫 `SigLIP2Assets`，所以现在它会被打进包内。若要按注释的意图「按需下载、不内置」，需要同时改脚本与目录命名。
- 出现 `error: input file '...' was modified during the build` 说明有另一个进程在写源码：等待后重试，**不要删 `.build`**。

---

## 19. 测试

命令行工具链没有 XCTest，测试是「可执行 target + 断言」：

- `Tests/LumaCoreChecks/main.swift`：网格布局、缩略图档位、感知哈希、行程分段、美化建议。
- `Tests/LumaContentChecks/main.swift`：源激活策略、能力位、内容引用、播放目标、任务中心。

约定：

- 纯逻辑新增优先放 `Sources/LumaCore` 并补断言，断言失败必须非零退出。
- 涉及数据层的行为用 `MetadataStore` 的临时库手工验证。
- 手工回归清单：建库引导（浅 / 深 / 自动 × 极端强调色）、百万级滚动、统一搜索六来源、跨库打开、播放器按住加速与字幕、切库后主题与设置、系统图库只读边界。

---

## 20. 编码规范

- 注释解释「为什么」，尤其是性能与并发的取舍；不复述「是什么」。
- 单文件按领域拆分；`LibraryStore` 主文件只放存储属性与生命周期。
- 命名：类型 UpperCamelCase、方法 / 属性 lowerCamelCase；SwiftUI 私有视图用 `private struct`。
- 新增可配置项先判断作用域（App 级 → `AppSettings`；图库级 → `settings` 表）。
- 不引入第三方框架，不新增资源目录，不改产物名。

---

## 21. 排错

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 启动落在建库引导 | 上次图库被移动 / 外置盘未挂载 / `ContainerPath.txt` 失效 | `⌥⌘O` 重选图库 |
| 图库搜索很慢 | 百万级 `LIKE '%x%'` 全表扫描，用不上索引 | 等待完成；关键词 / 相簿 / 文件夹命中会先返回 |
| 图库搜索为 0 | 当前模块不含图库数据、窗口未装填、或场景 / 人物还没跑识别 | 检查 `storeServesLibrary` 与 `waitForSystemWindow`；先跑识别 |
| 只有 10 张图 | 历史上跨库配额截断（已移除） | 确认走的是当前版本：搜索不做任何条数限制 |
| 播放黑屏有声 | 4K50/60 `hev1` 直连不可解码 | 自动改重编码，等待准备 |
| 缩略图不更新 | `editVersion` 未变或未失效 | 保存后调用 `ImageLoader.invalidate` |
| 构建被并发改动打断 | 另一个进程在写源码 | 等待后重试，不要删 `.build` |
| 重编译后反复弹钥匙串授权 | 用了 ad-hoc 签名（身份随二进制变） | 让 `ensure_local_signing` 生效，用固定 `Luma Local Dev` 身份 |

---

## 22. 变更同步清单

改完代码，至少问自己这四句：

1. 新增 / 移动 / 删除了文件？→ 更新 §4 清册 + AGENTS.md 文件职责表。
2. 新增了表、索引、缓存目录？→ 更新 §7 / §8，并写明失效条件。
3. 改了口径（阈值、防抖、倍率、分页）？→ 更新 §9 / §10 / §14。
4. 改了构建、签名、打包？→ 更新 §18，并实际跑一遍 `./build.sh`。
