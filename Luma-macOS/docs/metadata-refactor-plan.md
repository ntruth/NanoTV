# 产品元数据重构方案

**主题：单库模型、当前图库与“一个 Photos.sqlite”可行性**

| 项目 | 内容 |
| --- | --- |
| 版本 | v0.1 |
| 日期 | 2026-11-17 |
| 状态 | 方案 A 已确认，待实施 |
| 适用范围 | macOS 拾光（Luma）全部图库、系统照片库、网盘元数据 |

---

## 决策记录

| 决策项 | 结论 |
| --- | --- |
| 单库方案 | 采用方案 A：每库一个 Luma 可写 SQLite；官方库 `Photos.sqlite` 只读，写入走 PhotoKit |
| Luma 可写库文件名 | `database/PhotosLuma.sqlite` |
| 侧边栏分区标题 | “系统图库”改为“链接图库” |
| 真实媒体文件 | 同一图库内共享 Apple 原图与 derivatives，不复制第二份；跨图库不共享 |
| 历史数据迁移 | 不做 v6 → v7 数据迁移；旧 `PhotosClone.sqlite` 不读取，改名隔离，确认后可删除 |
| UI 样式 | 布局、配色、组件、交互全部保持不动，只改数据源与能力判断 |

---

## 0. 摘要

### 0.1 目标

把现在“拾光图库”和“系统图库”两套数据通路合并成一套：

- 同一时间只有一个**当前图库**，打开哪个 `.photoslibrary`，哪个就是当前图库。
- 只保留三个产品概念：**当前图库、链接的图库、链接的网盘**。
- 新增、导入、修改、删除、收藏、关键词、相簿、文件夹、人物、分析结果全部走同一个入口。
- 能用系统原生接口的走原生接口；原生接口不支持的，再操作数据表、文件与目录。
- 所有界面布局、配色、组件、交互保持不变。

### 0.2 结论

**可以做，但不能把 Luma 的数据写进 Apple 官方图库的 `database/Photos.sqlite`。**

准确结论分三句：

1. **官方 `.photoslibrary` 里的 `Photos.sqlite` 不能写。** 它是 Apple Photos 的 Core Data 数据库，第三方加表、加列、改行都会被 Photos 的完整性检查、升级或 iCloud 同步破坏，存在图库损坏和照片丢失风险。这不是权限问题。
2. **Luma 必须有一个自己可写的 SQLite。** 每个图库包内可以只保留一个 Luma 可写 SQLite；官方库的 `Photos.sqlite` 只作为只读内容源，真实写入通过 PhotoKit。
3. **“只用一个 Photos.sqlite，Luma 内容都写进去”在官方库上不可行；在 Luma 自建库上可行，但不建议复用 `Photos.sqlite` 这个文件名。** 复用会让系统的图库识别、当前代码的原生库判断和外部工具误判。

### 0.3 推荐方案

**已确认采用方案 A：每库一个 Luma 可写 SQLite + 官方库 `Photos.sqlite` 只读源 + PhotoKit 写回。**

- 真实媒体文件共享：官方库原生照片仍读 Apple 的 `originals` / `derivatives`，不复制第二份；Luma 只额外保存自己的元数据库、编辑渲染副本和可重建缓存。
- Luma 自有 SQLite 统一命名为 `database/PhotosLuma.sqlite`。新库直接使用该文件名；旧 `PhotosClone.sqlite` 不读取、不迁移，改名隔离，确认后可删除。
- 不做历史数据迁移：旧收藏、关键词、相簿、人物、AI 对话、网盘挂载列表、图库级设置都不带入新库。
- 不使用 `Luma.sqlite`、`Library.sqlite` 等其他新文件名，避免再引入命名体系。
- 官方库的 `database/Photos.sqlite` 永远只读；Luma 的收藏、关键词、标题、分析结果、相簿扩展、网盘缓存、智能助手对话全部写 Luma 自有 SQLite。
- 对用户只呈现“一个当前图库”，不呈现“两个数据库”。

---

## 1. 现状与问题

### 1.1 现状

当前应用实际存在三条数据通路：

| 通路 | 数据位置 | 代码 |
| --- | --- | --- |
| 拾光自建图库 | `database/PhotosClone.sqlite` 的 `assets / albums / folders / people / settings` | [MetadataStore.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/MetadataStore.swift#L356-L558) |
| 官方照片图库 | 只读 `database/Photos.sqlite` + 旁挂 `PhotosClone.sqlite` 的 `asset_overlays` | [LibraryPaths.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/LibraryPaths.swift#L70)、[LibraryStore+SystemLibrary.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+SystemLibrary.swift#L490-L549) |
| 系统图库索引 | 应用目录下的 `SystemIndex-*.sqlite`，或直连 `Photos.sqlite` | [SystemIndex.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/SystemIndex.swift#L32-L45)、[SystemIndex+Direct.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/SystemIndex+Direct.swift#L12-L33) |

> 上表是现状。重构后 Luma 可写库统一为 `database/PhotosLuma.sqlite`；旧 `PhotosClone.sqlite` 不读取、不迁移，改名隔离后保留或删除。

界面层因此分成两套：

- 拾光图库走 `photos`、`albums`、`folders`。
- 系统图库走 `systemPhotos`、`systemAlbums`、`systemFolders`、`systemIndex`。
- 侧边栏在原生库时直接换一棵树（[SidebarView.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Sidebar/SidebarView.swift#L43-L150)）。
- 大量操作通过 `isSystemScope` / `isNativeContainer` 分支（[LibraryStore+Query.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Query.swift#L95-L102)、[LibraryStore+Query.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Query.swift#L256)）。

### 1.2 问题

1. **概念重复**：同一个图库可以是“拾光库”，也可以是“系统图库连接”，用户需要理解两套分区。
2. **数据重复**：官方库的资产同时存在于 `Photos.sqlite`、`SystemIndex-*.sqlite`、`asset_overlays` 三处，职责不清。
3. **读写分叉**：收藏、隐藏、关键词、标题、相簿、删除分别有本地和原生两套实现，容易出现行为不一致。
4. **切换成本高**：系统图库连接列表存在当前库的 `settings` 里，链接图库和当前图库不是同一层概念。
5. **代码量放大**：`isSystemScope / isNativeContainer / system*` 在 40 多个文件里出现 1000 多次，任意改动都容易回归。

---

## 2. 目标与非目标

### 2.1 目标

- 当前图库唯一；打开即切换；应用重启恢复上次图库。
- 链接多个图库；链接多个网盘；但同一时间只渲染一个当前图库。
- 所有资产、相簿、文件夹、人物、分析、设置、网盘缓存进入**一个 Luma 可写 SQLite**。
- 所有写操作经过统一 Repository；原生能力通过 PhotoKit，非原生能力通过表、文件、目录。
- 界面布局、样式、组件、交互不变；只改数据来源、能力判断和重复分支。

### 2.2 非目标

- 不修改 Apple 的 `Photos.sqlite`、`originals`、`resources/derivatives`。
- 不做两个图库并排显示。
- 不改变网盘协议和网盘只读/可写边界。
- 不做云同步、协作、多用户。

---

## 3. 关键结论：“只用一个 Photos.sqlite”行不行

### 3.1 如果指的是 Apple 官方库的 `Photos.sqlite`

**不行。**

原因不是权限，而是数据所有权和系统兼容性：

| 风险 | 说明 |
| --- | --- |
| Core Data 结构 | `ZASSET`、`ZGENERICALBUM`、`Z_*` 关系表由 Photos 管理；加表、加列、改行会破坏模型一致性 |
| 完整性校验 | Photos 启动、升级、iCloud 同步时可能校验数据库；第三方写入会被视为损坏 |
| WAL 冲突 | Photos 自己持有连接和 WAL；第三方并发写会造成锁冲突、日志回放错误 |
| 图库升级 | macOS 升级可能迁移或重建 Photos 数据库，Luma 加的表会被丢弃或阻塞迁移 |
| 照片安全 | 最坏情况是图库打不开、照片索引丢失；恢复成本极高 |
| 支持边界 | Apple 不提供该数据库的写入接口；这不是可维护的产品方案 |

因此，任何“把 Luma 收藏、关键词、相簿、分析结果写进官方 `Photos.sqlite`”的设计都应直接排除。

### 3.2 如果指的是 Luma 自建库里的 `Photos.sqlite`

**技术上可以，但不建议复用这个文件名。**

Luma 自建 `.photoslibrary` 里可以只有一个 `database/Photos.sqlite`，所有 Luma 表都放进去。但当前代码用“文件是否存在”判断原生库：

```swift
// LibraryPaths.swift
static func isNativeLibrary(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "photoslibrary"
        && FileManager.default.fileExists(
            atPath: url.appendingPathComponent("database/Photos.sqlite").path)
}
```

如果 Luma 自建库也放一个 `Photos.sqlite`，它会被误判成官方库，随后走 PhotoKit 校验、原生库读取和只读分支，直接破坏现有行为。外部工具也可能把它当成 Apple 图库。

**已确认：**

- Luma 自有库统一使用 `database/PhotosLuma.sqlite`。
- 旧 `database/PhotosClone.sqlite` 不读取、不迁移，改名隔离后保留或删除。
- 不使用 `Photos.sqlite`、`Luma.sqlite`、`Library.sqlite` 等其他名字，避免与 Apple 库识别冲突或再引入命名体系。

### 3.3 三种可落地方案对比

| 方案 | 数据布局 | 官方库实时性 | 空间 | 结论 |
| --- | --- | --- | --- | --- |
| A. 实时双文件（已确认） | 每个图库一个 Luma 可写 SQLite；官方库另有 Apple `Photos.sqlite` 只读源 | 实时，PhotoKit 写回 | Luma 只存自己的数据与索引 | 采用 |
| B. 严格单文件 | 官方库只作为导入源，照片拷贝进 Luma 自有单文件库 | 不实时，需要重新导入 | 双份原图空间 | 可选，但会改变产品能力 |
| C. 写 Apple `Photos.sqlite` | Luma 数据全部写入官方库数据库 | 实时 | 无额外空间 | 禁止 |

**方案 A 中的“两个文件”不是两套产品概念：**

- `Photos.sqlite` 是 Apple 的素材目录，只读。
- `PhotosLuma.sqlite` 是 Luma 的唯一可写库。
- 用户只看到“当前图库”，看不到两个数据库。
- 这满足“打开哪个哪个就是当前图库”，也满足“Luma 内容只操作一个库”。

如果产品上必须做到“物理上只有一个 SQLite 文件”，只能选方案 B：放弃官方库实时浏览，把官方库当导入源。这个取舍需要在产品层明确。

---

## 4. 推荐方案 A：一个当前图库，一个 Luma 可写库

### 4.1 概念模型

```
当前图库 CurrentLibrary
  └─ 一个 .photoslibrary 包
      ├─ database/PhotosLuma.sqlite    ← Luma 唯一可写库
      ├─ originals/ resources/         ← managed 文件、缩略图、渲染、备份
      └─ database/Photos.sqlite        ← Apple 只读内容源（仅官方库存在）

链接的图库 LinkedLibraries
  └─ 应用级列表；点击即切换当前图库

链接的网盘 LinkedCloudDrives
  └─ 独立于图库；只读或 WebDAV 写
```

<svg xmlns="http://www.w3.org/2000/svg" width="980" height="500" viewBox="0 0 980 500" role="img" aria-label="Luma 元数据架构图">
  <defs>
    <style>
      .box { fill:#ffffff; stroke:#c9ced6; stroke-width:1.5; }
      .box-main { fill:#f5f8ff; stroke:#5b7cfa; stroke-width:2; }
      .box-readonly { fill:#fafafa; stroke:#9aa1aa; stroke-width:1.5; stroke-dasharray:6 4; }
      .box-soft { fill:#f7f8fa; stroke:#d7dbe2; stroke-width:1.5; }
      .title { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; font-size:14px; font-weight:600; fill:#1f2329; }
      .text { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; font-size:12px; fill:#5f6672; }
      .small { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; font-size:11px; fill:#7a818c; }
      .arrow { stroke:#5b7cfa; stroke-width:2; fill:none; marker-end:url(#arrow); }
      .arrow-gray { stroke:#9aa1aa; stroke-width:1.5; fill:none; marker-end:url(#arrow-gray); }
    </style>
    <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#5b7cfa"/>
    </marker>
    <marker id="arrow-gray" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#9aa1aa"/>
    </marker>
  </defs>

  <text x="40" y="32" class="title">图库 = 一个 .photoslibrary 包</text>
  <rect x="40" y="48" width="430" height="74" rx="12" class="box-main"/>
  <text x="60" y="76" class="title">当前图库 CurrentLibrary</text>
  <text x="60" y="98" class="text">同一时间只打开一个；打开即切换</text>

  <rect x="40" y="172" width="430" height="178" rx="12" class="box-main"/>
  <text x="60" y="200" class="title">Luma 可写 SQLite（唯一）</text>
  <text x="60" y="222" class="text">database/PhotosLuma.sqlite</text>
  <text x="60" y="246" class="text">luma_assets / luma_albums / luma_folders</text>
  <text x="60" y="268" class="text">luma_people / luma_analysis / luma_settings</text>
  <text x="60" y="290" class="text">luma_cloud_* / luma_ai_* / luma_derived_reports</text>
  <text x="60" y="318" class="small">收藏、关键词、标题、查看时间、分析结果都在这里</text>

  <rect x="520" y="48" width="420" height="104" rx="12" class="box-readonly"/>
  <text x="540" y="76" class="title">Apple Photos.sqlite（只读）</text>
  <text x="540" y="98" class="text">官方库的资产、相簿、人物、关键词、封面</text>
  <text x="540" y="120" class="text">只读解析；绝不加表、加列、改行</text>
  <text x="540" y="140" class="small">仅官方 .photoslibrary 存在</text>

  <rect x="520" y="190" width="420" height="86" rx="12" class="box-soft"/>
  <text x="540" y="218" class="title">PhotoKit 原生写入</text>
  <text x="540" y="240" class="text">导入、编辑、删除、收藏、隐藏、相簿</text>
  <text x="540" y="260" class="small">仅当当前库就是系统「照片」库且已授权</text>

  <rect x="40" y="382" width="250" height="78" rx="12" class="box-soft"/>
  <text x="60" y="410" class="title">文件与目录</text>
  <text x="60" y="432" class="text">originals / resources/renders</text>
  <text x="60" y="450" class="small">managed 导入、渲染、缩略图、备份</text>

  <rect x="320" y="382" width="280" height="78" rx="12" class="box-soft"/>
  <text x="340" y="410" class="title">链接的图库 LinkedLibraries</text>
  <text x="340" y="432" class="text">应用级 Libraries.json</text>
  <text x="340" y="450" class="small">点击切换当前图库</text>

  <rect x="630" y="382" width="310" height="78" rx="12" class="box-soft"/>
  <text x="650" y="410" class="title">链接的网盘 LinkedCloudDrives</text>
  <text x="650" y="432" class="text">SMB / WebDAV / 阿里云盘 / 百度网盘</text>
  <text x="650" y="450" class="small">独立缓存 luma_cloud_*</text>

  <path d="M 255 122 L 255 172" class="arrow"/>
  <text x="265" y="152" class="small">读写</text>

  <path d="M 470 260 L 520 130" class="arrow-gray"/>
  <text x="474" y="204" class="small">只读同步</text>

  <path d="M 470 232 L 520 232" class="arrow"/>
  <text x="478" y="224" class="small">写回</text>

  <path d="M 255 350 L 165 382" class="arrow"/>
  <text x="172" y="368" class="small">文件</text>

  <path d="M 470 371 L 460 382" class="arrow-gray"/>
  <path d="M 470 371 L 760 382" class="arrow-gray"/>
  <text x="476" y="376" class="small">切换 / 链接</text>
</svg>

### 4.2 文件布局

**Luma 自建图库：**

```
我的图库.photoslibrary/
├── database/
│   └── PhotosLuma.sqlite         # 唯一 Luma 可写库
├── originals/
├── resources/
│   ├── derivatives/
│   ├── renders/
│   ├── transcodes/
│   └── backups/
└── cloud/thumbs/
```

**Apple 官方图库：**

```
系统照片图库.photoslibrary/
├── database/
│   ├── Photos.sqlite             # Apple 只读，绝不写
│   └── PhotosLuma.sqlite         # 唯一 Luma 可写库（旁挂）
├── originals/                    # Apple 只读
├── resources/derivatives/        # Apple 只读
└── resources/renders/            # Luma 自己的渲染结果
```

**链接图库注册表：**

```
~/Library/Application Support/PhotosClone/Libraries.json
```

只存路径、名称、最近打开时间；不存照片、不存密钥。密钥仍在钥匙串。

### 4.2.1 真实数据存储：共享媒体文件，不共享元数据库

方案 A 的“双文件”只指**元数据层**：Apple 的 `Photos.sqlite` 只读，Luma 的 `PhotosLuma.sqlite` 可写。真实照片和视频不是两份，按资产来源共享同一份文件：

| 资产类型 | 真实文件位置 | 元数据位置 | 是否复制 |
| --- | --- | --- | --- |
| 官方库原生照片 / 视频 | Apple 的 `originals/`、`resources/derivatives/` | Apple `Photos.sqlite` + Luma `luma_assets` 索引 | 不复制；Luma 直接读原文件，缩略图优先复用 Apple derivatives |
| Luma 导入到官方库的照片 | 当前官方库包内的 `originals/`（Luma 子目录） | Luma `luma_assets`，`origin='managed'` | 只在 PhotoKit 不可用时作为回退；PhotoKit 可用时写入 Apple 图库，不额外复制 |
| Luma 编辑渲染结果 | 当前库 `resources/renders/` | Luma `luma_assets.edit_recipe` | 只存渲染副本；Apple 原图不变，或由 PhotoKit 写入 Apple 编辑栈 |
| Luma 缩略图 / 快缩略图 / 转码 | 当前库 `resources/derivatives/`、`resources/transcodes/` | 仅路径记录在 `luma_assets` | 可重建缓存，不参与同步 |
| 网盘照片 | 远端网盘 | Luma `luma_cloud_assets` | 不下载原图；只缓存缩略图与 EXIF |
| 链接的其他图库 | 各自图库包内 | 各自 `PhotosLuma.sqlite` | 不共享、不复制；切换当前库只是换读取目标 |

因此：

- **同一图库内，Apple 与 Luma 共享真实媒体文件**，不产生第二份原图。
- **不同图库之间不共享真实文件**，每个 `.photoslibrary` 是独立数据单元。
- **被共享的是媒体文件与目录；不共享的是元数据库**。Luma 的收藏、关键词、标题、分析、网盘缓存必须写自己的库，不能写 Apple 的库。
- 只有“把官方照片拷贝到 Luma 库”或“Luma 生成编辑副本”这类显式操作才会新增文件；普通浏览、收藏、关键词、打标签都不复制原图。

### 4.3 统一表设计

所有 Luma 表统一 `luma_` 前缀；旧表不读取、不迁移，旧库文件改名隔离后保留或删除。

| 表 | 关键字段 | 说明 |
| --- | --- | --- |
| `luma_library` | `id, kind, source_fingerprint, schema_version, last_sync_at` | 当前库自描述；`kind = managed / native` |
| `luma_assets` | `id, origin, native_id, storage_kind, storage_path, filename, original_name, title, captured_at, added_at, viewed_at, edited_at, width, height, size, kind, duration, favorite, hidden, deleted_at, edit_version, rotation, keywords, exif_json, place_*, native_flags, sync_state` | 唯一资产表，managed 与 native 都在这里 |
| `luma_asset_keywords` | `asset_id, keyword` | 关键词拆行，支持索引、计数与筛选 |
| `luma_albums` | `id, origin, native_id, name, folder_id, cover_asset_id, position, sync_state` | 统一相簿 |
| `luma_folders` | `id, origin, native_id, name, parent_id, position, sync_state` | 统一文件夹 |
| `luma_album_assets` | `album_id, asset_id, position, origin` | 相簿成员与顺序 |
| `luma_people` | `id, origin, native_id, name, face_count, cover, centroid, is_pet, updated_at` | 人物/宠物 |
| `luma_person_assets` | `person_id, asset_id, origin` | 人物关系 |
| `luma_scanned_faces` | `asset_id, origin` | 人脸扫描记录 |
| `luma_analysis` | `asset_id, origin, labels, text, feature, updated_at` | 场景、OCR、特征向量 |
| `luma_derived_reports` | `key, signature, payload, updated_at` | 体检、美化、相似缓存 |
| `luma_settings` | `key, value` | 图库级设置 |
| `luma_smart_albums` | `id, name, rules_json, created_at` | 智能相簿 |
| `luma_pinned_items` | `id, kind, target_id, position` | 侧边栏固定项 |
| `luma_ai_config` | `provider, endpoint, model, options_json` | 智能助手配置（不含 Key） |
| `luma_ai_messages` | `conversation_id, role, content, created_at` | 对话记录 |
| `luma_cloud_mounts` | `id, kind, name, url, options_json` | 网盘挂载 |
| `luma_cloud_assets` | `mount_id, path, size, remote_mtime, exif, labels, text, feature, viewed_at, analyzed_at` | 网盘元数据缓存 |
| `luma_cloud_people` / `luma_cloud_person_assets` | `mount_id, person_id, ...` | 网盘人物聚类 |
| `luma_cloud_favorites` / `luma_cloud_keywords` | `mount_id, path, value` | 网盘收藏与关键词 |

**关键约束：**

- `luma_assets.id` 是稳定主键；原生资产用 Apple `ZUUID`，managed 资产用 Luma UUID。
- `origin = native` 时，`native_id` 唯一；`origin = managed` 时，`storage_path` 指向库内原图。
- `sync_state`：`synced` / `local_only` / `pending`，用于标记 PhotoKit 写回结果。
- 原生资产的 Apple 侧收藏、隐藏、标题、关键词，用 `*_overridden` 标记 Luma 覆盖；同步时不会被 Apple 值覆盖。
- 如果 native 需要本地人物 / 相簿封面覆盖，可增加 `luma_native_people_overrides`、`luma_album_overrides`；它们只影响 Luma 展示，不写 Apple。
- 不再存在 `asset_overlays`、`system_analysis`、`system_library_path`、`system_libraries`。

### 4.4 原生库同步

官方库的 `Photos.sqlite` 是权威源，`luma_assets` 是 Luma 侧的统一读模型：

1. 打开官方库时读取 `Photos.sqlite` 指纹（主文件与 `-wal` 的大小、mtime）。
2. 指纹未变化：直接使用 `luma_assets`，不扫库。
3. 指纹变化：分批增量同步资产、相簿、文件夹、人物、关键词到 `luma_assets`。
4. 当前库就是系统「照片」库且已授权时，注册 `PHPhotoLibraryChangeObserver`，外部修改实时回写。
5. 同步可中断、可续传；界面沿用现有“正在读取图库…”进度胶囊。
6. 缩略图继续优先复用 Apple `resources/derivatives`；缺失时生成到当前库缓存目录。

> 取舍：全量镜像到 `luma_assets` 会让首次打开百万级库产生一次性同步成本，但之后所有查询、分页、统计只面对一个 SQLite。若无法接受首次成本，可退回“直连 `Photos.sqlite` + Luma 表旁挂”的混合读法，但读路径会重新分叉。

### 4.5 统一读写矩阵

| 操作 | managed 图库 | native 图库（PhotoKit 可用） | native 图库（不可用） | 网盘 |
| --- | --- | --- | --- | --- |
| 读取 | 查 `luma_assets` | 查 `luma_assets` | 查 `luma_assets` | 现有网盘目录 |
| 导入 | 拷贝到 `originals/` + 写表 | `PHAssetCreationRequest` | 拷贝到当前库 `originals/`，`origin='managed'` | 不涉及 |
| 编辑 | `resources/renders/` + `edit_recipe` | `PHContentEditingOutput` | 渲染副本 + 本地配方 | 不涉及 |
| 删除 | `deleted_at` + 到期清理 | `PHAssetChangeRequest.deleteAssets` | 仅 `luma_assets.deleted_at` | 不涉及 |
| 收藏 / 隐藏 | 写 `luma_assets` | PhotoKit + 本地表同步 | 仅写本地表 | 本地收藏表 |
| 标题 / 关键词 | 写 `luma_assets` | 写 `luma_assets`（PhotoKit 不开放） | 写 `luma_assets` | 本地关键词表 |
| 相簿 | 写 `luma_albums` / `luma_album_assets` | PhotoKit 相簿接口 | 写本地表 | 不涉及 |
| 文件夹 | 写 `luma_folders` | 优先 `PHCollectionListChangeRequest`；不可用则写本地表 | 写本地表 | 不涉及 |
| 人物 | 端侧聚类写 `luma_people` | 只读 Apple 人物，Luma 补充写表 | 同左 | 端侧聚类写 `luma_cloud_people` |

### 4.6 能力模型

界面不再用“是不是系统库”判断能不能操作，而用能力判断：

```swift
struct LibraryCapabilities {
    var canImport: Bool
    var canEditOriginal: Bool
    var canDeleteOriginal: Bool
    var canMutateAlbums: Bool
    var canMutateFolders: Bool
    var canOverlayMetadata: Bool
    var canWriteKeywords: Bool
    var canWriteTitle: Bool
    var canUsePhotoKit: Bool
}
```

- managed 图库：除原生专属能力外全部为 true。
- native 当前库且已授权：`canUsePhotoKit = true`，编辑、删除、收藏、隐藏、相簿为 true；关键词、标题仍走本地表。
- native 但非当前系统库 / 未授权：`canUsePhotoKit = false`，只允许本地表和本地副本。
- 网盘：按现有只读/WebDAV 能力。

### 4.7 PhotoKit 能力与全部操作明细

> 本机实测结果见 [PhotoKit 边界本机测试结果](file:///Users/lijialong/Documents/gitlab/photos/docs/photokit-boundary-test-results.md)。实测确认：收藏、日期、坐标、编辑、相簿、文件夹、导入、删除到最近删除都可用；但 **PhotoKit 隐藏后资产会从所有 PhotoKit 查询中消失，无法通过 PhotoKit 取消隐藏**，需要产品重新决策。

先给结论：

- **收藏照片可以走 PhotoKit。** `PHAssetChangeRequest.isFavorite` 是公开可写属性；当前代码已经在 `LibraryStore+SystemLibrary.swift` 的 `setSystemFavorite` 中接入，写回成功后清掉 Luma 覆盖值，失败则回退到 `luma_assets`。
- **隐藏照片可以走 PhotoKit，但本机实测有严重副作用。** `isHidden` 是公开可写属性，当前已接入；但隐藏后资产会从 `fetchAssetsWithLocalIdentifiers`、`includeHiddenAssets=YES`、已隐藏智能相簿和 `hidden == YES` 谓词中全部消失，PhotoKit 无法再取回或取消隐藏，只能在「照片」App 的已隐藏相簿里手动处理。
- **删除可以，但只能移入系统「最近删除」。** PhotoKit 没有永久删除、没有从「最近删除」恢复的公开 API。
- **编辑可以。** 照片通过 `PHContentEditingOutput` 写回；当前只有智能美化接入了这条路径，普通编辑、视频编辑尚未接入。
- **导入可以。** `PHAssetCreationRequest` / `PHAssetChangeRequest.creationRequestForAssetFrom...` 可以创建资产；当前未接入。
- **相簿可以。** 新建、重命名、删除、加照片、移出、排序都有公开 API；当前已接入。
- **文件夹可以。** `PHCollectionListChangeRequest` 支持新建、重命名、删除、加子集合、排序；当前未接入。
- **标题、关键词不可以。** PhotoKit 没有标题、关键词写接口；只能写 Luma 表。关键词当前已接入本地覆盖，标题在 native 下尚未接入。
- **智能相簿、相簿封面、重复项目合并、人物命名不可以。** 没有公开写 API；只能写 Luma 表，或引导用户去「照片」里操作。
- **修改拍摄日期、坐标可以。** `creationDate` 和 `location` 可写；当前 native 批量更改未接入。
- **查看时间、最近查看不可以。** PhotoKit 不暴露；只能写 Luma 表。

#### 4.7.1 PhotoKit 可写接口

以下 API 已按 macOS `Photos.framework` 头文件核对；除特别标注外，最低系统为 macOS 10.15。

| API / 属性 | 能做什么 | 关键限制 | 当前接入 |
| --- | --- | --- | --- |
| `PHAssetChangeRequest.isFavorite` | 收藏 / 取消收藏照片或视频 | 只能作用于系统当前照片库；需要读写权限；目标库校验通过 | 已接入 |
| `PHAssetChangeRequest.isHidden` | 隐藏 / 取消隐藏 | 同上；本机实测隐藏后资产从所有 PhotoKit 查询中消失，无法通过 PhotoKit 取消隐藏 | 已接入，需产品复核 |
| `PHAssetChangeRequest.creationDate` | 修改拍摄日期 | 同上；需逐资产提交 | 未接入 native |
| `PHAssetChangeRequest.location` | 修改坐标 | 只能写坐标；地名、POI 仍需本地逆地理编码 | 未接入 native |
| `PHAssetChangeRequest.contentEditingOutput` | 写回照片 / 视频编辑结果 | 需要先取 `PHContentEditingInput`；要写 renderedContentURL；需检查 `canPerformEditOperation` | 仅美化写回接入 |
| `PHAssetChangeRequest.revertAssetContentToOriginal()` | 还原到原图 | 原图必须已下载；不还原 Luma 自己的编辑配方 | 未接入 |
| `PHAssetChangeRequest.deleteAssets(_:)` | 移入「照片」最近删除 | 不能永久删除；不能恢复；30 天后由 Photos 清理 | 仅体检相似清理接入 |
| `PHAssetCreationRequest` | 导入照片 / 视频，可附带资源与文件名 | 只能写入系统当前照片库；`shouldMoveFile` 会移动源文件，需谨慎 | 未接入 |
| `PHAssetChangeRequest.creationRequestForAssetFromImageAtFileURL` | 从文件创建照片 | 同上；不保留 Luma 的自定义标题 / 关键词 | 未接入 |
| `PHAssetChangeRequest.creationRequestForAssetFromVideoAtFileURL` | 从文件创建视频 | 同上 | 未接入 |
| `PHAssetCollectionChangeRequest` | 新建 / 重命名 / 删除相簿，增删、插入、替换、移动照片 | 智能相簿不可写；没有相簿封面 / 关键照片 API | 已接入 |
| `PHCollectionListChangeRequest` | 新建 / 重命名 / 删除文件夹，增删、插入、替换、移动子集合 | 顶层排序需 macOS 11+ 的 `changeRequestForTopLevelCollectionListUserCollections:`；删除文件夹会递归删除子集合 | 未接入 |
| `PHPhotoLibraryChangeObserver` | 监听 Photos 外部变更 | 需要注册 / 注销；回调线程不是主线程 | 未接入 |
| `PHAssetResourceManager` | 读取 / 下载 iCloud 原图资源 | 只读；不是写回接口 | 未接入 |
| `PHImageManager` | 读取缩略图 / 图片数据 | 只读；大库逐张请求不适合替代 Photos.sqlite 批量查询 | 未接入；当前直接读文件 / derivatives |
| `PHPickerViewController` | 从系统「照片」中安全选择项目 | 只返回用户选中的项目，不等于全库 PhotoKit 权限 | 已接入「从照片导入」 |

#### 4.7.2 资产操作明细

| 操作 | PhotoKit | 说明 | 当前实现 |
| --- | --- | --- | --- |
| 导入照片 / 视频（文件、文件夹、剪贴板） | ✅ 可创建 | 只能写入系统当前照片库；需要读写权限 | managed 导入已接入；native 未接入 |
| 从系统「照片」选择并导入到拾光 | ✅ 可读取 | 通过 PHPicker 读取用户选中的项目，再拷贝到 Luma，不是写回 Apple | 已接入导入选择器 |
| 编辑照片：裁剪、滤镜、调色、旋转、RAW、美化 | ✅ 可写回 | 通过 `contentEditingOutput` 渲染输出；旋转没有纯元数据接口 | 仅智能美化写回接入；其他 native 编辑未接入 |
| 编辑视频：裁剪、转码、旋转 | ✅ API 支持 | `PHContentEditingInput.audiovisualAsset` + `contentEditingOutput`；实现成本高 | 未接入；当前用 ffmpeg 本地处理 |
| 非破坏性编辑配方 | ⚠️ 可存 | 可把配方写进 `PHAdjustmentData`；当前写回时只写空 data | 本地配方已支持；native 写回未接入 |
| 还原原图 / 撤销编辑 | ✅ 可还原 | `revertAssetContentToOriginal()`；需原图已下载 | 未接入 |
| 删除（移入最近删除） | ✅ 可删除 | 只能移入「照片」最近删除，不能永久删除 | 仅体检相似清理接入；普通删除未接入 |
| 从最近删除恢复 | ❌ 不支持 | 没有公开恢复 API；只能在「照片」里操作 | 不支持 native 恢复 |
| 永久删除 / 清空最近删除 | ❌ 不支持 | 没有公开永久删除 API；由 Photos 到期清理 | 不支持 native 永久删除 |
| 收藏 / 取消收藏 | ✅ 可写 | `isFavorite`；目标库校验通过后写回 | 已接入 |
| 隐藏 / 取消隐藏 | ⚠️ 有严重副作用 | `isHidden` 写入成功；本机实测隐藏后资产从所有 PhotoKit 查询中消失，无法再通过 PhotoKit 取消隐藏 | 已接入，建议改为 Luma 本地隐藏或明确提示去「照片」恢复 |
| 设置标题 | ❌ 不支持 | 没有标题写接口 | native 未接入；建议写 `luma_assets.title` |
| 添加 / 移除关键词 | ❌ 不支持 | 没有关键词写接口 | 已接入本地 `luma_assets.keywords` |
| 批量修改拍摄日期 | ✅ 可写 | `creationDate`；逐资产提交 | native 未接入 |
| 批量修改地点坐标 | ✅ 可写 | `location`；地名仍本地生成 | native 未接入 |
| 批量修改标题 | ❌ 不支持 | 只能写 Luma 表 | native 未接入 |
| 记录查看时间 / 最近查看 | ❌ 不支持 | PhotoKit 不暴露写入 | 已接入本地 `viewed_at` |
| 原地压缩（有损 / 无损） | ❌ 不支持 | 没有原地替换原文件 API；只能渲染输出或生成 Luma 副本 | native 不支持；managed 已接入 |
| 压缩后逐字节还原 | ❌ 不支持 | 依赖 Luma 自己的备份，不是 PhotoKit | 仅 managed 支持 |
| 智能美化写回原图 | ✅ 可写 | `contentEditingOutput`；当前已用于官方库原图 | 已接入 |
| 复制 / 粘贴编辑点 | ⚠️ 部分 | 本地复制配方；写回需要编辑输出 | native 未接入 |
| 设为桌面背景 | ❌ 不涉及 | 这是读取资产，不是写回 | 读取文件实现 |
| 打印 | ❌ 不涉及 | 只读 | 只读 |
| 导出原图 / 导出 JPEG | ✅ 可读取 | iCloud 资产用 `PHAssetResourceManager` 下载；普通资产可直接读文件 | 当前主要读文件；iCloud 需补 PhotoKit |
| 查找相似照片 | ❌ 不涉及 | 本地 Vision / 特征向量 | 本地实现 |
| 重复项目检测 | ❌ 不涉及 | 本地按大小 + 像素分组 | 本地实现 |
| 合并重复项目 | ❌ 不支持 | 没有公开合并 API；只能隐藏、删除或拷贝保留版本 | native 提供隐藏 / 删除 / 拷贝；Apple 内合并需去「照片」 |
| 图库体检清理相似备选 | ✅ 可删除 | 通过 `deleteAssets` 移入最近删除 | 已接入 |
| 人物命名 / 合并人物 | ❌ 不支持 | PhotoKit 没有人物写接口 | 本地人物可写；native 人物只读 |
| 设置人物封面 | ❌ 不支持 | 同上 | 本地人物可写 |

#### 4.7.3 相簿、文件夹与组织操作明细

| 操作 | PhotoKit | 说明 | 当前实现 |
| --- | --- | --- | --- |
| 新建相簿 | ✅ 可写 | `creationRequestForAssetCollection(withTitle:)` | 已接入 |
| 重命名相簿 | ✅ 可写 | `PHAssetCollectionChangeRequest.title` | 已接入 |
| 删除相簿 | ✅ 可写 | `deleteAssetCollections`；不删除照片 | 已接入 |
| 加入照片到相簿 | ✅ 可写 | `addAssets` | 已接入 |
| 从相簿移出照片 | ✅ 可写 | `removeAssets` | 已接入 |
| 相簿内排序 | ✅ 可写 | `moveAssets(at:to:)`；当前只做移到最前 / 最后 | 已接入 |
| 设置相簿封面 / 关键照片 | ❌ 不支持 | 没有公开 key asset API；只能写 Luma `cover_asset_id` | native 未接入；Apple 相册封面不会变 |
| 新建文件夹 | ✅ 可写 | `PHCollectionListChangeRequest` | 未接入 |
| 重命名文件夹 | ✅ 可写 | `PHCollectionListChangeRequest.title` | 未接入 |
| 删除文件夹 | ✅ 可写 | `deleteCollectionLists`；递归删除子文件夹 / 子相簿集合，不删除照片 | 未接入 |
| 把相簿移入文件夹 | ✅ 可写 | `addChildCollections` / `removeChildCollections` | 未接入 |
| 文件夹内排序 | ✅ 可写 | `moveChildCollectionsAtIndexes:toIndex:` | 未接入 |
| 顶层相簿 / 文件夹排序 | ✅ 可写 | `changeRequestForTopLevelCollectionListUserCollections:`（macOS 11+） | 未接入 |
| 新建 / 编辑 / 删除智能相簿 | ❌ 不支持 | Apple 智能相簿由系统规则生成，不可写 | 只能写 Luma 智能相簿 |
| 智能相簿加入 / 移出照片 | ❌ 不支持 | 内容由系统规则决定 | 不支持 |
| 侧边栏固定 / 取消固定 / 排序 | ❌ 不涉及 | Luma 自己的视图状态 | 写 `luma_settings` / `luma_pinned_items` |
| 收藏夹 / 最近保存 / 最近查看等视图 | ❌ 不涉及 | 读取或本地派生 | 本地查询 |
| 图库级设置、视图状态、缩略图大小 | ❌ 不涉及 | Luma 自己的设置 | 写 `luma_settings` |
| 网盘挂载 / 收藏 / 关键词 | ❌ 不涉及 | 网盘 API 或 Luma 缓存 | `luma_cloud_*` |
| WebDAV 新建 / 重命名 / 上传 / 删除 | ❌ 不涉及 | WebDAV 协议 | 现有 WebDAV 客户端 |
| 切换当前图库 / 链接图库 | ❌ 不涉及 | 文件路径与 Luma 数据库切换 | `Libraries.json` + `PhotosLuma.sqlite` |
| 在「照片」中打开 | ❌ 不涉及 | `NSWorkspace` | 现有实现 |
| 在访达中显示 | ❌ 不涉及 | `NSWorkspace` + 文件路径 | 现有实现 |
| 清理缩略图 / 转码缓存 | ❌ 不涉及 | 文件系统 | 现有实现 |

#### 4.7.4 读取与派生操作明细

| 操作 | PhotoKit | 说明 | 当前实现 |
| --- | --- | --- | --- |
| 浏览所有照片 / 时间轴 / 相簿 / 文件夹 | ✅ 可读取 | PhotoKit 可以 fetch，但百万级大库逐页 fetch 不如 Photos.sqlite 稳定 | 当前读 Photos.sqlite / 索引 |
| 读取 EXIF、尺寸、拍摄时间、地点 | ✅ 可读取 | 单张可用 PhotoKit；批量仍建议 Photos.sqlite | 当前读 Photos.sqlite |
| 读取缩略图 / 视频封面 | ✅ 可读取 | `PHImageManager`；当前优先复用 Apple derivatives | 当前读 derivatives |
| 读取相簿 / 文件夹 / 人物 | ✅ 可读取 | PhotoKit 与 Photos.sqlite 各有覆盖；人物未命名聚类需读 Photos.sqlite | 当前读 Photos.sqlite |
| 读取 Apple 关键词 | ✅ 可读取 | PhotoKit 不直接返回关键词；当前读 `Photos.sqlite.ZKEYWORD` | 当前读 Photos.sqlite |
| 读取最近查看 / 最近编辑 | ⚠️ 部分 | PhotoKit 不直接提供；当前读 Photos.sqlite 字段 | 当前读 Photos.sqlite |
| 读取 iCloud 原图 | ✅ 可下载 | `PHAssetResourceManager`；当前直接读文件可能失败 | 需要补 |
| 场景识别 / OCR / 相似特征 | ❌ 不涉及 | 本地 Vision，不上传 | 本地实现 |
| 人脸聚类 | ❌ 不涉及 | 本地 Vision；native 人物只读 Apple 结果 | 本地实现 |
| 回忆 / 旅行 / 值得重看 | ❌ 不涉及 | 本地派生 | 本地实现 |
| 地图 / 位置 / 足迹 / 地点统计 | ❌ 不涉及 | 本地派生；坐标可来自 Photos.sqlite | 本地实现 |
| 搜索 / 筛选 / 排序 / 分页 | ❌ 不涉及 | 本地查询 | 本地实现 |
| 图库体检 / 模糊 / 大视频 | ❌ 不涉及 | 本地分析 | 本地实现 |
| 重复项目检测 | ❌ 不涉及 | 本地分组 | 本地实现 |

#### 4.7.5 当前代码的写回门槛

所有 native 写回都必须同时满足：

1. 当前图库就是官方「照片」图库：`isSystemScope && isNativeContainer`（`canWriteSystemLibrary`）。
2. 系统照片权限为 authorized 或 limited（`PhotoKitBridge.ensureAuthorized()`）。
3. 用样本资产校验 PhotoKit 指向的就是当前打开的库（`PHPhotoLibrary` 只能操作系统当前库，不能指向任意 `.photoslibrary`）。
4. 失败时只能回退到 Luma 表或 Luma 文件，不能写 Apple 的 `Photos.sqlite`。

对应代码：

- 写回门槛：[LibraryStore+SystemAlbums.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+SystemAlbums.swift#L14-L34)。
- 收藏 / 隐藏：[LibraryStore+SystemLibrary.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+SystemLibrary.swift#L809-L881)。
- 相簿增删改与排序：[LibraryStore+SystemAlbums.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+SystemAlbums.swift#L61-L187)。
- 美化写回：[LibraryStore+Beauty.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Beauty.swift#L608-L659)。
- 体检清理相似：[LibraryStore+Health.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Health.swift#L348-L378)。
- PhotoKit 基础封装：[PhotoKitBridge.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/PhotoKitBridge.swift#L51-L180)。

#### 4.7.6 本次重构需要补的 PhotoKit 能力

按优先级：

1. **导入**：`PHAssetCreationRequest`，用于当前官方库的导入；失败回退到 `originals/`。
2. **普通删除**：把现有 `deleteAssets` 从体检清理扩展到单张 / 多选删除；仍然只能进最近删除。
3. **文件夹**：`PHCollectionListChangeRequest`，实现新建、重命名、删除、移动、排序。
4. **批量改日期 / 坐标**：`creationDate` / `location`，标题仍走本地表。
5. **外部变更监听**：`PHPhotoLibraryChangeObserver`，同步 Photos 中的新增、删除、收藏、隐藏。
6. **iCloud 原图读取**：`PHAssetResourceManager`，用于导出、压缩、编辑未下载资产。
7. **视频编辑**：`PHContentEditingInput.audiovisualAsset` + `contentEditingOutput`，优先级低于照片。
8. **还原原图**：`revertAssetContentToOriginal()`，需要先确保原图已下载。

不需要补、也不应该尝试的：写标题、写关键词、写智能相簿、写相簿封面、永久删除、从最近删除恢复、人物写回、重复项目合并。PhotoKit 没有这些公开能力。

### 4.8 PhotoKit 不支持能力的 SQLite 可行性

前提：这里的 SQLite 指 Luma 自有 `PhotosLuma.sqlite`；写 Apple 的 `Photos.sqlite` 仍然禁止。

评级：

- **✅ 可实现**：只写 Luma SQLite / 文件，Luma 内完整生效。
- **⚠️ 部分实现**：Luma 内生效，Apple「照片」不感知；或只对 managed 资产生效。
- **❌ 不可实现**：Apple 侧语义不存在，只能做本地占位，不建议作为产品承诺。

| 能力 | PhotoKit | 当前代码 | 可用 SQLite 表 / 字段 | 实现方式 | 可行性 | 生效范围 |
| --- | --- | --- | --- | --- | --- | --- |
| 设置标题 | ❌ 不支持 | managed 已支持；native 未接入 | `luma_assets.title` | 写表；native 标记 `sync_state='local_only'` | ✅ | Luma 内生效；Apple 不感知 |
| 添加 / 移除关键词 | ❌ 不支持 | managed + native 覆盖已支持 | `luma_assets.keywords`；建议增加 `luma_asset_keywords(asset_id, keyword)` 便于索引 | 写表；关键词拆行以支持搜索与计数 | ✅ | Luma 内生效；Apple 不感知 |
| 批量修改标题 | ❌ 不支持 | managed 批量更改已支持 | `luma_assets.title` | 事务批量更新 | ✅ | Luma 内生效；Apple 不感知 |
| 记录查看时间 / 最近查看 | ❌ 不支持 | native 覆盖、managed 字段已支持 | `luma_assets.viewed_at` | 写表；按时间建索引 | ✅ | Luma 内生效；Apple 不感知 |
| 设置相簿封面 / 关键照片 | ❌ 不支持 | managed 用 `Album.coverPhotoID`；native 无 | `luma_albums.cover_asset_id`；native 用 `luma_album_overrides` | 写表；封面只影响 Luma 展示 | ✅ / ⚠️ | Luma 内生效；Apple 相簿封面不变 |
| 新建 / 编辑 / 删除智能相簿 | ❌ 不支持 | 已支持，存 `smart_albums` JSON | `luma_smart_albums.rules_json` | 规则 + 查询引擎；删除只删规则 | ✅ | 仅 Luma；Apple 智能相簿不可写 |
| 手动往智能相簿加入 / 移出照片 | ❌ 不支持 | 目前无手动成员 | — | 只能改规则；要手动成员请用普通相簿 | ⚠️ | 不建议做成“手动智能相簿” |
| 人物命名 | ❌ 不支持 | local 已支持；native 只读 | `luma_people.name`；native 用 `luma_native_people_overrides` | 本地覆盖名字 | ✅ / ⚠️ | local 生效；native 仅 Luma |
| 人物合并 | ❌ 不支持 | 目前无合并函数 | `luma_people`、`luma_person_assets`、`luma_person_merges` | 合并 person_assets，保留一个 person；native 只做本地合并 | ✅ / ⚠️ | local 生效；native 仅 Luma |
| 设置人物封面 | ❌ 不支持 | local 有 `people.cover`；native 只读 keyAsset | `luma_people.cover`；native 用 overrides | 写封面 BLOB / 引用 | ✅ / ⚠️ | local 生效；native 仅 Luma |
| 重复项目合并 | ❌ 不支持 | managed `mergeDuplicateGroup` 已支持；native 只提供隐藏 / 删除 / 拷贝 | `luma_assets`、`luma_album_assets`、`luma_analysis`、`luma_people` | 保留一张，汇总收藏 / 关键词 / 标题 / 地点 / 相簿，其余 `deleted_at` | ✅ managed / ⚠️ native | managed 完整生效；native 只能本地合并，Apple 不合并 |
| 永久删除 | ❌ 不支持 | managed `deletePermanently`；native 禁止 | `luma_assets.deleted_at` + 文件删除 | managed 删原图 / 缩略图 / 渲染 / 备份；native 只写本地标记 | ✅ managed / ❌ native | native 无法永久删除 Apple 资产 |
| 从最近删除恢复 | ❌ 不支持 | managed `restore`；native 禁止 | `luma_assets.deleted_at` | managed 清空标记；native 只能撤销 Luma 本地标记 | ✅ managed / ❌ native | native 无法恢复 Apple 最近删除 |
| 清空最近删除 | ❌ 不支持 | managed `emptyTrash`；native 禁止 | `luma_assets` + 文件删除 | managed 批量清理；native 只能清 Luma 本地标记 | ✅ managed / ❌ native | native 无法清空 Apple 回收站 |
| 原地压缩 | ❌ 不支持 | managed `PhotoCompressor`；native 不支持 | `luma_assets` + `resources/backups/` | 压缩文件、更新行、保留备份 | ✅ managed / ⚠️ native | native 只能生成 Luma 副本，不能替换 Apple 原图 |
| 压缩后逐字节还原 | ❌ 不支持 | managed 已支持；native 不支持 | `resources/backups/` + `luma_assets` | 恢复备份文件与行 | ✅ managed / ❌ native | native 无 Apple 原图替换能力 |
| 复制 / 粘贴编辑点 | ⚠️ 部分 | managed 已支持；native 未接入 | `luma_assets.edit_recipe` | 本地存配方；应用时渲染 | ✅ Luma | native 需通过编辑输出写回 |
| 侧边栏固定 / 排序 | ❌ 不涉及 | 已支持 | `luma_pinned_items` | 写表 | ✅ | Luma 内 |
| 图库级设置 / 视图状态 | ❌ 不涉及 | 已支持 | `luma_settings` | 写表 | ✅ | Luma 内 |
| 网盘收藏 / 关键词 | ❌ 不涉及 | 已支持 | `luma_cloud_favorites` / `luma_cloud_keywords` | 写表 | ✅ | Luma 内 |
| Apple 内智能相簿 / 人物 / 重复合并 | ❌ 不支持 | 无 | — | 无法实现；只能引导用户去「照片」 | ❌ | Apple 侧不可写 |

**结论：**

- **SQLite 可以完整实现（Luma 内）**：标题、关键词、查看时间、智能相簿、相簿封面、人物命名 / 合并、人物封面、managed 重复合并、managed 永久删除 / 恢复 / 清空、managed 压缩 / 还原、固定项、图库设置、网盘缓存。
- **SQLite 只能做本地覆盖（Apple 不感知）**：native 标题、关键词、查看时间、相簿封面、人物命名 / 合并、重复处理。
- **SQLite 无法实现 Apple 语义**：Apple 永久删除、Apple 最近删除恢复、Apple 内重复合并、Apple 智能相簿、Apple 人物写回、Apple 相簿封面。
- **必须区分“Luma 内生效”和“Apple 可见”**：所有 native 本地覆盖都要在 UI 或数据中标记 `sync_state='local_only'`，不能让用户误以为已经写进「照片」。

### 4.9 直接修改 Apple `Photos.sqlite` 的可行性（仅研究，不作为产品方案）

结论先说：**文件层面可以 `UPDATE` / `INSERT`，但这不是可维护、可交付的产品方案。** Apple 的 `Photos.sqlite` 是 Core Data 私有存储，表、关系表、`Z_OPT` / `Z_ENT`、派生字段和缓存都由 Photos 管理；直接写会出现“写进去了但 Photos 不生效”“iCloud 覆盖”“升级后失效”“图库损坏”等问题。

下面只列字段映射，用于评估“技术上需要动什么”，不代表建议实施。字段名来自当前 macOS 图库的实际 schema，**不同 macOS 版本可能变化**。

| 操作 | 直接写 Apple 表 / 字段 | 还需要什么 | 结论 |
| --- | --- | --- | --- |
| 收藏 / 取消收藏 | `ZASSET.ZFAVORITE` | 可能还要维护 `Z_OPT`、修改时间与 Photos 缓存；iCloud 可能覆盖 | ❌ 不建议 |
| 隐藏 / 取消隐藏 | `ZASSET.ZHIDDEN` | 同上；隐藏还会影响 Moment / 智能集合 | ❌ 不建议 |
| 设置标题 | `ZADDITIONALASSETATTRIBUTES.ZTITLE` | 需要找到对应 asset 的 additional attributes 行 | ❌ 不建议 |
| 添加 / 移除关键词 | `ZKEYWORD.ZTITLE` + `Z_1KEYWORDS(Z_1ASSETATTRIBUTES, Z_53KEYWORDS)` | 需要新建 / 删除关系行，维护 `Z_ENT` / `Z_OPT`；不能只插关键词 | ❌ 不建议 |
| 修改拍摄日期 | `ZASSET.ZDATECREATED` | 可能还要改 `ZADDITIONALASSETATTRIBUTES.ZDATECREATEDSOURCE`、排序索引与缓存 | ❌ 不建议 |
| 修改坐标 | `ZASSET.ZLATITUDE`、`ZASSET.ZLONGITUDE` | 还要处理 `ZADDITIONALASSETATTRIBUTES.ZREVERSELOCATIONDATA` 与地名缓存 | ❌ 不建议 |
| 记录查看时间 | `ZADDITIONALASSETATTRIBUTES.ZLASTVIEWEDDATE` | Photos 自己也会写这个字段，外部写入容易被覆盖 | ❌ 不建议 |
| 新建相簿 | `ZGENERICALBUM`（`ZTITLE`、`ZUUID`、`ZKIND`、`ZCREATIONDATE`、`Z_FOK_PARENTFOLDER`） | 还要写相簿成员关系 `Z_34ASSETS`、文件夹关系 `Z_33ALBUMLISTS`，并维护 `Z_ENT` / `Z_OPT` | ❌ 不建议 |
| 相簿加入 / 移出照片 | `Z_34ASSETS(Z_34ALBUMS, Z_3ASSETS, Z_FOK_3ASSETS)` | 需要维护顺序键与关系表；只改相簿行无效 | ❌ 不建议 |
| 相簿内排序 | `Z_34ASSETS.Z_FOK_3ASSETS` | 需要重新编号并处理冲突 | ❌ 不建议 |
| 设置相簿封面 | `ZGENERICALBUM.ZCUSTOMKEYASSET` + `Z_33KEYASSETS` | 需要同时维护 key asset 关系；Photos 可能按自己的规则重选 | ❌ 不建议 |
| 删除 / 移入最近删除 | `ZASSET.ZTRASHEDSTATE`、`ZTRASHEDDATE`、`ZTRASHEDREASON` | 还要处理原图、derivatives、关系表与 Photos 回收站逻辑 | ❌ 不建议 |
| 从最近删除恢复 | 清空 `ZTRASHEDSTATE` / `ZTRASHEDDATE` | 需要恢复关系与文件状态；没有公开恢复语义 | ❌ 不建议 |
| 永久删除 / 清空回收站 | 删除 `ZASSET` 行及相关关系行 | 还要删原图、derivatives、缩略图、分析结果；漏删会留下坏引用 | ❌ 不建议 |
| 人物命名 | `ZPERSON.ZDISPLAYNAME`、`ZFULLNAME` | 可能还要维护 `ZPERSONREFERENCE` 与命名模型 | ❌ 不建议 |
| 人物合并 | `Z_62MERGECANDIDATES`、`ZPERSON.ZMERGECANDIDATE...`、`ZDETECTEDFACEGROUP.ZASSOCIATEDPERSON` | 涉及人脸检测、未命名聚类、person reference 多张表 | ❌ 不建议 |
| 重复项目合并 | `ZASSET.ZDUPLICATEMETADATAMATCHINGALBUM`、`ZDUPLICATEPERCEPTUALMATCHINGALBUM` | Apple 的重复集合是系统派生结果，不是简单字段 | ❌ 不建议 |
| 创建 / 编辑智能相簿 | 无用户可写表 | 智能相簿由 Photos 规则生成 | ❌ 不可行 |
| 原地压缩 / 逐字节还原 | 无单行字段 | 需要替换 `originals/` 与 `resources/derivatives/`，并保持所有关系和校验 | ❌ 不建议 |
| 编辑配方 / 非破坏性编辑 | `ZASSET.ZADJUSTMENTSSTATE`、`ZADDITIONALASSETATTRIBUTES.ZUNMANAGEDADJUSTMENT`、`ZADJUSTMENTTIMESTAMP` | 需要同时生成 rendered 文件、adjustment data 与关系记录 | ❌ 不建议 |

**为什么直接改不可行：**

1. **Core Data 一致性**：`Z_OPT` 是乐观锁版本，`Z_ENT` 是实体编号，`Z_PRIMARYKEY` 管理主键；手工写一行不等于完成一次合法的 Core Data 事务。
2. **关系表是私有且版本相关**：例如当前库是 `Z_34ASSETS`、`Z_33ALBUMLISTS`、`Z_33KEYASSETS`，这些编号会随 macOS / Photos 版本变化，硬编码必然失效。
3. **没有变更通知**：直接写数据库不会触发 PhotoKit 的 change observer；Photos 的内存缓存、缩略图、搜索结果都可能仍是旧值。
4. **iCloud 会覆盖**：iCloud 照片库同步以云端为准；本地直接写的字段可能在同步后被还原。
5. **文件和元数据必须同时一致**：删除、压缩、编辑、相簿封面都涉及原图、derivatives、关系表和分析缓存，漏掉任何一处都会留下坏引用。
6. **无官方支持**：Apple 不提供该数据库的写入契约；出问题无法恢复，也无法作为产品承诺。

**唯一可接受的“研究方式”：**

- 只对**复制出来的** `.photoslibrary` 做实验，绝不改唯一库或生产库。
- 实验前关闭「照片」，复制整个 `.photoslibrary`，在副本上读写。
- 结果只用于验证字段映射，不进入产品代码。
- 产品仍然使用 PhotoKit + Luma `PhotosLuma.sqlite` 覆盖层。

---

## 5. 界面保持不动的落法

### 5.1 侧边栏

现状是原生库直接换一棵树：

```swift
if store.isNativeContainer {
    nativeLibrarySection
} else {
    // 拾光分区 + 系统图库分区
}
```

改成一个统一入口：

- `currentLibrarySection`：当前图库的图库、精选集、固定、媒体类型、更多项目、场景、相簿。
- `linkedLibrariesSection`：其他已链接图库，沿用现有系统图库分区的行、图标、缩略图与右键菜单样式。
- `cloudSection`：不变。

视觉上仍然是三个分区、同样的行高与图标；原“系统图库”分区标题改为“链接图库”，行样式与交互不变。

### 5.2 能力判断替换只读判断

把 `isReadOnlyScope` 替换为：

```swift
store.canImport
store.canEditOriginal
store.canDeleteOriginal
store.canMutateAlbums
store.canOverlayMetadata
```

按钮、菜单、右键项的外观不变，只改可用性。这样官方库作为当前库时不再整体只读，而是按操作逐项开放。

### 5.3 Scope 归一

`SidebarItem.system*` 先做别名映射，保证视图不动：

| 旧 | 新 |
| --- | --- |
| `.systemLibrary` | `.library` |
| `.systemFavorites` | `.favorites` |
| `.systemVideos` | `.videos` |
| `.systemScreenshots` | `.screenshots` |
| `.systemHidden` | `.hidden` |
| `.systemTrash` | `.trash` |
| `.systemAlbum(id)` | `.album(id)` |
| `.systemFolder(id)` | `.folder(id)` |
| `.systemMediaTypes` | `.mediaTypes` |
| `.systemMoreItems` | `.moreItems` |
| `.systemKeywords` | `.keywords` |
| `.systemMap` / `.systemPlaces` / `.systemPeople` | `.map` / `.places` / `.people` |

第一阶段保留旧 case 作为转发，第二阶段删除。这样可以把 700 多处 `system*` 引用分批收敛，而不是一次性重写所有视图。

### 5.4 已确认文案变化

侧边栏分区标题由“系统图库”改为“链接图库”。这是本方案唯一一处用户可见的文案变化；布局、字体、行高、图标、交互均不变。

---

## 6. 代码改造清单

| 模块 | 现状 | 改造 |
| --- | --- | --- |
| [LibraryPaths.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/LibraryPaths.swift) | 同时维护 `metadataFile`、`systemIndexFile`、`systemThumbs` | 只保留一个 Luma 可写库路径 `PhotosLuma.sqlite`；移除 `SystemIndex-*.sqlite`；缓存目录收敛到库内 `resources/` |
| [MetadataStore.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/MetadataStore.swift) | `assets`、`asset_overlays`、`system_analysis`、`cloud_*` 分散 | 新建 `PhotosLuma.sqlite`；旧 `PhotosClone.sqlite` 不读取、改名隔离；升级 schema v7；建 `luma_*` 表 |
| [SystemIndex.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/SystemIndex.swift) | 独立索引库 / 直连模式 | 改为 `NativeLibrarySync`：把 Photos.sqlite 同步进 `luma_assets`；删除独立索引文件 |
| [SystemIndex+Direct.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/SystemIndex+Direct.swift) | 直连查询 `Photos.sqlite` | 保留为同步器的读取实现，不再作为第二套浏览模型 |
| [SystemPhotosLibrary.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/SystemPhotosLibrary.swift) | 生成 `SystemLibrarySnapshot` | 合并到 NativeLibrarySync，输出统一的 `[PhotoItem]` / 分页查询 |
| [LibraryStore+SystemLibrary.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+SystemLibrary.swift) | `systemLibraryPath`、`system_libraries`、连接/切换 | 拆成 `CurrentLibrary`、`LinkedLibraries`、`NativeSync`、`NativeWrite` |
| [LibraryStore.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore.swift) | `photos` 与 `systemPhotos` 两套状态 | 一个资产源；过渡期保留计算别名 |
| [LibraryStore+Query.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Query.swift) | `isSystemScope` 分支 50+ 处 | 改为统一查询 + 能力判断；Scope 只用于导航 |
| [LibraryStore+Selection.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Selection.swift) / Deletion / Organize / Intelligence / Beauty / Health | 按 scope 分叉 | 统一 Repository；按能力选择原生或本地 |
| [SidebarView.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Sidebar/SidebarView.swift) | `isNativeContainer` 分支 | 统一当前图库树；链接图库分区复用现有行样式 |
| [PhotoKitBridge.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/PhotoKitBridge.swift) | 编辑、删除、收藏、相簿 | 增加导入、文件夹、ChangeObserver；补齐能力检测 |
| [Models.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/Models.swift) | `PhotoSource`、`SidebarItem.system*`、`PinnedSidebarItem.system*` | 内部改为 `origin` + 通用 scope；旧 case 先保留转发 |

新增核心类型：

- `LibrarySession`：当前库 URL、`kind`、`database`、`capabilities`。
- `LibraryRepository`：资产、相簿、文件夹、人物、分析的统一查询与写入。
- `ManagedLibraryBackend`：文件 + 表。
- `NativeLibraryBackend`：Photos.sqlite 同步 + PhotoKit 写回 + 本地回退。
- `LibraryRegistry`：当前库与链接库列表。
- `LibraryCapabilities`：界面能力判断。

---

## 7. 旧库处理：不迁移历史数据

### 7.1 决策

- **不做 v6 → v7 数据迁移。** 旧 `PhotosClone.sqlite` 里的 `assets / albums / folders / people / asset_analysis / asset_overlays / settings / cloud_*` 全部不带入新库。
- 旧 `PhotosClone.sqlite` 不读取；首次打开时把三件套移动到 `database/legacy/PhotosClone-<timestamp>/`，确认新库稳定后可删除。
- `SystemIndex-*.sqlite` 与旧系统缓存属于可重建缓存，直接删除。
- 旧 `originals/`、`resources/renders/` 文件不删除；它们是用户文件，不是元数据。是否后续从这些文件重建 managed 资产，单独决定。
- 新库只从 Apple `Photos.sqlite` 同步原生库资产；managed 库从空库开始。

### 7.2 首次打开行为

1. 检查 `database/PhotosLuma.sqlite` 是否存在。
2. 不存在：新建空库，创建 `luma_*` 表，写入 `luma_library` 一行，`schema_version = 7`。
3. 若旧 `PhotosClone.sqlite` 存在：先 checkpoint WAL，再把主文件、`-wal`、`-shm` 移动到 `database/legacy/PhotosClone-<timestamp>/`，之后不再打开。
4. 删除 `SystemIndex-*.sqlite` 与旧的系统图库缓存。
5. managed 图库：新库为空；用户重新导入，或后续单独做“从 originals 重建索引”。
6. native 图库：从 `Photos.sqlite` 分批同步资产、相簿、文件夹、人物到 `luma_assets` / `luma_albums` / `luma_folders` / `luma_people`；Apple 原图、Apple 收藏、Apple 隐藏仍以 Photos 为准。
7. 初始化 `Libraries.json`：当前库 + 最近图库路径；不再读取旧库的 `system_libraries`。
8. `LibraryPaths.metadataFile` 指向 `database/PhotosLuma.sqlite`。

### 7.3 影响

- **managed 图库**：旧相簿、文件夹、收藏、关键词、人物、AI 对话、网盘挂载列表、图库级设置丢失。`originals/` 里的旧文件仍在，但新库不会自动索引，界面表现为空库。
- **native 图库**：Apple 照片、相簿、人物、Apple 收藏 / 隐藏仍可读；Luma 补充的收藏覆盖、关键词、标题、查看时间、Luma 相簿扩展丢失。
- **网盘**：挂载列表丢失，需要重新接入；钥匙串里的凭据仍在。
- **撤销栈**：本来只存在于内存，切换即清空，无影响。
- **外观 / App 级设置**：不受影响；图库级设置重置。

### 7.4 旧库保留与删除

- 默认保留 `database/legacy/PhotosClone-<timestamp>/`，不自动物理删除。
- 可在设置中提供“删除旧元数据”入口，二次确认后删除 legacy 目录。
- 旧 `originals/` 与 `resources/renders/` 默认不删除。

### 7.5 回滚

- 关闭应用，把 legacy 目录中的 `PhotosClone.sqlite` 三件套改回 `database/`，回退到旧版本应用。
- 新 `PhotosLuma.sqlite` 保留或删除均可；旧版本不会读取它。

---

## 8. 分阶段实施

| 阶段 | 内容 | 验收标准 |
| --- | --- | --- |
| Phase 0 | 定义 `LibrarySession`、`LibraryRepository`、`LibraryCapabilities`、schema v7、旧库隔离与新建逻辑 | 新库可创建；旧库不读取；无历史迁移；基础读写通过 |
| Phase 1 | 单库落地：`PhotosLuma.sqlite`、`luma_*` 表、删除 `SystemIndex-*.sqlite`、`Libraries.json` | 每个图库只有一个 Luma 可写 SQLite（`PhotosLuma.sqlite`） |
| Phase 2 | 读路径统一：原生元数据同步进 `luma_assets`；`photos` 单一来源；侧边栏统一 | managed 与 native 的浏览、分页、计数结果一致 |
| Phase 3 | 写路径统一：PhotoKit 导入/编辑/删除/相簿/文件夹 + 本地回退 | 读写矩阵全部通过；断网/未授权/非当前库均有明确回退 |
| Phase 4 | 清理 `system*` scope、旧 settings、旧表、重复查询 | 全量回归；百万级库启动与翻页性能达标 |
| Phase 5 | 文档、旧库处理说明、用户可见文案确认 | 旧库进入 legacy 目录；发布说明明确历史数据不迁移 |

### 8.1 Phase 0 的具体动作

1. 新建空 `PhotosLuma.sqlite`，创建全部 `luma_*` 表，写入 `luma_library`，`schema_version = 7`。
2. 旧 `PhotosClone.sqlite` 不读取；首次打开时移入 `database/legacy/PhotosClone-<timestamp>/`。
3. 删除 `SystemIndex-*.sqlite` 与旧系统缓存，不再生成新的独立索引库。
4. 定义 `LibrarySession`、`LibraryRepository`、`LibraryCapabilities` 的接口骨架，不接 UI。
5. managed 图库从空库启动；native 图库只从 `Photos.sqlite` 同步，不读旧 Luma 覆盖。
6. 用全新图库验证：创建、导入、收藏、隐藏、关键词、相簿、文件夹、删除、重启持久化。
7. 用旧图库验证：旧库被移入 legacy、新库为空、应用不崩溃、可回滚。

**不建议一次性大爆炸重构。** 当前 `isSystemScope / isNativeContainer / system*` 相关引用超过 1000 处，先抽象 Repository 和 Scope 别名，再逐文件收敛，能把回归风险控制在可验证范围内。

---

## 9. 风险与限制

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 写 Apple `Photos.sqlite` | 图库损坏、照片丢失 | 禁止；只读 + PhotoKit |
| 历史数据不迁移 | 旧相簿、收藏、关键词、人物、AI 对话、网盘挂载列表丢失；managed 旧文件不自动索引 | 旧库移入 `database/legacy/`；发布说明明确；确认后再删除 |
| PhotoKit 目标不匹配 | 打开的不是系统当前库，写回失败 | 用样本资产校验目标库；失败回退本地表 |
| 权限受限 / Limited | 只能访问部分照片 | 能力模型按授权状态降级 |
| 文件夹 API 不可用 | 无法写回 Apple 文件夹 | 文件夹只存 `luma_folders`，不写 Apple |
| iCloud 原图未下载 | 本地路径不存在 | 用 PhotoKit 资源下载或 derivatives |
| 百万级库首次同步 | 首次打开慢、库体积增大 | 分批、可续传、进度可见；必要时退回直连读 |
| 外部修改 | Photos 中新增/删除后 Luma 不更新 | 指纹增量 + PHPhotoLibraryChangeObserver |
| 撤销语义 | 原生写回无法完全撤销 | 撤销栈只覆盖 Luma 可撤销操作 |
| 网盘边界 | 被误当成图库 | 网盘单独模型，不进入 `luma_assets` 主表 |

---

## 10. 已确认决策与剩余事项

### 10.1 已确认

1. **单库方案**
   - 采用 A：每库一个 Luma 可写 SQLite，官方库 `Photos.sqlite` 只读，PhotoKit 实时写回。
   - B（官方库只作为导入源、严格只保留 Luma 一个 SQLite）不再作为主方案，仅作为未来需要“物理单文件”时的备选。
2. **Luma 可写库文件名**
   - 统一使用 `database/PhotosLuma.sqlite`。
   - 旧 `database/PhotosClone.sqlite` 不读取、不迁移；首次打开时移入 `database/legacy/`。
   - 不使用 `Photos.sqlite`、`Luma.sqlite`、`Library.sqlite` 等其他文件名。
3. **侧边栏文案**
   - “系统图库”改为“链接图库”。
   - 布局、字体、行高、图标、交互不变。
4. **历史数据**
   - 不做 v6 → v7 数据迁移。
   - 旧库改名隔离，确认后可删除；旧 `originals/` 与 `resources/renders/` 不自动删除。

### 10.2 剩余事项

1. **原生库回退策略**
   - 收藏/隐藏/关键词/标题：只写 Luma 表。
   - 导入/编辑：写 Luma 自有 `originals/` 与 `resources/renders/`，标记 `origin='managed'`。
   - 删除：只标记 `deleted_at`，不改 Apple 文件。
2. **实施排期**
   - Phase 0 的 Repository 接口、schema v7、旧库隔离与新建逻辑需要单独评审后再动代码；不写历史迁移脚本。

---

## 附录 A：为什么不能写 Apple 的 `Photos.sqlite`

Apple Photos 的 `Photos.sqlite` 是 Core Data 持久化存储，不是公开 API：

- 表名、列名、关系表、主键由 Apple 私有维护，随 macOS 版本变化。
- Photos 进程持有数据库连接和 WAL；第三方写入会与 Photos 的事务、锁、日志回放冲突。
- Photos 在启动、升级、iCloud 同步时会做完整性与迁移检查，额外表/列会被视为异常。
- 官方只提供 PhotoKit 作为读写接口；直接写文件属于不受支持的实现。
- 一旦损坏，恢复依赖 Apple 的图库修复或备份，产品无法兜底。

因此，本方案把 `Photos.sqlite` 明确定义为**只读内容源**，不承担任何 Luma 写入。

---

## 附录 B：当前代码证据

- 两个库文件路径：`metadataFile` 与 `systemIndexFile`（[LibraryPaths.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/LibraryPaths.swift#L54-L70)）。
- 两套数据库 schema：`assets / asset_overlays / system_analysis / cloud_*`（[MetadataStore.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/MetadataStore.swift#L356-L558)）。
- 系统图库索引与直连：`SystemIndex`（[SystemIndex.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/SystemIndex.swift#L32-L45)）、`SystemDirectSource`（[SystemIndex+Direct.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/SystemIndex+Direct.swift#L12-L33)）。
- 切换/连接系统图库：`switchLibraryContainer`、`connectSystemLibrary`、`system_library_path`、`system_libraries`（[LibraryStore+SystemLibrary.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+SystemLibrary.swift#L490-L549)、[LibraryStore+SystemLibrary.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+SystemLibrary.swift#L624-L687)）。
- 侧边栏原生分支（[SidebarView.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Sidebar/SidebarView.swift#L43-L150)）。
- 只读范围判断（[LibraryStore+Query.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Query.swift#L256)）。
- PhotoKit 写回能力（[PhotoKitBridge.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/PhotoKitBridge.swift#L51-L180)）。
- 原生库识别依赖 `database/Photos.sqlite` 是否存在（[LibraryPaths.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/LibraryPaths.swift#L190-L198)）。
