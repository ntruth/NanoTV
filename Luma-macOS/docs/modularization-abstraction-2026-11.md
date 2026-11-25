# 项目模块化与公共抽象建议

**主题：按“图库也是一种源”重构模块边界，承接单库方案与五模式扩展**

| 项目 | 内容 |
| --- | --- |
| 版本 | v0.1 |
| 日期 | 2026-11-22 |
| 状态 | 建议稿，不改代码 |
| 前置文档 | [产品元数据重构方案](file:///Users/lijialong/Documents/gitlab/photos/docs/metadata-refactor-plan.md)、[多模式内容框架评估](file:///Users/lijialong/Documents/gitlab/photos/docs/multi-mode-architecture-2026-11.md) |
| 核心结论 | “统一”应发生在**源契约、内容契约、播放契约**三层，不发生在资产表与 `PhotoItem` 上；图库是唯一拥有写入会话的源，其余云盘 / 资源 / 影院 / 电视都是只读浏览源 |

---

## 0. 结论

1. **图库应被视为 `SourceKind.library`，但它是特殊源：唯一拥有写入会话。**
   单库方案里的“当前图库”不是与五种模式并列的产品概念，而是“当前活动库源”；“链接图库”是同一 kind 的非活动实例，点击即替换当前库；云盘 / 网络资源 / 影院 / 电视是其他 kind 的只读浏览源，打开它们不改变当前图库。

2. **统一的是契约，不是数据库。**
   `luma_assets / luma_albums / luma_people` 只承载 library kind；云盘继续用 `luma_cloud_*`，网络资源用 `catalog_*`，电视用 `tv_*`，影院用 `cinema_*`。跨模式统一的是 `SourceDescriptor`、`ContentCard`、`PlaybackTarget`，不是一张大表。

3. **单库方案新增的 `LibrarySession / LibraryRepository / LibraryCapabilities` 方向正确，但需要改成“library kind 的内部实现”。**
   不要让它们变成全项目唯一模型，否则云盘、资源、电视都会被强行塞进“图库”语义。

4. **当前最急的模块化切口不是拆 SPM target，而是拆大文件与中心 switch。**
   `CinemaLibraryView` 9957 行、`GalleryView` 3384 行、`SidebarView` 1807 行、`LibraryStore` 1435 行 + 37 个扩展、`PhotosCloneApp` 781 行，已经让任何新模式都要在巨型文件里补分支。

5. **建议新增一个纯契约 target `LumaContentCore`，其余暂不拆。**
   当前 7 万多行全部是 App 内部代码，全面 SPM 化会引入大量 `public` 与迁移成本；先把“源 / 内容 / 播放 / 任务 / 错误”契约抽成独立 target，能拿到编译期边界，又不拖慢单库重构。

6. **新增影院/电视前，还需要补 8 类公共抽象。**
   源会话与激活策略、源生命周期与健康、统一错误与恢复动作、后台任务中心、内容查询与游标、导航状态、跨源搜索、源能力驱动的命令可用性。它们比“再多一个 Provider 协议”更影响后续维护成本。

---

## 1. “图库也是一种源”的统一模型

### 1.1 源分类与会话语义

| 源 kind | 产品名 | 是否拥有写入会话 | 打开方式 | 存储边界 |
| --- | --- | --- | --- | --- |
| `library`（active） | 当前图库 | 是，唯一 | 直接浏览 | `luma_assets / luma_albums / luma_folders / luma_people / luma_analysis` |
| `library`（linked） | 链接图库 | 否，点击后替换当前库 | 切换会话 | 各自图库包内的 `PhotosLuma.sqlite`，互不共享 |
| `cloudMount` | 网络云盘 | 否 | 直接浏览 | `luma_cloud_*`、云索引表、云端缩略图缓存 |
| `catalogSite` | 网络资源 | 否 | 直接浏览 | `catalog_*`、列表快照、海报缓存 |
| `cinemaFeed` | 网络影院 | 否 | 直接浏览 | `cinema_*`、刮削索引、海报缓存 |
| `iptv` | 网络电视 | 否 | 直接浏览 | `tv_*`、频道缓存、EPG、台标缓存 |

关键区别：

- **当前图库是“会话”**：同一时间只有一个，负责所有写操作与撤销栈。
- **链接图库是“可替换会话”**：点击它等于切换当前库，不是并行浏览。
- **云盘 / 资源 / 影院 / 电视是“浏览源”**：打开只改变右侧内容，不改变当前库。
- 这一区别必须写进模型，否则“图库统一”会被误做成“所有源都能写库”。

### 1.2 统一源模型图

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 700" width="100%" role="img" aria-label="统一源模型：图库作为源">
  <defs>
    <marker id="d1" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">
      <path d="M0,0 L0,6 L9,3 z" fill="#8a8f98"/>
    </marker>
    <style>
      .t { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; fill:#1d2129; }
      .m { fill:#6b7280; }
      .line { stroke:#8a8f98; stroke-width:1.3; fill:none; marker-end:url(#d1); }
    </style>
  </defs>

  <text x="24" y="30" class="t" font-size="19" font-weight="700">统一源模型：一个写入会话 + 多个只读浏览源</text>

  <!-- 注册表 -->
  <rect x="20" y="54" width="1080" height="112" rx="12" fill="#f2f6ff" stroke="#bfd0f5"/>
  <text x="36" y="80" class="t" font-size="13" font-weight="700">SourceRegistryState（唯一源目录，替代独立 LibraryRegistry）</text>

  <rect x="36" y="94" width="320" height="54" rx="8" fill="#fff" stroke="#d7e2f7"/>
  <text x="50" y="116" class="t" font-size="11" font-weight="600">activeLibraryID</text>
  <text x="50" y="136" class="t m" font-size="10">kind = library；唯一写入会话</text>

  <rect x="370" y="94" width="320" height="54" rx="8" fill="#fff" stroke="#d7e2f7"/>
  <text x="384" y="116" class="t" font-size="11" font-weight="600">linkedLibraries</text>
  <text x="384" y="136" class="t m" font-size="10">kind = library；点击替换当前库</text>

  <rect x="704" y="94" width="380" height="54" rx="8" fill="#fff" stroke="#d7e2f7"/>
  <text x="718" y="116" class="t" font-size="11" font-weight="600">linkedSources</text>
  <text x="718" y="136" class="t m" font-size="10">cloudMount / catalogSite / cinemaFeed / iptv</text>

  <!-- 源 -->
  <rect x="20" y="212" width="240" height="132" rx="10" fill="#eef4ff" stroke="#9db8ef"/>
  <text x="34" y="238" class="t" font-size="12" font-weight="700">当前图库（active）</text>
  <text x="34" y="260" class="t" font-size="10">library · managed / native</text>
  <text x="34" y="280" class="t" font-size="10">可导入 / 编辑 / 删除 / 相簿</text>
  <text x="34" y="300" class="t" font-size="10">撤销栈、写回、能力降级</text>
  <text x="34" y="324" class="t m" font-size="10">存储：luma_*</text>

  <rect x="276" y="212" width="220" height="132" rx="10" fill="#f5f8ff" stroke="#c7d5f0"/>
  <text x="290" y="238" class="t" font-size="12" font-weight="700">链接图库</text>
  <text x="290" y="260" class="t" font-size="10">library · 非活动实例</text>
  <text x="290" y="280" class="t" font-size="10">点击 = 替换当前库会话</text>
  <text x="290" y="300" class="t" font-size="10">各自独立包</text>
  <text x="290" y="324" class="t m" font-size="10">存储：各自的 PhotosLuma.sqlite</text>

  <rect x="512" y="212" width="140" height="132" rx="10" fill="#f2fbf7" stroke="#b9e3cf"/>
  <text x="526" y="238" class="t" font-size="12" font-weight="700">云盘</text>
  <text x="526" y="260" class="t" font-size="10">cloudMount</text>
  <text x="526" y="280" class="t" font-size="10">只读浏览</text>
  <text x="526" y="300" class="t" font-size="10">云索引 / 扫描</text>
  <text x="526" y="324" class="t m" font-size="10">luma_cloud_*</text>

  <rect x="668" y="212" width="140" height="132" rx="10" fill="#fff9f0" stroke="#f0d7ae"/>
  <text x="682" y="238" class="t" font-size="12" font-weight="700">网络资源</text>
  <text x="682" y="260" class="t" font-size="10">catalogSite</text>
  <text x="682" y="280" class="t" font-size="10">分类 / 搜索 / 分集</text>
  <text x="682" y="300" class="t" font-size="10">跨源聚合</text>
  <text x="682" y="324" class="t m" font-size="10">catalog_*</text>

  <rect x="824" y="212" width="130" height="132" rx="10" fill="#f8f4ff" stroke="#ddd0f2"/>
  <text x="838" y="238" class="t" font-size="12" font-weight="700">网络影院</text>
  <text x="838" y="260" class="t" font-size="10">cinemaFeed</text>
  <text x="838" y="280" class="t" font-size="10">本地 / 网盘 / 站点</text>
  <text x="838" y="300" class="t" font-size="10">刮削 / 播放线路</text>
  <text x="838" y="324" class="t m" font-size="10">cinema_*</text>

  <rect x="970" y="212" width="130" height="132" rx="10" fill="#fff5f5" stroke="#e9a3a3" stroke-dasharray="5 3"/>
  <text x="984" y="238" class="t" font-size="12" font-weight="700">网络电视</text>
  <text x="984" y="260" class="t" font-size="10">iptv</text>
  <text x="984" y="280" class="t" font-size="10">频道 / 分组 / EPG</text>
  <text x="984" y="300" class="t" font-size="10">直播播放</text>
  <text x="984" y="324" class="t m" font-size="10">tv_*</text>

  <path d="M140,166 L140,212" class="line"/>
  <path d="M386,166 L386,212" class="line"/>
  <path d="M582,166 L582,212" class="line"/>
  <path d="M738,166 L738,212" class="line"/>
  <path d="M889,166 L889,212" class="line"/>
  <path d="M1035,166 L1035,212" class="line"/>

  <!-- 统一契约 -->
  <rect x="20" y="388" width="1080" height="130" rx="12" fill="#ffffff" stroke="#d8dce3"/>
  <text x="36" y="414" class="t" font-size="13" font-weight="700">统一契约（所有 kind 共同实现；不含具体业务字段）</text>

  <rect x="36" y="428" width="196" height="72" rx="8" fill="#f7f8fa" stroke="#e3e7ee"/>
  <text x="50" y="450" class="t" font-size="11" font-weight="600">SourceSession</text>
  <text x="50" y="470" class="t m" font-size="10">激活 / 刷新 / 健康 / 断开</text>
  <text x="50" y="486" class="t m" font-size="10">激活策略：换库 or 浏览</text>

  <rect x="248" y="428" width="196" height="72" rx="8" fill="#f7f8fa" stroke="#e3e7ee"/>
  <text x="262" y="450" class="t" font-size="11" font-weight="600">ContentRepository</text>
  <text x="262" y="470" class="t m" font-size="10">容器 / 分页 / 详情</text>
  <text x="262" y="486" class="t m" font-size="10">查询 / 排序 / 过滤</text>

  <rect x="460" y="428" width="196" height="72" rx="8" fill="#f7f8fa" stroke="#e3e7ee"/>
  <text x="474" y="450" class="t" font-size="11" font-weight="600">PlaybackResolver</text>
  <text x="474" y="470" class="t m" font-size="10">PlaybackTarget → 流</text>
  <text x="474" y="486" class="t m" font-size="10">VOD / Live 统一入口</text>

  <rect x="672" y="428" width="196" height="72" rx="8" fill="#f7f8fa" stroke="#e3e7ee"/>
  <text x="686" y="450" class="t" font-size="11" font-weight="600">SearchCoordinator</text>
  <text x="686" y="470" class="t m" font-size="10">源内 / 跨源搜索</text>
  <text x="686" y="486" class="t m" font-size="10">去抖 / 排序 / 范围</text>

  <rect x="884" y="428" width="200" height="72" rx="8" fill="#f7f8fa" stroke="#e3e7ee"/>
  <text x="898" y="450" class="t" font-size="11" font-weight="600">JobCenter</text>
  <text x="898" y="470" class="t m" font-size="10">扫描 / 刮削 / EPG / 同步</text>
  <text x="898" y="486" class="t m" font-size="10">进度 / 取消 / 代次</text>

  <path d="M140,344 L140,388" class="line"/>
  <path d="M386,344 L386,388" class="line"/>
  <path d="M582,344 L582,388" class="line"/>
  <path d="M738,344 L738,388" class="line"/>
  <path d="M889,344 L889,388" class="line"/>
  <path d="M1035,344 L1035,388" class="line"/>

  <!-- 存储边界 -->
  <rect x="20" y="548" width="1080" height="120" rx="12" fill="#fffdf8" stroke="#ecd9b0"/>
  <text x="36" y="574" class="t" font-size="13" font-weight="700">存储边界：统一契约，不统一表</text>
  <text x="36" y="600" class="t" font-size="11">library：luma_assets / luma_albums / luma_folders / luma_people / luma_analysis / luma_settings</text>
  <text x="36" y="622" class="t" font-size="11">cloudMount：luma_cloud_*；catalogSite：catalog_*；cinemaFeed：cinema_*；iptv：tv_*</text>
  <text x="36" y="646" class="t" font-size="11" fill="#c0392b">禁止：把云盘 / 资源 / 影院 / 电视条目写入 luma_assets，或把 library 资产写进 catalog_* / tv_*</text>
  <text x="36" y="666" class="t m" font-size="10">跨源展示用 ContentCard 聚合；跨源搜索用 ContentRef；不跨表 JOIN。</text>
</svg>
```

### 1.3 激活策略必须成为模型的一部分

单库方案里“链接图库点击即切换当前图库”，而“云盘点击只是浏览”。这不是 UI 细节，而是源的语义差异。建议显式建模：

```swift
enum SourceActivationPolicy {
    case replaceLibrarySession   // 链接图库：切换当前库
    case browseReadOnly          // 云盘 / 资源 / 影院 / 电视：只换浏览源
}

struct SourceDescriptor {
    var id: SourceID
    var kind: SourceKind
    var name: String
    var activation: SourceActivationPolicy
    var content: ContentCapabilities
    var write: WriteCapabilities      // 非 library kind 全部为 false
}
```

`isSystemScope` / `isNativeContainer` 这类判断应由“当前会话的能力”替代；单库方案已经朝这个方向走，但 `LibraryCapabilities` 还应拆成：

- `ContentCapabilities`：可浏览、可搜索、可分页、可播放、有 EPG、有分类。
- `WriteCapabilities`：可导入、可编辑原图、可删除原图、可改相簿 / 文件夹、可改本地元数据、可写回原生库。

前者所有源都有，后者只有 library 有。界面只依赖这两组能力，不再依赖“是哪个模式”。

---

## 2. 模块化建议

### 2.1 模块依赖图

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 660" width="100%" role="img" aria-label="模块依赖与边界">
  <defs>
    <marker id="e1" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">
      <path d="M0,0 L0,6 L9,3 z" fill="#8a8f98"/>
    </marker>
    <marker id="e2" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">
      <path d="M0,0 L0,6 L9,3 z" fill="#d9534f"/>
    </marker>
    <style>
      .t { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; fill:#1d2129; }
      .m { fill:#6b7280; }
      .line { stroke:#8a8f98; stroke-width:1.3; fill:none; marker-end:url(#e1); }
      .red { stroke:#d9534f; stroke-width:1.3; fill:none; stroke-dasharray:5 4; marker-end:url(#e2); }
    </style>
  </defs>

  <text x="24" y="30" class="t" font-size="19" font-weight="700">建议模块边界：契约在中间，实现与 UI 在两侧</text>

  <!-- UI -->
  <rect x="20" y="56" width="1080" height="106" rx="12" fill="#f7f9fd" stroke="#d7dff0"/>
  <text x="36" y="82" class="t" font-size="12" font-weight="700">UI 层（PhotosClone/Features + Platform）</text>
  <rect x="36" y="94" width="176" height="52" rx="7" fill="#fff" stroke="#e1e6ef"/>
  <text x="50" y="116" class="t" font-size="11" font-weight="600">Library</text>
  <text x="50" y="134" class="t m" font-size="10">照片网格 / 查看器</text>
  <rect x="224" y="94" width="158" height="52" rx="7" fill="#fff" stroke="#e1e6ef"/>
  <text x="238" y="116" class="t" font-size="11" font-weight="600">Cloud</text>
  <text x="238" y="134" class="t m" font-size="10">目录 / 云影院</text>
  <rect x="394" y="94" width="158" height="52" rx="7" fill="#fff" stroke="#e1e6ef"/>
  <text x="408" y="116" class="t" font-size="11" font-weight="600">Catalog</text>
  <text x="408" y="134" class="t m" font-size="10">站点频道 / 详情</text>
  <rect x="564" y="94" width="158" height="52" rx="7" fill="#fff" stroke="#e1e6ef"/>
  <text x="578" y="116" class="t" font-size="11" font-weight="600">Cinema</text>
  <text x="578" y="134" class="t m" font-size="10">海报墙 / 剧集</text>
  <rect x="734" y="94" width="158" height="52" rx="7" fill="#fff5f5" stroke="#e9a3a3" stroke-dasharray="5 3"/>
  <text x="748" y="116" class="t" font-size="11" font-weight="600">TV（新增）</text>
  <text x="748" y="134" class="t m" font-size="10">频道 / EPG / 直播</text>
  <rect x="904" y="94" width="180" height="52" rx="7" fill="#fff" stroke="#e1e6ef"/>
  <text x="918" y="116" class="t" font-size="11" font-weight="600">Platform</text>
  <text x="918" y="134" class="t m" font-size="10">设计系统 / 组件 / 窗口</text>

  <path d="M560,162 L560,206" class="line"/>
  <text x="570" y="190" class="t m" font-size="10">只依赖契约</text>

  <!-- ContentCore -->
  <rect x="20" y="206" width="1080" height="124" rx="12" fill="#f2f6ff" stroke="#bfd0f5"/>
  <text x="36" y="232" class="t" font-size="12" font-weight="700">LumaContentCore（新增 target，纯 Foundation，无 SwiftUI / AppKit）</text>
  <rect x="36" y="244" width="170" height="66" rx="7" fill="#fff" stroke="#d7e2f7"/>
  <text x="50" y="266" class="t" font-size="11" font-weight="600">Source</text>
  <text x="50" y="284" class="t m" font-size="10">Descriptor / Registry</text>
  <text x="50" y="300" class="t m" font-size="10">Session / 激活策略</text>
  <rect x="218" y="244" width="170" height="66" rx="7" fill="#fff" stroke="#d7e2f7"/>
  <text x="232" y="266" class="t" font-size="11" font-weight="600">Content</text>
  <text x="232" y="284" class="t m" font-size="10">Ref / Card / Detail</text>
  <text x="232" y="300" class="t m" font-size="10">Query / Cursor</text>
  <rect x="400" y="244" width="170" height="66" rx="7" fill="#fff" stroke="#d7e2f7"/>
  <text x="414" y="266" class="t" font-size="11" font-weight="600">PlaybackTarget</text>
  <text x="414" y="284" class="t m" font-size="10">源 + 条目 + 模式</text>
  <text x="414" y="300" class="t m" font-size="10">VOD / Live 能力</text>
  <rect x="582" y="244" width="170" height="66" rx="7" fill="#fff" stroke="#d7e2f7"/>
  <text x="596" y="266" class="t" font-size="11" font-weight="600">Search</text>
  <text x="596" y="284" class="t m" font-size="10">源内 / 跨源</text>
  <text x="596" y="300" class="t m" font-size="10">结果与范围</text>
  <rect x="764" y="244" width="150" height="66" rx="7" fill="#fff" stroke="#d7e2f7"/>
  <text x="778" y="266" class="t" font-size="11" font-weight="600">Jobs</text>
  <text x="778" y="284" class="t m" font-size="10">进度 / 取消 / 代次</text>
  <text x="778" y="300" class="t m" font-size="10">源生命周期</text>
  <rect x="926" y="244" width="158" height="66" rx="7" fill="#fff" stroke="#d7e2f7"/>
  <text x="940" y="266" class="t" font-size="11" font-weight="600">Errors / Progress</text>
  <text x="940" y="284" class="t m" font-size="10">恢复动作</text>
  <text x="940" y="300" class="t m" font-size="10">播放进度接口</text>

  <!-- 实现层 -->
  <rect x="20" y="374" width="1080" height="122" rx="12" fill="#f2fbf7" stroke="#b9e3cf"/>
  <text x="36" y="400" class="t" font-size="12" font-weight="700">实现层（实现 ContentCore 协议；禁止 SwiftUI）</text>
  <rect x="36" y="412" width="300" height="66" rx="7" fill="#fff" stroke="#cfe9dc"/>
  <text x="50" y="434" class="t" font-size="11" font-weight="600">LumaSourceKit（P1 抽出）</text>
  <text x="50" y="452" class="t m" font-size="10">Catalog 站点 / MovieFeed / IPTV / HTTP</text>
  <text x="50" y="468" class="t m" font-size="10">M3U / XMLTV / JSON 片源解析</text>
  <rect x="352" y="412" width="390" height="66" rx="7" fill="#fff" stroke="#cfe9dc"/>
  <text x="366" y="434" class="t" font-size="11" font-weight="600">PhotosClone/Services/Library（library kind 内部）</text>
  <text x="366" y="452" class="t m" font-size="10">LibraryRepository / Managed &amp; Native Backend</text>
  <text x="366" y="468" class="t m" font-size="10">NativeSync / PhotoKit / MetadataStore</text>
  <rect x="758" y="412" width="326" height="66" rx="7" fill="#fff" stroke="#cfe9dc"/>
  <text x="772" y="434" class="t" font-size="11" font-weight="600">PhotosClone/Services/Media</text>
  <text x="772" y="452" class="t m" font-size="10">图片 / 视频 IO、缩略图、封面、台标缓存</text>
  <text x="772" y="468" class="t m" font-size="10">纯网络 / 解析不放 AppKit</text>

  <path d="M560,330 L560,374" class="line"/>
  <text x="570" y="358" class="t m" font-size="10">实现契约</text>

  <!-- 内核 -->
  <rect x="20" y="520" width="530" height="56" rx="10" fill="#f8f4ff" stroke="#ddd0f2"/>
  <text x="36" y="554" class="t" font-size="12" font-weight="700">PlaybackCore（保持独立，新增 Live 模式）</text>

  <rect x="566" y="520" width="534" height="56" rx="10" fill="#f7f8fa" stroke="#d8dce3"/>
  <text x="582" y="554" class="t" font-size="12" font-weight="700">LumaCore（纯算法，保持）</text>

  <path d="M560,496 L285,520" class="line"/>
  <path d="M285,576 L760,576" class="line"/>

  <!-- 组合根 -->
  <rect x="20" y="600" width="1080" height="42" rx="9" fill="#fffdf8" stroke="#ecd9b0"/>
  <text x="36" y="626" class="t" font-size="11">App/CompositionRoot：唯一装配点。Features 不 import 具体 Provider；Provider 不 import Feature。</text>

  <text x="760" y="626" class="t" font-size="10" fill="#c0392b">禁止 Feature ↔ Feature 横向依赖</text>
  <path d="M206,120 L224,120" class="red"/>
  <path d="M552,120 L564,120" class="red"/>
</svg>
```

### 2.2 模块职责表

| 模块 | 职责 | 现有代码归属 | 新增/迁移建议 |
| --- | --- | --- | --- |
| `LumaCore` | 纯算法、尺寸、哈希、文档规则 | `Sources/LumaCore` | 不动 |
| `PlaybackCore` | 播放时间轴、片源计划、AVPlayer 引擎、字幕 | `Sources/PlaybackCore` | 新增 `PlaybackMode`、Live 分支、`ResolvedStream` |
| `LumaContentCore`（新） | 源、内容、播放目标、搜索、任务、错误、进度接口 | 无 | P0 新建；不依赖 AppKit / SwiftUI |
| `LumaSourceKit`（可选） | 站点 / 片源 / IPTV 适配器、HTTP 传输、解析器 | 现 `Services/Catalog`、未来 TV/Movie | P1 抽；也可先留 App 内，按协议隔离 |
| `Services/Library` | 单库会话、Repository、Managed/Native 后端、NativeSync、PhotoKit | `Services/Library`、`Services/Media/PhotoKitBridge` | 按单库方案改造 |
| `Services/Media` | 图片 / 视频 IO、缩略图、色彩、缓存 | `Services/Media`、`Services/Cloud` 的图片部分 | 把 AppKit 依赖集中到这里 |
| `Features/Library` | 照片网格、查看器、编辑、整理 | `Features/Gallery`、`Viewer`、`Organize`、`Collections` 等 | 不直接 import 云盘 / 资源 / 影院 |
| `Features/Cloud` | 云盘目录 / 云影院 | `Features/Cloud`、`Sidebar` 云分区 | 只依赖 ContentCore |
| `Features/Catalog` | 站点频道 / 详情 / 发现 | `Features/Catalog` | 只依赖 ContentCore |
| `Features/Cinema` | 海报墙 / 剧集 / 播放线路 | `Features/Cinema` | 只依赖 ContentCore |
| `Features/TV`（新） | 频道 / 分组 / EPG / 直播 | 无 | 只依赖 ContentCore |
| `Store` | 轻量编排、跨 Feature 协调 | `LibraryStore` + 37 个扩展、`CloudBrowserModel`、`CatalogBrowserModel` | 只保留 `SourceHubModel`、`PlaybackCoordinator`、`SearchCoordinator` |
| `App` | 组合根、窗口、命令、URL 处理 | `App/PhotosCloneApp`、`RootView` | 只在这里 import 具体实现 |

### 2.3 目录落地建议

```text
Sources/
├── LumaCore/                         # 不动
├── PlaybackCore/                     # 新增 Live 能力
├── LumaContentCore/                  # 新增：契约层
│   ├── Source/
│   │   ├── SourceID.swift
│   │   ├── SourceKind.swift
│   │   ├── SourceDescriptor.swift
│   │   ├── SourceCapabilities.swift
│   │   └── SourceRegistryState.swift
│   ├── Content/
│   │   ├── ContentRef.swift
│   │   ├── ContentPage.swift
│   │   ├── ContentQuery.swift
│   │   └── ContentDetail.swift
│   ├── Playback/
│   │   └── PlaybackTarget.swift
│   ├── Search/
│   │   └── ContentSearch.swift
│   ├── Jobs/
│   │   └── SourceJob.swift
│   ├── Progress/
│   │   └── PlaybackProgressStore.swift
│   └── Errors/
│       └── SourceError.swift
├── LumaSourceKit/                    # P1 可选
│   ├── HTTP/
│   ├── Catalog/
│   ├── Movie/
│   └── TV/
└── PhotosClone/
    ├── App/                          # 组合根、命令
    ├── Platform/                     # DesignSystem、Components、Window、Keyboard
    ├── Features/
    │   ├── Library/
    │   ├── Cloud/
    │   ├── Catalog/
    │   ├── Cinema/
    │   └── TV/
    ├── Services/
    │   ├── Library/                  # Repository / Backend / NativeSync
    │   ├── Media/                    # 图片视频 IO / 缓存
    │   └── AI/
    └── Store/                        # 只放编排，不放领域实现
```

### 2.4 模块化强度：三档，建议选中间

| 方案 | 做法 | 优点 | 风险 | 建议 |
| --- | --- | --- | --- | --- |
| 轻量 | 只改目录与命名，仍一个 target | 成本最低 | 无编译期边界，靠 review | 作为过渡 |
| 标准 | 新增 `LumaContentCore` target；其余保持 App | 契约有编译期边界；迁移成本可控 | 需要给契约类型加 `public` | **推荐** |
| 重量 | 每个 Feature / Service 独立 target | 边界最强，可独立测试 | 7 万行代码大量 `public`、循环依赖暴露、迁移周期长 | 暂不建议 |

**推荐路径：**

1. 先建 `LumaContentCore`，只放协议、值类型、错误、任务接口。
2. `PlaybackCore` 增加 `PlaybackMode` / `ResolvedStream`。
3. App 依赖两个 target；现有代码逐步把“协议实现”移到 `Services`。
4. TV / MovieFeed 新代码直接写在 `LumaSourceKit` 或 `Services` 下，必须只依赖 `LumaContentCore`。
5. 等新代码稳定、旧代码迁移到 Repository 后，再考虑拆 Feature target。

### 2.5 当前最需要拆的大文件

| 文件 | 行数 | 问题 | 建议拆法 |
| --- | ---: | --- | --- |
| [CinemaLibraryView.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Cinema/CinemaLibraryView.swift) | 9957 | 海报墙、筛选、详情、剧集、任务、设置全在一个文件 | `CinemaHomeView`、`CinemaShelfView`、`CinemaPosterGrid`、`CinemaDetailView`、`CinemaSeriesView`、`CinemaFilterBar`、`CinemaTaskCenter` |
| [GalleryView.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Gallery/GalleryView.swift) | 3384 | 时间轴、网格、搜索、拖拽、键盘、工具栏耦合 | `GalleryTimelineView`、`GalleryGridContainer`、`GallerySearchResults`、`GalleryToolbar`、`GalleryDropHandler` |
| [SidebarView.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Sidebar/SidebarView.swift) | 1807 | 图库 / 云盘 / 资源分区手写，电视还要再加 | `SidebarLibrarySection`、`SidebarCloudSection`、`SidebarCatalogSection`、`SidebarTVSection`、`SidebarRow` |
| [PhotosCloneApp.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/App/PhotosCloneApp.swift) | 781 | 所有命令与 `.disabled` 集中在一个文件 | `LibraryCommands`、`PhotoCommands`、`VideoCommands`、`ViewCommands`、`ImportCommands` |
| [LibraryStore.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore.swift) + 37 个扩展 | 1435 + 扩展 | 浏览、选择、导入、编辑、AI、健康、云、影院全在一个类 | 按单库方案拆 `LibrarySession`、`LibraryRepository`；再拆 `PlaybackCoordinator`、`SearchCoordinator`、`SourceHubModel` |
| [CatalogBrowserModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/CatalogBrowserModel.swift) + Discovery | 1428 + 1513 | 浏览、发现、健康、搜索、片单、日历、关注全在一个模型 | `CatalogBrowseState`、`CatalogDiscoveryState`、`CatalogPersistence`、`CatalogPlaybackBridge` |
| [CloudProviders.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Cloud/CloudProviders.swift) | 1391 | 多个云盘实现与统一调度混在一个文件 | 按 provider 拆文件，保留 `CloudService` 只做调度 |
| [MetadataStore.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/MetadataStore.swift) | 924 | 所有 schema 与查询混在一起 | 按单库方案拆 `LibraryRepository`、`NativeSync`、`CloudIndexStore` |
| [SystemIndex.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/SystemIndex.swift) | 2042 | 独立索引 + 直连两套读法 | 单库方案改为 `NativeLibrarySync` 的读取实现 |

### 2.6 依赖规则

1. **Feature 只能依赖 `LumaContentCore`、`PlaybackCore`、`Platform`。**
   影院不能 import 网络资源的模型；资源不能 import 影院视图；电视不能 import 云盘。
2. **Provider 只能依赖 `LumaContentCore` + Foundation。**
   不允许 import SwiftUI；尽量不 import AppKit。当前 `Services` 下 30+ 个文件直接 import AppKit / SwiftUI，是边界失效的直接证据。
3. **Library 的内部实现只出现在 `Services/Library`。**
   `ManagedLibraryBackend`、`NativeLibraryBackend`、`NativeSync`、`PhotoKitBridge` 不暴露给云盘 / 资源 / 电视。
4. **组合根唯一。**
   只有 `App` 知道具体 Provider 类型；Feature 通过协议拿数据。
5. **Store 只做编排。**
   `SourceHubModel` 负责源列表、健康、任务；“怎么查、怎么播、怎么存”在 Repository / Provider / PlaybackCoordinator。
6. **禁止跨 kind 写表。**
   任何 Provider 不得直接写 `luma_assets`；只有 library Repository 可以。

---

## 3. 还需要公共抽象的 12 组对象

前一篇文档已经给出“源描述 / 播放目标 / 内容卡片”的方向。这里补齐**为了让单库重构和五模式同时成立，还缺什么**，按优先级排序。

### 3.1 总表

| 组 | 抽象 | 现状证据 | 不做的后果 | 优先级 |
| --- | --- | --- | --- | --- |
| A | `SourceActivationPolicy` | 链接图库点击=换库；云盘点击=浏览；两种行为现在由视图分支表达 | 统一源模型后行为混淆 | P0 |
| B | `SourceSession` + `BrowseSession` | `LibraryStore.systemLibraryPath`、`cloudModel.scanMountID`、`catalogModel.selectedSourceID` 各自维护 | 无法回答“当前在浏览哪个源、写入哪个库” | P0 |
| C | `SourceError` + `RecoveryAction` | `CloudOAuthError` 有 `requiresReauth`；`CatalogError` 自成一套；影院任务又是一套 | 电视/影院错误无法统一呈现“重试/重新登录/打开浏览器/重配” | P0 |
| D | `SourceJobCenter` | 云盘模型有 8+ 个 Task 字段；资源模型有 5+ 个；LibraryStore 更多 | 电视 EPG、影院刮削、云盘扫描各自造任务与进度 | P0 |
| E | `ContentQuery` + `PageCursor` | 资源有 page 参数；云盘有目录；图库有 SQL 分页；影院有筛选 | 每个源一套分页/排序，跨源列表无法统一 | P0 |
| F | `PlaybackCoordinator` | `PlaybackHooks` + `CatalogPlaybackContext` + 云盘流 + 影院条目 | 播放解析、续播、进度、Now Playing 继续分散 | P0 |
| G | `NavigationState` + `Breadcrumb` | `catalogReturnItem`、`cloudTrail`、影院文件夹、`sidebarItem` 各一套 | 电视/影院详情返回逻辑继续特判 | P1 |
| H | `ContentSearchCoordinator` | 资源有跨源搜索；图库有全局搜索；云盘有目录搜索 | 电视/影院搜索无法进入统一入口 | P1 |
| I | `ContentSnapshotStore` + `SourceRevision` | 资源有 `pageSnapshots`；云盘有目录缓存；`contentRevision` / `cloudIndexRevision` / `cinemaDataRevision` 各自为政 | 每个新模式都要重写“先铺旧数据” | P1 |
| J | `ArtworkCache` | 资源海报、影院海报、云缩略图、人物头像各有缓存 | 电视需要第五套台标缓存 | P1 |
| K | `CommandPolicy` | `PhotosCloneApp` 大量 `.disabled(store.is...)`；新模式下按钮可用性要逐条补 | 电视频道页出现照片操作 | P1 |
| L | `SourceLifecycle` + `SourceHealth` | 资源有 health；云盘有 error/reauth；影院有 task | 源健康、重连、过期提示不统一 | P1 |
| M | `AIToolProvider` | `LibraryStore+AITools` 1823 行、`AICinemaTools` 1057 行、`AIAgent` 483 行 | 电视/在线影院接入 AI 要再复制一套工具 | P2 |
| N | `IngestService` | 资源“保存到图库”、云盘导入、本地导入各一套 | 电视录制/影院缓存到图库继续分叉 | P2 |
| O | `MetadataEnricher` | `CinemaMetadataSource` 只服务影院；资源靠站点字段；电视 EPG 自成一类 | 电影/剧集元数据无法共享 | P2 |
| P | `RequestProfile` + `HTTPTransport` | `CatalogSource` 有 UA/Referer/TLS；云盘有 headers；SMB 有自签设置 | 电视请求头、Cookie、重试、限流重复实现 | P1 |

> 命名建议：不要让 `ContentCore` 变成另一个 god module。上表 A–F 放契约层，G–P 中与 UI 强相关的放 Feature/Platform，其余放 Services。

### 3.2 重点说明

#### A. `SourceActivationPolicy`

这一项是“图库也是一种源”能否落地的分水岭。

- 链接图库：`replaceLibrarySession`，点击后 `LibrarySession` 换 URL，`LibraryRepository` 换数据库，撤销栈清空。
- 云盘 / 资源 / 影院 / 电视：`browseReadOnly`，只替换右侧浏览上下文，当前库与写入能力不变。

如果不显式建模，最后一定会在 `SidebarView` 或 `navigate(to:)` 里写 `if case .library` 特判，等于没有统一。

#### B. `SourceSession` 与 `BrowseSession`

建议两个概念分开：

```swift
@MainActor
protocol SourceSession: AnyObject {
    var descriptor: SourceDescriptor { get }
    var state: SourceSessionState { get }     // idle / connecting / ready / failed
    func activate() async
    func refresh() async
    func deactivate() async
}

@MainActor
final class LibrarySession: SourceSession {
    var repository: any LibraryRepository
    var capabilities: LibraryWriteCapabilities
}
```

`LibrarySession` 来自单库方案，继续保留；`BrowseSession` 可以由同一个协议表达，但**不拥有写入能力**。这样 `LibraryStore` 不再同时承担“当前库 + 当前云盘 + 当前资源”的状态。

#### C. `SourceError` + `RecoveryAction`

统一错误不是为了少写几个 enum，而是为了让界面能一致地给出恢复入口：

```swift
struct SourceError: Error {
    enum Kind {
        case unauthorized          // 需要重新登录
        case keychainDenied
        case tlsUntrusted
        case http(Int)
        case parse
        case unavailable
        case cancelled
        case blocked               // 站点要求人机验证
    }
    var kind: Kind
    var message: String
    var recovery: [RecoveryAction]
}

enum RecoveryAction {
    case retry
    case reauthorize
    case openInBrowser(URL)
    case reconfigureSource
    case allowInsecureTLS
}
```

现有 `CloudOAuthError.requiresReauth` 已经证明这个方向有效；把它提升到源层，电视和影院就能复用同一套错误卡片。

#### D. `SourceJobCenter`

现状是每个模型自己持有 Task：

- [CloudBrowserModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/CloudBrowserModel.swift#L51-L124)：`scanTask`、`refreshLoopTask`、`thumbnailPrefetchTask`、`metadataFlushTask`、`analysisTask`、`metadataTask`、`peopleTask`、`healthTask`。
- [CatalogBrowserModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/CatalogBrowserModel.swift#L143-L217)：`healthTask`、`globalSearchTask`、`calendarTask`、`thumbTask`、页面 `task`。
- `LibraryStore` 还有导入、压缩、分析、体检、刮削等任务。

电视会新增 EPG 刷新、频道列表刷新、台标预取、直播重连；如果继续分散，任何“切换源 / 退出页面”都要手动取消一堆任务。

建议：

```swift
@MainActor
final class SourceJobCenter {
    func run(_ job: SourceJob, for source: SourceID) -> JobHandle
    func cancelAll(for source: SourceID)
    var progress: [SourceID: [SourceJobKind: JobProgress]]
}
```

任务定义只描述“干什么、属于哪个源、可不可取消、代次”，具体实现仍由 Provider 完成。

#### E. `ContentQuery` + `PageCursor`

图库的 SQL 分页、资源的 `page`、云盘的目录、影院的筛选、电视的频道分组，本质都是“在某个容器里按条件取一页”。建议统一为：

```swift
struct ContentQuery {
    var container: ContentContainerID?
    var search: String?
    var sort: ContentSort?
    var filters: [ContentFilter]
    var cursor: PageCursor?
    var limit: Int
}

struct ContentPage {
    var items: [ContentCard]
    var next: PageCursor?
    var totalHint: Int?
}
```

各源在能力里声明自己支持哪些排序 / 过滤（资源已有 `supportedSorts`），不支持的选项由 UI 隐藏，而不是每个模式写一套工具栏。

#### F. `PlaybackCoordinator`

播放不应该继续由 `LibraryStore` 和 `VideoPlayback` 直接拼装。建议一个薄协调器：

- 输入 `PlaybackTarget`。
- 调 `PlaybackResolver` 拿 `ResolvedStream`。
- 管续播、进度、Now Playing、片头片尾、下一集。
- 对 Live：跳过续播、进度、片尾、缓存。

这样 `VideoPlayback` 只负责“把流播出来”，不再知道资源 / 云盘 / 影院 / 电视。

#### G. `NavigationState` + `Breadcrumb`

现状有三套“返回”：

- 资源详情：`catalogReturnItem`、`catalogReturnSourceID`。
- 云盘：`cloudTrail` + `selectedFolderPath`。
- 影院：文件夹层级 + 详情。
- 图库：`sidebarItem` + 特殊返回。

建议统一为每个源维护一小段导航栈：

```swift
struct SourceNavigationState {
    var root: ContentContainerID?
    var path: [ContentContainerID]
    var detail: ContentRef?
    var returnTarget: ContentRef?
}
```

视图只问“返回上一级是什么”，不再各自特判。

#### H. `ContentSearchCoordinator`

资源已经有跨源搜索、今日总榜、聚合片单；图库有全局搜索；电视需要频道搜索。建议统一入口：

- 单源搜索：调用当前源的 `ContentRepository.search`。
- 跨源搜索：由 `SourceRegistryState` 的已启用源并发调用，按源分组返回。
- 排序与去重：按源顺序、标题归一化、`ContentRef` 去重；电影可用 TMDB/豆瓣 ID 去重。

这能把“资源页的跨源搜索”升级成全局能力，而不是资源模式专属。

#### I/J/K/L. 缓存、图片、命令、健康

- `ContentSnapshotStore`：资源的 `pageSnapshots` 已经证明“先铺旧数据再刷新”有效；云盘目录缓存、电视频道缓存可以复用同一接口。
- `SourceRevision`：把 `contentRevision`、`cloudIndexRevision`、`cinemaDataRevision` 收敛成“每个源自己的版本号”，缓存键统一。
- `ArtworkCache`：海报、缩略图、台标都是“按源 + URL/路径取图”，只是尺寸与过期策略不同。
- `CommandPolicy`：把命令的 `.disabled` 判断从 `PhotosCloneApp` 移到能力 + 选择上下文的组合，电视/影院不需要再补几十条判断。
- `SourceLifecycle/SourceHealth`：资源的健康探测、云盘的重新授权、影院的任务状态，统一成“源状态 + 最近检测时间 + 恢复动作”。

#### M/N/O. AI、入库、元数据补全

- `AIToolProvider`：智能助手工具目前按模式拆文件；新增电视/在线影院会继续复制。建议按源能力注册工具，例如 `browse.search`、`playback.open`、`library.save`。
- `IngestService`：从云盘、资源、电视录制、影院缓存把媒体保存到当前图库，应走同一个“导入 + 去重 + 元数据”入口。
- `MetadataEnricher`：`CinemaMetadataSource` 可以泛化为“给 ContentDetail 打补丁”的能力，影院、在线电影、剧集、EPG 节目单共用接口。

---

## 4. 与单库重构的接口映射

### 4.1 类型映射

| 单库方案中的类型 | 建议归属 | 与其他源的关系 |
| --- | --- | --- |
| `LibrarySession` | `LumaContentCore` 协议 + `Services/Library` 实现 | 是 `SourceSession` 的 library 特化 |
| `LibraryRepository` | `Services/Library` | 实现 `ContentRepository`，只服务 library kind |
| `ManagedLibraryBackend` | `Services/Library` | library 内部细节，不暴露 |
| `NativeLibraryBackend` | `Services/Library` | library 内部细节，不暴露 |
| `NativeSync` | `Services/Library` | 只把 `Photos.sqlite` 同步进 `luma_assets` |
| `LibraryCapabilities` | `LumaContentCore` | 拆成 `ContentCapabilities` + `WriteCapabilities` |
| `LibraryRegistry` | **合并进 `SourceRegistryState`** | 避免第二个注册表 |
| `luma_assets` | 仅 library kind | 云盘 / 资源 / 影院 / 电视禁止写入 |
| `luma_cloud_*` | 云盘 kind | 单库方案已明确网盘不进入主表 |
| `catalog_*` / `tv_*` / `cinema_*` | 各自 kind | 与单库方案并列，不做跨表 JOIN |

### 4.2 不要做的事

- 不要把 `LibraryRegistry` 和 `SourceRegistry` 做成两套。单库方案的链接图库、链接网盘，本质上就是 `SourceRegistryState` 的三个字段。
- 不要把云盘 / 资源 / 电视塞进 `luma_assets`。单库方案的非目标已经写明“网盘单独模型”，应扩展到所有非 library kind。
- 不要让 `LibraryRepository` 变成所有源的通用 Repository。它是 library 的写模型；其他源只需要只读 `ContentRepository`。
- 不要为了统一而让 `PhotoItem` 承载频道、电影、EPG。`PhotoItem` 留在 library / 照片类源；跨源展示用 `ContentCard`。

### 4.3 实施顺序建议

| 阶段 | 单库重构 | 多模式框架 | 说明 |
| --- | --- | --- | --- |
| 顺序 1 | Phase 0：`LibrarySession` / `LibraryRepository` / schema v7 | 定义 `SourceDescriptor` / `SourceSession` 契约骨架 | 两者共用一套“会话 + 能力”语言 |
| 顺序 2 | Phase 1：新建 `PhotosLuma.sqlite`，删除旧索引 | `PlaybackTarget` / `ResolvedStream` / `PlaybackCoordinator` | 播放抽象与数据库改造互不阻塞 |
| 顺序 3 | Phase 2–3：读路径、写路径统一 | `SourceRegistryState` 合并链接库 / 链接网盘 / 资源 / 影院 / 电视 | 单库先稳定，再把源注册表推广 |
| 顺序 4 | Phase 4–5：清理 `system*` | TV MVP（M3U + HLS + Live） | 电视不需要等旧 scope 全清完 |
| 顺序 5 | 收尾 | 在线影院（MovieProvider + 适配器） | 依赖电视验证过的内容/播放契约 |

**关键判断：** 单库重构是“library kind 的内部重构”，不应阻塞电视；但电视也不能再建一套自己的“库/源注册表”。两者在 `SourceSession` 与 `SourceRegistryState` 上会合。

---

## 5. 反模式与边界

| 反模式 | 为什么不行 | 替代方案 |
| --- | --- | --- |
| 把电视频道塞进 `PhotoItem` | 无 EXIF、无相簿、无编辑、无时长；会污染照片网格与人物/地图派生 | `TVChannel` + `ContentCard` |
| 把在线电影塞进 `CinemaFile` | `photoID` / `cloudMountID` 无意义；刮削与站点元数据会打架 | `MovieProvider` + `MoviePlaybackOption` |
| 所有源共用 `luma_assets` | 表字段与业务语义被强行拉平；单库方案已明确网盘不进入 | 每 kind 独立表，统一契约 |
| 两个注册表 | 链接库、链接网盘、资源、电视会分裂成两套列表 | 一个 `SourceRegistryState` |
| 把 `LibraryStore` 当通用源仓库 | 会让 37 个扩展继续膨胀 | `SourceHubModel` + 各 Feature 模型 |
| 所有 Feature 拆成 SPM target | 7 万行代码大量 `public`，迁移成本高于收益 | 先抽 `LumaContentCore`，Feature 保持目录边界 |
| 为每个模式写一套命令可用性 | `PhotosCloneApp` 继续膨胀，容易漏 | `CommandPolicy` + 能力位 |
| 为每个模式写一套缓存 | 海报 / 台标 / 缩略图重复实现 | `ArtworkCache` + `SourceRevision` |
| 现在做动态插件 | 签名、安全、调试成本高 | 编译期 Provider 注册表，配置外置 |

---

## 6. 验收清单

### 6.1 模块化验收

1. `LumaContentCore` 不 import SwiftUI / AppKit；`PlaybackCore` 不 import 业务模型。
2. 任意 Feature 不 import 另一个 Feature 的具体类型。
3. 任意 Provider 不 import `LibraryStore`、`CloudBrowserModel`、`CatalogBrowserModel`。
4. `PhotosCloneApp` 的命令可用性不再直接读 `sidebarItem`，而是读能力 + 选择上下文。
5. `Services` 下不再新增 SwiftUI import；AppKit 依赖集中在 `Services/Media` 与 `Platform`。

### 6.2 抽象验收

1. 新增网络电视频道页：`GalleryView`、`sidebarTitle`、`PhotosCloneApp` 三处不需要新增分支。
2. 新增在线电影源：只新增 `MovieProvider` 适配器与注册表条目。
3. 切换链接图库：只替换 `LibrarySession`，不触发云盘 / 资源 / 电视的状态重置。
4. 播放电视直播：进度条、续播、片尾、自动下一集、字幕自动匹配都不出现。
5. 任意源的签名直链不进入数据库与日志。
6. 云盘 / 资源 / 影院 / 电视的条目不会出现在 `luma_assets`；`luma_assets` 只来自 library kind。

### 6.3 文档与测试

1. 每个 Source kind 有明确的“存储边界 / 能力 / 激活策略”说明。
2. M3U / XMLTV / JSON 片源解析有 fixture 测试；`PlaybackTarget` 解析有单元测试。
3. 现有 `LumaCoreChecks` 保留；新增 `LumaContentChecks` 覆盖契约层。

---

## 7. 附录：代码索引

| 主题 | 位置 |
| --- | --- |
| 单库方案：概念模型 | [metadata-refactor-plan.md](file:///Users/lijialong/Documents/gitlab/photos/docs/metadata-refactor-plan.md#L175-L189) |
| 单库方案：统一表 | [metadata-refactor-plan.md](file:///Users/lijialong/Documents/gitlab/photos/docs/metadata-refactor-plan.md#L325-L359) |
| 单库方案：能力模型 | [metadata-refactor-plan.md](file:///Users/lijialong/Documents/gitlab/photos/docs/metadata-refactor-plan.md#L388-L409) |
| 单库方案：代码改造清单 | [metadata-refactor-plan.md](file:///Users/lijialong/Documents/gitlab/photos/docs/metadata-refactor-plan.md#L719-L743) |
| 单库方案：分阶段实施 | [metadata-refactor-plan.md](file:///Users/lijialong/Documents/gitlab/photos/docs/metadata-refactor-plan.md#L789-L810) |
| 前一篇：多模式评估 | [multi-mode-architecture-2026-11.md](file:///Users/lijialong/Documents/gitlab/photos/docs/multi-mode-architecture-2026-11.md) |
| 模式枚举 | [Models.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/Models.swift#L458-L591) |
| 内容页分发 | [GalleryView.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Gallery/GalleryView.swift#L1343-L1449) |
| 侧边栏分区 | [SidebarView.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Sidebar/SidebarView.swift#L1311-L1447) |
| 导航动作 | [LibraryStore+Organize.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Organize.swift#L10-L29) |
| 标题与范围 | [LibraryStore+Query.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Query.swift#L10-L110) |
| 云盘状态与任务 | [CloudBrowserModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/CloudBrowserModel.swift#L51-L124) |
| 资源状态与任务 | [CatalogBrowserModel.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/CatalogBrowserModel.swift#L143-L217) |
| 站点协议 | [CatalogClient.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Catalog/CatalogClient.swift#L14-L57) |
| 云盘统一调度 | [CloudProviders.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Cloud/CloudProviders.swift#L914-L949) |
| 播放源解析 | [VideoPlayback.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Viewer/VideoPlayback.swift#L2643-L2665) |
| 播放钩子 | [LibraryStore+PlaybackHooks.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+PlaybackHooks.swift#L1-L101) |
| 播放内核进度 | [PlaybackSession.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PlaybackCore/PlaybackSession.swift#L303-L355) |
| 影院作用域 | [CinemaModels.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/CinemaModels.swift#L51-L54) |
| 影院条目 | [CinemaModels.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/CinemaModels.swift#L525-L649) |
| 应用装配 | [PhotosCloneApp.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/App/PhotosCloneApp.swift#L48-L59) |
