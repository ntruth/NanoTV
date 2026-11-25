# 拾光 iOS 版可行性报告

> 结论先行：**技术可行，但不是「把现有工程编译成 iOS」**。推荐架构是 **Mac 作为图库主机，iOS 作为原生客户端**：Mac 端新增局域网服务（Bonjour 发现 + HTTPS/Token 鉴权 + Range 流式读取），iOS 复用数据层与领域模型、重写触控交互层。
>
> 三项核心诉求（同局域网读 Mac 图库、播放照片与视频、手机相册回传本地库）可行性高；「能力与桌面版完全一致」需要分档实现，桌面专属能力无法 1:1 迁移，详见第 8 节。
>
> 非局域网（外网）访问同样可行：首选 Tailscale 类覆盖网络，其次自建反向中继；公网端口映射不作为产品方案，见第 7 节。

---

## 1. 需求拆解

| # | 需求 | 判定 | 说明 |
|---|---|---|---|
| R1 | 出一个 iOS App，能力接近拾光 | 可行，需分档 | 浏览、组织、搜索、播放可对齐；编辑、网盘、桌面专属项需裁剪或降级 |
| R2 | 把 Mac 本地图库当作一个「源」 | 可行 | Mac 进程内新增 HTTP 服务，暴露分页查询、缩略图、原图与视频 |
| R3 | iOS 端读取、播放（同局域网） | 可行 | Bonjour 发现 + TLS + Range；视频走原文件 Range 或 Mac 端转 HLS |
| R4 | 手机相册同步到本地库 | 可行 | iOS 用 PhotoKit 导出原始资源，分块上传；Mac 复用现有导入管线（SHA-256 去重） |
| R5 | 其余功能可行性 | 多数可行，少数受限或不可用 | 见第 8 节矩阵 |

本报告的隐含前提：**Mac 是唯一写入者与唯一数据源**，iOS 不直接打开 `.photoslibrary`，也不直接读写 SQLite 文件。这是整个方案成立的关键约束，原因见第 9 节。

---

## 2. 现状事实（来自当前代码）

### 2.1 工程规模

| 指标 | 实测值 | 来源 |
|---|---|---|
| Swift 代码总量 | 约 91,211 行（`Sources/`，不含测试） | `wc -l` 统计 |
| `Features/`（视图层） | 39,397 行 | 同上 |
| `Services/` | 24,073 行 | 同上 |
| `Store/`（状态与业务编排） | 17,061 行 | 同上 |
| `LumaCore/`（无 UI 纯算法） | 9 个文件，零 AppKit 依赖 | [LumaCore](../Sources/LumaCore) |
| 导入 AppKit 的文件 | 100 个 | 全局检索 `import AppKit` |
| 构建形态 | 单一 SwiftPM 可执行 target，仅声明 macOS 14 | [Package.swift](../Package.swift#L4-L31) |
| 第三方依赖 | 无；仅链接 `libsqlite3`、`NetFS`、`Photos` | 同上 |

含义：**视图层占了四成代码，且全部与 AppKit/macOS 交互绑定**。iOS 的主要成本不是「协议」，而是交互层重写。

### 2.2 数据与文件布局

- 图库是标准 `.photoslibrary` 包，应用数据写在包内第一层：`database/PhotosClone.sqlite`、`originals/<UUID 首字符>/`、`resources/derivatives|renders|transcodes|backups`，见 [LibraryPaths.swift](../Sources/PhotosClone/Services/Library/LibraryPaths.swift#L8-L35)。
- 元数据表结构完整（`assets` / `folders` / `albums` / `album_assets` / `people` / `person_assets` / `asset_analysis` / `asset_overlays` / `system_analysis` / `derived_reports` / `cloud_assets` 等），见 [MetadataStore.swift](../Sources/PhotosClone/Services/Library/MetadataStore.swift#L385-L590)。
- 大图库已有分页下推能力：超过 5,000 张时按 600 张/页走 SQL 窗口，见 [LibraryStore.swift](../Sources/PhotosClone/Store/LibraryStore.swift#L783) 与 [PhotoQuery.swift](../Sources/PhotosClone/Domain/PhotoQuery.swift#L20-L45)。
- 缩略图已有两级（`_q.jpg` 快速层 + `_1_105_c.jpeg`），见 [LibraryPaths.swift](../Sources/PhotosClone/Services/Library/LibraryPaths.swift#L304-L325)。

这意味着服务端**不需要重新发明查询层**，把现有 `PhotoQuery → SQL` 结果序列化即可。

### 2.3 平台耦合点（决定 iOS 能不能直接复用）

| 依赖 | 当前用法 | iOS 可用性 | 结论 |
|---|---|---|---|
| AppKit（`NSImage`/`NSOpenPanel`/`NSWorkspace`） | 100 个文件 | 不可用 | 视图层重写；服务层做图像抽象 |
| `Process` 调 ffmpeg | 视频转码、抽帧，见 [VideoSupport.swift](../Sources/PhotosClone/Services/Media/VideoSupport.swift#L40-L63) | **禁止子进程** | 转码必须留在 Mac，或改集成 libav* |
| `NetFS`（SMB） | 网盘 SMB 挂载 | 不可用 | iOS 不直连 SMB；走 Mac 代理 |
| `Photos.sqlite` 只读解析 | 系统「照片」图库 | 仅 macOS | iOS 只能读 iPhone 自身相册 |
| `LocalHLSServer` | 绑定 `127.0.0.1` 的 BSD socket 服务，见 [LocalHLSServer.swift](../Sources/PhotosClone/Services/Video/LocalHLSServer.swift#L4-L54) | 可移植（需改 `0.0.0.0` + 鉴权 + Range） | 可演进为局域网媒体服务 |
| `Network.framework`（`NWBrowser`） | SMB 的 Bonjour 发现，见 [SMBClient.swift](../Sources/PhotosClone/Services/Cloud/SMBClient.swift#L29-L40) | 可用 | 直接复用发现范式 |
| SQLite3 C API | 全量元数据 | 可用 | 数据层可移植 |
| Vision / Core ML / AVFoundation / Core Image | 端侧识别、播放、编辑 | 可用 | 可移植，模型需按 iOS 重新打包 |
| Keychain | 智能助手 API Key | 可用 | 直接复用 |

---

## 3. 方案选型

| 方案 | 形态 | 优点 | 致命问题 | 结论 |
|---|---|---|---|---|
| **A. Mac 图库主机 + iOS 客户端** | Mac 起服务，iOS 远程浏览/播放/上传 | 复用现有数据层；Mac 算力承担转码与 AI；单一写入者，无同步冲突 | Mac 需开机且拾光在运行 | **推荐** |
| B. iCloud/CloudKit 双向同步 | 两端各存一份图库 | 脱离局域网可用 | 要重写存储层；PB 级不现实；冲突合并成本极高 | 不推荐 |
| C. iOS 直接挂载图库目录（SMB/WebDAV/iCloud Drive）读写 SQLite | iOS 把 `.photoslibrary` 当网络盘 | 看似省服务端 | SQLite WAL 在网络文件系统上的锁不可靠，易损坏；大图库随机读极慢 | **禁止** |
| D. 局域网 Web（PWA）而非原生 App | 同一套 HTTP 服务 + 响应式网页 | 零签名、零审核、跨设备；验证协议最快 | 相册后台同步、原生相册写入、动效体验受限 | 作为 P0 过渡，可与 A 并行 |

方案 A 的关键收益：**所有写操作仍然发生在 Mac 的 `LibraryStore` 内**，撤销栈、删除生命周期、导入去重、ffmpeg 转码、人脸与 SigLIP 分析全部原样复用，iOS 只做「请求 + 渲染 + 上传」。

---

## 4. 推荐架构

```svg
<svg viewBox="0 0 960 480" width="100%" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="拾光 iOS 局域网架构">
  <defs>
    <linearGradient id="gBrand" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#F6B45A"/>
      <stop offset="55%" stop-color="#EF7C5B"/>
      <stop offset="100%" stop-color="#8C6BF2"/>
    </linearGradient>
    <filter id="soft" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#1B1B22" flood-opacity="0.10"/>
    </filter>
    <marker id="arw" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M0,0 L10,5 L0,10 z" fill="#6B6B76"/>
    </marker>
  </defs>
  <rect width="960" height="480" fill="#FCFBF8"/>

  <!-- iPhone -->
  <rect x="24" y="70" width="272" height="344" rx="18" fill="#FFFFFF" stroke="#E7E2D9" filter="url(#soft)"/>
  <rect x="24" y="70" width="272" height="6" rx="3" fill="url(#gBrand)"/>
  <text x="44" y="102" font-family="-apple-system, PingFang SC, sans-serif" font-size="15" font-weight="600" fill="#23232B">iPhone / iPad · 拾光 iOS</text>
  <text x="44" y="122" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">SwiftUI · iOS 17+ · 仅作为客户端</text>

  <rect x="44" y="138" width="232" height="36" rx="9" fill="#FBF7F0" stroke="#EFE7DA"/>
  <text x="56" y="160" font-family="-apple-system, PingFang SC, sans-serif" font-size="12" fill="#3A3A44">浏览 / 网格 / 查看器</text>

  <rect x="44" y="182" width="232" height="36" rx="9" fill="#FBF7F0" stroke="#EFE7DA"/>
  <text x="56" y="204" font-family="-apple-system, PingFang SC, sans-serif" font-size="12" fill="#3A3A44">缩略图磁盘缓存 + LRU</text>

  <rect x="44" y="226" width="232" height="36" rx="9" fill="#FBF7F0" stroke="#EFE7DA"/>
  <text x="56" y="248" font-family="-apple-system, PingFang SC, sans-serif" font-size="12" fill="#3A3A44">AVPlayer · Range / HLS</text>

  <rect x="44" y="270" width="232" height="36" rx="9" fill="#FBF7F0" stroke="#EFE7DA"/>
  <text x="56" y="292" font-family="-apple-system, PingFang SC, sans-serif" font-size="12" fill="#3A3A44">PhotoKit 导出 + 上传队列</text>

  <rect x="44" y="314" width="232" height="36" rx="9" fill="#FBF7F0" stroke="#EFE7DA"/>
  <text x="56" y="336" font-family="-apple-system, PingFang SC, sans-serif" font-size="12" fill="#3A3A44">Keychain 配对令牌</text>

  <text x="44" y="386" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">写操作一律回传 Mac 执行</text>

  <!-- LAN -->
  <rect x="336" y="150" width="286" height="128" rx="16" fill="#FFFDF9" stroke="#E7E2D9" stroke-dasharray="6 5"/>
  <text x="356" y="178" font-family="-apple-system, PingFang SC, sans-serif" font-size="13" font-weight="600" fill="#23232B">同一局域网（Wi-Fi）</text>
  <text x="356" y="202" font-family="-apple-system, PingFang SC, sans-serif" font-size="11.5" fill="#5C584E">Bonjour 发现 _luma._tcp</text>
  <text x="356" y="224" font-family="-apple-system, PingFang SC, sans-serif" font-size="11.5" fill="#5C584E">TLS（固定证书）+ Bearer Token</text>
  <text x="356" y="246" font-family="-apple-system, PingFang SC, sans-serif" font-size="11.5" fill="#5C584E">HTTP/1.1 · Range · ETag</text>
  <text x="356" y="266" font-family="-apple-system, PingFang SC, sans-serif" font-size="10.5" fill="#9A927F">访客 Wi-Fi 客户端隔离会导致发现失败</text>

  <!-- Mac -->
  <rect x="660" y="48" width="276" height="388" rx="18" fill="#FFFFFF" stroke="#E7E2D9" filter="url(#soft)"/>
  <rect x="660" y="48" width="276" height="6" rx="3" fill="url(#gBrand)"/>
  <text x="680" y="80" font-family="-apple-system, PingFang SC, sans-serif" font-size="15" font-weight="600" fill="#23232B">Mac · 拾光 1.x（图库主机）</text>
  <text x="680" y="100" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">唯一写入者 · 唯一数据源</text>

  <rect x="680" y="116" width="236" height="34" rx="9" fill="#F4F1FB" stroke="#E2DCF4"/>
  <text x="692" y="138" font-family="-apple-system, PingFang SC, sans-serif" font-size="12" fill="#3A3A44">LAN Service（NWListener）</text>

  <rect x="680" y="158" width="236" height="34" rx="9" fill="#FBF7F0" stroke="#EFE7DA"/>
  <text x="692" y="180" font-family="-apple-system, PingFang SC, sans-serif" font-size="12" fill="#3A3A44">LibraryStore / MetadataStore</text>

  <rect x="680" y="200" width="236" height="58" rx="9" fill="#FBF7F0" stroke="#EFE7DA"/>
  <text x="692" y="220" font-family="-apple-system, PingFang SC, sans-serif" font-size="12" fill="#3A3A44">.photoslibrary 图库包</text>
  <text x="692" y="240" font-family="-apple-system, PingFang SC, sans-serif" font-size="10.5" fill="#8A8578">originals · database · resources</text>

  <rect x="680" y="266" width="236" height="34" rx="9" fill="#FBF7F0" stroke="#EFE7DA"/>
  <text x="692" y="288" font-family="-apple-system, PingFang SC, sans-serif" font-size="12" fill="#3A3A44">外置盘 / NAS 上的图库</text>

  <rect x="680" y="308" width="236" height="34" rx="9" fill="#FBF7F0" stroke="#EFE7DA"/>
  <text x="692" y="330" font-family="-apple-system, PingFang SC, sans-serif" font-size="12" fill="#3A3A44">ffmpeg 转码 → HLS</text>

  <rect x="680" y="350" width="236" height="34" rx="9" fill="#FBF7F0" stroke="#EFE7DA"/>
  <text x="692" y="372" font-family="-apple-system, PingFang SC, sans-serif" font-size="12" fill="#3A3A44">导入服务（SHA-256 去重）</text>

  <!-- links -->
  <line x1="296" y1="200" x2="336" y2="200" stroke="#6B6B76" stroke-width="1.4" marker-end="url(#arw)"/>
  <line x1="622" y1="200" x2="660" y2="200" stroke="#6B6B76" stroke-width="1.4" marker-end="url(#arw)"/>
  <text x="480" y="128" text-anchor="middle" font-family="-apple-system, PingFang SC, sans-serif" font-size="10.5" fill="#5C584E">← 查询 / 缩略图 / 视频 Range　·　写回 / 上传 / 导入进度 →</text>

  <line x1="660" y1="300" x2="622" y2="300" stroke="#6B6B76" stroke-width="1.4" marker-end="url(#arw)"/>
  <line x1="336" y1="300" x2="296" y2="300" stroke="#6B6B76" stroke-width="1.4" marker-end="url(#arw)"/>

  <!-- footer -->
  <rect x="336" y="330" width="286" height="46" rx="12" fill="#F7F5EF" stroke="#E7E2D9"/>
  <text x="352" y="349" font-family="-apple-system, PingFang SC, sans-serif" font-size="10.5" fill="#5C584E">可选：同一服务直接提供 PWA，</text>
  <text x="352" y="365" font-family="-apple-system, PingFang SC, sans-serif" font-size="10.5" fill="#5C584E">浏览器免签名先验证协议与性能。</text>
</svg>
```

### 4.1 分层与复用边界

| 层 | 现状 | iOS 处理 |
|---|---|---|
| `LumaCore` | 纯算法、无 UI | 原样复用（跨平台 target） |
| `Domain` 模型 / `PhotoQuery` | 纯数据与查询描述 | 抽到共享 target，改为 `Codable` DTO |
| `MetadataStore` / `SQLite` | 仅依赖 SQLite3 C API | 仅保留在 Mac；iOS 不直连数据库 |
| `Services`（导入、图像、视频、AI） | 混有 AppKit/`Process`/`NetFS` | 按 `#if os(macOS)` 切分，能力留在 Mac |
| `Store`（LibraryStore） | `ObservableObject` + 文件路径 | Mac 端原地演化；iOS 新建轻量 Store |
| `Features`（39k 行） | SwiftUI + AppKit | 重写触控版；可参考布局模型，不复用视图代码 |

---

## 5. 局域网服务设计

### 5.1 发现与配对

1. Mac 启动服务后发布 Bonjour 服务：类型 `_luma._tcp`，TXT 记录包含 `proto=1`、`library=<图库名>`、`pair=required`。现有 [SMBClient.swift](../Sources/PhotosClone/Services/Cloud/SMBClient.swift#L29-L40) 已证明 `NWBrowser` 在本工程的可用性。
2. iOS 首次连接：Mac 主窗口显示 6 位配对码 → iOS `POST /v1/pair` → 下发 256 位设备令牌，存 Keychain。
3. 传输层：TLS（Mac 生成自签名身份）；配对码同时作为证书指纹的短校验串，iOS 确认后固定 SPKI 哈希；令牌放 `Authorization: Bearer`。不建议退回明文 HTTP + HMAC，图库内容属于高隐私数据。
4. 服务默认只监听局域网接口；提供「允许的设备」列表与逐个撤销；不默认开放外网。

### 5.2 接口草案（服务端全部基于现有 Store 能力实现）

| 方法 | 路径 | 作用 | 复用点 |
|---|---|---|---|
| GET | `/v1/info` | 协议版本、图库名、能力位、当前 revision | 新增 |
| POST | `/v1/pair` | 配对，返回设备令牌 | 新增 |
| GET | `/v1/sidebar` | 相簿 / 文件夹树 + 计数 + 封面 | `LibraryStore` 现有树结构 |
| GET | `/v1/query` | 分页查询：`PhotoQuery` + `offset/limit` | [MetadataStore+Query.swift](../Sources/PhotosClone/Services/Library/MetadataStore+Query.swift) |
| GET | `/v1/thumb/{id}?w=200` | 缩略图，带 ETag | `ImageLoader.gridThumbnail` 生成 + 缓存 |
| GET | `/v1/asset/{id}?variant=display&max=2600` | 服务端解码后的展示图（HEIC/RAW 转标准 JPEG） | `ImageLoader` + `RawSupport` |
| GET/HEAD | `/v1/asset/{id}/original` | 原图，支持 `Range` | `LibraryPaths.sourceURL` |
| GET | `/v1/video/{id}` | 视频；系统解不了的容器 302 到 HLS | `VideoSupport` + `LocalHLSServer` |
| GET | `/v1/hls/{id}/index.m3u8` | 转码流（边转边播） | 现有 HLS 管线改为局域网可达 |
| GET | `/v1/live/{id}` | 实况照片的配对视频 | `LibraryPaths.livePhotoURL` |
| PATCH | `/v1/assets/{id}` | 收藏 / 评分 / 旗标 / 色标 / 标题 / 关键词，带 `If-Match: revision` | `LibraryStore+Metadata` |
| POST | `/v1/albums/{id}/items` | 加入 / 移出 / 相簿内排序 | `LibraryStore+Organize` |
| GET | `/v1/search?q=` | 全文、场景标签、OCR、人物 | `SearchQuery` / `PhotoIntelligence` 结果 |
| GET | `/v1/people` | 人物列表与关系（只读） | `people` / `person_assets` |
| POST | `/v1/imports` | 创建导入会话，返回缺失项 | 新增（包 `ImportService`） |
| PUT | `/v1/imports/{sid}/items/{sha256}` | 分块上传单项 | 新增 |
| POST | `/v1/imports/{sid}/commit` | 提交并生成缩略图/入库 | [ImportService.swift](../Sources/PhotosClone/Services/Import/ImportService.swift#L20-L63) |
| GET | `/v1/jobs/{id}` | 导入 / 转码进度 | 新增 |

### 5.3 大图库与缓存

- 服务端只返回窗口数据（沿用每页 600 的既有策略），绝不返回整库 JSON。
- 缩略图分三档按需生成并落盘：`w=200`（手机网格）、`w=600`（iPad / 放大网格）、`max=2600`（查看器），带 `ETag` + `Cache-Control: immutable`（id 是 UUID，内容不可变）。
- iOS 端用 `URLCache` + 自建磁盘 LRU（建议 2–4 GB 上限，按可用空间调整）；网格滚动只预取前后各一屏。
- 原图与 RAW 不在手机上解码：查看器请求 `variant=display`，由 Mac 用 ImageIO/Core Image 渲染，避免 iPhone 解码 50MP RAW 造成卡顿与内存峰值。

### 5.4 视频

- 原生支持的容器（MP4/MOV/M4V）直接 `Range` 读取原文件，AVPlayer 拖动成本最低。
- MKV/AVI/WMV 等继续走 Mac 的 ffmpeg 转封装 / HLS；现有 HLS 服务只需改三件事：监听 `0.0.0.0`、校验令牌、按会话隔离目录。
- 外挂字幕由服务端提供同名字幕文本（SRT/VTT），iOS 端用 AVPlayer 字幕渲染；内嵌字幕与音轨切换依赖 HLS 主播放列表。
- 播放期间 Mac 端持有 `IOPMAssertion` 阻止空闲睡眠；客户端断开后释放。

### 5.5 一致性与并发

- **单一写入者**：所有变更经 Mac 的 `LibraryStore` 执行并 `save()`，iOS 不落库。
- 增加一个图库级 `revision`（`settings` 表内自增，`save()` 时 +1）；查询返回 `revision`，PATCH 带 `If-Match`，冲突返回 `409` 并附最新快照。
- 删除 / 恢复 / 永久删除沿用现有确认与生命周期逻辑；iOS 只负责二次确认 UI。
- 撤销栈目前在 Mac 内存中，跨设备语义需明确：建议 P1 只支持「本设备最近一次操作可撤销」，不做全局协同撤销。

### 5.6 多图库的现状限制

[LibraryPaths.swift](../Sources/PhotosClone/Services/Library/LibraryPaths.swift#L15-L16) 的 `root` 是全局静态状态，切换图库会改全局并写 bootstrap。因此 **P0 只能服务「Mac 当前打开的图库」**；要支持 iOS 同时选择多个图库，需要把 `LibraryPaths` / `MetadataStore` 从全局单例改成实例作用域（中等改造量，P5 再做）。

---

## 6. 手机相册 → 本地库同步

```svg
<svg viewBox="0 0 960 600" width="100%" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="手机相册同步时序">
  <defs>
    <marker id="a2" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M0,0 L10,5 L0,10 z" fill="#5C584E"/>
    </marker>
  </defs>
  <rect width="960" height="600" fill="#FCFBF8"/>

  <rect x="40" y="24" width="200" height="40" rx="10" fill="#FFFFFF" stroke="#E7E2D9"/>
  <text x="140" y="49" text-anchor="middle" font-family="-apple-system, PingFang SC, sans-serif" font-size="13" font-weight="600" fill="#23232B">iPhone · 拾光 iOS</text>

  <rect x="380" y="24" width="200" height="40" rx="10" fill="#FFFFFF" stroke="#E7E2D9"/>
  <text x="480" y="49" text-anchor="middle" font-family="-apple-system, PingFang SC, sans-serif" font-size="13" font-weight="600" fill="#23232B">Mac · LAN Service</text>

  <rect x="720" y="24" width="200" height="40" rx="10" fill="#FFFFFF" stroke="#E7E2D9"/>
  <text x="820" y="49" text-anchor="middle" font-family="-apple-system, PingFang SC, sans-serif" font-size="13" font-weight="600" fill="#23232B">图库 / ImportService</text>

  <line x1="140" y1="64" x2="140" y2="560" stroke="#D9D3C7" stroke-dasharray="4 6"/>
  <line x1="480" y1="64" x2="480" y2="560" stroke="#D9D3C7" stroke-dasharray="4 6"/>
  <line x1="820" y1="64" x2="820" y2="560" stroke="#D9D3C7" stroke-dasharray="4 6"/>

  <text x="140" y="92" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">读取 PHAsset（按 creationDate 增量）</text>

  <line x1="140" y1="112" x2="480" y2="112" stroke="#5C584E" stroke-width="1.4" marker-end="url(#a2)"/>
  <text x="146" y="106" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#3A3A44">POST /v1/imports · 提交候选清单（文件名/大小/拍摄时间）</text>

  <line x1="480" y1="150" x2="140" y2="150" stroke="#5C584E" stroke-width="1.4" marker-end="url(#a2)"/>
  <text x="146" y="144" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#3A3A44">200 · 返回缺失项与已存在项的 assetId</text>

  <text x="140" y="184" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">PHAssetResourceManager 导出原图 + 配对视频</text>
  <text x="140" y="202" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">（iCloud 资源需 isNetworkAccessAllowed，可显示进度）</text>

  <line x1="140" y1="226" x2="480" y2="226" stroke="#5C584E" stroke-width="1.4" marker-end="url(#a2)"/>
  <text x="146" y="220" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#3A3A44">PUT /v1/imports/{sid}/items/{sha256} · 4–8 MB 分块，可续传</text>

  <line x1="480" y1="268" x2="820" y2="268" stroke="#5C584E" stroke-width="1.4" marker-end="url(#a2)"/>
  <text x="486" y="262" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#3A3A44">写入临时区 → 边收边算 SHA-256</text>

  <line x1="820" y1="304" x2="480" y2="304" stroke="#5C584E" stroke-width="1.4" marker-end="url(#a2)"/>
  <text x="486" y="298" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#3A3A44">命中重复 → 丢弃临时文件，返回既有 id</text>

  <line x1="480" y1="340" x2="820" y2="340" stroke="#5C584E" stroke-width="1.4" marker-end="url(#a2)"/>
  <text x="486" y="334" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#3A3A44">未命中 → ImportService 拷贝进 originals、生成缩略图、补 EXIF</text>

  <line x1="820" y1="382" x2="480" y2="382" stroke="#5C584E" stroke-width="1.4" marker-end="url(#a2)"/>
  <text x="486" y="376" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#3A3A44">入库（批次 ID · 实况配对 · 相簿归属）</text>

  <line x1="480" y1="420" x2="140" y2="420" stroke="#5C584E" stroke-width="1.4" marker-end="url(#a2)"/>
  <text x="146" y="414" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#3A3A44">200 · 逐项结果 + 新 revision（iOS 记录 lastSyncToken）</text>

  <rect x="120" y="446" width="720" height="96" rx="12" fill="#F7F5EF" stroke="#E7E2D9"/>
  <text x="140" y="470" font-family="-apple-system, PingFang SC, sans-serif" font-size="11.5" font-weight="600" fill="#23232B">触发与边界</text>
  <text x="140" y="492" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#5C584E">· 触发：手动「同步新照片」、前台进入、Wi-Fi + 充电时的 BGProcessingTask（系统不保证执行时机）</text>
  <text x="140" y="512" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#5C584E">· 后台传输：URLSession background 配置上传文件，App 挂起后仍由系统接管；大视频必须分块并持久化进度</text>
  <text x="140" y="532" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#5C584E">· 失败策略：单项失败不阻断整批；重试按 sha256 去重；服务端崩溃后临时区可清理</text>
</svg>
```

### 6.1 关键实现细节

| 项 | 方案 |
|---|---|
| 取哪些照片 | `PHAsset` 按 `creationDate`/`modificationDate` 增量，范围可选「全部 / 最近 30 天 / 指定相簿」 |
| 导出的资源 | 原图资源 + 实况配对视频（`.pairedVideo`）+（可选）调整数据；ProRAW 取 DNG 原资源 |
| 去重 | 服务端最终以 SHA-256 为准；客户端先提交「文件名 + 大小 + 拍摄时间」做预检，避免重复上传 |
| 大视频 | 分块 4–8 MB，内容寻址，断点续传；不要指望单次 PUT 传完数 GB |
| iCloud 优化存储 | 资源可能不在本机，需允许网络下载并展示「等待下载」状态，避免误判为失败 |
| 实况照片 | 同时上传配对视频，Mac 端沿用同名配对逻辑；iOS 端播放直接用配对视频 |
| 入库表现 | 沿用现有「导入项目」批次分组，手机同步作为独立来源标注 |
| 反向同步 | 可选：Mac → iPhone 相册，用 `PHPhotoLibrary` 创建资产；视频由 Mac 转码后再传，避免 iPhone 解码失败 |
| 后台限制 | 不能保证「锁屏后仍持续扫描相册」；体验上应明确为「打开 App 即续传」 |

---

## 7. 非局域网（外网）访问

### 7.1 结论

可以，但**外网访问的瓶颈不是协议，而是 NAT/运营商、家庭上行带宽与安全边界**。不建议把 Mac 的服务端口直接映射到公网；推荐按以下优先级选择：

1. **覆盖网络（Tailscale / WireGuard）**：改动最小，安全边界清晰。
2. **自建反向隧道中继**：不依赖第三方，但需要服务器与运维。
3. **Cloudflare Tunnel + Access**：适合轻量浏览，不适合大码率视频。
4. **IPv6 直连 + DDNS**：取决于运营商与路由器。
5. **公网端口映射**：仅用于调试，不进入产品方案。

### 7.2 路径对比

| 路径 | 原理 | 优点 | 限制 | 可行性 |
|---|---|---|---|---|
| Tailscale / WireGuard 覆盖网络 | 两端加入同一 tailnet，WireGuard 加密；NAT 打洞失败时自动走 DERP 中继 | 免公网 IP、免端口映射、设备级 ACL、基本免运维 | 需要两端安装 VPN 客户端；iOS 不能内嵌隧道（NetworkExtension 权限与审核成本高），只能引导用户安装 Tailscale | **高（推荐）** |
| 自建反向隧道中继 | Mac 主动建立 TLS 长连接到 VPS，iOS 连同一中继，按连接转发 | 不暴露家庭 IP；中继只见密文；不依赖第三方账号 | 需要 VPS、域名、证书、监控；中继带宽按流量计费 | 中 |
| Cloudflare Tunnel + Access | `cloudflared` 出站隧道 + 身份校验 | 零端口映射、自带 SSO 与访问控制 | 大量图片/视频经 CDN，受条款与带宽限制，视频体验差 | 中（浏览可用，视频不推荐） |
| IPv6 直连 + DDNS | 家庭获得公网 IPv6，防火墙只放行已配对设备 | 无中继、延迟最低、零流量费 | 运营商与路由器支持不一；蜂窝网络 IPv6 可达性不稳定 | 中 |
| 公网端口映射 + DDNS + 反向代理 | 路由器映射端口 | 实现最简单 | CGNAT 下通常不可用；暴露面大，必须自建鉴权、限流与补丁机制 | 低（仅调试） |

### 7.3 推荐架构

```svg
<svg viewBox="0 0 960 540" width="100%" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="外网访问三条路径">
  <defs>
    <linearGradient id="gWan" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#F6B45A"/>
      <stop offset="55%" stop-color="#EF7C5B"/>
      <stop offset="100%" stop-color="#8C6BF2"/>
    </linearGradient>
    <marker id="aW" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M0,0 L10,5 L0,10 z" fill="#6B6B76"/>
    </marker>
  </defs>
  <rect width="960" height="540" fill="#FCFBF8"/>

  <!-- iPhone -->
  <rect x="24" y="130" width="220" height="262" rx="16" fill="#FFFFFF" stroke="#E7E2D9"/>
  <rect x="24" y="130" width="220" height="6" rx="3" fill="url(#gWan)"/>
  <text x="44" y="162" font-family="-apple-system, PingFang SC, sans-serif" font-size="14" font-weight="600" fill="#23232B">iPhone · 拾光 iOS</text>
  <text x="44" y="190" font-family="-apple-system, PingFang SC, sans-serif" font-size="11.5" fill="#3A3A44">连接管理器</text>
  <text x="44" y="212" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">① LAN　② Tailnet　③ Relay</text>
  <text x="44" y="236" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">路径记忆 / 自动回退</text>
  <text x="44" y="260" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">10 秒健康探测</text>
  <text x="44" y="284" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">蜂窝默认只取缩略图</text>
  <text x="44" y="308" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">原图 / 视频需显式确认</text>

  <!-- Mac -->
  <rect x="706" y="100" width="228" height="330" rx="16" fill="#FFFFFF" stroke="#E7E2D9"/>
  <rect x="706" y="100" width="228" height="6" rx="3" fill="url(#gWan)"/>
  <text x="724" y="132" font-family="-apple-system, PingFang SC, sans-serif" font-size="14" font-weight="600" fill="#23232B">Mac · 拾光（图库主机）</text>
  <text x="724" y="158" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">同一套 /v1 API，单写者</text>
  <text x="724" y="182" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">设备白名单 + 令牌撤销</text>
  <text x="724" y="206" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">每设备并发 / 带宽限流</text>
  <text x="724" y="230" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">ffmpeg 自适应码率转码</text>
  <text x="724" y="254" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#8A8578">服务不监听公网网卡</text>

  <!-- route 1 -->
  <text x="470" y="166" text-anchor="middle" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#5C584E">① 同一 Wi-Fi：Bonjour 直连，零中继</text>
  <line x1="244" y1="180" x2="706" y2="180" stroke="#6B6B76" stroke-width="1.4" marker-end="url(#aW)"/>

  <!-- route 2 -->
  <text x="470" y="250" text-anchor="middle" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#5C584E">② 覆盖网络：Tailscale / WireGuard，打洞失败自动走 DERP</text>
  <rect x="392" y="264" width="160" height="72" rx="12" fill="#FFFDF9" stroke="#E7E2D9" stroke-dasharray="5 4"/>
  <text x="472" y="294" text-anchor="middle" font-family="-apple-system, PingFang SC, sans-serif" font-size="11.5" font-weight="600" fill="#23232B">Tailnet / DERP</text>
  <text x="472" y="314" text-anchor="middle" font-family="-apple-system, PingFang SC, sans-serif" font-size="10.5" fill="#8A8578">端到端加密</text>
  <line x1="244" y1="300" x2="392" y2="300" stroke="#6B6B76" stroke-width="1.4" marker-end="url(#aW)"/>
  <line x1="552" y1="300" x2="706" y2="300" stroke="#6B6B76" stroke-width="1.4" marker-end="url(#aW)"/>

  <!-- route 3 -->
  <text x="470" y="390" text-anchor="middle" font-family="-apple-system, PingFang SC, sans-serif" font-size="11" fill="#5C584E">③ 自建中继 / Cloudflare Tunnel：Mac 主动外连</text>
  <rect x="392" y="404" width="160" height="72" rx="12" fill="#FFFDF9" stroke="#E7E2D9" stroke-dasharray="5 4"/>
  <text x="472" y="434" text-anchor="middle" font-family="-apple-system, PingFang SC, sans-serif" font-size="11.5" font-weight="600" fill="#23232B">Relay</text>
  <text x="472" y="454" text-anchor="middle" font-family="-apple-system, PingFang SC, sans-serif" font-size="10.5" fill="#8A8578">中继只见密文</text>
  <line x1="244" y1="440" x2="392" y2="440" stroke="#6B6B76" stroke-width="1.4" marker-end="url(#aW)"/>
  <line x1="552" y1="440" x2="706" y2="440" stroke="#6B6B76" stroke-width="1.4" marker-end="url(#aW)"/>

  <text x="480" y="512" text-anchor="middle" font-family="-apple-system, PingFang SC, sans-serif" font-size="10.5" fill="#9A927F">公网端口映射只作调试兜底：反向代理 + mTLS / Access + IP 白名单 + 限流</text>
</svg>
```

### 7.4 客户端与服务端改动

| 项 | LAN 版 | 外网版 |
|---|---|---|
| 发现 | Bonjour `_luma._tcp` | 扫二维码写入 tailnet 域名 / 中继地址；保留手动填 IP |
| 路径选择 | 唯一路径 | LAN → Tailnet → Relay 依次尝试，记住上次成功路径 |
| 页大小 | 600 / 页 | 200 / 页（4G 下再降到 120） |
| 预取 | 前后各一屏 | 仅视口 ±1 屏，禁止整屏预取 |
| 缩略图 | 200 / 600 / 2600 三档 | 网格固定 200，查看器先 1024 再按需原图 |
| 视频 | 原文件 Range 或单档 HLS | 1080p / 720p / 480p 自适应码率，上行不足自动降档 |
| 上传 | 直接分块 | 蜂窝默认只入队，Wi-Fi 才传原图；断点续传与退避重试 |
| 服务端 | 监听内网 | 监听 tailnet / 内网网卡；限流、审计日志、异常熔断 |
| 证书 | 自签 + SPKI 固定 | Tailscale 证书走系统信任；自签仍固定 SPKI |

流量参考：600 张缩略图按 15–30 KB/张估算约 9–18 MB/页，4G 下必须降低页大小；1080p 视频约 2–4 Mbps，4K 需 15–25 Mbps。

### 7.5 外网安全控制点

- 不把服务端口直接暴露到公网；确需暴露时，前面必须有反向代理，启用 mTLS 或 Cloudflare Access，并限制来源 IP。
- 配对必须「物理在场」：Mac 本机确认 + 短时效配对码；外网不允许仅凭 6 位码完成配对；失败次数锁定。
- 设备令牌可撤销、可轮换；记录设备名、最近连接时间与来源 IP。
- 端到端加密：覆盖网络自带；自建中继用 TLS + 应用层加密，中继只转发密文。
- 图片与视频 URL 使用短时签名，避免令牌泄露后长期可拉取。
- 单设备并发与总带宽限流，防止打满家庭上行；异常请求直接断开。

### 7.6 现实约束（需要写进产品说明）

- **Mac 必须在线**：跨公网的网络唤醒基本不可用（WoL 广播不出公网）。要么 Mac 常供电常开，要么单独做「离线只读副本」。
- **家庭上行决定体验**：上行 20 Mbps 时同时只够 1–2 路 1080p；这也是必须做自适应码率的原因。
- **蜂窝流量**：默认只浏览缩略图，原图与视频需用户确认；同步原图默认只在 Wi-Fi 下进行。
- **隐私**：走第三方 CDN/中继时，元数据与流量特征会暴露给第三方（内容可加密）；敏感场景选自建中继或 overlay。
- **成本**：自建中继按流量计费，视频是大头；覆盖网络的个人额度通常够用。

### 7.7 建议

- 第一优先 **Tailscale**：服务端只需把监听地址从 LAN 扩展到 tailnet，iOS 端加「远程地址」配置即可，改动最小。
- 若坚持不装第三方 App：做自建中继，但要把服务器、证书、监控与流量成本算进产品。
- 「Mac 不在线也要能看」是另一个需求：只能靠离线只读副本或对象存储中的代理图，不能与远程访问混为一谈。

---

## 8. 功能可行性矩阵

分级：**A** 可完全对齐；**B** 能力对齐、交互重写；**C** 只读或受限；**D** 桌面专属 / 不适用。

| 功能域 | 关键能力 | iOS 实现路径 | 可行性 |
|---|---|---|---|
| 浏览 | 年 / 月 / 全部时间轴、四种网格、缩放、框选 | 服务端分页 + SwiftUI 网格 | A |
| 查看器 | 渐进加载、胶片条、信息面板、幻灯片 | 原生重写手势与转场 | B |
| 搜索 | 关键词、全文、场景标签、OCR、组合时间词 | 复用 Mac 的搜索与标签结果 | A |
| 排序 / 筛选 | 拍摄时间、大小、类型、评分、旗标、色标 | `PhotoQuery` 下推 SQL | A |
| 相簿 / 文件夹 | 增删改移、封面、相簿内排序 | 写操作回传 Mac | B |
| 元数据 | 收藏、评分、旗标、色标、关键词、标题 | PATCH + revision | A |
| 删除 | 最近删除、恢复、永久删除（含清理产物） | 沿用 Mac 生命周期逻辑 | A |
| 撤销 / 重做 | 30 步图库级撤销 | 语义改为「本设备最近操作」 | C |
| 编辑 | 旋转裁剪、滤镜、RAW、实况 | Core Image 可移植；渲染落盘在 Mac | B |
| 压缩 / 导出 | 有损 / 无损、格式与尺寸 | iOS 可执行，导出到「文件」或相册 | B |
| 视频播放 | Range、HLS、字幕、音轨、倍速、画中画 | AVPlayer + Mac 转码 | A |
| 实况照片 | 播放、导出配对视频 | 配对视频可播；原生 Live Photo 效果需额外封装 | B |
| 导入 | 文件、分享扩展、相册 | 上传 + Mac 导入 | A |
| 手机相册同步 | 增量、断点续传、去重 | 见第 6 节 | A |
| 场景 / OCR / 二维码 / 证件 | Vision 端侧识别 | 直接读 Mac 结果；本地重跑需移植 | A（只读）/ B（本地） |
| SigLIP 语义搜索 / 相似照片 | 图文向量 | 读 Mac 已算好的向量与结果 | A |
| 人脸聚类 / 人物页 | 聚类、命名、同框 | 读 Mac 结果；本地重算成本高 | A（只读）/ C（本地） |
| 地图 / 位置 / 足迹回放 | MapKit、聚合、动画 | MapKit 可移植；动画逻辑在 `LumaCore` | B |
| 回忆 / 旅行 / 值得重看 | 派生卡片与影片导出 | 数据由 Mac 产出，iOS 可播放与导出 | A |
| 智能助手 | 26 个工具、云模型 | 网络客户端可移植；工具执行走 Mac API | A |
| 影院 | 刮削、海报墙、网盘播放 | TMDB/豆瓣可移植；播放经 Mac 代理 | B |
| 网络存储 | WebDAV / AList / 阿里云 / 夸克 / SMB | 前四者可直连移植；SMB 不可用 | B / C |
| 系统「照片」图库 | 解析 `Photos.sqlite` | 仅 macOS；iOS 只能读 iPhone 自身相册 | D |
| 图库切换 / 多图库 | 多库并存 | 需把全局路径改实例作用域 | C |
| 保险库 / 体检 / 美化扫描 | 重 IO 扫描 | 建议 Mac 执行、iOS 展示结果 | C |
| 打印 / 桌面壁纸 / 全局快捷键 | 桌面交互 | 不适用 | D |

结论：**日常使用闭环（看、找、放、整理、回传）可以做到接近一致；「完全一样」不成立，但可以在体验上做到无明显短板。**

---

## 9. 关键技术风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| SQLite 放在网络盘上读写 | WAL 锁不可靠、库损坏风险 | 明确禁止方案 C；iOS 只走 HTTP API |
| iOS 禁止子进程 | ffmpeg 无法在手机上执行 | 转码全部留在 Mac；如需端侧转码则集成 libav*（包体、GPL 与工程成本都要评估） |
| `NetFS` 仅 macOS | SMB 网盘无法在 iOS 直连 | P0 统一经 Mac 代理；后续再引第三方 SMB 实现 |
| Mac 休眠 / 退出 / 换网 | 连接中断 | 服务随 App 运行；活动时阻止空闲睡眠；iOS 自动重连 + 指数退避 |
| 外网无公网 IP / CGNAT | 端口映射不可用 | 走覆盖网络或反向中继，不依赖公网 IP |
| 家庭上行带宽不足 | 视频卡顿、并发受限 | 自适应码率 HLS + 每设备限流 + 默认低码率 |
| 公网暴露 | 被扫描、爆破、盗链 | 不映射端口；必须暴露时加反代、mTLS/Access、失败锁定与短时签名 URL |
| 蜂窝流量 | 用户流量超支 | 默认只取缩略图；原图与相册同步仅 Wi-Fi |
| 百万级图库 | 首屏慢、内存高 | 沿用 600/页窗口；缩略图按需生成 + ETag + 本地缓存 |
| HDR / HEIF / RAW | iOS 端解码失败或偏色 | 查看器统一由 Mac 渲染 SDR JPEG；视频保留 HEVC 直传 |
| 后台任务不保证 | 同步不及时 | 明确定位为「前台续传」；用后台 URLSession 与 BGProcessingTask 尽力而为 |
| 局域网安全 | 图库隐私泄露 | TLS + 配对令牌 + 设备撤销；默认只监听内网，不做端口映射 |
| App Store 审核 | 上架不确定 | 同类「配套服务端」应用有先例（如 NAS 相册类）；自用优先 TestFlight / 自签 |
| 多图库全局状态 | 无法同时服务多个库 | P0 只服务当前库；P5 把 `LibraryPaths` 实例化 |
| 编辑结果落盘 | iOS 渲染后需要入库 | 由 iOS 上传渲染结果，Mac 作为新副本或新编辑版本入库 |

---

## 10. 复用与改造量

```svg
<svg viewBox="0 0 960 420" width="100%" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="代码复用分层">
  <rect width="960" height="420" fill="#FCFBF8"/>
  <text x="40" y="46" font-family="-apple-system, PingFang SC, sans-serif" font-size="15" font-weight="600" fill="#23232B">按现有代码的实际依赖划分复用等级</text>

  <rect x="40" y="70" width="880" height="56" rx="12" fill="#F1F7F0" stroke="#D9E8D6"/>
  <text x="60" y="94" font-family="-apple-system, PingFang SC, sans-serif" font-size="13" font-weight="600" fill="#2F5D33">直接复用</text>
  <text x="60" y="114" font-family="-apple-system, PingFang SC, sans-serif" font-size="11.5" fill="#4A6B4C">LumaCore · SQLite 封装 · PhotoQuery · Domain 模型 · Keychain · Vision/CoreML 调用方式</text>

  <rect x="40" y="136" width="880" height="56" rx="12" fill="#FBF7EC" stroke="#EDE2C9"/>
  <text x="60" y="160" font-family="-apple-system, PingFang SC, sans-serif" font-size="13" font-weight="600" fill="#7A5A18">小幅抽取</text>
  <text x="60" y="180" font-family="-apple-system, PingFang SC, sans-serif" font-size="11.5" fill="#7A6A45">MetadataStore · ImportService · WebDAV / 云盘客户端 · AI 客户端 · 派生数据计算</text>

  <rect x="40" y="202" width="880" height="56" rx="12" fill="#FDF2E9" stroke="#F0D8C2"/>
  <text x="60" y="226" font-family="-apple-system, PingFang SC, sans-serif" font-size="13" font-weight="600" fill="#8A4B1D">需要适配</text>
  <text x="60" y="246" font-family="-apple-system, PingFang SC, sans-serif" font-size="11.5" fill="#7D6250">ImageLoader（NSImage → UIImage/CGImage）· ImageTransform · VideoSupport（Process 隔离）· LibraryStore</text>

  <rect x="40" y="268" width="880" height="56" rx="12" fill="#FBEDEC" stroke="#EFCFCB"/>
  <text x="60" y="292" font-family="-apple-system, PingFang SC, sans-serif" font-size="13" font-weight="600" fill="#8A2F28">必须重写</text>
  <text x="60" y="312" font-family="-apple-system, PingFang SC, sans-serif" font-size="11.5" fill="#7D4A45">Features/Views（39,397 行）· 快捷键 / 打印 / 拖拽 / 菜单 / 多窗口 · 触控交互与转场</text>

  <rect x="40" y="334" width="880" height="56" rx="12" fill="#F3F2EF" stroke="#E1DED6"/>
  <text x="60" y="358" font-family="-apple-system, PingFang SC, sans-serif" font-size="13" font-weight="600" fill="#6B675C">iOS 不可用</text>
  <text x="60" y="378" font-family="-apple-system, PingFang SC, sans-serif" font-size="11.5" fill="#7A766B">ffmpeg 子进程 · NetFS SMB · Photos.sqlite 解析 · NSOpenPanel / NSSavePanel / NSWorkspace</text>
</svg>
```

具体改造清单（按文件）：

1. `Package.swift`：增加 `.iOS(.v17)`，拆出 `LumaKit`（共享模型与协议）与 `LumaMobile`（iOS App）target。
2. `LibraryPaths`：保持 Mac 端全局状态；新增「服务端会话」概念，P0 绑定当前图库。
3. `ImageLoader` / `ImageTransform`：抽出 `PlatformImage` 类型别名与解码入口，服务端额外提供「按尺寸出 JPEG」。
4. `VideoSupport`：`Process` 相关代码加 `#if os(macOS)`；iOS 端只保留 AVPlayer 与远端 HLS。
5. `LocalHLSServer`：抽出可复用的 HTTP 响应与 Range 逻辑，新增局域网监听与令牌校验。
6. 新增 `Services/LAN/`：路由、配对、鉴权、上传会话、限流与日志（不暴露文件系统路径）。
7. `MetadataStore`：新增 revision 自增与 `assets` 增量分页接口；保持 WAL 与单写者。
8. `ImportService`：增加「临时区 → 校验 → 入库」路径与批次 ID，复用现有 SHA-256 与缩略图生成。
9. iOS 新工程：浏览、查看器、视频、相簿、同步四个主模块先行，其余按阶段补齐。

---

## 11. 分期路线

| 阶段 | 范围 | 交付物 | 验收口径 |
|---|---|---|---|
| P0 | Mac 端服务：Bonjour、配对、`/v1/query`、缩略图、展示图、视频 Range/HLS；顺带提供 PWA | 可在浏览器完整浏览并播放；协议文档 | 10 万张图库首屏 600 项出图；4K 视频 1.5 秒内起播；未配对设备拿不到任何数据 |
| P1 | iOS 原生：网格、查看器、视频、相簿导航、搜索、元数据写入 | TestFlight 可安装包 | 与 Mac 视图一致的分页与计数；写操作冲突返回 409 并可恢复 |
| P2 | 手机相册同步：增量、去重、分块、后台上传、实况与 ProRAW | 同步页与导入批次 | 断网续传；重复项零新增；1000 张批量同步无内存峰值 |
| P3 | 编辑、压缩、导出、人物 / 场景只读、地图、回忆、AI 助手 | 功能补齐 | 编辑副本可回传入库；AI 工具写操作仍需确认 |
| P4 | 远程访问：Tailscale 接入、LAN → Tailnet → Relay 回退、WAN 分页与自适应码率 | 远程浏览与播放 | 4G 下 200/页可流畅滚动；弱网自动降码率；断网后恢复 |
| P5 | 多图库实例化、离线只读副本、网盘直连 | 稳定版 | 切换图库不影响 Mac 当前视图；离线可看已缓存相簿 |

不建议在 P0 就做：多图库并发会话、iOS 本地人脸重算、iOS 端 ffmpeg、SMB 直连、iCloud 同步、公网端口映射。

---

## 12. 结论与需要拍板的点

**结论：**

1. 三项核心诉求（同局域网读 Mac 图库、iOS 播放、手机相册回传）技术路径清晰，且能大量复用现有数据层、导入管线与转码能力，可行性高。
2. 真正的成本在 **iOS 交互层重写**（视图层 3.9 万行、100 个文件依赖 AppKit），而不是网络协议。
3. 建议先做 **Mac 端局域网服务 + PWA** 验证协议、性能与缓存策略；验证通过后再投入原生 iOS。这样即使原生 App 延期，也已经获得「手机可看图库」的可用能力。
4. 明确不做「iOS 直接读写图库目录 / SQLite」，这是数据安全底线。
5. 非局域网场景同样可行：优先 Tailscale 等覆盖网络，其次自建反向中继；公网端口映射不进入产品方案。外网体验的上限由家庭上行带宽决定，必须配套自适应码率与限流。

**需要确认的决策点：**

- 发行方式：TestFlight 自用、App Store 上架，还是先只做 PWA？
- 是否必须「脱离 Mac 也能用」？如果是，需要独立 iOS 本地图库，工作量与复杂度会显著上升。
- Mac 是否可以要求「常开 + 拾光常驻」？否则同步与播放的可用性需要重新定义。
- 是否接受安装 Tailscale / WireGuard 客户端？如果拒绝，就得自建中继并承担服务器与流量成本。
- 是否需要多图库同时在线？这决定 P5 是否提前。
- 相册同步是单向（手机 → Mac）还是也要反向（Mac → 手机相册）？
