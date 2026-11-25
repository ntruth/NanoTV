# AGENTS.md — 拾光 Luma 开发规范

本文件是本仓库的**架构约定与协作规范**，面向所有参与开发的人与 AI Agent。`README.md` 描述“产品是什么”，本文件描述“代码必须怎么写”。

修改代码前请先读完本文件；若实现与本文冲突，以本文为准并在同一次改动中更新本文。

---

## 1. 技术栈与硬约束

- Swift 5.9，最低 macOS 14，SwiftPM（`Package.swift`），**无第三方依赖**，仅链接系统 `libsqlite3`。
- UI 全部 SwiftUI；必须依赖 AppKit 能力时才 `import AppKit`（`NSOpenPanel`/`NSSavePanel`/`NSWorkspace`/`NSImage` 等）。
- 不引入 Combine 之外的响应式框架；状态由 `LibraryStore`（`ObservableObject` + `@Published`）统一承载。
- 不引入资源目录（`.xcassets`）；图标在 `Resources/AppIcon.icns`，由 `Tools/make_icon.swift` 绘制 1024 PNG 后用 `iconutil` 打包。
- 界面语言为简体中文，代码注释使用中文。

---

## 2. 构建与验证

```sh
./build.sh debug     # 日常开发
./build.sh           # release
open Luma.app
```

- 产物固定为仓库根目录 `Luma.app`（可执行文件 `Luma`，bundle `com.baymax.luma`，显示名「拾光」）。不要修改 `build.sh` 中的产物名。
- 只改代码不跑构建 = 未完成。每次交付前至少保证：
  1. `./build.sh debug` 退出码为 0；
  2. `open Luma.app` 后进程存活（不闪退）；
  3. 手动走一遍被改动的界面路径。
- 纯逻辑（布局、档位等）改动需跑 `swift run LumaCoreChecks`，断言失败会以非零码退出。命令行工具链没有 XCTest，新增纯逻辑优先放进 `Sources/LumaCore` 并在 `Tests/LumaCoreChecks/main.swift` 补断言。
- 临时脚本放 `/tmp`，不要提交。
- 若出现 `error: input file '...' was modified during the build`，说明有另一个构建/编辑进程在同时改动文件；等待数秒后重试，**不要**删除 `.build` 或中断他人构建。
- 需要连通性调试时可临时起本地服务（如 WebDAV 模拟），但不要向仓库添加测试服务器代码。

---

## 3. 架构与数据流

```
SwiftUI View ──读取 @Published / 调用方法──▶ LibraryStore ──▶ MetadataStore(SQLite)
      │                                          │
      └──── ImageLoader（缩略图/大图缓存） ◀──────┘──▶ LibraryPaths（文件系统） / CloudService（网络）
```

- **唯一状态源**：`LibraryStore`。视图不得自己持有照片/相簿数组，不得直接读写数据库或原图目录。
- **大图库浏览走分页窗口**：本地图库超过 `LibraryStore.windowThreshold`（5000）且处于「所有照片」网格时，`pagedQuery` 把范围/筛选/排序下推到 `MetadataStore+Query`，`visiblePhotos` 只返回已加载的窗口（每页 600）。视图里的总数一律用 `store.visibleCount` / `visibleVideoCount`，不要用 `visiblePhotos.count`。
- **唯一落盘入口**：
  - 元数据：`MetadataStore`（由 `LibraryStore.save()` 触发）。
  - 文件：`LibraryPaths` 提供的 URL + `FileManager`，且只能经由 `LibraryStore`/`ImportService`/`ImageLoader` 等服务层执行。
- **唯一路径入口**：`LibraryPaths`（本地）与 `CloudPaths`（网盘缓存）。除 `LibraryPaths.systemThumbs` 外，任何路径都不得在视图层拼接。
- **视图 → Store 单向调用**：Store 不持有任何 View；跨视图通信通过 Store 的 `@Published` 状态（如 `viewerID`、`showLibraryPicker`）。

### 文件职责

完整目录清册见 `docs/development.md` §4（`Sources/Luma` 的 7 个一级目录逐文件列出）。下面只列关键文件：

| 文件 | 职责 | 不要放什么 |
| --- | --- | --- |
| `Store/LibraryStore.swift` | 存储属性、初始化、持久化 | 具体绘制、Core Image 渲染细节 |
| `Store/LibraryStore+*.swift` | 按领域拆分的查询/组织/导入/系统图库/网盘等方法扩展 | 新的存储属性（extension 不能声明） |
| `Store/SelectionModel.swift` / `ViewerModel.swift` / `CloudBrowserModel.swift` | 选择、查看器、网盘浏览状态，独立 `ObservableObject` | 图库内容状态、业务规则 |
| `Store/LibraryStore+Paging.swift` | 大图库分页窗口：加载、追加、定位、查看器胶片条 | SQL 拼接、视图绘制 |
| `Store/LibraryStore+Undo.swift` | 图库级撤销 / 重做栈：最近 30 步内存快照、⌘Z 与 Edit 菜单入口 | 文件系统删除、永久删除、导入、编辑器调整历史 |
| `Store/LibraryStore+Intelligence.swift` | 端侧场景/OCR 分析编排、场景统计、相似照片范围 | 直接调用 Vision 请求（放 `PhotoIntelligence`） |
| `Store/LibraryStore+Health.swift` | 图库体检扫描、相似连拍分组、模糊与大视频统计、「值得重看」 | 视图绘制、直接解码原图 |
| `Domain/SceneTags.swift` | 场景目录 `SceneCatalog`、`PhotoAnalysis`、中文检索词表 | Vision/IO、视图状态 |
| `Domain/LibraryHealth.swift` | 图库体检结果模型（模糊项、相似组、大视频） | 扫描逻辑、IO |
| `Domain/Duplicates.swift` | 重复组模型与检测 / 推荐保留算法（纯计算） | IO、视图状态、数据库 |
| `Features/Gallery/DuplicatesView.swift` | 重复项目页（本地合并 / 系统图库隐藏与拷贝、总览统计、分组卡片、建议保留标注、确认） | 重复检测算法、SQL、路径拼接 |
| `Services/Media/PhotoIntelligence.swift` | Vision 分类 / OCR / 特征向量提取与归一化 | 业务规则、UI、数据库写入 |
| `Services/Media/PhotoQuality.swift` | 缩略图清晰度评估（拉普拉斯方差） | 缓存策略、业务规则 |
| `Services/Media/PhotoBeauty.swift` | 缩略图 256×256 采样亮度/色彩/清晰度，调用 `BeautyAdvisor` 出建议 | 阈值与业务规则（放 LumaCore）、UI |
| `Services/Media/PersonPalette.swift` | 人物照片缩略图平均色采样与色调归纳（色彩气质） | 业务规则、视图状态、持久化 |
| `Services/Media/PersonAvatarLoader.swift` | 人物 / 宠物头像的取图请求、后台解码与内存缓存 | 视图状态、业务规则 |
| `Domain/PersonInsight.swift` | 人物摘要派生模型：年度/时段/地点/同框/高光与画像文案 | IO、SQL、视图状态 |
| `Domain/PlaceInsight.swift` | 地点摘要派生模型：到访轨迹/四季/时段/地标/坐标与足迹文案 | IO、SQL、视图状态 |
| `Features/People/PersonInsightViews.swift` | 人物详情页头（摘要 / 全部切换）、摘要卡片、高光与色彩展示 | 数据聚合、SQL、路径拼接 |
| `Features/Maps/PlaceDetailView.swift` | 地点详情：地图感页头、到访轨迹、四季、地标、旅行日志式照片墙 | 数据聚合、SQL、路径拼接 |
| `Domain/RevisitInsight.swift` | 「值得重看」派生模型：按人物 / 地点 / 场景 / 年份拆主体，最久未打开排序、年份分层与摘要文案 | IO、SQL、视图状态 |
| `Features/Revisit/RevisitView.swift` | 值得重看总览（今日重看、主体切换、只看未打开、时光碎片）与主体详情（封面叙事、年份筛选、排序、框选） | 数据聚合、SQL、路径拼接 |
| `Store/LibraryStore+Revisit.swift` | 当前范围（拾光 / 系统图库 / 网盘）的重看照片与主体拆分入口 | 视图绘制、SQL 拼接 |
| `Store/LibraryStore+Beauty.swift` | 智能美化：扫描推荐分组、批量渲染美化副本、应用前确认 | 视图绘制、SQL 拼接 |
| `Store/LibraryStore+Deletion.swift` | 删除生命周期：资产文件产物与数据库痕迹的统一清理、软删除脱离相簿、删除确认请求 | 视图绘制、单独的删除流程分支 |
| `Features/Gallery/DeleteConfirmView.swift` | 删除确认卡片（扇形缩略图预览、数量与类型拆分、可撤销/不可撤销的按钮与默认键）与断开连接确认卡片 | 删除逻辑、路径拼接 |
| `Domain/BeautyRecommendation.swift` | 美化候选、分组与报告模型 | 扫描逻辑、IO |
| `Features/Organize/BeautyRecommendView.swift` | 智能美化推荐面板（分组卡片、查看、一键美化） | 扫描算法、路径拼接 |
| `Features/Editor/EditState+Beauty.swift` | 把美化建议按强度叠加到 `EditState` | 视图状态、扫描 |
| `Domain/AIAgentModels.swift` | 智能助手提供商、配置、对话与检索建议模型 | 网络请求、Keychain、视图状态 |
| `Services/AI/AIProviderClient.swift` | OpenAI 兼容的 chat/completions 请求与错误映射 | 业务规则、UI、持久化 |
| `Services/AI/AILibraryContext.swift` | 当前范围快照 → 提示词、检索建议解析 | 直接读数据库、发送请求 |
| `Services/AI/AIImageEncoder.swift` | 发送前把照片压成长边 1024 的 JPEG data URL | 保存图片、修改图库 |
| `Services/AI/AILibraryTools.swift` | 工具定义（搜索/相簿/收藏/关键词/选中）与参数解析 | 直接改图库、弹窗确认 |
| `Services/AI/AILibraryCinemaTools.swift` | 影院工具定义（浏览/播放/个人状态/清单/维护）与确认文案 | 直接改图库、弹窗确认 |
| `Services/AI/AIKeychain.swift` | 智能助手 API Key 的读写（转调统一凭据保险库，旧条目一次性迁移） | 直接调用 `SecItem*`、把 Key 写入数据库或日志 |
| `Services/Shared/KeychainAccess.swift` | 全应用唯一直接调用 Security.framework 的入口（读取 / 写入 / ACL） | 在业务代码里拼钥匙串查询 |
| `Services/Shared/LumaKeychainVault.swift` | 统一凭据保险库：所有业务凭据存一个钥匙串条目，进程内缓存 + 旧条目一次性迁移 | 每次启动重复读旧条目、逐功能弹授权 |
| `Store/LibraryStore+AIAgent.swift` | 智能助手状态、请求编排、对话持久化、检索建议应用 | 直接拼接 HTTP 请求（放 `AIProviderClient`） |
| `Store/LibraryStore+AITools.swift` | 工具执行与写操作确认；只调用现有 Store 方法 | 绕过 `save()`、直接写 SQLite |
| `Store/LibraryStore+AICinemaTools.swift` | 影院工具执行：检索、播放、收藏 / 想看 / 评分、清单、忽略、元数据刷新、跳过片头、观看记录 | 绕过 `LibraryStore` 直接写文件或数据库 |
| `Features/AI/AIAssistantView.swift` | 智能助手面板（对话、照片引用、检索建议） | 网络与持久化细节 |
| `Features/Organize/LibraryHealthView.swift` | 图库体检页（指标、卡片、相似组预览、清理入口） | 扫描算法、路径拼接 |
| `Features/Maps/FootprintPlaybackView.swift` | 足迹回放覆盖层：统一时钟、连续跟随镜头、同步光点、胶片质感 HUD 与控制台 | 站点聚类、视觉匀速与巡航帧计算（放 `LumaCore/FootprintPlayback`） |
| `Domain/CloudInsight.swift` | 网盘分类范围 `CloudScope`、分类计数与按文件名的截屏识别 | IO、Vision、视图状态 |
| `Services/Cloud/CloudEXIF.swift` | 网盘照片头部 EXIF 解析（拍摄时间 / 相机 / 镜头 / 曝光 / GPS）与 JPEG TIFF 回退解析 | 网络请求、UI、数据库 |
| `Store/LibraryStore+CloudInfo.swift` | 网盘 EXIF 扫描编排、地图 / 位置 / 人物 / 值得重看 / 重复项目 / 相似检索 / 图库体检派生 | 视图绘制、SQL、写网盘 |
| `Store/LibraryStore+CloudInsight.swift` | 网盘分类筛选、端侧识别编排与计数缓存 | 视图绘制、SQL |
| `Features/Sidebar/CloudMountDetailView.swift` | 打开中网盘的「媒体类型 / 场景 / 更多项目」入口与各自的收起状态 | 网络请求、筛选算法 |
| `Domain/PhotoQuery.swift` | 可下推的范围/筛选/排序描述与 `SidebarItem` 映射 | SQL、IO |
| `Services/Library/MetadataStore+Query.swift` | `PhotoQuery` → SQL：count / page / index / neighbor / 索引提示 | UI、业务规则 |
| `Sources/LumaCore/` | 无 UI 依赖的纯算法：网格布局、缩略图档位、美化建议（`BeautyAdvisor`）、足迹站点与连续巡航编排（`FootprintPlayback`）、票据 / 证件文字判定（`DocumentText`）、地标就近匹配（`LandmarkCatalog`） | 任何 AppKit/SwiftUI/模型 IO |
| `Services/Library/LibraryPaths.swift` | 图库与系统路径的唯一入口 | 业务规则、UI |
| `Services/Import/ImportService.swift` | 导入、缩略图生成、预览缩略图 | 业务规则（由 Store 决定） |
| `Services/Media/ImageLoader.swift` | 缩略图/显示图解码与内存缓存 | 视图状态 |
| `Services/Library/MetadataStore.swift` | SQLite schema 与读写 | 直接访问文件系统 |
| `Services/Library/MetadataStore+DerivedCache.swift` | 跨范围派生缓存表（`system_analysis` / `derived_reports` / `cloud_assets` / `cloud_people`）的读写与清理 | 业务规则、视图状态 |
| `Domain/CacheRecords.swift` | 网盘缓存行模型与派生报告缓存键 | IO、数据库 |
| `Store/LibraryStore+SystemCache.swift` | 系统图库识别 / 特征缓存的回填、落库与签名失效 | 视图绘制、SQL |
| `Store/LibraryStore+CloudCache.swift` | 网盘 EXIF / 识别 / 特征 / 查看记录的落库与目录回填、网盘体检报告缓存 | 视图绘制、SQL、网络请求 |
| `Services/Media/PhotoKitBridge.swift` | 系统「照片」图库的真实写入（PhotoKit 编辑 / 删除 / 相簿 / 收藏隐藏 / 文件夹验证）与权限申请 | 业务规则、UI、直接改 `Photos.sqlite` |
| `Store/LibraryStore+SystemAlbums.swift` | 系统图库相簿增删改、照片加入移出与手动排序、写回前校验与内存同步 | 视图绘制、SQL、直接改 `Photos.sqlite` |
| `Domain/Models.swift` | 纯数据模型与枚举 | 网络/IO |
| `Features/Gallery/GalleryView.swift` | 网格容器、工具栏、拖放与框选 | 文件写入、缩略图解码细节 |
| `Features/Gallery/PhotoGrids.swift` | 正方形/瀑布流网格布局 | 业务规则 |
| `Components/PhotoCell.swift` | 网格单元格（选择、悬停、拖放、右键菜单） | 缩略图解码细节（复用 `PhotoThumbnailLoader`）、路径拼接 |
| `Components/PhotoThumbnailView.swift` | `PhotoThumbnailView` / `PhotoThumbnailLoader`：所有缩略图取图 | 业务规则、视图状态 |
| `Features/Viewer/InfoPanelView.swift` | 查看器信息面板 + `PhotoInfoContent`（网格浮动信息卡共用同一份完整字段） | 另一套独立的详情字段（新字段只改这里） |
| `Features/Cloud/CloudWizard*.swift` | 网盘接入向导：根视图 + 各接入方式的步骤视图与动作扩展 | 网盘协议实现、凭据持久化 |
| `Features/Gallery/TimelineOverviewView.swift` | 年/月总览卡片 | 数据分组规则（复用 `store.sections`） |
| `Features/Settings/*` | `SettingsKeys`、设置模型 `AppSettings`、设置窗口 | 业务逻辑 |
| `Services/Cloud/CloudProviders.swift` / `WebDAVClient.swift` / `SMBClient.swift` / `CloudSupport.swift` | 网盘协议与接口 | UI |

### 单文件行数上限

- **单文件 2000 行是硬上限（含注释与空行）。** 新代码不得让文件超过 2000 行。
- 超过 2000 行时先按职责拆分，再继续加功能。优先拆法：
  1. 纯模型 / 纯算法 / 解析器 → `Domain/` 或 `Services/`；
  2. 可独立复用的视图块 → 同 Feature 下的 `*View.swift` / `*Card.swift`；
  3. 状态与动作 → 独立 `ObservableObject` 或 Store 扩展；
  4. 最后才保留一个只负责组装的主文件。
- 现有超限文件不要求一次性重写；每次触碰时必须至少做到“不再增加行数”，并把本次新增逻辑放进新文件。拆分是行为保持重构，必须单独提交，不和功能改动混在一起。
- 当前超限清单（2026-11-22，按优先级逐步处理）：

| 文件 | 行数 | 首选拆法 |
| --- | ---: | --- |
| `Features/Cinema/CinemaLibraryView.swift` | 10088 | 海报墙 / 详情 / 剧集 / 筛选 / 任务 / 设置拆成独立视图 |
| `Features/Viewer/VideoPlayback.swift` | 3476 | 播放编排、字幕、音频、诊断、UI 覆盖层分文件 |
| `Features/Gallery/GalleryView.swift` | 3384 | 时间轴、网格、搜索、工具栏、拖放分文件 |
| `Store/LibraryStore+Cinema.swift` | 3207 | 刮削、播放、进度、清单、作用域拆扩展文件 |
| `Features/Catalog/CatalogChannelView.swift` | 3021 | 频道页、详情、卡片、筛选、工具栏分文件 |
| `Features/Collections/CollectionsView.swift` | 2805 | 精选集总览、详情、卡片分文件 |
| `Services/Library/SystemIndex+Direct.swift` | 2673 | 查询、映射、同步拆文件 |
| `Store/LibraryStore+Cloud.swift` | 2240 | 扫描、目录、播放、缓存、维护拆扩展文件 |
| `Features/Viewer/PhotoViewer.swift` | 2106 | 画面、HUD、控制条、手势、键盘分文件 |
| `Services/Library/SystemIndex.swift` | 2042 | 建库、增量同步、查询拆文件 |

---

## 4. 状态与持久化规范

- `photos`/`albums`/`folders` 的 `didSet` 只负责刷新视图版本号（`contentRevision`）。**任何修改后必须显式调用 `save()`**，否则重启丢失。
- 修改模型字段时：
  1. 在 `Models.swift` 中给新字段**默认值**（保证旧 JSON/SQLite 记录可解码）；
  2. 在 `MetadataStore` 中同步 `CREATE TABLE`、`photo(from:)` 读取、`write(_:)` 写入；
  3. 旧库升级通过 `addColumnIfNeeded("assets", "列名", "类型")` 补列，禁止让用户重建图库；
  4. 用已有图库启动一次，确认历史数据仍在。
- 一次性迁移逻辑（旧目录 → 分片目录、旧 JSON → SQLite）写在 `LibraryPaths`/`MetadataStore` 的迁移方法中，必须幂等。
- 删除记录必须走 `LibraryStore.purgeAssetArtifacts(_:)` + `purgeAssetMetadata(_:)`（`Store/LibraryStore+Deletion.swift`）：原图、实况照片配对视频、缩略图 / 快速缩略图、编辑渲染结果、压缩备份、转码缓存、网盘缩略图一并删除并 `ImageLoader.invalidate(photo:)`；数据库侧由 `MetadataStore.removeAssetDerivedData(_:)` 清掉 `asset_analysis` / `person_assets` / `scanned_faces` / `asset_overlays` 与没有照片的空人物，相簿成员与封面由 `detachFromAlbums(_:)` 处理（软删除同样要脱离相簿）。永久删除与「最近删除」过期清理共用这一份清单，不要在两处各写一套。
- 端侧智能分析结果写在 `asset_analysis` 表（`asset_id` 主键 + `labels` / `text` / `feature` BLOB / `updated_at`），只允许经 `MetadataStore.saveAnalysis(_:)` / `removeAnalysis(_:)` 写入；内存里的 `analysisIndex` 只保留标签与文字，特征向量按需从数据库读，禁止把向量塞进 `PhotoItem`。删除照片时由 `purgeAssetMetadata(_:)` 同步清理 `removeAssetDerivedData(_:)` 与 `analysisIndex`。
- 场景匹配统一走 `SceneCatalog.matches(_:analysis:photo:)`（内部先调 `PhotoAnalysis.belongs(to:)`：比 Vision 标签，再比 `SceneCategory.keywords` 的 OCR 关键词；票据、证件靠文字判定）。`PhotoIntelligence` 会在 `labels` 里追加合成标签 `qrcode` / `barcode`（`VNDetectBarcodesRequest`）、`idphoto`（单人脸 + 竖幅/方幅 + 居中的启发式）、`invoice` / `idcard`（`LumaCore/DocumentText` 的发票特征词与身份证校验位规则），二维码 / 条码载荷以「二维码：/条码：」前缀并入 `text` 供搜索；翻拍类照片先用 `VNDetectDocumentSegmentationRequest` 裁出文档区域再 OCR（占画面不足 15% 不裁切）。「名胜古迹」额外接受地理位置命中：`SceneCatalog.matches(_:analysis:photo:)` 在标签 / 关键词都没命中时，用 `LumaCore/LandmarkCatalog` 按 EXIF 坐标就近匹配内置地标表，没有坐标再用 POI / 城市 / 区县文字匹配；地标表只用于归类与展示地标名，不联网、不落库。新增识别项后由「重新分析全部照片…」（`reanalyzeIntelligence()`）覆盖历史结果，不要在视图层另写匹配规则。
- 「最近查看」写在 `assets.viewed_at`，由 `LibraryStore.recordView(_:)` → `MetadataStore.setViewedAt(_:date:)` 单行更新（不要为一次打开触发全量 `save()`）；系统图库的 `viewedAt` 只来自 `Photos.sqlite`，不写回。
- 图库级撤销 / 重做（`LibraryStore+Undo`）：可逆的元数据变更在 `save()` 之后必须调用 `recordUndo(_:beforePhotos:beforeAlbums:beforeFolders:)` 记录修改前的快照；撤销 / 重做只回填内存快照再 `save()`，不得调用会重新记录撤销的公开方法。撤销栈只在内存里保留最近 30 步，切换图库时由 `resetUndoHistory()` 清空；永久删除、清空最近删除、导入、编辑与压缩不进入撤销栈。`⌘Z` / `⇧⌘Z` 统一走 `performUndoCommand()` / `performRedoCommand()`（文本输入中转发给系统文本框，编辑器内由编辑器自己的调整历史处理）。
- 「图库体检」是**派生视图**：扫描结果放在 `healthReport`（内存）并**写入当前图库的 `derived_reports`**（key = `local|health` / `system|<图库路径>|health` / `cloud|<挂载>|<目录>|health`），打开页面时由 `restoreCachedHealthReportIfNeeded()` / `restoreCloudDerivedReports` 回填；判定阈值集中在 `LibraryHealthTuning`，不要散落到视图里。系统图库复用 `scanLibraryHealth`，从 `systemLoadedPhotos`（索引模式为当前窗口）用缩略图检查，结果标记 `healthReportScopeTag = "system"` 并按 `systemCacheSignature` 失效；网盘体检复用 `PhotoQuality.sharpness(cgImage:)` 与 `LibraryStore.buildSimilarGroups`，只检查当前目录（最多 500 张），并提供 `CloudHealthView`。只有官方「照片」图库作为当前图库时（`canDeleteSystemPhotos`），才允许经 PhotoKit 把相似备选移入「照片」的最近删除。
- 「值得重看」同样是**派生视图**：候选照片来自 `LibraryStore+Health.revisitPhotos`（阈值由 `LibraryHealthTuning` 决定），主体拆分、最久未打开排序、年份分层与摘要文案全部由 `Domain/RevisitInsight` 在打开页面时纯内存计算，不落库、不上传；视图只读 `Subject` 上预先算好的字段，不在 `body` 里遍历照片。人物主体来自本地人脸聚类或系统 / 网盘已有结果，地点主体复用 `PlaceClusterBuilder.clusters`，场景主体只取 `revisitSceneIDs` 里的回忆型分类。
- 「重复项目」同样是派生视图：分组与推荐保留项由 `Domain/Duplicates.swift` 纯计算，结果按 `contentRevision` 缓存到 `duplicateGroups`，不落库（计算来自本地 `assets`，无需缓存）。合并必须走 `LibraryStore.mergeDuplicateGroup` / `mergeAllDuplicateGroups`：保留一个版本、汇总收藏 / 关键词 / 标题 / 地点 / 相簿关系（含相簿封面），其余副本移入最近删除（可恢复）；批量合并只 `save()` 一次，禁止在视图层直接改 `photos` 或逐组调用 `delete`。系统图库复用同一视图（`.systemDuplicates`），分组来自 `systemDuplicateGroups`（补充官方 `isDuplicateItem` 标记），副本只能经 `hideSystemDuplicateCopies` / `hideAllSystemDuplicateCopies` 写 `asset_overlays` 隐藏、`importSystemDuplicateKeep` 拷贝到拾光，或（官方库作为当前图库时）经 PhotoKit 移入「照片」最近删除；额外连接的系统图库仍不可删除。
- 「智能美化」同样是派生视图：推荐分组放在 `beautyReport`（内存）并写入 `derived_reports`（`local|beauty` / `system|<图库路径>|beauty` / `cloud|<挂载>|<目录>|beauty`），换库时由 `resetBeautyState()` 清空内存；阈值与调整量集中在 `LumaCore/BeautyAdvisor`，App 侧 `PhotoBeauty` 只负责采样。网盘范围用 `cloudThumbnail` + `PhotoBeauty.advice(image:)` 扫描（`CloudBrowserModel.beautyReportIsCloud` 标记来源），批量应用走 `applyCloudBeauty`：下载/读取原图 → 同一套 `EditState.beautified` + `PhotoRenderer` → 作为新照片导入当前图库，网盘文件不变。系统图库用 `scanSystemBeautyCandidates` 采样（`beautyReportIsSystem` 标记来源）；应用有两种出口：`applySystemBeauty` 从官方原图渲染后经 `ImportService.importFile` 另存到拾光，或（官方库作为当前图库时）`applyBeautyToSystemOriginals` 经 PhotoKit 写回原图并在「照片」里保留可撤销的调整。来源标记必须参与推荐面板的过期判断，禁止跨范围复用扫描结果。
- 「人物摘要」同样是派生视图：年度轨迹、时段偏好、地点、同框人物与「色彩气质」都由 `Domain/PersonInsight` 在打开人物时从可见照片派生，不落库、不上传；本地图库在内存里计算，系统图库索引模式必须走 `SystemIndex.personInsight(_:)` 的 SQL 聚合，禁止为了摘要把整库照片读入内存。高光照片只读取缩略图，色彩采样最多 10 张。
- 本地人脸聚类只有 `startFaceClustering()`（增量：只处理不在 `scannedFaceIDs` 里的照片）与 `resetFaceAnalysis()`（清空扫描记录与聚类后从头跑）两个入口；剩余量由 `pendingFacePhotoCount` 提供并按内容版本缓存，禁止在视图里自己遍历 `photos` 统计。重新识别必须换 `faceClusterToken` 作废旧任务的收尾写回，否则旧任务会把旧结果覆盖回来。系统图库的人物只能经 `refreshSystemPeople()` 重新读取官方结果，不得调用本地聚类。
- 「人物」总览的聚合筛选（`PeopleGroupFilter`：全部 / 已命名 / 待命名 / 宠物）只做展示筛选，选择存当前图库的 `SettingsKeys.peopleFilter`；分节依据 `SystemPersonInfo.isUnnamed` / `isPet` 与 `LocalPerson.isUnnamed`，不要在视图里另写命名规则。「全部」必须平铺展示、不按命名状态分节；只有点选某一项后才收窄集合，筛选为空显示对应空状态。
- 「个人收藏」的浏览方式（`FavoritesViewMode`：全部 / 年 / 类型 / 地点 / 相机 / 人物）只做展示层：状态存 `SettingsKeys.favoritesViewMode`，汇总数据由 `LibraryStore+Favorites` 一次载入完整收藏列表后交给 `FavoritesDigestBuilder` 生成。相机维度必须经 `CameraBrand.detect` 按品牌聚合，品牌配色与设备插画只放在 `FavoritesDigestView`（`brandColors` / `BrandDeviceArt`），不要在 Domain 里引入 SwiftUI；地点按城市、人物只统计已命名。点分类卡片设置 `selectedFavoriteBucket` 下钻，`computeVisiblePhotos` 会从 `favoritesDigestSource` 过滤并关闭分页；顶栏用 `clearFavoritesBucket()` 返回当前维度。系统图库索引模式最多载入 30,000 条收藏。
- 「地点摘要」与人物摘要共用页面交互与高光 / 色彩组件，但统计独立：`Domain/PlaceInsight` 只基于该地点聚类里的照片（到访轨迹、四季、时段、POI 地标、坐标），同框人物来自本地人脸聚类或系统图库已有结果；同样不落库、不上传，照片列表直接使用聚类快照，避免受分页窗口与当前筛选影响。
- 网盘分类浏览同样是**派生视图**：范围枚举与计数模型在 `Domain/CloudInsight.swift`，筛选在 `LibraryStore+CloudInsight`，端侧识别结果放在 `CloudBrowserModel.analysis`（内存）并写入 `cloud_assets`（`mount_id + path`，同一行还存 EXIF / 特征 / 查看记录）；切换挂载、断开连接或换库时必须调用 `resetCloudInsight()` 清空内存，断开挂载时由 `removeCloudMount` 清理该挂载的 `cloud_assets` / `cloud_people` / 派生报告。网盘文件**带有 EXIF**：拍摄时间、相机、镜头、曝光与 GPS 由 `Services/Cloud/CloudEXIF` 读取文件头部解析（SMB 直接读挂载文件，WebDAV 走 `Range: bytes=0-262143`，官方网盘用直链 + Range），结果写回当前 `cloudPhotos` 的 `PhotoItem` 与 `cloudDirectoryCache`（内存）并落 `cloud_assets`；进入目录时由 `hydrateCloudCache` 按「路径 + 文件大小」校验后回填。媒体类型仍按扩展名/文件名推断（截屏走 `CloudMediaNaming.looksLikeScreenshot`），不要把文件名推断说成相机元数据。
- 智能美化只生成渲染副本（与编辑器同一条 `commit` 管线：`Luma/resources/renders/` + `editRecipe` + `editVersion` + `ImageLoader.invalidate`），绝不覆盖原图；已编辑照片从原图重建编辑点后再叠加建议，不能丢弃用户已有调整。系统图库可经 PhotoKit 把美化结果作为可撤销调整写回原图（`applyBeautyToSystemOriginals`），这仍然不是覆盖原文件。
- 跨范围派生缓存（系统图库识别 / 特征、体检与美化报告、网盘 EXIF / 分析 / 人物 / 查看记录）必须落当前图库的 `Luma.sqlite`：`system_analysis`（按 `library_path`）、`derived_reports`（按范围 key + signature）、`cloud_assets`（按 `mount_id + path`）、`cloud_people` / `cloud_person_assets`（按 `mount_id`）。缓存必须带失效条件：系统图库用 `systemCacheSignature`（图库路径）比对 `system_analysis_signature|<path>`，不一致时 `purgeSystemCache` + `removeDerivedReports(prefix:)`；照片增删不会让整库识别缓存作废；网盘按「远端文件大小」校验，断开挂载时 `purgeCloudAssets` / `purgeCloudPeople` / `removeDerivedReports`。禁止把这些缓存写进 Apple 的目录、`Photos.sqlite` 或网盘。
- 系统图库的真实写入只能经 `PhotoKitBridge`（`PHPhotoLibrary.performChanges` + `PHContentEditingOutput` / `deleteAssets` / 相簿与文件夹的 ChangeRequest），且必须 `canWriteSystemOriginals` / `canDeleteSystemPhotos` / `canManageSystemAlbums`（`isSystemScope && isNativeContainer`）为真；由 Photos 自己更新原图与它的数据库。禁止直接以 SQL 改 `Photos.sqlite`，也禁止对额外连接的系统图库做真实写入。
- 系统图库相簿写回：`LibraryStore+SystemAlbums` 提供新建 / 重命名 / 删除相簿、照片加入 / 移出 / 移到最前最后、收藏 / 隐藏写回。相簿映射用 Photos.sqlite 的 `ZGENERICALBUM.ZUUID`（`SystemAlbumInfo.uuid`，由索引或按需回查得到），由 `PhotoKitBridge.fetchAlbum` 解析 localIdentifier。删除相簿只删相簿本身，不删照片；新建后需要 `reloadSystemLibrary()` 才能拿到新相簿的 Z_PK。执行前必须 `prepareSystemLibraryWrite()`（权限 + 用样本照片校验「打开的就是系统照片库」），校验失败时收藏 / 隐藏退回 `asset_overlays`，相簿操作直接中止并提示。
- 文件夹管理尚未接入：`PhotoKitBridge.verifyFolderWriteSupport()` 会临时新建一个文件夹读回类型并删除，用于验证「照片」是否允许通过 PhotoKit 管理文件夹；只有验证通过后才能继续实现，不能假定可用。

### 智能助手（AI）

- 配置写当前图库的 `settings`（`ai_config`），对话写 `ai_conversation`；两者都是 **per-library** 数据，切换图库时由 `loadAIState()` 重新读取。API Key 只能经 `AIKeychain` / `LumaKeychainVault` 写统一凭据保险库（旧版 service `com.baymax.luma.ai` 的条目只读取一次后迁入），禁止写入数据库、`UserDefaults`、日志或对话内容。
- 请求只能经 `AIProviderClient`（OpenAI 兼容 `chat/completions`）发出，不引入第三方 SDK；新增提供商只增加 `AIProvider` 的默认 Base URL / 模型与设置项。
- 提示词只能由 `AIContextBuilder` 组装：当前范围摘要 + 最多 40 张候选照片的元数据/本地 Vision 标签/OCR；禁止把整个 `photos` 数组或文件路径序列化给模型。
- 图片默认不发送。开启「图片理解」后，只能经 `AIImageEncoder` 压成长边约 1024 的 JPEG（单次最多 6 张），跳过 RAW、视频与云端照片；不得上传原图。
- 智能助手可通过工具修改图库，工具分为九类：
  - 检索：`search_photos` / `list_albums` / `list_folders` / `list_videos`
  - 浏览：`navigate` / `select_photos` / `open_photo`
  - 相簿：`create_albums` / `add_photos_to_album` / `remove_photos_from_album` / `rename_album` / `delete_album` / `move_album` / `set_album_cover`
  - 文件夹：`create_folder` / `rename_folder` / `delete_folder`
  - 图片与视频：`set_favorite` / `set_hidden` / `add_keywords` / `remove_keywords` / `set_title`
  - 压缩：`compress_photos`
  - 美化：`beautify_photos`
  - 最近删除：`trash_photos` / `restore_photos`
  - 影院：`list_cinema_items` / `list_cinema_scopes` / `cinema_tree` / `search_cinema_library` / `list_cinema_series` / `list_cinema_lists` / `list_cinema_activity` / `navigate_cinema` / `play_cinema` / `search_cinema_candidates` / `apply_cinema_match` / `scrape_cinema` / `match_cinema` / `update_cinema_state` / `manage_cinema_list` / `ignore_cinema` / `restore_cinema_ignored` / `refresh_cinema_metadata` / `set_cinema_intro_skip` / `manage_cinema_progress`
  - 网络资源：`list_catalog_sources` / `search_catalog` / `catalog_new_today` / `list_catalog_following` / `list_catalog_watchlist` / `browse_catalog` / `play_catalog_item` / `set_catalog_watchlist` / `follow_catalog_person`
- 工具定义与参数解析集中在 `AILibraryTools`（含 `AILibraryCinemaTools` 的影院扩展；`writeToolNames` / `describe`），执行在 `LibraryStore+AITools` / `LibraryStore+AICinemaTools`；新增工具必须同时补齐定义、写操作白名单、确认文案、执行分支与 README/官网说明。
- 所有写操作必须先经用户确认，再调用 `LibraryStore` 现有方法并 `save()`；禁止直接写 SQLite、删除或编辑原图、导入，禁止写官方 `Photos.sqlite`（官方库只允许 `asset_overlays` 的收藏 / 隐藏 / 关键词等补充元数据）。
- 工具参数里的照片 ID 必须验证为当前图库中真实存在且未删除的项目；工具失败或用户取消时，必须把失败结果回传给模型，不能伪造成功。模型回答不得声称未通过工具完成的操作已执行。
- 智能助手不提供永久删除（`trash_photos` 只移入最近删除，可用 `restore_photos` 恢复）、导入、编辑原图与改文件能力，也不支持在只读来源写入。
- `compress_photos` 必须复用 `PhotoCompressor`（与压缩面板同一引擎），禁止在 AI 层另写编解码；只允许本地图库、非视频项目，且只在结果更小时替换原文件（`onlyIfSmaller = true`）。压缩支持 `mode = lossy / lossless`：有损可调质量、长边与格式；无损保持像素与尺寸，JPEG 仅经 `LumaCore/JPEGMetadataStripper` 剥离 EXIF / XMP / IPTC / COM，其它格式重编码为 PNG。压缩参数（模式、质量、长边、格式、备份）由工具参数临时构造 `CompressionSettings`，不得修改用户在压缩面板里的默认设置。
- `beautify_photos` 必须复用 `LibraryStore.applyBeauty(to:strength:)`（与编辑器/美化建议同一管线），只生成可还原的美化副本并保留原图；禁止 AI 层直接写 `editedFilename` 或覆盖原文件，只允许本地图库的非视频项目。

### 缩略图与缓存

- 缩略图统一走 `ImageLoader.thumbnail(for:)`：内存 `NSCache` + 磁盘文件；`cacheKey` 含 `editVersion`，编辑保存后必须 `ImageLoader.invalidate`。
- 视图层取图统一走 `PhotoThumbnailView(photo:purpose:)`（内部 `PhotoThumbnailLoader` 负责缓存命中、快速层与目标档位）：按实际显示尺寸选 `.grid(maxPixel:)` / `.cover(pt)` / `.filmstrip(pt)` / `.preview(pt)`，禁止在视图里另写解码顺序，也禁止封面类一律解码 1200px。
- 不得把 `NSImage` 存入 `PhotoItem` 或任何 `Codable` 模型。
- 网盘缩略图优先服务端缩略图；WebDAV 走 `Range: bytes=0-262143` + EXIF/渐进式探测，禁止为了缩略图整文件下载。

---

## 5. 图库与文件系统不变量

- 图库是 `.photoslibrary` 包；**拾光的数据统一写入包内 `Luma/` 目录**（`Luma/database/Luma.sqlite`、`Luma/originals/`、`Luma/resources/`、`Luma/cloud/` 等），图库根目录只保留 Apple 自己的结构。官方库里的 `Photos.sqlite` 与 Apple 自带原图只读：不修改 Apple 的数据库、`originals/` 与 `resources/`。真实编辑 / 删除系统图库照片必须经 PhotoKit（见 §4），由 Photos 自己写原图与数据库；任何情况下都不得用 SQL 直接改 `Photos.sqlite`。
- 旧版 `private/com.lijialong.photosclone/` 的数据由 `migrateSidecarToLibraryRootIfNeeded` 上移（幂等）。**数据库迁移禁止直接搬运 `-wal` / `-shm`**：先把旧库三件套复制到临时目录、用 SQLite 打开做 `wal_checkpoint(TRUNCATE)` 合并，再只把主库文件搬进图库目录；把别的库的日志放进当前库目录会被当成当前库的日志回放，直接覆盖现有数据。
- **没有图库时不允许创建任何固定位置数据**：
  - `LibraryPaths.configure()` 在无图库时不得调用 `prepare()`（除非检测到旧版本地数据用于迁移）；
  - `LibraryStore` 在 `needsLibrarySetup == true` 时不得打开/创建 `MetadataStore`；
  - 主界面被 `RootView` 的建库门禁挡住，此时不应有写操作。
- 切换图库必须经过 `LibraryPaths.switchContainer(to:migratingLocalData:)`，它会处理目录结构与数据迁移；不要手工搬文件。
- 打开任意图库（含官方「照片」图库）都以该图库为准：`activateLibrary(_:)` 统一走 `switchLibraryContainer(_:)`，展示该库自己的内容，元数据写入该库自己的 `Luma/database/Luma.sqlite`。打开图库时传 `migratingLocalData: false`，不把上一个库的内容搬进新库；只有建库引导的「迁入旧库」才迁移。侧边栏「系统图库」的 `connectSystemLibrary(_:)` 仍是只读浏览，不切换当前图库。
- 图库选择记录：`UserDefaults["settings.recentLibraries"]`（最多 10 个），由 `rememberLibrary(_:)` 维护；当前图库以 `Application Support/Luma/ContainerPath.txt` 为真源。
- 侧边栏固定三个分区：**拾光**（本地图库范围）/ **系统图库**（`store.systemLibraries`，可保存多个连接，同一时间只有一个处于连接/展开状态，只读）/ **网络存储**（`store.cloudMounts`）。当当前图库就是官方「照片」图库时（`isNativeContainer`），主侧边栏直接展示该库自己的结构（图库 / 精选集 / 固定 / 媒体类型 / 更多项目 / 场景 / 相簿），「固定」条目自动指向系统图库入口，不再渲染「拾光」「系统图库」两个分区；此时它自己的连接不再需要出现在系统图库列表里（`loadSystemLibraries()` 会剔除当前容器自身）。系统图库的连接列表与该连接状态都是 **per-library** 数据：写在当前图库自己的 `MetadataStore.settings`（`system_libraries` / `system_library_path`），切换图库时必须重新 `loadSystemLibraries()`；`UserDefaults["settings.systemLibraries"]` 只作为旧版全局列表的一次性迁入来源。连接用 `registerSystemLibrary(_:)`（追加或更新），断开用 `removeSystemLibrary(_:)`。网络存储的 `cloud_mounts`、云端收藏 `cloud_favorites` 同样写在图库自己的 settings 里。
- 切换 / 新建图库必须走 `reloadPerLibraryState()`：它会重读图库级设置、视图状态、系统图库连接、网盘挂载与收藏；切换前先调用 `resetCloudStateForLibrarySwitch()` 清空上一个图库的挂载与目录缓存，否则旧挂载会被当成新库的连接写回新库。
- 每个图库只管理自己的数据：照片与元数据、系统图库连接、网盘挂载与收藏、库级设置（视图状态 / 导入选项 / 最近删除保留期 / 系统图库载入上限 / 网格元数据显示）全部写在该图库内。新图库必须以空连接、默认设置启动；只有旧版全局设置会在升级时一次性迁入当时打开的图库。
- 系统「照片」图库的扫描结果（索引与元数据，不含原图）缓存在当前图库的 `resources/system-cache/`，缩略图缓存在 `resources/system-thumbs/`，签名取 `Photos.sqlite` 的大小 + 修改时间，并记录生成快照时的载入上限（`settings.system.maxAssets`）；签名变化或载入上限与当前设置不一致时必须重扫，不得把旧上限的快照当成最新缓存。超大图库按 `settings.system.maxAssets`（随图库保存，默认 0 = 不限制）从新到旧截断载入，`SystemLibrarySnapshot.totalAssetCount` 保留真实总数用于提示；禁止为系统图库复制原图，拷贝出口仍走 `importSystem*`。不限制载入时也必须按拍摄日期从新到旧分批扫描（`ZDATECREATED` 索引子查询 + `CROSS JOIN` 固定顺序），保证边扫边显示时媒体类型、相簿等范围能尽早出图，禁止按 `ZASSET` 原始行序扫描到结尾才出现分类内容。十万项以上走 `SystemIndex.prepare` 建索引时同样必须通过 `onBatch` 逐批把 `PhotoItem` 交给主线程（`drainSystemBatches`，先显示缓冲上限 `systemStreamDisplayLimit`），索引就绪后再 `applySystemIndex` 切换成 SQL 窗口，禁止让界面在索引写完前一直空白。
- 相簿 / 文件夹与人物列表都是纯元数据：重扫或建索引前必须先调用 `SystemIndex.albumMetadata` / `SystemIndex.peopleMetadata` 直接读 `Photos.sqlite`（只查 `ZGENERICALBUM` / `ZPERSON` / `ZFACECROP` 与关键人脸），把侧边栏与人物页先展示出来，不要等照片扫描结束；扫描 / 索引完成后再用完整数据替换。扫描期间 `systemAlbumIsEmpty` 不得按空的 `assetIDs` 判定为空相簿。
- 系统图库缩略图必须**优先读官方 `resources/derivatives`**（照片 `_1_105_c.jpeg`、视频 `_1_102_o.jpeg` 封面帧，路径由 `LibraryPaths.systemDerivativePath` 推导，扫描时记录到 `systemThumbnailPath`），只有文件缺失时才从原图 / 视频现场生成到 `system-thumbs/`；生成必须经过 `ImageLoader` 的并发门控（3 路）与同文件去重，禁止为网格滚动同时解码几十张原图。
- 打开相簿 / 文件夹时由 `LibraryStore.navigate(to:)` 触发 `prewarmOpenedCollection`：用 `ImageLoader.prewarmQuickThumbnails` 预热前 300 张的快速层缩略图（3 路并发，解码后写入本地 quick 缓存），让首屏与回看直接命中；切换范围取消上一次预热，换库时在 `reloadPerLibraryState()` 取消。预热只做快速层，禁止扩充到整本相簿或抢占可见格子的解码优先级。
- 系统图库的相簿 / 文件夹分组缓存键是 `systemStructureRevision`（只随相簿、文件夹变化），不是 `contentRevision`；侧边栏计数统一走 `systemSidebarCounts` 的一次遍历缓存。禁止在扫描过程中按每批照片重建相簿分桶或对每个计数各扫一遍全库。
- 十万级以上的系统图库「所有照片」网格在视图层按 1200 张渐进渲染（`systemRenderLimit`，滚动到底追加），避免 SwiftUI 对整库做 diff；本地大图库仍走 SQL 分页窗口。
- 系统图库侧边栏的相簿与文件夹按 `ZGENERICALBUM.Z_PK`（`sortIndex`）排序并混排，与官方「照片」一致；不要改回按名称排序。打开系统图库默认 `grouping == .all`、`sortKey == .capturedAt` 降序。
- 官方相簿内部沿用 `Photos.sqlite` 关联表（`Z_<n>ASSETS`，按 `Z_FOK_3ASSETS` 排序）保存的显示顺序，包含官方的手动拖拽顺序；`sortKey == .capturedAt` 时不得再按拍摄日期重排相簿，改选其它排序字段时才由拾光排序。
- 侧边栏的文件夹（本地 `.folder` 与系统 `.systemFolder`）进入后只展示**下一层**的子文件夹与相簿卡片，不得把整个子树的照片直接铺开；系统文件夹用 `SystemFolderOverviewView`（只读，封面取子层第一个有内容的相簿）。
- 侧边栏一级分区标题（「相簿」「媒体类型」「场景」「更多项目」）可点击打开右侧二级总览：范围是 `.allAlbums` / `.systemAlbums` / `.mediaTypes` / `.systemMediaTypes` / `.scenes` / `.moreItems` / `.systemMoreItems`；「系统图库」「网络存储」分区标题分别对应 `.systemLibraries` / `.cloudStorages`，展示已连接图库与已接入存储的卡片。这些总览范围在 `photos(for:)` 返回空数组、`isGridScope` 必须排除，只渲染卡片墙视图（`AlbumsOverviewView` / `SystemFolderOverviewView` / `MediaTypesOverviewView` / `ScenesOverviewView` / `MoreItemsOverviewView` / `SystemLibrariesOverviewView` / `CloudStoragesOverviewView`）；卡片墙的数量与封面只能读 `store.mediaTypeSummary` / `store.sceneSummary` 的汇总缓存，禁止在视图里遍历整库。
- 侧边栏相簿与文件夹默认收起（只记录用户展开过的 `expandedFolders` / `expandedSystemFolders`），不要改成默认展开——系统图库可能有上万个相簿。

---

## 6. 权限矩阵（必须遵守）

| 范围 | 读取 | 写入（改元数据/删/编辑） | 上传/重命名/新建文件夹 |
| --- | --- | --- | --- |
| 本地图库 | ✅ | ✅ | ✅ |
| 官方「照片」图库作为**当前图库**（`isNativeContainer`，`sidebarItem` 为 `.system*`） | ✅ | 拾光补充元数据写 `asset_overlays`；编辑 / 删除 / 相簿增删改 / 加入移出排序 / 收藏隐藏经 PhotoKit 写回「照片」 | ❌ |
| 官方「照片」图库作为**额外连接**（只读浏览，`isSystemScope && !isNativeContainer`） | ✅ | ❌ | ❌ |
| WebDAV 网盘 | ✅ | ❌ | ✅ |
| SMB 共享 | ✅ | ❌ | ❌ |
| 阿里云盘 / 百度网盘 / 夸克网盘 / 115 网盘 | ✅ | ❌ | ❌ |

- 判断统一使用 `store.isSystemScope`、`store.isCloudScope`、`store.isReadOnlyScope`、`store.isNativeContainer`、`store.canEditNativeOverlay`、`store.isCurrentCloudWritable`。
- 智能美化在三种范围都可用（`store.canScanBeauty` = 已建库）：本地图库生成可还原的渲染副本；系统图库与网盘是只读来源，默认从原图（官方 derivative / 云端大图）渲染并把结果作为新照片导入当前图库；官方库作为当前图库时，系统图库还可选择经 PhotoKit 写回原图（可撤销）。菜单项、体检页入口与推荐面板都用同一个 `canScanBeauty` 判断。
- 官方「照片」图库是当前图库时，它是**增强对象**而不是只读浏览：内容读取 `Photos.sqlite`，拾光的补充元数据写在该库的 `Luma.sqlite`（`asset_overlays`，`MetadataStore.saveOverlay(_:_:)`），绝不回写 `Photos.sqlite`；编辑、删除、相簿增删改、照片加入移出与排序、收藏与隐藏只允许经 PhotoKit，导入与重命名仍然禁止。额外连接的系统图库（`!isNativeContainer`）一律只读。
- 任何写操作入口（菜单、右键、快捷键、工具栏）都必须先做权限判断；只读时菜单项应 `disabled`，不要只在执行时弹 Toast。
- 系统图库的拷贝出口：`importSystemSelectionToLibrary` / `importSystemAlbumToLibrary` / `importSystemFolderToLibrary`，目录递归用 `systemFolderAssetIDs`，重复项目按「同名 + 同大小」跳过。

### 6.1 三范围功能对齐（本地图库 / 系统图库 / 网盘）

同一功能只要在三种范围里说得通，就应当**三处都有入口、同一套外观**；确实做不到的，必须在本文与 `README.md` 里写明原因，并在界面上禁用入口或给出中文说明，不能静默消失或另画一套 UI。

| 能力 | 拾光本地图库 | 系统图库（含官方库作当前库） | 网络存储 | 约束 |
| --- | --- | --- | --- | --- |
| 浏览：网格 / 列表 / 瀑布流 / 完整宽高比、缩放、排序、筛选、搜索 | ✅ | ✅ | ✅ | 统一走 `ThumbnailAspect`、`store.thumbSize`、`photoFilter`、`sortKey`；网盘必须用 `cloudVisiblePhotos`，不得另写筛选分支。 |
| 相簿 / 文件夹 | ✅ 可增删改 | ✅ 相簿可增删改、照片可加入移出与手动排序；文件夹只读（待验证） | ✅ 按目录浏览 | 系统图库通过 PhotoKit 写回，需要官方库作为当前库；新建相簿后重新载入索引；网盘只读目录，WebDAV 仅额外支持新建文件夹与上传。 |
| 收藏 / 隐藏 / 关键词 / 查看时间 | ✅ | ✅ 收藏 / 隐藏经 PhotoKit 写回「照片」，关键词与查看时间写 `asset_overlays` | 仅收藏（`cloud_favorites`，写在当前图库） | 额外连接的系统图库、SMB 与官方网盘一律只读；写回失败时收藏 / 隐藏退回 `asset_overlays`。 |
| 场景 / 包含文字（端侧识别） | ✅ 结果落 `asset_analysis`，可重复分析 | ✅ 结果落 `system_analysis`（按图库路径），内存 `systemAnalysisIndex` 即时刷新 | ✅ 结果落 `cloud_assets`（按挂载 + 路径），内存 `CloudBrowserModel.analysis` 即时刷新 | 系统图库在后台持续识别（索引分页 200 张/次，结果逐张出现，可停止）；网盘每次 120 张。两者都只写当前图库的 `Luma.sqlite`；禁止写 `Photos.sqlite` 或网盘。**打开图库默认不识别**：只有用户本次运行中主动点过「识别照片内容…」且未手动停止时（`systemAnalysisAutoResume`），重新载入后才会对新增照片续跑。 |
| 值得重看（`revisit`） | ✅ | ✅ 只读派生（`LibraryHealthTuning` 阈值） | ✅ 只读派生 | 先按「拍摄超过两年 + 一年以上未打开」筛出候选，再由 `Domain/RevisitInsight` 按人物 / 地点 / 场景 / 年份拆主体（人物需共同出现 ≥2 张、地点 ≥2 张、场景 ≥3 张），年份分层与未打开计数在派生时算好，视图只展示；网盘用 EXIF 拍摄时间 + 本机查看记录（`cloud_assets.viewed_at` / `CloudBrowserModel.viewedAt`，不写网盘）判定，入口在「更多项目」。 |
| 图库体检（模糊 / 相似连拍 / 过大视频） | ✅ | ✅ 只读预览；官方库作当前库时可移入「照片」最近删除 | ✅ 只读预览 | 系统图库用官方 derivative / 缓存缩略图检查当前已载入照片（索引模式为当前窗口），结果落 `derived_reports`；网盘对当前目录缩略图逐张检查（最多 500 张），结果同样落 `derived_reports` 并按目录回填。网盘不提供清理动作；系统图库的清理只经 PhotoKit。 |
| 重复项目 | ✅ 可合并 | ✅ 隐藏副本 / 拷贝保留版本 / PhotoKit 移入「照片」最近删除 | ✅ 只读 | 网盘按「文件大小 + 像素尺寸」在内存分组，只展示与提示，不在本机合并网盘文件。 |
| 相似检索 | ✅ 特征库 | ✅ 特征落 `system_analysis`，结果进入 `similarScope` | ✅ 特征落 `cloud_assets`，结果进入 `similarScope` | 系统图库与网盘都对缩略图现算 `PhotoIntelligence.feature`（最多 80 张），结果按范围过滤浏览；系统图库索引模式只比较当前窗口。 |
| 智能美化 | ✅ 渲染副本 | ✅ 副本另存拾光，或 PhotoKit 写回原图（可撤销） | ✅ 副本另存拾光 | 系统图库从官方原图渲染、网盘从云端大图渲染；推荐结果落 `derived_reports`。写回原图仅限官方库作当前库（`canWriteSystemOriginals`），其余只另存副本。 |
| 地图 / 位置 | ✅ | ✅ | ✅ | 网盘 GPS 来自 `CloudEXIF`（WebDAV/SMB/官方网盘读取文件头部）；复用 `PhotoMapView` / `PlaceStatisticsView`，地名缺失时走本机逆地理编码。 |
| 人物 | ✅ 端侧聚类 | ✅ 官方识别结果 | ✅ 端侧聚类 | 网盘用 `cloudThumbnail` + `FaceClusterEngine.analyze(cgImage:assetID:)`，结果落 `cloud_people` / `cloud_person_assets`，切换挂载即清空内存。 |
| 导入 / 编辑 / 压缩 / 删除 / 重命名 | ✅ | 仅「拷贝到拾光」；编辑 / 删除 / 相簿与收藏隐藏经 PhotoKit，导入与重命名禁止 | 仅 WebDAV 上传 / 新建文件夹 | 只读范围必须 `disabled` 菜单项，执行层再做一次权限判断；PhotoKit 入口必须在 `isNativeContainer` 下才启用。 |
| 智能助手 | ✅ 读写（写操作需确认） | ✅ 只读问答 + 补充元数据类工具 | ✅ 只读问答 | 写工具统一受 `isReadOnlyScope` / `canEditNativeOverlay` 约束；不得绕过 `LibraryStore`。 |
| 信息面板 / 查看器 / 幻灯片 | ✅ | ✅ | ✅ 字段来自 EXIF | 共用 `InfoPanelView` 与查看器，不另写一套。 |

新增功能时按下面顺序落地，缺一不可：

1. 先判断该能力属于“读取 / 派生 / 写入 / 端侧分析”哪一类，再对照上表确定三种范围的可用性；
2. 可派生（纯内存计算）的能力优先在系统图库实现，不能因为“只读”就不给入口；
3. 需要写原图、写元数据或写 Apple 数据库的能力：系统图库默认只保留拷贝出口，只有官方库作为当前图库时才允许经 PhotoKit 真实编辑 / 删除；网盘只保留上传（WebDAV）或置灰；
4. 展示层复用现有组件（`SectionHeaderView`、网格组件、相簿卡片、`CategoryOverviewView`、`MoreItemsOverviewView`），同一入口的名称、图标与排序在三个范围保持一致；网盘照片网格与拾光 / 系统图库共用 `GalleryView` 的网格与顶部栏，不得再维护第二套网格；
5. 新增 `SidebarItem` 必须同步 `sidebarTitle`、`isSystemScope`、`navigationParent`、`isGridScopeForCommands`、`GalleryView` 的 `isGridScope` / `supportsZoomControl` / `content`、`EmptyStateView`，并补 `README.md`；
6. 端侧识别 / 派生结果必须同时进入内存与落库缓存：内存结果参与 `visibleStateKey` / 汇总缓存键，保证识别过程中网格与场景计数会刷新；落库走 `system_analysis` / `derived_reports` / `cloud_assets`，并提供回填方法。系统图库的识别必须持续增量（每批 200 张、逐张刷新），不得只跑固定一批就停下；但**不得在打开图库时自动开跑**，只有用户主动开启过（`systemAnalysisAutoResume`）才由 `resumeSystemAnalysisIfNeeded()` 对新增照片续跑。

---

## 7. 导入规范

- 统一使用 `ImportService.importFile(_:)`：复制原文件 → 提取 EXIF/视频元数据 → 生成缩略图。不要在别处重复实现。
- 批量导入按 CPU 核数并发（`withTaskGroup`，上限 6），并在内存中积攒后批量落盘：过程中用 `MetadataStore.appendPhotos(_:)` 增量写入新照片，结束/取消时再调用一次 `save()` 同步相簿与文件夹关系，禁止逐张全量重写。
- **导入始终拷贝原文件**，不支持引用原位置（产品决策，勿加“不拷贝”开关）。
- 从系统「照片」导入走 `importSystemPhotos` 私有管线；剪贴板粘贴必须拷贝（临时文件会被清理）。
- 按文件夹生成相簿的结构由 `ImportOptions` 控制；新增导入选项必须同时接入 `ImportView` 与 `LibraryStore.startImport`。
- 导入完成后：`save()`、清理选择、Toast 汇总；大批量导入应显示进度并支持取消。

---

## 8. 时间轴与网格 UI 约定

- `store.isTimelineScope`（`.library` / `.systemLibrary`，以及网盘的「全部项目」根页面）才允许「年 / 月 / 所有照片」分段与总览卡片；网盘的媒体类型、更多项目、目录相簿、分类总览与专用页面都不算。
- 照片显示形式由 `store.thumbnailAspect`（`ThumbnailAspect`：正方形 / 完整宽高比 / 瀑布流 / 列表）决定，本地图库、系统图库与网盘共用同一设置；新增形式只需接入 `GalleryView.sectionGrid`，网盘通过 `isTimelineScope` 走同一条网格链路。
- 非时间轴范围 `store.sections` 必须返回单段（无年/月分段、无段头），保证相簿与文件夹是普通网格。
- 相簿 / 文件夹链路的上一级由 `LibraryStore.navigationParent` 统一给出，工具栏左侧显示「返回上一级」按钮，菜单「照片 › 返回上一级」与 `⌘[` 复用同一个方法（`navigateUp()`）；不要在视图里各自拼父级判断。
- 年总览：每年一张拼图卡片（最多 4 张照片），点击 `openMonths(of:)`；月总览：按月分段、按天卡片，点击 `openAllPhotos(at:)` 定位。大图库改用 `store.yearBuckets` / `store.monthGroups`（SQL 分区，最多 4 张样本 + 真实总数），不要为了总览遍历全部照片。
- 网格尺寸只能由 `store.thumbSize`（`LibraryStore.thumbSizeRange` = 56…360，`didSet` 已夹紧）与容器宽度推导；不要写死像素。
- 卡片圆角用 `settings.cardRadius`，小封面用 `settings.smallCoverRadius`；悬停用 `settings.hoverLift` 与 `settings.motion.hover`；页面级动画用 `settings.motion.layout/overlay`。`RoundedRectangle` 统一 `.continuous`。
- 颜色使用语义色（`.primary`/`.secondary`/`.quaternary`/`.background`/`.bar`）或 `Color.accentColor`，禁止硬编码 RGB（图标绘制脚本除外）。唯一例外是品牌面（建库首屏、关于）：可用 `LumaDesign.LumaBrand` 里的官网品牌色与渐变，常规界面不得引用。
- 强调色统一由 `AppSettings.accentColor` 下发：根视图（`RootView`）、设置窗口与导入窗口同时应用 `.tint(...)` 与 `.accentColor(...)`，前者负责控件、后者让 `Color.accentColor`（选中框、高亮、强调文字、渐变）解析成同一颜色。新增强调色用途一律写 `Color.accentColor`，不要在视图里直接写 `Color.purple` / `.blue` 等固定色，否则会和用户选择的强调色分叉。
- 大列表必须使用 `LazyVStack`/`LazyVGrid`/`List`；单元格使用固定 `frame`，避免布局抖动。
- 总览页（相簿 / 场景 / 媒体类型 / 更多项目等）不再在内容区重复大标题：页面标题与返回层级统一由窗口工具栏（`store.sidebarTitle` + `store.navigationParent`）展示，内容区只保留数量、显示方式与新建等操作。卡片网格按可用宽度均分列宽（`GridItem(.flexible())` + 计算列数），默认铺满窗口；更多项目的卡片封面统一走 `LibraryStore.moreItemsCover(for:)`（系统索引库查 SQL，本地库先命中先返回，按内容版本缓存）。
- 文件夹卡片封面统一用 `FolderMosaicImage`：2×2 四宫格，每张图占 25%，不足 4 张留浅色占位，只有 1 张时铺满；封面从文件夹子树里的相簿各取前几张汇总（本地图库 `folderPhotosMap`、系统图库 `folderPhotos`），列表视图仍用单张封面。
- 系统图库的「相簿」总览必须按 `systemChildren(of:)` 的混排顺序渲染（文件夹与相簿按 `sortIndex` / `Z_PK` 交错），不要先排全部文件夹再排全部相簿，否则与侧边栏顺序不一致。
- 侧边栏的相簿 / 文件夹行：文件夹按 `level` 每级缩进 14pt（顶层 8pt），相簿行留出同样的箭头列宽与间隙，保证相簿封面与文件夹图标同列；箭头列固定 12pt、与图标之间只留 3pt（`folderChevronWidth` / `folderChevronGap`），不要再用行间距把图标推远。「固定」区第一层不再为箭头列预留缩进，与其它固定项左对齐。文件夹行只用强调色文件夹图标——曾试过给文件夹加载照片缩略图，展开 / 滚动侧边栏时缩略图解码会把主线程压满，已回退，不要改回去。
- 查看器里的动图统一交给 `Components/AnimatedImageView`（`NSImageView.animates = true`）播放，打开即循环、切图从头播放，不要在 SwiftUI `Image` 里自行计时；取图走 `ImageLoader.animatedImage(for:)`（本地原图）或 `LibraryStore.cloudAnimatedImage(for:)`（网盘先下载完整文件，限 80MB）；已编辑照片是静态渲染结果，`PhotoItem.playsAnimation` 已排除。
- 查看器画面角标：`isRAWFile` / `isPortraitCapture` / 实况照片在照片左上角显示「RAW」「人像」「实况」胶囊（实况可点击原位播放），`hasLocation` 的照片在右上角显示地图图钉（点按打开信息面板）；已命名人物由 `LibraryStore.personNames(for:)` 反查，名字胶囊排在角标下方（最多 3 个 + `+N`）。角标按实际显示尺寸贴在照片本体上，不落在竖图 / 宽图两侧的留白里；放大或实况播放时隐藏，不参与缩放拖拽，嵌入与全屏共用同一套位置。

---

## 9. 设置项接入流程

新增一个用户可调项必须**全部**完成：

1. 先判断归属：视图状态、导入选项、最近删除保留期、系统图库载入上限、网格元数据显示、网盘收藏、智能助手配置与对话属于**图库级设置**（写当前图库的 SQLite）；外观、强调色、动效、查看器与视频播放等属于 **App 级偏好**（写 `UserDefaults`）。API Key、Cookie、账号密码、PIN 一律属于凭据，只能写统一凭据保险库 `LumaKeychainVault`。
2. `SettingsKeys` 增加键名（`settings.xxx`）；
3. `AppSettings` 增加 `@Published` 属性：图库级用 `persistLibraryFlag` / `persistLibraryInt` / `persistLibraryJSON`，App 级继续写 `UserDefaults`；
4. 图库级属性必须在 `AppSettings.reloadLibraryScopedValues()` 中读取（缺少键时给默认值），并在 `SettingsView` 对应的图库 Tab 或说明中标注「随图库保存」；
5. `AppSettings.init()` 中给出默认值（布尔用 `object(forKey:) as? Bool ?? 默认值`，避免 `bool(forKey:)` 把“未设置”当 `false`）；
6. `SettingsView` 对应 Tab 增加控件与一句说明文案；
7. 在真正消费该设置的地方接入行为（视频自动播放、HDR、动效等），不要只做“装饰性开关”；
8. 更新 `README.md` 的“设置”一节。

只与单个视图相关的轻量状态可用 `@AppStorage`（如幻灯片间隔），但业务设置一律进 `AppSettings`。禁止把图库级设置写进全局 `UserDefaults`，否则切换图库会串数据。

---

## 10. 网盘接入规范

- 新增网盘类型：`CloudKind` 增加 case → 更新 `title`/`supportsWrite` → 在 `CloudService.list/stream` 分派 → 在 `CloudWizard` 增加向导 flow 与凭据步骤 → `CloudMountInfoView` 补充说明。
- Cookie 模式与 SMB 的接入范围存在 `CloudMount.scopeRoots` / `excludedRoots`：为空扫描全部（整个网盘 / 整个共享），非空只扫描选中目录并始终跳过排除目录（SMB 按路径前缀覆盖子树）。向导确认页读取目录并支持多选、下钻与「接入 / 排除」切换；侧边栏与存储卡片可「编辑接入范围…」直接回到该页。扫描器把选中的目录挂成顶层相簿；范围变化时清空目录树，并用 `CloudScanSnapshot.scopeSignature`（包含目录 + 排除目录）让旧快照失效。
- WebDAV 请求统一走 `WebDAVClient`（已处理百分号编码、Basic Auth、PROPFIND/MKCOL/PUT/MOVE/DELETE、Range）。
- OAuth：`CloudOAuthStore` 的凭据统一存入 `LumaKeychainVault`（旧版 service `com.baymax.photosclone.oauth` / `com.lijialong.photosclone.oauth` 只读取一次后迁移），回调固定 `127.0.0.1:53682`，必须校验 `state`；token 过期由 `CloudService.accessToken(for:)` 自动刷新并回写。
- 钥匙串调用必须收口在 `KeychainAccess`：业务代码只允许通过 `LumaKeychainVault`（或其封装 `AIKeychain` / `CinemaKeychain` / `CloudSecretStore`）读写，禁止自己拼 `SecItemCopyMatching` / `SecItemAdd` / `SecItemUpdate`，避免同一凭据在不同地方重复弹授权框。旧条目迁移结果会记在保险库元数据里，同一台机器上每项最多只读一次。
- 网盘凭据禁止写入 `UserDefaults`、日志或 `CloudMount`。
- 影院刮削源（TMDB / TheTVDB / 豆瓣 Cookie）、OpenSubtitles API Key、字幕账号与家长 PIN 同样属于凭据：统一由 `CinemaKeychain` 写入 `LumaKeychainVault`（`cinema.*` 前缀），禁止写 `UserDefaults`。旧版明文键由 `AppSettings.loadSecretsFromVault()` 在启动时迁移一次，确认写入保险库后立即从 `UserDefaults` 删除。
- 网络请求失败必须转为用户可读中文错误（`WebDAVError` / `CloudOAuthError`），不要直接抛英文 `NSError` 文案。
- 网盘目录缓存以 `mountID + path` 为键；退出网盘或切换目录时不要泄漏 `Task`。
- 网盘侧边栏的「媒体类型 / 更多项目」分区标题与拾光、系统图库一致，点标题打开卡片总览（`CloudOverviewSection`，状态在 `CloudBrowserModel.overview`）；选中具体范围、进入子目录、切换挂载或换库时必须清空总览，否则会停留在旧目录的卡片墙。总览卡片复用 `AlbumCoverImage` 与同一套布局，封面取当前目录里属于该范围的第一张。
- 网盘侧边栏的树结构与系统图库一致：影院（网盘自有）→ 媒体类型 → 更多项目 → 场景 → 相簿（不再有「固定」分区）。必须与拾光 / 系统图库共用 `SidebarSectionHeader` / `SidebarCategoryRow`：入口顺序、图标、标题与显示条件分别由 `MediaTypeKey.cloudCases`、`CloudScope.moreItems(counts:analyzedCount:)` 统一定义，侧边栏与总览共用同一份定义，不要另写一套行样式。「全部项目」由网盘行承担，媒体类型不再单列；数量为 0 的媒体类型、重复项目与尚未识别的包含文字按系统图库规则隐藏；没有目录相簿时隐藏相簿分区。分区标题点击只打开总览（`openCloudOverview`），再次点击不退回网格。媒体类型与场景默认收起（折叠状态键含 `v2`，旧版本保存的展开态不沿用）。「更多项目」必须与系统图库同名同序，包括只读能力入口：图库整理（`CloudScope.ratings`，评分 / 旗标 / 色标写 `cloud_marks`，不写网盘）、最近编辑 / 最近删除 / 导入项目（`CloudReadOnlyScopeView` 只读说明页）；最近保存按网盘文件修改时间（`addedAt`）取最近 30 天。
- 网络存储网格必须使用 `store.cloudVisiblePhotos`（已统一处理范围、搜索、筛选、排序并缓存），不要直接遍历 `cloudPhotos` 生成可见列表；`CloudBrowserModel.revision` 参与缓存失效。打开网盘时侧边栏要展开该挂载的「媒体类型 / 场景 / 更多项目」：范围由 `CloudScope` 表示，行高亮比较的是 `cloudModel.scope` 而不是 `sidebarItem`（`sidebarItem` 始终是 `.cloudMount(id)`）；`cloudVisiblePhotos` 与 `visibleStateKey` 的缓存键必须包含 `String(describing: cloudModel.scope)` 与 `cloudModel.analysis.count`，否则切换范围后网格不刷新。
- 网盘照片网格不得再自建：`GalleryView` 的 `.cloudMount` 分支只负责分派，普通照片列表直接复用 `photoContent`（同一套网格、顶部栏、空态与预取）；分类总览走 `CloudOverviewView`，人物 / 位置 / 关键词 / 体检 / 重复项目 / 地图走各自的网盘专用页面，图库整理复用 `OrganizeStudioView`（数据源切到 `cloudPhotos`），最近编辑 / 最近删除 / 导入项目走 `CloudReadOnlyScopeView`。`isTimelineScope` 只对网盘「全部项目」根页面为真，目录相簿、媒体类型、最近保存与「更多项目」照片页都是普通网格；`setCloudScope` / `selectCloudFolder` 与 `navigate(to:)` 共用 `clearTransientBrowsingState()`，换范围时清理选择、搜索与筛选。
- 网盘侧边栏的分区收起状态必须放在 `CloudMountDetailView` **自己的 `@State`** 里，挂载行的展开箭头用 `SidebarView.collapsedCloudMounts`（每个网盘独立，`cloudMountRow` 的箭头与名称是两个并排按钮，不能把 Button 套进 Button）。把收起状态放到外层 `@State` + `ForEach` 闭包里曾出现「点了收起条目还在」的问题，不要改回去。
- 网盘场景 / 图内文字识别：只允许经 `LibraryStore.analyzeCloudContent()` 触发，逐张用 `cloudThumbnail(for:)` 取缩略图后调用 `PhotoIntelligence.analyze(cgImage:)`，每次最多 120 张、可取消；结果写 `CloudBrowserModel.analysis` 并经 `saveCloudAnalysis` 落 `cloud_assets`，搜索与信息面板通过 `LibraryStore+Intelligence` 的回退读取，禁止写入 `asset_analysis` 或网盘。进入目录时由 `hydrateCloudCache` 回填，远端文件大小变化即作废。
- 网盘 EXIF：解析集中在 `Services/Cloud/CloudEXIF`，只读文件头部（`probeRange` = 前 256KB；SMB 用 `SMBClient.fileURL` 读本地挂载文件，WebDAV 用 `WebDAVClient.data(path:byteRange:)`，官方网盘用 `CloudService.stream` 直链 + Range），禁止为读 EXIF 下载整张原图；JPEG 截断数据回退到内置 TIFF/IFD 解析（GPS 三个 RATIONAL、日期、Make/Model/Lens、曝光参数）。编排在 `Store/LibraryStore+CloudInfo.swift`：目录载入后自动读取前 200 张（`cloudMetadataPageSize`），可取消、可「继续读取」，结果写回 `PhotoItem` 与 `cloudDirectoryCache`（内存）并经 `saveCloudEXIF` 落 `cloud_assets`；换挂载 / 换库只清内存，断开挂载才 `purgeCloudAssets`。
- 网盘地图 / 位置：`geoPhotos` 在 `isCloudScope` 时返回 `cloudGeoPhotos`，`PhotoMapView` / `PlaceStatisticsView` 原样复用；缺少地名时由 `resolveMissingCloudPlacesIfNeeded()` 用本机逆地理编码补齐（写 `PlaceCache.json`，不写网盘）。
- 网盘人物：`scanCloudPeople()` 逐张 `cloudThumbnail` → `FaceClusterEngine.analyze(cgImage:assetID:)` → `assign`，结果同时写 `CloudBrowserModel.people` 与 `cloud_people` / `cloud_person_assets`（`markCloudPeopleScanned` 记录已扫描路径），打开挂载时由 `loadCloudCacheForMount` 回填；页面为 `CloudPeopleView`，禁止调用本地 `startFaceClustering()`（它依赖本地缩略图与数据库）。人物列表与详情必须与系统图库共用 `PeoplePersonCardShell`、`PersonDetailHero`、`PersonInsightSummaryView` / `PersonMapPanel(source: .cloud)` 与 `PersonAvatarLoader`：卡片尺寸、筛选、悬停、摘要 / 地图 / 全部影像三档在同一套组件内实现，不要另写卡片或详情页。
- 网盘重复项目：`cloudDuplicateGroups` 用 `DuplicateDetector.groups(from:)` 纯内存计算，页面 `CloudDuplicatesView` 只读展示并提示到网盘 App 合并；不得调用 `mergeDuplicateGroup` 或删除网盘文件。
- 网盘图库体检：范围 `CloudScope.health` → `CloudHealthView`，扫描只经 `scanCloudHealth()`：当前目录最多 500 张，逐张 `cloudThumbnail` 后调用 `PhotoQuality.sharpness(cgImage:)` 与 `PhotoIntelligence.feature(cgImage:)`，归并复用 `LibraryStore.buildSimilarGroups`，结果写 `CloudBrowserModel.healthReport` 并由 `persistCloudHealthReport` 落 `derived_reports`（key 含挂载 + 目录）；不提供删除 / 清理按钮，只能预览并引导到网盘 App。
- 网盘相似检索：`findSimilarPhotos(to:)` 在 `isCloudScope` 时转到 `findSimilarCloudPhotos`，对当前目录最多 80 张现算 `PhotoIntelligence.feature`（`cloudFeature` 会落 `cloud_assets`），结果写入 `similarScope`；`cloudVisiblePhotos` 会按 `similarScope.ids` 过滤，切换范围 / 进入目录 / 换挂载必须清空。
- 网盘智能美化：`scanBeautyCandidates` 在 `isCloudScope` 时走 `scanCloudBeautyCandidates`（缩略图采样，推荐报告落 `derived_reports`）；`applyBeauty` 转 `applyCloudBeauty`：读取云端大图 → `EditState.beautified` → `PhotoRenderer.renderCG` → 写入临时文件 → `ImportService.importFile` 导入当前图库，继承拍摄时间 / EXIF / 收藏。禁止直接覆盖或上传美化结果（WebDAV 上传需另做入口），禁止把云端原图当成本地文件路径使用。
- 云照片的「收藏」只写入当前图库的 `MetadataStore.settings`（`cloud_favorites`，键为 `mountID|path`），不得写回 NAS 或网盘；`makeCloudPhoto` 创建时叠加收藏状态，切换收藏后要同步当前列表与 `cloudDirectoryCache`。系统图库的真实编辑 / 删除只经 PhotoKit（`canWriteSystemOriginals` / `canDeleteSystemPhotos`），网盘的写操作（改名、删除、隐藏、相册、编辑）仍禁止。
- SMB 走 `SMBClient`：用系统 `NetFSMountURLSync` 挂载（`mountpath` 传 `nil`，由系统挂到 `/Volumes/<共享名>`），再用 `getmntinfo`（`resolvedMount(host:share:)`）找到实际挂载点后以 `FileManager` 读目录/文件；**不要把挂载点指定到应用私有目录**（普通用户无权限，NetFS 会返回 EPERM/EINVAL）。只读，不支持上传、重命名与删除。密码只走钥匙串，禁止拼进命令行、日志或 `CloudMount`。自动发现依赖 `Info.plist` 的 `NSBonjourServices`（`_smb._tcp`）；共享列表通过 `SMBShareDiscovery` 调用系统 `smbutil view`，密码只经伪终端写入，禁止进入 argv / 环境变量 / 日志；「整个共享」递归扫描结果与目录浏览共用 `cloudDirectoryCache`，缓存键需带 `tree` 前缀避免冲突。
- SMB 向导的「共享 → 子目录」多级浏览由 `CloudWizard+SMB` 承担：单击共享只把地址设为 `smb://主机/共享名`，双击共享进入目录浏览（`enterShare`，`smbBrowseShare` 非空时渲染面包屑 + 子文件夹），单击子目录把地址定位到 `smb://主机/共享名/子目录` 并验证，双击继续下钻（层数不限）；所有跳转统一走 `browse(to:)`，读取失败/空目录/读取中都要有文案；双击与单击必须用 `TapGesture(count: 2).exclusively(before:)` 组合，避免双击同时触发单击的验证；切换设备、重新发现与关闭向导都要 `resetBrowseState()`。地址中的子路径由 `SMBClient.pieces` 解析，`list/scanTree` 会自动拼到挂载点后面，不要在向导里另写路径拼接。
- **子路径只能拼一次**：`SMBClient.ensureMounted()` 返回共享挂载点（`/Volumes/<共享名>`，不含地址里的子路径），`mountedRoot`/`fileURL` 才包含子路径。`list`/`scanTree` 必须用 `ensureMounted()` 的返回值再 `appending(subPath …)` 一次；若改用 `mountedRoot` 会拼成 `/Volumes/share/dir/dir`，表现为「未能打开文件 X，因为它不存在」。
- SMB 向导复用凭据：`prefillSMBAccount(for:)` 只从**当前图库已保存的** `CloudMount` 取用户名、从钥匙串（`store.cloudPassword(for:)`）取密码，按主机名大小写不敏感匹配；匹配不到不得猜测或复用其它主机的账号。复用后直接 `discoverShares(host:)` 列出共享，并在界面显示「已复用…」；密码仅存在于视图的 `@State` 内存中，禁止写入日志、`UserDefaults` 或新的持久化。

---

## 11. 并发与性能

- 磁盘/网络/图片解码等耗时操作用 `Task.detached(priority:)` 或 `await` 的 async API；UI 状态更新回到主线程。
- 批量任务必须可取消（参考 `importTask`/`compressionTask` 模式），并在 `Task` 内检查 `Task.isCancelled`。
- 网盘缩略图并发限制由 `CloudConcurrencyGate(limit: 3)` 控制；新增高开销资源加载需复用或新增同类门控。
- 大图库不允许在视图或 Store 里对 `photos` 全量 `filter` / `sorted` 来生成可见列表：走 `pagedQuery` + `MetadataStore.page`。新增排序键必须同时接入 `MetadataStore+Query.orderExpression` 与对应的 `(排序键, id)` 复合索引，否则 SQLite 会对全表临时排序。
- 地图页的派生数据（`geoPhotos` / `placeClusters` / `placeGroups`）必须按 `contentRevision` 缓存（`LibraryStore` 的 `geoPhotosCache*` 等），聚类用引用类型桶就地累加；禁止在视图 body 里对整库重扫或重复聚类——十万级图库每次 body 重算会让打开地图直接卡住。地图图钉的缩略图必须异步加载，禁止在 `mapView(_:viewFor:)` 里同步解码原图。
- 地图图钉必须按**单张照片**落点（`MapCanvas` 的 `PhotoAnnotation` + `clusteringIdentifier = "photo"`），由 MapKit 随缩放自动聚类 / 拆分；禁止退回「一个地点一个平均坐标图钉」——同一区县几百张照片会被压成一个点，缩放时看不出真实分布。`MKClusterAnnotation` 的展示与点击放大都在 `MapCanvas.Coordinator` 内处理。
- 足迹回放由 `FootprintCruiseTimeline` 统一编排行进与旅拍停留，`FootprintPlaybackView` 只能用同一个时钟同步驱动光点、镜头、站点和时间条。默认「丝滑」采用距离 / 镜头高度决定的视觉匀速，不按现实地理速度播放，极短移动必须保留最短可辨认时长；暂停、播放中变速、按时间拖动、重播与重新跟随都不得另起互相竞争的时间轴或恢复逐段独立动画。行进光点使用线性比例，平滑只用于镜头姿态与显式转场。
- 人物页 / 人物详情的头像只能经 `PersonAvatarLoader` 异步取用（`.task(id:)` + 内存缓存），禁止在 body 里 `NSImage(data:)` 解码裁切图，或按人物逐次调用 `anyPhoto(id:)` 查库——上千人的列表滚动时这两件事都会掉帧。
- 年 / 月总览走 `MetadataStore.yearBuckets` / `monthGroups`（窗口函数按年/月/日分区，样本上限 4 张），分段标题用 `count` 而不是 `photos.count`。
- 查看器单步翻页在分页模式下用 `MetadataStore.neighbor`（keyset 查询），不要用 `LIMIT 1 OFFSET n` 做长按连翻。
- `MetadataStore.readLibrary` **不按文件是否存在过滤**照片：外置盘未挂载或文件临时不可达时，过滤出的空结果一旦被 `save()` 写回就会清空整库元数据；缺失文件交给缩略图占位。
- 避免在 `body` 中做重计算；视图内允许的仅有轻量映射（如按月内照片分天分组）。
- 预览图 `maxPixel` 上限：查看器 2600（`ImageLoader.displayImage`）、全尺寸 6000（`fullNSImage`，打印/编辑用）、网格缩略图 1200、快速缩略图 260，不要随意调大。

---

## 12. 文案、图标与交互

- 所有面向用户的文案为简体中文；使用 SF Symbols 图标，尺寸与项目现有风格一致（`font(.system(size:))`）。
- 可点击控件提供 `.help("…")` 说明；有默认动作的弹窗按钮使用 `.keyboardShortcut(.defaultAction)`。
- 危险操作必须二次确认，统一走 `Store/LibraryStore+Deletion.swift` 的确认请求与 `Features/Gallery/DeleteConfirmView.swift` 的确认卡片：移到最近删除（`confirmDelete`）、永久删除（`confirmPermanentDelete`）、清空最近删除（`confirmEmptyTrash`）都先设置 `pendingDeletion`，由卡片展示扇形缩略图预览、数量与「照片 / 视频」拆分，确认后 `performPendingDeletion()` 才真正执行。不可撤销的卡片默认按钮是「取消」（回车不会误删），可撤销的「移到最近删除」默认按钮是确认。破坏性菜单项使用 `role: .destructive`，禁止绕过卡片直接调 `delete` / `deletePermanently`（智能助手已有自己的确认流程除外）。断开系统图库 / 网络存储同样走确认卡片（`confirmRemoveSystemLibrary` / `confirmRemoveCloudMount` → `pendingDisconnect`），文案必须写明「不删除原始数据」或「只清理本机缓存」。
- 新增快捷键必须同步 `ShortcutHelpView`（`Features/Viewer/ShortcutHelpView.swift`）与 `README.md` 快捷键表。
- 空状态、错误状态都要有文案（参考 `EmptyStateView`、`ToastView`）。
- 需要把一组强控制并入窗口工具栏时，按 §17：控制必须落在窗口工具栏，具体展示形态按功能场景自行决定。

---

## 13. 禁止事项

- ❌ 引入第三方依赖或资源包。
- ❌ 在视图层直接读写文件、数据库或拼接路径。
- ❌ 直接修改 `photos`/`albums`/`folders` 后不调用 `save()`。
- ❌ 在没有图库（`needsLibrarySetup`）时创建固定位置目录或数据库。
- ❌ 对额外连接的系统图库、SMB 与官方网盘提供写操作入口（官方「照片」图库作当前库时，编辑 / 删除只能经 PhotoKit）。
- ❌ 直接用 SQL 修改 Apple 的 `Photos.sqlite`，或把拾光缓存写进 Apple 的目录。
- ❌ 为缩略图下载整个 WebDAV 原文件。
- ❌ 把 `NSImage`、`CIImage` 等运行时对象放进 `Codable` 模型。
- ❌ 硬编码 `/Users/...`、`~/Pictures/...` 等绝对路径（测试脚本除外）。
- ❌ 只做“装饰性设置项”（开关没有任何行为）。
- ❌ 提交含密钥、token、临时调试代码的改动。
- ❌ 把 API Key、Cookie、账号密码、PIN 或 OAuth token 写入图库数据库、`UserDefaults`、日志或智能助手对话记录。
- ❌ 让智能助手绕过工具确认直接修改图库，或绕过 `LibraryStore` 写文件与数据库。

---

## 14. 常见陷阱

- **产物名一致**：SwiftPM 可执行目标、产物与应用都叫 `Luma`；`pkill -x Luma`。
- **多进程改文件**：本仓库可能被多个会话同时编辑；遇到编译期“file modified during the build”只需等待重试。
- **`metadataFile` 位置**：`<图库根目录>/Luma/database/Luma.sqlite`（Apple 的 `Photos.sqlite` 仍在 `<图库根目录>/database/`，两者分开），不是 `Application Support`；无图库时 `root` 指向 `Application Support/Luma`，仅用于迁移旧数据。
- **官方图库识别**：`isNativeLibrary` 以是否存在 `database/Photos.sqlite` 判定；`isLibraryContainer` 只看扩展名与是否目录。
- **ATS**：`Info.plist` 已允许任意加载与本地网络；新增域名/端口无需再改，但不要把该配置用于生产收紧以外的场景。
- **HDR 开关**：关闭时查看器把图像转 8 位 sRGB（`ImageLoader.sdrImage`），不要把这个转换加到网格缩略图上（性能）。
- **视频自动播放**：受 `settings.autoPlayVideo` 控制，转码后播放同样遵循该设置。
- **查看器方向键语义**：照片用 ← / → / ↑ / ↓ 翻页；图库视频与照片一致，只用 ← / → 翻页，↑ / ↓ 按 `settings.videoSeekStep`（设置里可改，默认 5 秒）快进 / 快退；网络资源（剧集）反过来：← / → 快进 / 快退，↑ / ↓ 切上一集 / 下一集。任何场景下 ⌘ + 方向键都只在上一个 / 下一个视频之间跳转，J / L 固定快退 / 快进 10 秒。不要把图库视频的 ← / → 改回快进，否则照片与视频混播时的左右翻页会失效。
- **视频旋转**：`VideoPlayerStage.quarterTurns` 只影响播放层与截图朝向，不改原文件；旋转后播放层尺寸由 `playerFrame(in:)` 按画面比例与填充模式重算，不要用 `rotationEffect` 直接转整块画面（会出现黑边或裁剪错误）。
- **`systemPhotos` 只读**：系统图库的 `PhotoItem.source == .system`，`sourceURL` 指向官方包内文件，禁止直接写回；真实编辑 / 删除只允许经 `PhotoKitBridge`（且仅限官方库作为当前图库）。
- **导入窗口**：`ImportSheetView` 在独立 `Window(id: "import")` 中，新增状态需经 `LibraryStore` 传递，不要用 `@State` 跨窗口共享。
- **选取图库窗口**：`LibraryPickerView` 在独立 `Window(id: "libraryPicker")` 中（600×400，`.windowResizability(.contentSize)`），打开期间 `RootView` 对主窗口 `orderOut` 整窗隐藏、关闭后 `makeKeyAndOrderFront` 恢复。不要改回挂主窗口的 sheet：sheet 是主窗口的子窗口，主窗口一隐藏 sheet 会跟着消失。红叉关闭窗口由 `LibraryPickerView.onDisappear` 兜底映射为「取消」。
- **端侧模型输入**：`Resources/Models/SigLIP2/ImageEncoder.mlmodelc` 的输入已从 `ImageType` 改为 MultiArray `[1,3,256,256]`（RGB，0…255），`YOLO11n` 同理（640×640）。Core ML 的 ImageType 通道会把像素归一化到 0…1，再叠加模型图内的 `x/127.5-1` 预处理会得到近乎全黑的输入；不要在 Swift 里改回 `MLFeatureValue(pixelBuffer:)`。
- **标签向量必须同运行时生成**：`tag_embeddings.bin` 由本机 Swift 文本编码器生成，必须与图像编码器使用同一运行时；修改 `tags.json` 的提示词后要用 Swift 侧重新生成。用 Python coremltools 生成会与本机 Core ML 数值偏差（余弦约 0.8），导致标签几乎全部丢失。
- **境外逆地理编码**：`CLGeocoder` 在国内网络下只对中国大陆坐标返回结果，境外坐标（东京、暹粒等）统一报 `kCLErrorDomain 8`。`WorldCityIndex` 用 `Resources/Models/Places/world-cities.json`（GeoNames cities15000，CC BY 4.0）按最近城市兜底；不要把这个离线兜底改成联网服务，也不要把坐标上传到第三方。
- **模型打包**：`build.sh` 会把 `Resources/Models` 复制到 `Luma.app/Contents/Resources/Models`；模型约 373MB，注意不要提交临时脚本或未使用的模型文件。

---

## 15. 提交前检查清单

- [ ] `./build.sh debug` 通过，`open Luma.app` 正常启动
- [ ] 改动涉及的三类范围（本地图库 / 系统图库 / 网盘）权限行为正确
- [ ] 修改过的数据在重启后仍然存在（`save()` / schema 迁移验证）
- [ ] 新增设置项有默认值、有持久化、有实际行为
- [ ] 新增 UI 使用语义色、`settings.cardRadius` 与 `settings.motion`
- [ ] 新增快捷键已同步快捷键面板与 README
- [ ] README / AGENTS 与实际实现一致（功能、限制、文件职责）
- [ ] 无新增编译警告（尤其未使用变量、Sendable 捕获）
- [ ] 未提交临时脚本、调试输出、密钥或大文件

---

## 16. 文档维护

- `README.md`：产品能力、构建方式、目录结构、图库结构、快捷键、已知限制。**功能变化必须同步**。
- `AGENTS.md`（本文件）：架构不变量、编码规范、流程与清单。新增架构级约定时同步更新。
- 文档中的路径、类名、命令必须与代码一致；重构后若改名，先改代码再改文档，并在同一次改动中完成。

---

## 17. 顶栏融合：功能控制必须落在窗口工具栏

适用于需要一组强控制、又不该在内容区造悬浮控制层的界面（已落地：视频播放，`settings.videoControlPlacement == .topIntegrated`）。

**唯一硬约束**
- 控制必须并入窗口工具栏那一行，和返回、标题、页面操作共用同一层 chrome。
- 禁止在内容区再叠一条控制栏或玻璃胶囊——那会变成「工具栏 + 第二行」，与窗口 chrome 割裂。

**展示形态按场景自主决定**
- 下方描述只是视频播放的参考实现，不是通用模板；其它功能按自身操作密度与信息量取舍。
- 有连续量且需要长期可见的（播放进度、缩放、导出进度等）：可采用「中区信息 + 连续量、两侧操作」的舱体结构；也可以只把主操作放进工具栏，连续量留在内容区，只要不新增悬浮控制层。
- 离散、低频或强上下文相关的操作（筛选、排序、批处理、视图切换）：优先用原生 `ToolbarItem`、`Menu` 或现有 popover，不必为了视觉统一强行做成胶囊。
- 只读状态类信息：用紧凑状态块、菜单项说明或 `.help`，避免长期占用工具栏宽度。

**通用原则（非强制）**
- 信息保留：加入控制不得删减原有工具栏信息（视频场景里的标题、地点、日期、序号圆环都要保留）；空间不足可截断、换行或折叠进菜单，但要保持可发现。
- 主次分明：一个最主要操作视觉最重，其余同组或收进菜单；避免把大量图标平铺导致挤压。
- 可读可点：字号与点击区域以实际可读可点为准，不要沿用系统最小字号硬塞；参考视频播放的主按钮 30pt、次级按钮 28pt、时间 11pt monospaced。
- 视觉一致：自定义按钮沿用应用墨色与 `Color.accentColor` 表达选中态，避免系统默认 tint 混色；需要材质时与工具栏自身材质协调。
- 反馈与动效：状态切换、数值变化给轻量过渡（如 symbol / numeric transition），连续量支持悬停与拖动预览；按 `settings.motion` 控制强度。
- 响应式：窗口变窄时优先收起低频项（进菜单或系统溢出），不要靠压缩字号和间距硬塞。

**状态与设置**
- 顶栏形态属于 **App 级偏好**：按 §9 接入 `SettingsKeys` + `AppSettings` + `SettingsView`，默认值保留原来的内容区方案。
- 需要跨「工具栏 / 内容区」共享的运行时状态（如 `viewer.videoPlayer`）提升到对应的 Model，只在使用它的叶子视图用 `@ObservedObject` 订阅，避免高频状态更新触发整棵大 body 重算。
- 全屏沉浸等没有窗口工具栏的场景，必须回退到内容区方案，不能让控件凭空消失。

**已验证的失败方案（不要回退）**
- ❌ 在画面上方另叠一条玻璃胶囊：视觉上成为「工具栏 + 第二行」。
- ❌ 把全部按钮平铺进工具栏：图标过小、互相挤压、系统蓝色 tint 与墨色混排。
