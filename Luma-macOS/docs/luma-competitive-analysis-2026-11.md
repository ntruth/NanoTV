# 拾光 Luma 能力盘点与竞品对比

| 项目 | 内容 |
| --- | --- |
| 版本 | v1.5（2026-11-24 专业蒙版与创意模板） |
| 日期 | 2026-11-24 |
| 对比基线 | 拾光当前代码（含图库、影院、网络电视、网络资源四条产品线） |
| 竞品资料截止 | 2026-11 公开资料 |
| 对比范围 | macOS 桌面照片管理、云相册、自托管图库、macOS 图库工具；附本地影视库 / IPTV 能力快照 |
| 文档性质 | 功能覆盖对比与产品建议，不是逐项实测评测 |
| 一句话结论 | v1.5 之后，编辑已经具备「范围/画笔蒙版、克隆、镜头校正、场景推荐、风格混合、电影感向导、海报模板」的工作流；当前最大短板是**协作与多端、视频编辑、AI 修图与专业色彩管理**。 |

> 评级符号：`●` 原生完整支持；`◐` 部分支持、有限支持或需手动；`○` 缺失或需外部工具；`—` 不适用。符号表示“功能覆盖”，不代表实现质量、性能或易用性。

---

## 0. 执行摘要

### 0.0 本轮已落地（2026-11-18）

本轮按“先补短板”的顺序，已经落地以下 MVP：

| 模块 | 已落地 | 说明 |
| --- | --- | --- |
| 图库保险库 | 设置 › 图库 › 图库保险库 | 为 `originals` / `database` / `resources/renders` 生成 SHA-256 清单；支持创建备份、逐文件校验、恢复缺失/损坏文件；损坏文件先移入 `vault-quarantine` |
| 查重 2.0 | 重复项目页 › 精确重复 / 相似照片 | 精确重复优先按 SHA-256 归组；感知哈希（64 位 dHash）+ 拍摄时间 + 宽高比生成相似组；相似组只展示，合并需二次确认 |
| 导入增强检测 | 导入窗口 › 导入选项 | 导入前 SHA-256 查重（图库 + 本批次）、磁盘空间预检、复制后哈希校验；进度显示跳过/失败/已校验数量 |
| 元数据工作流 | 网格 / 信息面板 / 右键 / 筛选菜单 / 快捷键 | 0–5 星评分、留用/排除旗标、8 种色标；`/` 层级关键词；按评分下限、旗标、色标筛选；`⌥1…⌥5`、`⌥P`、`⌥X`、`⌥6…⌥9` |
| 产品化 | 设置 › 图库 › 更新与诊断；构建脚本 | GitHub Releases 检查更新；本地诊断日志与导出；`CODESIGN_IDENTITY` / `PACKAGE=1` / `NOTARIZE=1` 构建流程；`PrivacyInfo.xcprivacy` 与 hardened runtime entitlements |

### 0.0.1 v1.2 代码复核（2026-11-23）

对 v1.1 之后的代码做了一次全量复核。下表只列**经代码确认**的新增或状态变化；未列出的 v1.1 条目维持原判断。

| 模块 | v1.2 状态 | 证据与边界 |
| --- | --- | --- |
| 图库保险库 | ✅ 已实现 | 对 `originals` / `database` / `resources/renders` 生成 SHA-256 清单，支持备份、逐文件校验、恢复缺失/损坏文件，损坏文件先进 `vault-quarantine`；缩略图/转码缓存视为可重建数据不纳入备份 |
| 完整性校验 | ✅ 已实现 | 保险库逐文件校验 + 恢复；体检仍以模糊/相似/大视频为主，尚未合并成统一“图库体检 2.0”报告 |
| 查重升级 | ✅ 已实现 | 感知哈希（64 位 dHash）+ 拍摄时间窗 + 宽高比归组相似照片；精确重复按 SHA-256 归组；相似组只展示，不自动合并 |
| 导入查重与校验 | ✅ 已实现 | 导入前 SHA-256 查重（图库 + 本批）、磁盘空间预检、复制后哈希校验；进度显示跳过/失败/已校验数量 |
| 元数据工作流 | ✅ 已实现（部分边界） | 0–5 星、留用/排除旗标、8 种色标、`/` 层级关键词的存取与展示、整理工作室按评分/旗标/色标分布筛选；仍缺树状关键词编辑、同义词、保存搜索 |
| 系统图库直连索引 | ✅ 已实现 | 直接读 Photos 索引，不复制原图；百万级分页；评分/旗标/色标筛选尚未下推到索引 SQL，只在已加载窗口内后置过滤 |
| 影院 / 影视库 | ✅ 新增产品线 | TMDB / 豆瓣 / NFO 刮削、书架 / 海报墙 / 卡片 / 列表四视图、详情页、继续观看、多版本、任务中心、多海报切换与「设为封面」、NFO 导出、播放信息面板 |
| 网络电视 IPTV | ✅ 新增产品线 | M3U 频道、分类、频道墙、播放、XMLTV 节目单与回看均可用；录制未做 |
| 网络资源 Catalog | ✅ 新增产品线 | 多站点适配、关注、演员 / 机构本地资料库、与影院/搜索打通 |
| 播放器能力 | ✅ 已实现 | HDR / 杜比视界检测与色调映射、内封/外挂/在线字幕、多音轨、章节、倍速保持音调、画中画、硬解切换、S / A / ⇧⌘I 快捷键 |

**v1.2 复核后的主要缺口**（与上方“本轮边界”合并阅读）

- 协作与多端仍是空白：共享相册、只读 Web 画廊、评论、手机入口 / 移动端。
- 编辑已形成完整工作流，仍缺视频裁剪与导出、HDR/全景、AI 降噪、范围/画笔蒙版、克隆、天空替换、双重曝光、色彩管理与外部编辑器。
- 专业工作流还差：XMP 侧车、保存搜索、手动堆栈 / 虚拟副本、对比视图、图库合并/拆分、跨图库容器搜索。
- 产品化还差：静默自动更新、崩溃符号化上传、多语言、MCP / Shortcuts。
- 影院侧还差：网络影院在线播放、蓝光原盘菜单（与影库层无关）；网络电视还差录制。

### 0.0.2 v1.3 编辑深度落地（2026-11-24）

编辑器从「基础调整」扩到「基础 + 进阶」，全部沿用同一条非破坏配方（`EditState` JSON）。旧配方用 `decodeIfPresent` 兼容，复制 / 粘贴编辑点同样携带新字段，渲染顺序为「修复 → 曲线 + HSL → 局部蒙版 → 镜头 / 透视」，全部在裁剪之前完成。

| 能力 | 落地方式 | 边界 |
| --- | --- | --- |
| 曲线 | 5 个控制点 + 单调三次 Hermite 插值，与 HSL 合成 28³ 颜色立方体，带 LRU 缓存 | RGB 合成曲线，暂无单通道曲线 / 色阶 |
| HSL | 8 条色带（红橙黄绿青蓝紫洋红）× 色相 / 饱和 / 明度，45° 内平滑过渡 | 无阴影 / 高光色轮式色彩分级 |
| 局部蒙版 | 径向 / 线性蒙版，可反向、调大小与羽化，画面内拖动定位；局部调曝光 / 对比 / 饱和 / 色温 | 无主体 / 天空 / 颜色 / 亮度范围选择 |
| 修复 | 点按修复，径向蒙版 + 邻近区域采样覆盖，自动选择采样方向 | 无克隆图章与内容感知填充 |
| 镜头 / 透视 | `CIPinchDistortion` 镜头畸变（外扩时自动放大铺满）+ `CIPerspectiveTransform` 垂直 / 水平透视 | 无镜头配置文件自动校正 |
| 前后对比 | 右下角长按「按住对比」，或按住 `\` 查看原图；保留旋转 / 裁剪对齐 | 无并排 / 分屏对比视图 |
| 直方图 | 调整面板顶部实时 RGB 直方图（160px 采样、64 bins，异步去抖） | 无高光 / 阴影溢出提示与颜色取样 |

仍缺：视频裁剪导出、HDR/全景合成、AI 降噪、自定义预设管理与版本快照、软打样 / ICC、外部编辑器 round-trip。

### 0.0.3 v1.4 编辑工作流与风格（2026-11-24）

在 v1.3 的基础上，本轮把编辑器从「一组合格的调整项」补成「可以天天用的工作流」，并加入第一批风格化能力。所有新增参数仍然写进同一份 `EditState` JSON，旧配方继续兼容。

| 能力 | 落地方式 | 边界 |
| --- | --- | --- |
| 预设 | 9 套内置风格（清透 / 奶油 / 日系青 / 电影青橙 / 暖调胶片 / 冷调都市 / 黑白高反差 / 褪色记忆 / 暗调静物）+ 自定义保存、删除、导入导出、0–100% 强度 | 预设不携带裁剪 / 蒙版 / 修复 / 画框 |
| 批量套用 | 编辑器内「套用到选中的 N 张」；按配方从原图重建，一次写入 | 不含系统图库与只读来源 |
| 快照 | 编辑会话内保存 / 恢复 / 删除多份参数快照 | 仅当前会话有效 |
| 选择性粘贴 | 全部 / 仅基础 / 仅颜色与风格 / 仅几何与镜头 / 仅蒙版与修复 | — |
| 分屏对比 | 预览区可开分屏，左右拖动分割线；原图保留旋转、裁剪与拉直 | 无并排独立缩放 |
| 直方图 | 高光 / 阴影剪切提示点 | 无溢出斑马纹 |
| 吸管取色 | 悬停显示色块、HEX 与 R/G/B | 基于 320px 采样图 |
| 裁剪与拉直 | ±15° 拉直、Vision 自动水平、三分 / 黄金 / 对角网格 | 无镜头配置文件自动校正 |
| 曲线 | RGB 合成 + R/G/B 单通道 | 无色阶输入 / 输出端点 |
| 色彩分级 | 阴影 / 中间调 / 高光三个色轮（色相 + 饱和 + 亮度） | 无 LGG 数值微调 |
| LUT | 导入 `.cube`（复制进图库）、0–100% 强度混合 | 仅 3D LUT，无 1D / 组合节点 |
| 胶片 | 颗粒、高光光晕、右上漏光、褪色 | 无真实胶片扫描纹理 |
| 创意 | 移轴 / 上下虚化、径向模糊、白边 / 黑边 / 拍立得画框 | 画框在保存时烘焙 |

仍缺：颜色 / 亮度范围蒙版、画笔与橡皮、克隆图章、AI 降噪、HDR/全景、天空替换、双重曝光、肤色美化、文字与拼图、软打样 / ICC、外部编辑器与 XMP、生成式编辑。

### 0.0.4 v1.5 专业蒙版与创意模板（2026-11-24）

本轮补的是“专业分水岭 + 最容易分享出去的创意”。所有蒙版与镜头参数仍然沿用非破坏配方，旧配方继续兼容。

| 能力 | 落地方式 | 边界 |
| --- | --- | --- |
| 范围蒙版 | 颜色范围（色相 + 容差 + 最低饱和）与亮度范围（区间 + 羽化），用 16³ 颜色立方体生成柔和遮罩 | 无主体 / 天空 / 颜色取样吸管 |
| 画笔蒙版 | 画面内直接涂抹，软硬笔、橡皮、清除；圆点序列存进配方 | 单笔上限 3000 点，无压感 |
| 克隆 | 先点采样点、再点目标；画面显示采样点与虚线连接 | 无内容感知填充 |
| 镜头配置 | 广角 / 超广角 / 鱼眼 / 长焦预设、暗角校正；按 EXIF 镜头焦段自动选择 | 无镜头数据库与色差校正 |
| 场景推荐 | 从 320px 采样统计肤色 / 亮度 / 绿蓝比 / 暖色比，推荐 2 套预设并说明原因 | 规则启发式，不上模型 |
| 风格混合 | 任意两套预设按 0–100% 比例混合后再套用 | 几何 / 蒙版 / 画框不参与混合 |
| 电影感向导 | 一键 2.39:1 裁切 + 青橙分级 + S 曲线 + 颗粒 + 高光光晕 | 无 LUT 包与逐项引导 |
| 海报模板 | 杂志封面 / 旅行手账 / 拍立得 / 日期印章 / 手写标注；可编辑标题、地点、日期、签名，导出 PNG、存到桌面、复制、系统分享 | 导出 2400px 宽，无多图拼贴 |

仍缺：主体 / 天空蒙版、AI 降噪、HDR / 全景、天空替换、双重曝光、肤色精修、文字与拼图、软打样 / ICC、外部编辑器与 XMP、本地生成式。

**本轮边界（需要下一轮继续）**

- 评分/旗标/色标筛选只接入本地图库；系统「照片」图库可以写入叠加数据、正常展示，但索引分页筛选尚未接入。
- 智能相簿条件尚未加入评分/旗标/色标；关键词已支持 `/` 层级展示，但还没有树状批量编辑。
- 保险库只备份 `originals` / `database` / `renders`，未复制缩略图、转码、系统图库缓存；尚未做真实百万级图库的恢复演练。
- 查重哈希首次扫描需要读取全库文件；中断后没有持久化断点，重新进入会继续补未计算项。
- 导入查重按 SHA-256 精确匹配；相似照片不会阻止导入；RAW+JPEG、HEIC+JPEG 自动堆栈尚未做。
- 更新检查只打开发布页，不是静默自动更新；崩溃捕获只覆盖未捕获异常 + 本地日志，不含符号化与上传。
- 共享相册、只读 Web 画廊、手机入口、视频裁剪、XMP 侧车、跨库搜索仍未开始。

### 0.1 拾光现在处于什么位置

拾光已经不是一个“Photos 克隆”。从代码和 README 看，它同时具备四类能力：

1. **多来源统一入口**：自建图库、直接打开的系统“照片”图库、SMB / WebDAV / 阿里云盘 / 百度网盘 / AList，共用一个侧边栏、查看器、搜索和整理心智。
2. **本地优先的端侧智能**：SigLIP 2 语义标签、YOLO11n 主体确认、Vision OCR / 人脸 / 条码、地标匹配、票据与证件规则、人脸聚类，全部在本机完成。
3. **深度派生内容**：人物摘要、地点摘要、旅行故事、值得重看、足迹回放、图库体检、智能美化、回忆影片。这一层明显强于普通看图软件。
4. **可执行的照片代理**：26 个工具、6 家云模型 + 自定义 OpenAI 兼容接口，能建相簿、改元数据、压缩、美化、移入最近删除，写操作需确认。

它的能力结构可以概括为：

> **管理强、洞察强、隐私强、性能强；编辑中、协作弱、专业工作流弱、产品化弱。**

**图 1：竞品定位（定性示意，非评分）**

<svg viewBox="0 0 900 520" width="100%" role="img" aria-label="拾光与竞品定位图" xmlns="http://www.w3.org/2000/svg" style="max-width:900px;display:block;margin:12px auto 4px;">
  <rect x="0" y="0" width="900" height="520" rx="18" fill="#FBF8F3"/>
  <text x="36" y="36" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="17" font-weight="700" fill="#2B2620">拾光与竞品：本地/隐私 ↔ 云端/协作，易用 ↔ 专业</text>
  <text x="36" y="58" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#7A7166">位置为功能覆盖与产品定位的定性判断，不代表销量、质量或评测分数</text>

  <rect x="100" y="80" width="740" height="360" rx="12" fill="#FFFFFF" stroke="#E4DED4"/>
  <line x1="470" y1="80" x2="470" y2="440" stroke="#D8D2C8" stroke-dasharray="5 7"/>
  <line x1="100" y1="260" x2="840" y2="260" stroke="#D8D2C8" stroke-dasharray="5 7"/>

  <text x="118" y="106" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" font-weight="600" fill="#A3988A">本地 + 专业</text>
  <text x="700" y="106" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" font-weight="600" fill="#A3988A">云端 + 专业</text>
  <text x="118" y="428" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" font-weight="600" fill="#A3988A">本地 + 大众</text>
  <text x="700" y="428" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" font-weight="600" fill="#A3988A">云端 + 大众</text>

  <text x="470" y="485" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#7A7166">更本地 / 更隐私　←　→　更云端 / 更协作</text>
  <text x="36" y="300" text-anchor="middle" transform="rotate(-90 36 300)" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#7A7166">更易用　←　→　更专业</text>

  <!-- Luma -->
  <circle cx="270" cy="175" r="9" fill="#E8A33D" stroke="#FFFFFF" stroke-width="3"/>
  <text x="285" y="170" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="13" font-weight="700" fill="#8A5A13">拾光 Luma</text>
  <text x="285" y="187" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#A3988A">本地优先 · 多来源 · 洞察</text>

  <!-- Apple -->
  <circle cx="430" cy="290" r="9" fill="#4A90E2" stroke="#FFFFFF" stroke-width="3"/>
  <text x="445" y="285" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="13" font-weight="700" fill="#245C99">Apple 照片</text>
  <text x="445" y="302" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#A3988A">系统集成 · iCloud</text>

  <!-- Google -->
  <circle cx="705" cy="305" r="9" fill="#34A853" stroke="#FFFFFF" stroke-width="3"/>
  <text x="720" y="300" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="13" font-weight="700" fill="#1E6B35">Google 相册</text>
  <text x="720" y="317" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#A3988A">云 · Ask Photos · 生成式</text>

  <!-- Lightroom -->
  <circle cx="300" cy="110" r="9" fill="#7B61FF" stroke="#FFFFFF" stroke-width="3"/>
  <text x="315" y="105" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="13" font-weight="700" fill="#4B35B8">Lightroom Classic</text>
  <text x="315" y="122" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#A3988A">专业 DAM · RAW · 插件</text>

  <!-- Mylio -->
  <circle cx="520" cy="175" r="9" fill="#2EC4B6" stroke="#FFFFFF" stroke-width="3"/>
  <text x="535" y="170" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="13" font-weight="700" fill="#15796F">Mylio Photos+</text>
  <text x="535" y="187" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#A3988A">设备网格 · Vault</text>

  <!-- Eagle -->
  <circle cx="240" cy="225" r="9" fill="#FF6B5A" stroke="#FFFFFF" stroke-width="3"/>
  <text x="255" y="220" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="13" font-weight="700" fill="#A93B2E">Eagle 4</text>
  <text x="255" y="237" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#A3988A">素材库 · 标签 · MCP</text>

  <!-- Immich -->
  <circle cx="560" cy="140" r="9" fill="#1F8A70" stroke="#FFFFFF" stroke-width="3"/>
  <text x="575" y="135" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="13" font-weight="700" fill="#146653">Immich</text>
  <text x="575" y="152" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#A3988A">自托管 · 多用户 · 共享</text>

  <!-- China cloud -->
  <circle cx="750" cy="355" r="9" fill="#9AA0A6" stroke="#FFFFFF" stroke-width="3"/>
  <text x="765" y="350" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="13" font-weight="700" fill="#5F6368">国内云相册</text>
  <text x="765" y="367" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#A3988A">自动备份 · 成片 · 共享</text>

  <text x="36" y="510" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#A3988A">注：PowerPhotos、ACDSee、PhotoPrism 未全部标出，避免拥挤；它们在“图库生命周期 / 就地索引 / 专业元数据”上更靠左上。</text>
</svg>

### 0.2 五个判断

1. **功能广度已经超过 Apple 照片的“本地管理”部分**，尤其在多来源、语义搜索、人物/地点洞察、AI 代理和百万级图库性能上。
2. **“资产安全感”已从最短板变成已有 MVP**：图库保险库、逐文件校验/恢复、感知哈希查重、导入查重与复制后校验都已落地；仍未完成的是图库合并/拆分、跨库搜索与真实大库恢复演练。
3. **“专业元数据”已经补上第一层**：评分、旗标、色标、`/` 层级关键词展示、整理工作室筛选都已可用；仍缺保存搜索、XMP 写回、手动堆栈/虚拟副本、对比视图。
4. **“协作与多端”现在是最明显短板**：没有共享相册、评论、只读 Web 画廊、手机端自动备份、多用户权限。Apple、Google、Immich、Eagle 都在补。
5. **编辑已经具备专业工具的大半**：v1.3–v1.5 依次补上曲线（RGB + 单通道）、HSL 与色彩分级、径向/线性/颜色/亮度/画笔蒙版、修复与克隆、镜头预设与透视、预设/快照/批量、LUT、胶片、虚化、画框、场景推荐、风格混合、电影感向导与海报模板；仍缺主体/天空蒙版、AI 降噪、HDR/全景、天空替换、双重曝光、肤色精修、文字与拼图、色彩管理与外部编辑器。生成式编辑仍不建议作为近期主攻，除非做“本地生成”的隐私差异。

### 0.3 如果只补六件事

| 优先级 | 补什么 | 为什么 | 直接参照 | 状态 |
| --- | --- | --- | --- | --- |
| P0 | 图库保险库：备份、校验、恢复、缺失原图检查 | 数据安全是照片管理的第一信任门槛 | Mylio Vault / SecureCloud、Immich DB Backup、Lightroom 目录备份 | ✅ 本轮 MVP |
| P0 | 查重升级：感知哈希 + 相似堆栈 + 导入时查重 | 现有“大小 + 尺寸”会漏掉重压缩、缩放、轻编辑副本 | PowerPhotos、Lightroom 15.4、Immich、ACDSee | ✅ 本轮 MVP |
| P0 | 元数据工作流：评分、旗标、色标、层级关键词、保存搜索 | 这是“整理”从相簿级进入资产级的关键 | Lightroom、ACDSee、Mylio、Eagle | ✅ 评分/旗标/色标/层级展示；保存搜索待补 |
| P0 | 共享相册 / 只读 Web 画廊 | 照片的价值一半在“给别人看”，拾光目前只有系统分享文件 | Apple 共享相册、Google 相册、Immich、PhotoPrism | ⏳ 下一轮 |
| P0 | 手机入口：伴侣 App 或局域网增量导入 | 大部分新照片在手机里；没有入口就没有新增资产 | Apple / Google 自动备份、Eagle Viewer、ACDSee Mobile Sync | ⏳ 下一轮 |
| P0 | 产品化：公证、自动更新、崩溃报告 | 已有本地/开发者签名、公证脚本与版本检查；静默自动更新与崩溃上传仍缺，用户不敢长期用 | 所有商业竞品 | ✅ 公证脚本/检查更新/本地诊断；静默自动更新待补 |

### 0.4 战略建议

- **不要做“另一个 Lightroom”**：全量专业修图是十年积累的深坑，投入产出比低。
- **不要做“另一个 Google 相册”**：自建云同步、存储、多用户、CDN 的成本与合规压力极高。
- **做“本地优先的智能照片资产库”**：以本地 / NAS 为主，云端可选；用 WebDAV / SMB / 对象存储做备份与共享，而不是自建云。
- **把 AI 从“聊天助手”升级为“可审计的资产代理”**：MCP、Shortcuts、插件、动作日志、可回滚。这是拾光相对 Apple / Google 更灵活的地方。
- **用“个人记忆图谱”做长期护城河**：人物、地点、旅行、重看、关系、事件，这些是云相册做不深、专业 DAM 不屑做的中间地带。

### 0.5 下一轮做什么（本轮完成后）

**建议下一轮主题：把“能整理”变成“能给别人看、新照片能进来”。**

| 优先级 | 任务 | 交付物 | 为什么现在做 |
| --- | --- | --- | --- |
| P0 | 共享相册 / 只读 Web 画廊 | 局域网或 NAS 托管的只读 Web 相册；链接密码/过期；评论/表情；下载原图开关 | 拾光目前只能通过系统分享发文件，缺“会更新的相册” |
| P0 | 手机入口 | 伴侣 App 或局域网增量导入；导入前查重、导入后校验；可选“只导入新照片” | 大部分新增照片在手机里；没有入口就没有新增资产 |
| P1 | 编辑工作流（v1.3–v1.5 已完成） | 曲线（RGB + 单通道）、HSL 与三段分级、径向/线性/颜色/亮度/画笔蒙版、修复与克隆、镜头预设与透视、预设/快照/批量、LUT、胶片、虚化、画框、场景推荐、风格混合、电影感向导、海报模板 | 已落地；剩余是色阶端点、主体/天空蒙版、AI 降噪、镜头数据库与视频编辑 |
| P1 | 视频快速编辑 | 入点/出点、裁剪、旋转、封面帧、H.264/HEVC 导出、压缩、HDR 色调映射 | 视频播放已经很强，编辑是明显短板 |
| P1 | 智能相簿 / 保存搜索接入元数据 | 评分、旗标、色标、是否有编辑、是否已备份、是否已备份到保险库 | 本轮只做了工具栏筛选，智能相簿还没吃到新字段 |
| P1 | XMP 侧车 | 导出时写 XMP、导入时读 XMP；评分/旗标/色标/层级关键词 round-trip | 换工具不丢元数据，是专业用户的底线 |
| P1 | 图库生命周期补全 | 图库合并/拆分、只读引用库、跨库搜索 | PowerPhotos 的强项；拾光已有数据结构，但还差产品化 |
| P2 | 人脸与标签深水区 | 人脸合并/拆分、命名建议、标签纠错/主动学习、宠物本地识别 | 端侧 AI 的“最后一公里”，比换更大模型更能提升感知 |
| P2 | 全库 RAG / MCP | 检索 + 引用来源；MCP Server / Shortcuts / 动作审计 | 把 AI 从“聊天”升级为“可审计的资产代理” |
| P2 | 生成式编辑 | 本地模型可选的“移除”小场景 | 不作为默认云功能；只在隐私定位下做差异 |

**本轮遗留技术债（下一轮应先清理）**

1. 系统图库索引分页尚未接入评分/旗标/色标筛选；当前只支持展示与叠加写入。
2. 智能相簿条件、保存搜索还没有评分/旗标/色标。
3. 保险库尚未做真实大库恢复演练；只有代码级与编译级验证。
4. 查重哈希扫描没有持久化断点；大库中断后需要重新进入补扫。
5. 导入查重只做精确 SHA-256；相似照片不阻止导入，RAW+JPEG / HEIC+JPEG 未自动堆栈。
6. 检查更新只打开发布页；崩溃捕获只有未捕获异常 + 本地日志，没有符号化/上传。
7. 元数据快捷键使用 `⌥` 组合，避免与搜索输入冲突；如果后续做“无修饰键选片”，需要在查看器内单独拦截。

---

## 1. 对比范围与方法

### 1.1 竞品选择

| 产品 | 类型 / 定位 | 选它的原因 | 参考版本 | 资料等级 |
| --- | --- | --- | --- | --- |
| Apple 照片 | 系统内置 | 系统基准；共享、回忆、编辑、iCloud 集成 | macOS 27 | 官方 + 媒体 |
| Google 相册 | 云相册 | 云 + AI 搜索 / 生成式编辑 / 自动成片 | 2026 | 官方 + 媒体 |
| Adobe Lightroom Classic | 专业 DAM + RAW | 元数据、筛选、编辑、打印、插件的完整范式 | 15.x | 官方发行说明 |
| Mylio Photos+ | 本地优先多设备 | 设备网格、Vault、去重、空间、跨端 | v24+ | 官方 |
| Eagle 4 | 素材 / 资产库 | 标签、智能文件夹、颜色搜索、插件、MCP、移动端 | 4.0 | 官方 |
| PowerPhotos 3.5 | macOS 图库工具 | 多库、合并、拆分、跨库搜索、重复检测、元数据批改 | 3.5 | 官方 |
| ACDSee Photo Studio Mac | DAM + 编辑 | 引用浏览、评分/色标、批量、AI 人脸/关键词、生成式 | 26 / 27 | 官方 |
| Immich | 自托管 | 手机备份、多用户、共享、堆栈、层级标签、XMP、API | 2026 | 官方功能页 |
| PhotoPrism | 自托管 | 就地索引、标签、颜色搜索、侧车、秘密链接 | 2026 | 官方功能页 |
| 一刻相册 / 腾讯相册管家 | 国内云相册 | 大众用户的“自动备份 + 共享 + 成片 + 清理”预期 | 2026 | 商店页 + 媒体 |
| 时光相册 | 已停运云相册 | 反面案例：纯云相册的商业与数据风险 | 2023-12 停运 | 媒体 |

> 说明：Apple 照片、Google 相册的部分功能分地区、分账号灰度；ACDSee Mac 27 在 2026-11 处于预售、月底发放；Lightroom 以 Classic 为主，云版 Lightroom 只在“多设备同步 / Web”处补充说明。

### 1.2 为什么不是所有功能都“实测”

这是一份**功能覆盖对比**，用于回答“还缺什么”，不是实验室评测。竞品能力来自官方功能页、发行说明和公开报道；拾光能力来自当前仓库 README 与代码。具体到某个版本、某个地区、某张显卡，实际表现可能不同。文末列出资料出处与待核实项。

### 1.3 拾光能力证据

| 能力 | 证据 |
| --- | --- |
| 产品能力总览 | [README.md](file:///Users/lijialong/Documents/gitlab/photos/README.md) |
| 架构与硬约束 | [AGENTS.md](file:///Users/lijialong/Documents/gitlab/photos/AGENTS.md) |
| 图库与索引 | [LibraryStore.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore.swift)、[MetadataStore.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/MetadataStore.swift) |
| 大图库分页 | [LibraryStore+Paging.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Store/LibraryStore+Paging.swift) |
| 重复检测 | [Duplicates.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Domain/Duplicates.swift)（SHA-256 精确重复 + 感知哈希相似组）、[PerceptualHash.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/LumaCore/PerceptualHash.swift) |
| 导入 | [ImportService.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Import/ImportService.swift)（始终拷贝、UUID 文件名）、[PhotoHasher.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/PhotoHasher.swift)（导入查重与复制后校验） |
| 图库保险库 | [LibraryVaultService.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Library/LibraryVaultService.swift)（SHA-256 清单、备份、校验、恢复） |
| 编辑器 | [PhotoEditor.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Editor/PhotoEditor.swift#L5-L73)（调整、滤镜、裁剪、美化） |
| 端侧智能 | [PhotoIntelligence.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/PhotoIntelligence.swift)、[SigLIPEngine.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/SigLIPEngine.swift) |
| 人脸聚类 | [FaceClustering.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/People/FaceClustering.swift) |
| 系统图库写入 | [PhotoKitBridge.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Media/PhotoKitBridge.swift) |
| AI 助手工具 | [AILibraryTools.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/AI/AILibraryTools.swift) |
| 打包与签名 | [build.sh](file:///Users/lijialong/Documents/gitlab/photos/build.sh)（本地签名 / 可选公证 / 版本检查；无静默自动更新） |
| 影院 / IPTV / 网络资源 | [CinemaScraper.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Cinema/CinemaScraper.swift)、[CinemaLibraryView.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Features/Cinema/CinemaLibraryView.swift)、[IPTVService.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/TV/IPTVService.swift)、[CatalogStore.swift](file:///Users/lijialong/Documents/gitlab/photos/Sources/PhotosClone/Services/Catalog/CatalogStore.swift) |

---

## 2. 拾光当前能力盘点

| 领域 | 已有能力（摘要） | 覆盖度 | 关键实现 / 说明 |
| --- | --- | --- | --- |
| 图库模型 | `.photoslibrary` 包、多图库、最近 10 个、系统图库多连接、每库独立设置 | ● | 库内 `database/`、`originals/`、`resources/`、`cloud/`；单实例单窗口 |
| 导入 | 拖拽、文件面板、剪贴板、PhotoKit、按文件夹建相簿、实况照片配对、并发拷贝、导入查重与校验 | ◐ | 始终拷贝进库、UUID 文件名；导入前 SHA-256 查重 + 空间预检 + 复制后校验；无监控文件夹、无相机卡摄取 |
| 浏览 | 年/月/所有照片、四种网格、缩放、排序、筛选、框选、方向键、悬停元数据 | ● | 5000 张以上下推 SQLite 分页，每页 600；查看器渐进加载与预取 |
| 组织 | 多级相簿/文件夹、拖拽加入、相簿内排序、自定义封面、智能相簿、撤销/重做 | ● | 30 步内存撤销；相簿/文件夹层级完整 |
| 元数据 | 标题、日期、地点、关键词、收藏、隐藏、最近删除、相机/镜头/曝光、评分/旗标/色标、`/` 层级关键词 | ◐ | 评分/旗标/色标已接入网格、信息面板、右键与快捷键；无树状关键词、保存搜索、XMP 写回；批量仅标题/日期/地点 |
| 搜索 | 文件名、标题、相机、地点、场景标签、OCR 文字、人物、时间词、类型限定、跨来源统一搜索 | ● | 中文口语映射；SigLIP 语义向量；相似照片；影院/电视/资源共用 SearchCenter |
| 端侧智能 | SigLIP 2 200+ 中文标签、YOLO11n、Vision OCR/人脸/条码、地标、票据/证件规则 | ● | 全程本机；结果写 `asset_analysis` / `system_analysis` / `cloud_assets` |
| 人物 | 本地人脸聚类、命名、同框、年度轨迹、光线偏好、常去之地、色彩气质 | ● | 系统图库读取官方人物；本地不区分宠物、无人脸合并/拆分 |
| 地点 / 地图 | 地图聚合、地点详情、四季、时段、地标、足迹回放、视野统计 | ● | MapKit；地点摘要由本机派生 |
| 回忆 / 旅行 | 按月/地点/收藏/那年今日、Ken Burns 播放、三种风格、导出 mp4、旅行故事线 | ● | 导出无声；无配乐、无手动编辑行程 |
| 值得重看 | 两年以上且一年未打开、今日重看、按人物/地点/场景/年份拆主体 | ● | 本机派生，不落库 |
| 编辑 | 基础调整、RGB + 单通道曲线、8 色带 HSL、三段色彩分级、径向/线性蒙版、点按修复、镜头畸变与透视、色彩分级、LUT、胶片、移轴/径向虚化、画框、预设与快照、选择性粘贴、分屏对比、直方图与吸管、裁剪拉直 | ● | 非破坏配方与编辑点 JSON；无范围/画笔蒙版、克隆、AI 降噪、镜头配置文件、HDR/全景、色彩管理与外部编辑器 |
| 视频 | 30 种扩展名、AVPlayer、ffmpeg 转码缓存、倍速/连播/画中画/截帧/全屏、HDR/DV 色调映射、字幕、多音轨、章节、播放信息 | ◐ | 播放强；无裁剪、旋转导出、稳定、视频压缩、封面设置 |
| 压缩 / 导出 | 有损/无损压缩、备份与逐字节还原、JPEG/HEIC/PNG/TIFF、尺寸/质量/命名规则 | ● | 无损模式剥离 EXIF/XMP/IPTC/COM；不支持 WebP/AVIF 输出 |
| 打印 / 幻灯片 | 每张一页打印、幻灯片间隔、Ken Burns | ◐ | 无联系表、相册书、版式、打印色彩配置 |
| 系统图库 | 读 `Photos.sqlite`、overlay 补充元数据、PhotoKit 写回编辑/删除/相簿/收藏/隐藏 | ● | 文件夹管理尚未接入；关键词/标题只能 overlay |
| 网络存储 | SMB、WebDAV、阿里云盘、百度网盘、AList；OAuth、钥匙串、服务端缩略图、Range EXIF | ● | SMB/官方网盘只读；WebDAV 可写；分析有每次 120 张、体检 500 张上限 |
| 影院 | TMDB/豆瓣/NFO 刮削、书架/海报墙/卡片/列表、详情、继续观看、多版本、任务中心、多海报、NFO 导出 | ● | 网络影院在线播放仍是占位；蓝光原盘菜单未做 |
| 网络电视 | M3U 频道、分类、频道墙、播放、EPG 节目单、回看 | ● | 录制未做；EPG 只保留近 8 天到未来 3 天 |
| 网络资源 | 多站点聚合、关注、演员/机构资料库 | ● | 与影院/搜索共用入口 |
| AI 助手 | 6 家提供商 + 自定义、26 个工具、19 个写操作确认、对话随库保存、Key 仅钥匙串 | ● | 默认不上传图片；单次最多 40 张候选元数据、可选 6 张缩略图 |
| 性能 | 百万级分页、系统索引、derivatives 复用、3 路缩略图、预热、缓存失效 | ● | 无公开基准与回归测试 |
| 隐私 / 安全 | 本地 AI、Keychain、不写 Apple 原图与 `Photos.sqlite`、AI 默认不发图 | ◐ | 无应用锁、无加密保险库、无锁定文件夹 |
| 产品化 | macOS 14+、SwiftUI、无第三方依赖、中文界面、公证脚本、版本检查、本地诊断 | ◐ | 无静默自动更新、崩溃符号化上传、多语言、完整无障碍审计 |

---

## 3. 总览对比矩阵

### 3.1 图库与生命周期

| 能力项 | 拾光 | Apple 照片 | Google 相册 | Lightroom Classic | Mylio Photos+ | Eagle 4 |
| --- | --- | --- | --- | --- | --- | --- |
| 本地图库 / 包格式 | ● | ● | ○ | ● | ● | ● |
| 多图库并存 / 快速切换 | ● | ◐ | ○ | ◐ | ● | ● |
| 引用原位置、不搬文件 | ◐ | ○ | — | ● | ● | ○ |
| 图库合并 / 拆分 / 迁移 | ○ | ○ | — | ◐ | ◐ | ◐ |
| 图库级备份 / 保险库 | ● | ◐ | ● | ◐ | ● | ○ |
| 完整性校验 / 修复 | ● | ◐ | ● | ◐ | ● | ○ |
| 跨库统一搜索 | ○ | ○ | ● | ◐ | ● | ● |
| 精确重复检测 | ● | ● | ◐ | ● | ● | ● |
| 相似 / 重压缩 / 编辑副本检测 | ● | ◐ | ◐ | ◐ | ● | ● |
| 导入时查重 | ● | ○ | ● | ◐ | ● | ◐ |
| 导入重命名 / 目录规则 | ◐ | ○ | ○ | ● | ◐ | ◐ |
| 自动导入 / 监控文件夹 | ○ | ◐ | ● | ◐ | ● | ◐ |
| 外部编辑器 round-trip | ○ | ○ | — | ● | ◐ | ◐ |
| XMP / EXIF 元数据写回 | ○ | ◐ | ○ | ● | ◐ | ◐ |

> 读表：拾光在“多图库 + 系统图库 + 网盘”三源统一上很强；v1.2 已把**图库级备份/校验、精确与相似查重、导入查重**补齐（●）。仍落后的是**合并/拆分、跨库统一搜索**；引用原位置只覆盖系统图库与只读网盘，尚无本地文件夹引用库。

### 3.2 浏览、组织与搜索

| 能力项 | 拾光 | Apple 照片 | Google 相册 | Lightroom Classic | Mylio Photos+ | Eagle 4 |
| --- | --- | --- | --- | --- | --- | --- |
| 时间轴 / 年视图 | ● | ● | ● | ◐ | ● | ◐ |
| 多种网格（方形/宽高比/瀑布流/列表） | ● | ◐ | ◐ | ◐ | ◐ | ● |
| 地图浏览 | ● | ● | ◐ | ◐ | ● | ○ |
| 人物 / 人脸 | ● | ● | ● | ◐ | ● | ○ |
| 宠物识别 | ◐ | ● | ● | ○ | ◐ | ○ |
| 场景 / 物体标签 | ● | ● | ● | ○ | ● | ◐ |
| OCR 图内文字 | ● | ● | ● | ○ | ● | ◐ |
| 自然语言 / 语义搜索 | ● | ● | ● | ◐ | ● | ◐ |
| 按颜色 / 色调搜索 | ○ | ○ | ○ | ○ | ◐ | ● |
| 相簿 / 文件夹层级 | ● | ● | ● | ● | ● | ● |
| 智能相簿 / 规则筛选 | ● | ● | ◐ | ● | ● | ● |
| 关键词（扁平） | ● | ● | ◐ | ● | ● | ● |
| 层级关键词 | ◐ | ○ | ○ | ● | ◐ | ◐ |
| 评分 / 旗标 / 色标 | ● | ◐ | ○ | ● | ● | ◐ |
| 堆栈 / 虚拟副本 | ◐ | ○ | ○ | ● | ◐ | ○ |
| 连拍 / 相似组 | ● | ● | ◐ | ● | ◐ | ◐ |
| 对比 / 筛选视图 | ◐ | ○ | ○ | ● | ◐ | ◐ |
| 保存搜索 / 搜索历史 | ○ | ◐ | ◐ | ● | ● | ● |
| 多窗口 / 标签页 | ○ | ◐ | ● | ● | ◐ | ● |

> 读表：拾光的“看”和“找”已经很强；v1.2 补齐了**评分/旗标/色标**，层级关键词做到路径存取与展示，连拍自动成组与整理工作室提供有限筛选。仍缺的是**手动堆栈/虚拟副本、Compare/Survey 对比、保存搜索**。

### 3.3 编辑、视频与输出

| 能力项 | 拾光 | Apple 照片 | Google 相册 | Lightroom Classic | Mylio Photos+ | Eagle 4 |
| --- | --- | --- | --- | --- | --- | --- |
| 非破坏性编辑 | ● | ● | ● | ● | ◐ | ◐ |
| 基础调整 | ● | ● | ● | ● | ● | ◐ |
| 曲线 / 色阶 | ◐ | ● | ◐ | ● | ◐ | ○ |
| HSL / 色彩分级 | ● | ● | ◐ | ● | ◐ | ○ |
| 局部蒙版 / 画笔 / 渐变 | ● | ◐ | ● | ● | ◐ | ○ |
| 修复 / 克隆 / 去污 | ● | ● | ● | ● | ◐ | ○ |
| 镜头校正 / 透视 / 几何 | ◐ | ◐ | ◐ | ● | ◐ | ○ |
| RAW 解码 | ● | ● | ◐ | ● | ● | ◐ |
| HDR / 全景合成 | ○ | ○ | ○ | ● | ○ | ○ |
| 生成式编辑（移除/扩展/重绘） | ○ | ● | ● | ● | ○ | ○ |
| 视频播放 | ● | ● | ● | ○ | ● | ● |
| 视频裁剪 / 旋转 / 导出 | ◐ | ◐ | ◐ | ○ | ◐ | ◐ |
| 视频转码 / 格式兼容 | ● | ● | ● | ○ | ◐ | ● |
| 批量导出 | ● | ● | ● | ● | ● | ● |
| 导出相簿层级目录 | ○ | ◐ | ◐ | ◐ | ● | ◐ |
| 打印 / 联系表 / 相册书 | ◐ | ● | ◐ | ● | ◐ | ◐ |
| 幻灯片 / 回忆影片 | ● | ● | ● | ◐ | ● | ○ |
| 影片配乐 | ○ | ● | ● | ◐ | ◐ | ○ |
| 共享相册 / 评论 / 协作 | ○ | ● | ● | ◐ | ◐ | ○ |
| Web 画廊 / 链接分享 | ○ | ◐ | ● | ● | ◐ | ○ |
| 水印 / 社交尺寸 | ○ | ◐ | ◐ | ● | ◐ | ○ |
| 360° / 空间照片 | ○ | ◐ | ◐ | ○ | ◐ | ○ |

> 读表：拾光的编辑已从“完整工作流”走到“专业工具的大半”。v1.3–v1.5 依次补上曲线（RGB + 单通道）、HSL 与三段分级、径向/线性/颜色/亮度/画笔蒙版、修复与克隆、镜头配置与透视、预设/快照/批量、LUT、胶片、虚化、画框、场景推荐、风格混合、电影感向导与海报模板；蒙版与修复两项升到 ●。剩下的 ◐ 是“自动化与色彩管理”：无色阶端点、无主体/天空蒙版、无镜头数据库与色差校正、无 AI 降噪、无软打样与外部编辑器。视频侧仍是播放强、编辑弱（◐，无裁剪导出）。

### 3.4 平台、协作与生态

| 能力项 | 拾光 | Apple 照片 | Google 相册 | Lightroom Classic | Mylio Photos+ | Eagle 4 |
| --- | --- | --- | --- | --- | --- | --- |
| 手机端 / 自动备份 | ○ | ● | ● | ◐ | ● | ◐ |
| 多设备同步 | ○ | ● | ● | ● | ● | ◐ |
| 家庭 / 多用户 / 权限 | ○ | ◐ | ● | ◐ | ◐ | ○ |
| 共享链接 / 外部协作 | ○ | ◐ | ● | ● | ◐ | ○ |
| Web 访问 | ○ | ◐ | ● | ● | ◐ | ○ |
| 端侧 AI / 隐私优先 | ● | ● | ◐ | ◐ | ● | ◐ |
| 云 AI / 生成式能力 | ◐ | ● | ● | ● | ○ | ○ |
| 插件 / 扩展 / MCP | ○ | ◐ | ○ | ● | ◐ | ● |
| Shortcuts / 自动化 | ○ | ● | ○ | ◐ | ◐ | ◐ |
| 多语言 / 国际化 | ○ | ● | ● | ● | ● | ● |
| 无障碍 / VoiceOver | ◐ | ● | ● | ● | ◐ | ◐ |
| 公证 / 自动更新 / 崩溃报告 | ◐ | ● | ● | ● | ● | ● |
| 百万级图库性能 | ● | ● | ● | ● | ◐ | ◐ |
| 网络存储 / NAS | ● | ○ | ○ | ◐ | ● | ○ |
| 系统照片库读写 | ● | — | ○ | ○ | ◐ | ○ |
| 自托管 / 无厂商云 | ● | ◐ | ○ | ◐ | ● | ● |

> 读表：拾光在“隐私、NAS、系统照片库读写、百万级性能”上有独特优势；“公证脚本 + 版本检查 + 本地诊断”已落地（◐，静默更新与崩溃上传仍缺）；“手机、共享、Web、多语言”仍是明显空白，这些空白会直接限制用户规模。

### 3.5 工具、自托管与国内云相册

| 能力项 | 拾光 | PowerPhotos 3.5 | ACDSee Mac 26/27 | Immich | PhotoPrism | 国内云相册 |
| --- | --- | --- | --- | --- | --- | --- |
| 多图库合并 / 拆分 | ○ | ● | ○ | ○ | ○ | ○ |
| 跨库统一搜索 | ○ | ● | ● | ● | ● | ◐ |
| 引用原位置浏览 | ◐ | — | ● | ◐ | ● | ○ |
| 图库级备份 / 保险库 | ● | ◐ | ○ | ◐ | ◐ | ● |
| 精确 / 相似查重 | ● | ● | ● | ● | ● | ◐ |
| 评分 / 旗标 / 色标 | ● | — | ● | ◐ | ◐ | ○ |
| 层级关键词 | ◐ | — | ● | ● | ◐ | ○ |
| XMP / 元数据写回 | ○ | — | ● | ● | ● | ○ |
| 人脸识别 | ● | — | ● | ● | ● | ● |
| OCR / 文字搜索 | ● | — | ◐ | ● | ◐ | ◐ |
| 场景 / 物体识别 | ● | — | ● | ● | ● | ● |
| 批量重命名 / 转换 | ◐ | ○ | ● | ○ | ○ | ○ |
| 手机自动备份 | ○ | — | ○ | ● | ○ | ● |
| 共享相册 / 多人 | ○ | — | ○ | ● | ◐ | ● |
| Web 访问 | ○ | — | ○ | ● | ● | ● |
| 自托管 / 无厂商云 | ● | ● | ● | ● | ● | ○ |
| API / 插件 | ○ | ○ | ◐ | ● | ◐ | ○ |
| 视频编辑 | ○ | — | ○ | ○ | ○ | ◐ |
| 多语言 | ○ | ● | ● | ● | ● | ● |

> 读表：Immich 是“功能最接近 Google 相册的自托管方案”，PhotoPrism 是“最强就地索引 + 标签 + 侧车”，PowerPhotos 是“macOS 图库生命周期工具”，ACDSee 是“引用浏览 + DAM + 编辑”的传统强者。拾光不需要全做，但要知道每一项的“及格线”在哪。

### 3.6 新增产品线快照（v1.2）

v1.1 之后的代码新增了影院、网络电视、网络资源三条产品线，不属于照片竞品矩阵，但会占用同一套来源 / 索引 / 播放 / 任务基础设施，单独列一张状态表：

| 模块 | 能力 | 状态 | 边界 |
| --- | --- | --- | --- |
| 影院 | TMDB / 豆瓣 / NFO 刮削与手动匹配 | ✅ | 支持多候选、整目录刮削、NFO 读取 |
| 影院 | 书架 / 海报墙 / 卡片 / 列表四视图 | ✅ | 顶栏切换并记忆；卡片模式为主卡 + 胶片条 |
| 影院 | 详情页：简介 / 评分 / 资料 / 演职员 / 技术角标 | ✅ | 页面内铺满，含继续播放与进度 |
| 影院 | 多海报切换与「设为封面」 | ✅ | 最多 5 张，左右切换；豆瓣-only 条目仅一张 |
| 影院 | 继续观看 / 观看记录 / 任务中心 | ✅ | 每 10 秒落盘；任务中心合并刮削与其它任务 |
| 影院 | 多版本、收藏 / 想看 / 清单、忽略、删除 | ✅ | 右键菜单与海报墙统一 |
| 影院 | 播放：HDR / DV、字幕、音轨、章节、倍速、画中画 | ✅ | 与图库视频共用播放器；S / A / ⇧⌘I 快捷键 |
| 影院 | NFO 导出 | ✅ | 刮削后按开关自动导出，也可手动立即导出 |
| 影院 | 网络影院在线播放 | ⏳ | 仍是跳转占位，未接入在线片源 |
| 影院 | 蓝光原盘 / ISO 菜单 | ○ | 取决于解码链路，影库层未做 |
| 网络电视 | M3U 频道、分类、频道墙、播放 | ✅ | 与影院共用播放器 |
| 网络电视 | EPG 节目单 / 回看 | ✅ | XMLTV 解析、节目进度、按天回看；只保留近 8 天到未来 3 天 |
| 网络电视 | 录制 | ○ | 未做 |
| 网络资源 | 多站点聚合、关注、演员 / 机构资料库 | ✅ | 本地 SQLite 资料库 + 多站点适配 |

> 影院 UI 规范与 35 屏 mock 见 `docs/cinema-poster-wall/index.html`；IPTV 竞品与方案见 `docs/iptv-competitor-report-2026-11.html`。

---

## 4. 分领域深度对比

**图 2：拾光能力栈与缺口（定性示意）**

<svg viewBox="0 0 900 560" width="100%" role="img" aria-label="拾光能力栈与缺口" xmlns="http://www.w3.org/2000/svg" style="max-width:900px;display:block;margin:12px auto 4px;">
  <rect x="0" y="0" width="900" height="560" rx="18" fill="#FBF8F3"/>
  <text x="36" y="36" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="17" font-weight="700" fill="#2B2620">拾光能力栈：已有能力与主要缺口</text>
  <text x="36" y="58" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#7A7166">实线框 = 已有能力；红色虚线框 = 建议补的缺口。按“来源 → 资产 → 智能 → 体验 → 协作”分层。</text>

  <!-- Layer 1 -->
  <rect x="40" y="86" width="130" height="72" rx="12" fill="#F5D9A8" stroke="#E8A33D"/>
  <text x="105" y="118" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="14" font-weight="700" fill="#8A5A13">来源层</text>
  <text x="105" y="137" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#8A5A13">Source</text>
  <rect x="180" y="86" width="430" height="72" rx="10" fill="#FFFFFF" stroke="#E4DED4"/>
  <text x="196" y="113" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#2B2620">本地图库 · 系统照片 · SMB / WebDAV</text>
  <text x="196" y="134" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#2B2620">阿里云盘 · 百度网盘 · AList</text>
  <rect x="625" y="86" width="235" height="72" rx="10" fill="#FFF5F3" stroke="#FF6B5A" stroke-dasharray="5 5"/>
  <text x="641" y="113" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#A93B2E">手机自动备份 · 云端写回</text>
  <text x="641" y="134" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#A93B2E">离线缓存 · 增量索引</text>

  <!-- Layer 2 -->
  <rect x="40" y="176" width="130" height="72" rx="12" fill="#E2DAFF" stroke="#7B61FF"/>
  <text x="105" y="208" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="14" font-weight="700" fill="#4B35B8">资产层</text>
  <text x="105" y="227" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#4B35B8">Asset</text>
  <rect x="180" y="176" width="430" height="72" rx="10" fill="#FFFFFF" stroke="#E4DED4"/>
  <text x="196" y="203" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#2B2620">SQLite 元数据 · 缩略图 · 编辑配方</text>
  <text x="196" y="224" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#2B2620">相簿 / 文件夹 · 索引 · 派生缓存</text>
  <rect x="625" y="176" width="235" height="72" rx="10" fill="#FFF5F3" stroke="#FF6B5A" stroke-dasharray="5 5"/>
  <text x="641" y="203" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#A93B2E">合并 / 拆分 / 迁移 · 本地引用库</text>
  <text x="641" y="224" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#A93B2E">跨库搜索 · 备份第二目标</text>

  <!-- Layer 3 -->
  <rect x="40" y="266" width="130" height="72" rx="12" fill="#CFF0EC" stroke="#2EC4B6"/>
  <text x="105" y="298" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="14" font-weight="700" fill="#15796F">智能层</text>
  <text x="105" y="317" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#15796F">Intelligence</text>
  <rect x="180" y="266" width="430" height="72" rx="10" fill="#FFFFFF" stroke="#E4DED4"/>
  <text x="196" y="293" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#2B2620">SigLIP2 · YOLO · Vision OCR / 人脸</text>
  <text x="196" y="314" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#2B2620">地标 · 票据 / 证件 · AI Agent</text>
  <rect x="625" y="266" width="235" height="72" rx="10" fill="#FFF5F3" stroke="#FF6B5A" stroke-dasharray="5 5"/>
  <text x="641" y="293" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#A93B2E">宠物 · 人脸合并 · 标签纠错</text>
  <text x="641" y="314" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#A93B2E">全库 RAG · 本地 LLM</text>

  <!-- Layer 4 -->
  <rect x="40" y="356" width="130" height="72" rx="12" fill="#D6E8FA" stroke="#4A90E2"/>
  <text x="105" y="388" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="14" font-weight="700" fill="#245C99">体验层</text>
  <text x="105" y="407" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#245C99">Experience</text>
  <rect x="180" y="356" width="430" height="72" rx="10" fill="#FFFFFF" stroke="#E4DED4"/>
  <text x="196" y="383" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#2B2620">四种网格 · 查看器 · 编辑器</text>
  <text x="196" y="404" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#2B2620">地图 · 人物 · 回忆 · 重看</text>
  <rect x="625" y="356" width="235" height="72" rx="10" fill="#FFF5F3" stroke="#FF6B5A" stroke-dasharray="5 5"/>
  <text x="641" y="383" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#A93B2E">堆栈 / 对比 / 保存搜索</text>
  <text x="641" y="404" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#A93B2E">视频裁剪导出 · 软打样 / 外部编辑</text>

  <!-- Layer 5 -->
  <rect x="40" y="446" width="130" height="72" rx="12" fill="#FFD9D3" stroke="#FF6B5A"/>
  <text x="105" y="478" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="14" font-weight="700" fill="#A93B2E">协作层</text>
  <text x="105" y="497" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#A93B2E">Collaboration</text>
  <rect x="180" y="446" width="430" height="72" rx="10" fill="#FFFFFF" stroke="#E4DED4"/>
  <text x="196" y="473" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#2B2620">导出 · 打印 · 幻灯片 · 系统分享</text>
  <text x="196" y="494" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#2B2620">压缩 · 备份副本</text>
  <rect x="625" y="446" width="235" height="72" rx="10" fill="#FFF5F3" stroke="#FF6B5A" stroke-dasharray="5 5"/>
  <text x="641" y="473" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#A93B2E">共享相册 · Web 画廊 · 评论</text>
  <text x="641" y="494" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="12" fill="#A93B2E">手机端 · 多用户 · 水印 / 相册书</text>

  <text x="36" y="545" font-family="-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif" font-size="11" fill="#A3988A">结论：拾光的“中段”很厚（来源、资产、智能、体验），两端偏薄（摄取与协作）。资产层已补上备份 / 校验 / 查重，接下来优先“协作层”，再补“体验层”的专业化。</text>
</svg>

### 4.1 图库模型与资产安全

**拾光现状**

- `.photoslibrary` 包，多图库、最近 10 个、系统图库多连接；同一时间只渲染一个当前图库。
- 自建库的所有导入都拷贝进库，原文件用 UUID 重命名；不支持“本地文件夹引用库”（系统图库与只读网盘属于引用式访问）。
- 已有图库保险库：对 `originals` / `database` / `resources/renders` 生成 SHA-256 清单，支持备份、逐文件校验、恢复缺失/损坏文件，损坏文件先移入 `vault-quarantine`；缩略图 / 转码缓存视为可重建数据不纳入备份。
- 删除会清理原图、实况配对、缩略图、渲染副本、转码缓存、压缩备份、网盘缩略图和分析结果，这一点做得比多数竞品细。

**竞品做法**

- PowerPhotos：多库管理、合并、拆分、跨库搜索、重复检测、批量元数据、按相簿层级导出。
- Mylio：设备网格 + Vault + SecureCloud，强调“云可选、离线可用、自动多副本”。
- Immich：数据库自动备份、外部只读库、存储模板、API、监控。
- Lightroom Classic：目录备份、目录修复、XMP 侧车、引用原文件。
- PhotoPrism：就地索引，不搬文件；侧车与 WebDAV。

**差距**

1. 保险库仍是手动触发的单库方案：没有定时备份、第二目标（外置盘 / NAS）与逐资产备份状态。
2. 校验只覆盖保险库清单内的文件；孤儿缩略图、数据库与文件不一致、磁盘坏块还没有并入统一“图库体检 2.0”。
3. 没有库合并/拆分/迁移：多库用户只能手动搬。
4. 没有跨库搜索：多库是“切换”，不是“统一”。
5. 没有引用库：想管理现有文件夹的用户被“必须导入”挡在门外。

**建议**

- 保险库已落地（快照清单 + 校验 + 恢复）；下一步补第二目标（外置盘 / NAS / WebDAV）、定时备份与恢复演练。
- 把“图库体检”从“模糊/相似/大视频”扩展到“缺失原图、孤儿文件、数据库完整性、缩略图失效、备份状态”。
- 增加“库合并/拆分”和“只读引用库”，至少让用户能把旧库并进来、把归档库挂进来。
- 跨库搜索可以后做，但索引结构要提前留好“库 ID”维度。

### 4.2 导入与摄取

**拾光现状**

- 拖拽、文件面板、剪贴板、PhotoKit 选择、按文件夹建相簿、实况照片配对、并发拷贝与批量落盘。
- 始终拷贝，UUID 文件名；导入前 SHA-256 查重（图库 + 本批）、磁盘空间预检、复制后哈希校验，进度显示跳过 / 失败 / 已校验数量；不写回 EXIF。仍没有监控文件夹、相机卡摄取、Tethered Capture。
- 支持保留上层目录结构（导入选项），但没有“重命名模板 / 备份到第二目标”；导入后校验已具备。

**竞品做法**

- Lightroom：导入预设、重命名模板、第二副本、版权/关键词、自动导入、Tethered Capture。
- Mylio：自动按日期/文件夹整理、去重、从硬盘/卡/手机/扫描仪导入。
- ACDSee：不导入，直接浏览文件夹；批量重命名/缩放/转换；Mobile Sync。
- Apple / Google：手机自动备份，用户零操作。
- Eagle：浏览器扩展、剪贴板、批量保存、拖拽。

**差距**

- 没有“导入工作流”，只有“导入文件”。
- 没有相机卡 / 手机入口，新增资产的第一公里缺失。
- 已有 SHA-256 导入查重与复制后校验；仍缺按感知哈希拦截“相似但非精确”的重复。
- 没有 RAW+JPEG、HEIC+JPEG 配对堆栈；只有实况照片配对。
- 没有时区修正、拍摄日期纠错、文件名模板。

**建议**

- 做“导入预设”：目标相簿/文件夹、重命名模板、第二副本、关键词/版权、导入后校验。
- SHA-256 导入查重与复制后校验已落地；下一步把感知哈希也纳入“相似但非精确”的询问/跳过。
- 增加“监控文件夹”和“相机卡/手机局域网导入”；先做增量导入，不必做全量同步。
- 把 RAW+JPEG、HEIC+JPEG 自动配成堆栈，减少网格噪音。

### 4.3 浏览与性能

**拾光现状**

- 年/月/所有照片，四种网格（方形、完整宽高比、瀑布流、列表），缩放、排序、筛选、框选、方向键、悬停元数据。
- 5000 张以上下推 SQLite 分页，每页 600；查看器渐进加载、相邻预取；系统图库复用 `derivatives`；百万级图库有明确设计。
- 单实例、单窗口；没有标签页、分屏、第二显示器、对比视图。

**竞品做法**

- Apple 照片：系统级流畅、年/月/日、搜索即缩略图、幻灯片、共享。
- Lightroom：Grid / Loupe / Compare / Survey、第二显示器、筛选栏、胶片条。
- ACDSee：Tabs、Home Page、Activity Manager、Split View Before/After。
- Eagle：悬停预览、空格预览、新窗口打开、多种布局、颜色搜索。
- Mylio：日历、地图、空间、跨设备优化预览。

**差距**

- 没有 Compare / Survey，选片效率低。
- 没有标签页 / 多窗口 / 第二屏，跨相簿对照困难。
- 没有“快速预览”（空格）与“参考图”模式。
- 没有公开的性能基准与回归测试，百万级优势难以证明。

**建议**

- 增加“对比视图”（2–4 张，缩放/平移同步）和“筛选视图”（Pick/Reject）。
- 增加标签页、分屏、第二显示器；至少支持“在新窗口打开”。
- 建立 1 万 / 10 万 / 100 万三档基准库，固定测首屏、滚动、搜索、冷启动、内存。
- 把“年/月”总览的视觉优势继续保持，这是拾光相对 Lightroom 的差异化。

### 4.4 组织与元数据

**拾光现状**

- 多级相簿/文件夹、拖拽加入、相簿内排序、自定义封面、智能相簿、关键词、收藏、隐藏、最近删除、撤销/重做。
- 批量更改只有标题、拍摄日期、地点；关键词支持 `/` 层级路径的存取与展示，并可在整理工作室批量增删；评分 / 旗标 / 色标已完整接入网格、信息面板、右键与快捷键。仍缺同义词、树状编辑与保存搜索。
- 智能相簿条件很丰富：媒体类型、收藏、已编辑、关键词、相机、镜头、地点、定位、日期、像素、大小、文件名、时长、场景、图内文字；尚未包含评分 / 旗标 / 色标 / 备份状态。

**竞品做法**

- Lightroom：星级、旗标、色标、层级关键词、收藏夹/智能收藏、堆栈、虚拟副本、保存的筛选、XMP。
- ACDSee：评分、色标、分类、关键词、地点、批量元数据、保存搜索、Reject Tag。
- Mylio：评分、关键词、分类、空间、日历、地图、去重。
- Eagle：标签、文件夹、智能文件夹、评分、颜色搜索、注释、自动标签。
- Immich：层级标签、收藏、堆栈、归档、XMP 侧车。

**差距**

- 决策字段已补齐（评分 / 旗标 / 色标），但系统图库索引分页与智能相簿条件还没吃这些字段，选片工作流仍有一段落差。
- 关键词有 `/` 路径但缺树状编辑与父级自动补全，无法稳定表达“地点 > 城市 > 区县”。
- 连拍已自动成组；但没有手动堆栈与虚拟副本，RAW+JPEG、编辑副本仍会散落。
- 没有保存搜索，复杂条件每次重搭。
- 元数据不能写回文件，换工具就丢。

**建议**

- 评分 + 旗标 + 色标 + 层级关键词展示已完成；下一步补保存搜索、树状关键词编辑与同义词。
- 增加“堆栈/虚拟副本”，并在网格里以堆栈首图呈现。
- 引入 XMP 侧车读写，至少支持导出时写、导入时读；不要直接改原图 EXIF，除非用户明确选择。
- 智能相簿增加“评分/旗标/色标/堆栈/是否有编辑/是否已备份”条件。

### 4.5 搜索与发现

**拾光现状**

- 文件名、标题、相机、地点、场景标签、OCR 文字、人物、时间词、类型限定、中文口语映射。
- SigLIP 语义向量支持“海边日落”“吃火锅”“一个女孩”这类查询；“查找相似照片”按余弦相似度。
- 已有跨来源统一搜索（本地库 / 系统库 / 网盘 / 影院 / 电视 / 资源）；仍缺多图库容器同时搜索、颜色/色调搜索、保存搜索/搜索历史与命中解释。

**竞品做法**

- Apple：Spotlight 重建索引、自然语言、搜索即缩略图、人物/地点/场景。
- Google：Ask Photos 对话式搜索、Gemini 编辑、自然语言理解、跨设备。
- Lightroom：元数据/关键词/收藏/智能收藏，精确但不懂语义。
- Mylio：Dynamic Search + 1000+ SmartTags + OCR。
- Eagle：AI Search（语义/以图搜图/跨源）、颜色搜索、智能文件夹。
- PhotoPrism：标签、地点、分辨率、颜色、色度、质量过滤。
- Immich：CLIP 语义搜索、人脸、OCR、地图。

**差距**

- 跨来源（图库 / 系统库 / 网盘 / 影院 / 电视 / 资源）已经能一起搜；“多个图库容器同时搜”仍缺。
- 没有颜色/色调/构图搜索，而这是设计/灵感类用户的高频需求。
- 没有保存搜索/搜索历史，重复查询成本高。
- 没有“为什么命中”的解释，用户不敢信语义结果。

**建议**

- 建“全局搜索索引”：库 ID + 来源 + 资产 ID，先支持本地库 + 系统库 + 已挂载网盘。
- 增加颜色搜索（主色/色调/黑白）与“相似构图”。
- 搜索结果展示命中原因：场景标签、OCR 片段、人物、地点、相似度。
- 保存搜索与搜索历史，允许一键变成智能相簿。

### 4.6 端侧 AI 与人物

**拾光现状**

- SigLIP 2 图文模型 + 200+ 中文标签；YOLO11n 确认猫、狗、汽车、披萨等主体；Vision 负责 OCR、人脸、人体姿态、二维码、票据/证件规则；地标表按 GPS 就近匹配。
- 人脸聚类：`VNDetectFaceRectanglesRequest` + 人脸裁剪 + 相似度分配，人物页有命名、同框、年度轨迹、光线偏好、常去之地、色彩气质。
- 宠物只在系统图库读取官方结果；本地 SigLIP / YOLO 能打出猫狗标签，但本机人脸聚类不区分宠物。
- 没有标签纠错、主动学习、人脸合并/拆分、命名建议。

**竞品做法**

- Apple / Google：人脸、宠物、场景、OCR、自然语言，模型与体验成熟。
- Mylio：1000+ SmartTags、人脸、OCR、Dynamic Search。
- ACDSee：AI 人脸（可批量接受/拒绝）、AI 关键词、AI 相似分组、反向图搜。
- Immich：CLIP、人脸、OCR、堆栈。
- PhotoPrism：标签、人脸、地点、颜色/色度/质量。

**差距**

- 人脸“最后一公里”不足：不能合并重复人物、拆分错误聚类、批量确认建议。
- 标签是“只读结果”：用户不能纠正“这不是猫”，模型不会从纠正中学习。
- 本机宠物聚类缺失（系统图库宠物相簿可读）；没有视频关键帧分析；没有多语言标签。
- 没有端侧 LLM，语义搜索是“标签匹配”，不是“理解+推理”。

**建议**

- 先做人脸 UX：合并、拆分、批量确认、隐藏、命名建议；这比换更大模型更能提升感知。
- 给标签加“确认/否定/改标签”，把用户反馈写回本地，做轻量主动学习。
- 加宠物模型与视频关键帧分析；视频只分析 3–5 帧即可覆盖大部分场景。
- 端侧 LLM 可作为可选插件，先不做默认。

### 4.7 地点、旅行与回忆

**拾光现状**

- 地图聚合、单张图钉、视野统计、地点详情（到访轨迹、四季、时段、地标、同框、色彩气质、年度高光）、足迹回放（统一时钟、镜头、光点、胶片颗粒、日期水印）、旅行自动分段、回忆影片、那年今日、值得重看。
- 回忆影片支持三种风格、导出 mp4，但无声；旅行不能手动编辑行程；足迹不能导出 GPX。

**竞品做法**

- Apple：回忆、幻灯片配乐、保存为视频、共享相册、地点。
- Google：自动成片、Photo to Video、拼图、Mood、Wardrobe、共享。
- Mylio：日历、地图、家庭历史元数据、幻灯片。
- Immich：Memories、地图、相册、共享。
- 国内云相册：AI 分类、照片故事、一键短视频、共享相册。

**差距**

- 情感表达层很强，但“成品”不够：没有配乐、旁白、模板、转场编辑。
- 旅行/足迹不能手动修正，自动化失败时用户无法接管。
- 没有通知/小组件/屏保等“被动重看”入口。
- 没有协作回忆（多人往同一段旅行里加照片/留言）。

**建议**

- 做“故事工作室”：配乐、旁白、标题卡、模板、横竖版、社交尺寸；先支持本地音频。
- 旅行/足迹支持手动合并、拆分、改起止、加/删站点、导出 GPX。
- 增加“那年今日”通知、菜单栏/小组件、Apple TV 屏保（可选）。
- 共享回忆：只读链接 + 允许被邀请者上传，是分享与回忆的交叉点。

### 4.8 编辑

**拾光现状**

- 非破坏配方：旋转、翻转、裁剪/比例、拉直、滤镜、曝光、亮度、对比、饱和、高光、阴影、色温、色调、锐化、暗角、降噪、自动增强、美化建议；曲线（RGB + 单通道）、HSL、色彩分级、径向/线性/颜色/亮度/画笔蒙版、修复与克隆、镜头配置与透视、LUT、胶片、虚化、画框全部写进同一份 `EditState` JSON。
- RAW 走 `CIRAWFilter`，支持 DNG/CR2/CR3/NEF/ARW/RAF/ORF/RW2 等；复制/粘贴编辑点（支持按分类选择性粘贴）；编辑器有独立调整历史与多份快照；`直方图` 带高光/阴影剪切提示，吸管可读 HEX 与 RGB；长按按钮、按住 `\` 或分屏可对比原图。
- 预设：9 套内置风格 + 自定义保存 / 导入导出 / 强度混合，支持两套风格按比例混合、按场景自动推荐，并可套用到选中的多张照片；电影感向导与 5 套海报模板可直接出分享图；仍没有色阶输入输出端点、主体/天空蒙版、AI 降噪、镜头数据库与色差校正、HDR/全景、双重曝光、肤色精修、文字与拼图、软打样、外部编辑器与 XMP。

**竞品做法**

- Lightroom：完整 RAW、曲线、HSL、颜色分级、蒙版、修复、镜头/透视、HDR/全景、AI 降噪、预设、历史、外部编辑、打印/相册书。
- ACDSee：RAW、颜色/色调轮、Light EQ、蒙版（主体/背景/天空/颜色/亮度）、克隆、AI 预设、前后对比、生成式。
- Apple：曲线、可选颜色、修饰、Clean Up、Extend、Spatial Reframing。
- Google：Magic Editor、Magic Eraser、Portrait Light、Photo Unblur、生成式。
- Mylio：AutoEnhance、AutoColor、裁剪、白平衡、色调、颜色、暗角、降噪、锐化、预设。

**差距**

- 拾光已具备专业工具的大半，但与顶级工具的差距集中在“自动化与色彩管理”：没有色阶端点、主体/天空识别蒙版、镜头数据库与色差校正、AI 降噪、HDR/全景。
- 创意侧仍缺天空替换、双重曝光、肤色精修、文字/拼图与真实胶片纹理；生成式仍是空白。
- 没有色彩管理（软打样、ICC、广色域导出）与外部编辑器 round-trip——如果目标包含摄影爱好者，这是硬伤。

**建议**

- 第一阶段（v1.3–v1.5 已完成）曲线、HSL、分级、径向/线性/颜色/亮度/画笔蒙版、修复与克隆、镜头预设、预设/快照/批量、LUT、胶片、虚化、画框、场景推荐、风格混合、电影感与海报模板。
- 第二阶段做“主体/天空蒙版 + 色阶端点 + 镜头数据库 + 色差校正 + AI 降噪”。
- 第三阶段做“天空替换 + 双重曝光 + 肤色精修 + 文字/拼图 + 版本快照持久化”。
- 第四阶段做“外部编辑器 + XMP 互通 + 色彩管理 + 本地生成式”。
- 生成式编辑只做“本地模型可选”，不作为默认云功能；否则与隐私定位冲突。

### 4.9 视频

**拾光现状**

- 30 种视频扩展名；AVPlayer 原生解码 H.264/HEVC/ProRes/MPEG-4/VP8/VP9/AV1；系统不支持时用 ffmpeg 转码为 H.264 + AAC MP4 并缓存；播放器支持倍速、连播、循环、填充/适应、旋转显示、画中画、截帧、全屏、音量、上一个/下一个、可拖动控制条。
- 已补齐 HDR 检测与 libplacebo 色调映射、杜比视界、内封/外挂/在线字幕、多音轨、章节、播放信息；仍没有视频裁剪、旋转导出、稳定、慢动作编辑、音频编辑、视频压缩、视频封面设置。

**竞品做法**

- Apple：视频裁剪、旋转、滤镜、慢动作、回忆配乐。
- Google：视频裁剪、稳定、滤镜、Photo to Video。
- Immich：硬件转码、HDR 播放、Motion Photos。
- PhotoPrism：FFmpeg 按需转码、缩略图抽帧。
- Lightroom：不处理视频。

**差距**

- 播放强，编辑弱：用户拍的长视频无法在拾光里剪短、转竖屏、换封面。
- HDR / 杜比视界的色调映射已在播放侧落地；HDR 导出与编辑仍缺。
- 没有视频压缩，和照片压缩能力不匹配。
- 没有视频关键帧分析，视频在语义搜索里是“黑盒”。

**建议**

- 做“视频快速编辑”：入点/出点、裁剪、旋转、封面帧、导出 H.264/HEVC、压缩。
- HDR / 杜比视界的色调映射已在播放侧落地；下一步补 HDR 导出与编辑。
- 视频分析抽 3–5 帧，复用照片的场景/OCR/人脸管线。
- 视频回忆支持配乐与转场，和照片回忆共用“故事工作室”。

### 4.10 输出、分享与协作

**拾光现状**

- 导出原格式或 JPEG/HEIC/PNG/TIFF，质量、最长边、文件名规则；视频原文件；实况照片带配对视频；压缩有损/无损；打印每张一页；幻灯片；回忆导出 mp4；系统 `ShareLink` 分享文件。
- 没有共享相册、评论、反应、只读 Web 画廊、链接权限/过期、水印、社交尺寸预设、相簿层级导出、拼图、相册书、联系表、影片配乐。

**竞品做法**

- Apple：iCloud 共享相册（macOS 27 全分辨率、表情回应、Android/Windows 可参与）、幻灯片配乐并保存为视频、相册书。
- Google：共享相册/对话、链接分享、拼图、Photo to Video、Wardrobe、Mood。
- Lightroom：Web 画廊、共享相册、打印/相册书、水印、导出预设。
- Immich：共享相册、公开链接、评论/活动、多用户、锁定文件夹。
- PhotoPrism：相册秘密链接、过期时间、WebDAV。
- 国内云相册：共享相册、AI 成片、一键分享。

**差距**

- 拾光的“整理”很强，“给别人看”很弱。
- 没有链接权限/过期，分享只能发文件，不能发“会更新的相册”。
- 没有评论/反应，家庭共享场景缺失。
- 没有水印/社交尺寸，摄影师交付与社交媒体发布不方便。
- 没有相簿层级导出，迁移到其他工具困难。

**建议**

- 把“分享”做成一级入口：只读 Web 相册、链接权限（公开/密码/过期）、评论/反应、下载原图开关。
- 增加水印/社交尺寸预设、相簿层级导出、拼图/联系表。
- 共享相册优先支持“局域网/NAS 托管”，避免自建公网服务。
- 与“回忆/旅行”打通：分享一段旅行故事，而不是一堆文件。

### 4.11 网络存储与云

**拾光现状**

- SMB、WebDAV、阿里云盘、百度网盘、AList；OAuth 2.0 桌面授权；钥匙串；服务端缩略图；WebDAV Range 读 EXIF；SMB 直接读挂载文件；云端 EXIF、场景、人脸、体检、美化、重复、值得重看都有派生；WebDAV 可新建/重命名/上传/删除。
- SMB 与官方网盘只读；分析每次最多 120 张、体检最多 500 张；缩略图缓存，不缓存原图；无后台同步/离线缓存/增量索引。

**竞品做法**

- Mylio：NAS 作为 Vault、设备网格、优化预览、离线访问。
- Immich：外部只读库、存储模板、硬件转码、数据库备份。
- PhotoPrism：就地索引、WebDAV、按需转码。
- Lightroom：网络卷上的目录/原文件。
- Eagle：库可放外置盘，第三方云同步。

**差距**

- “能连”但“不能当主库”：没有持久索引、离线缓存、写入、后台同步。
- 大目录分析有上限，用户不知道还剩多少、什么时候完成。
- 没有“NAS 作为保险库”的备份/恢复闭环。
- 没有多用户/权限，NAS 家庭共享场景缺失。

**建议**

- 做“NAS 保险库”：备份/恢复/校验，优先 WebDAV/SMB。
- 做“离线缓存 + 增量索引”：常用目录保留缩略图与元数据，原图按需拉取。
- 对可写协议（WebDAV）支持元数据/相册写回；SMB/官方网盘保持只读但明确提示。
- 把分析上限改成“可续跑 + 进度 + 预估”，不要硬截断。

### 4.12 系统照片库集成

**拾光现状**

- 直接打开 `.photoslibrary` 作为当前图库；读 `Photos.sqlite`；拾光补充元数据写 `database/PhotosClone.sqlite` 的 `asset_overlays`；真实写入走 PhotoKit（编辑、删除、相簿、收藏、隐藏）；复用 `resources/derivatives`；多连接、只读解析、扫描边读边显示、载入上限、连拍快照、重复项目只读处理。
- 文件夹管理未接入；关键词/标题 PhotoKit 不开放，只能 overlay；共享图库/iCloud 状态未明确覆盖。

**竞品做法**

- PowerPhotos：多库、合并、拆分、跨库搜索、重复、元数据批改、按相簿层级导出。
- Apple：原生。
- Mylio：导入 Apple 图库/文件夹。
- 其他竞品基本不碰系统图库。

**差距**

- 这是拾光的独特护城河，但“最后一公里”还没走完：文件夹管理、共享图库、iCloud 优化存储、权限失败恢复。
- 系统图库的“体检/清理”能力受只读限制，用户容易误解“为什么不能删”。
- 没有“把拾光库导出回系统照片”的一键通道。

**建议**

- 把“Apple 照片最佳伴侣”作为明确卖点：多库管理、跨库搜索、重复清理、只读分析、PhotoKit 安全写回。
- 补文件夹管理验证与共享图库支持；对 iCloud 优化存储给出明确状态。
- 增加“导出到系统照片”与“从系统照片增量导入”的双向通道。

### 4.13 AI 助手与代理

**拾光现状**

- 26 个工具：检索/浏览、选择/打开、相簿、文件夹、图片与视频、压缩、美化、最近删除；19 个写操作需确认；不支持永久删除、导入、编辑原图；系统图库/网盘/官方库按权限矩阵限制。
- 6 家提供商 + 自定义 OpenAI 兼容；Key 仅钥匙串；对话随库保存；默认不发图；单次最多 40 张候选元数据，可选 6 张 1024px 缩略图。

**竞品做法**

- Google：Ask Photos 对话式搜索、Gemini 编辑、Photo to Video。
- Apple：Apple Intelligence 编辑、搜索索引、共享相册。
- Lightroom：AI 降噪、生成式移除/扩展、Assisted Culling。
- Eagle：AI Search、AI Action、AI Models、MCP/Skill、插件中心。
- ACDSee：AI 关键词、人脸、相似分组、反向图搜、生成式。
- Mylio：SmartTags、Dynamic Search。

**差距**

- 没有全库 RAG：助手只能看 40 张候选，不能“基于我 10 万张照片回答并给出来源”。
- 没有自然语言修图：能压缩/美化，不能“把这张调成胶片感、去掉左边的人”。
- 没有视频理解；没有 MCP/Shortcuts/插件；没有动作审计与一键回滚。
- 没有本地 LLM 选项；云端模型意味着元数据出本机（虽然默认不发图）。

**建议**

- 做“可审计的资产代理”：动作日志、批量操作预览、一键回滚、按库/按用户配额。
- 做 MCP Server / Shortcuts：让外部 Agent 能安全调用“搜索、建相簿、加关键词、导出”，这是比聊天更长期的价值。
- 全库 RAG 先做“检索 + 引用来源”，不要做“凭记忆回答”。
- 本地小模型先做“查询解析/标签纠错/标题生成”，不要硬上本地多模态大模型。

### 4.14 平台、分发与产品化

**拾光现状**

- macOS 14+、SwiftUI、无第三方依赖、中文界面；单实例单窗口；已有本地/开发者签名、可选公证脚本、版本检查与本地诊断；仍无静默自动更新、崩溃符号化上传、多语言、完整无障碍审计。
- 代码规范清晰，架构分层好；发布工程只到“脚本打包 + 手动安装”，还缺发布通道与可观测性。

**竞品做法**

- 所有商业竞品：多语言、公证、自动更新、崩溃报告、App Store/官网分发、隐私政策、帮助文档、教程。
- Eagle：插件中心、MCP、移动端、社区。
- Mylio：多平台、订阅/买断、Vault 硬件生态。

**差距**

- 用户不敢长期用：还没有公证后的正式分发通道、静默自动更新与崩溃上传；出问题只能靠本地日志导出。
- 非中文用户无法使用；无障碍不完整。
- 没有发布节奏与回滚机制。

**建议**

- 已有公证脚本、版本检查、隐私清单与本地诊断；产品化清单剩下：Sparkle 式静默更新、opt-in 崩溃上传、App Sandbox 评估、英文界面、VoiceOver 审计。
- 建立发布通道：稳定版/测试版、迁移回滚、数据库升级演练。
- 做“首次启动 5 分钟”引导：建库/打开系统库/导入/备份，一次讲清。

---

## 5. 差距清单（可执行）

> 优先级口径：**P0** 现在不做会直接影响数据安全、核心留存或可交付性；**P1** 明显提升竞争力；**P2** 差异化/锦上添花。成本：**S** 模块内改动；**M** 新表/新服务/新 UI；**L** 跨层或新子系统；**XL** 新模型/新平台/长期投入。

### A. 资产安全与图库生命周期

> v1.2 状态：✅ A1 保险库、✅ A2 完整性校验、✅ A3 查重升级已落地；A7 的导入查重 / 空间预检 / 复制后校验已完成，监控文件夹与相机卡仍缺。⏳ 仍缺：A4 合并/拆分、A5 本地引用库、A6 跨库搜索。

| ID | 缺口 | 用户影响 | 竞品参照 | 建议 | 优先级 | 成本 |
| --- | --- | --- | --- | --- | --- | --- |
| ✅ A1 | 图库保险库：备份/恢复/第二副本 | 不敢把十年照片交给你 | Mylio Vault、Immich DB Backup | 快照清单 + 校验和 + 外置盘/NAS/WebDAV 目标 + 恢复演练 | P0 | L |
| ✅ A2 | 完整性校验：缺失原图/孤儿文件/DB 不一致 | 坏了不知道，知道也修不了 | Mylio、Lightroom 目录修复 | 体检 2.0 + 一键修复 + 报告导出 | P0 | M |
| ✅ A3 | 查重升级：pHash + 相似 + 导入查重 | 重压缩/缩放/轻编辑副本漏检 | PowerPhotos、Lr 15.4、Immich、ACDSee | 感知哈希 + 相似堆栈 + 导入默认查重 | P0 | M |
| A4 | 图库合并/拆分/迁移 | 多库用户只能手动搬 | PowerPhotos | 合并预览、冲突处理、相簿/元数据保留 | P1 | L |
| A5 | 只读引用库（不搬文件） | 现有文件夹用户被挡在门外 | Lightroom、ACDSee、PhotoPrism | 引用库 + 只读标记 + 缩略图缓存 | P1 | L |
| A6 | 跨库/跨来源统一搜索 | 多库/多源不能一起找 | PowerPhotos、Mylio、Immich | 全局索引（库 ID + 来源 + 资产 ID） | P1 | L |
| A7 | 导入工作流：重命名/目录/监控/相机卡/校验 | 导入是体力活，容易出错 | Lightroom、Mylio、ACDSee | 导入预设 + 监控文件夹 + 卡/手机入口 | P1 | M |

### B. 元数据与专业工作流

> v1.2 状态：✅ B1 评分/旗标/色标已完成；◐ B2 只完成层级关键词的路径存取/展示与批量增删，树状编辑、同义词、保存搜索仍缺；◐ B5 有整理工作室分布筛选与连拍组内挑选，Compare/Survey 仍缺；◐ B4 只有连拍自动成组。⏳ 仍缺：B3 XMP、B4 手动堆栈/虚拟副本、B6 版本、B7 外部编辑器。

| ID | 缺口 | 用户影响 | 竞品参照 | 建议 | 优先级 | 成本 |
| --- | --- | --- | --- | --- | --- | --- |
| ✅ B1 | 评分/旗标/色标 | 无法快速选片/交付 | Lightroom、ACDSee、Mylio、Eagle | 键盘 1–5、P/X、6–9 色标；筛选与智能相簿 | P0 | S |
| ◐ B2 | 层级关键词/同义词/保存搜索 | 关键词越多越乱，复杂条件每次重搭 | Lightroom、ACDSee、Mylio | 树状关键词 + 同义词 + 保存搜索 | P0 | M |
| B3 | XMP/EXIF 读写与元数据导出 | 换工具就丢元数据 | Lightroom、ACDSee、Immich、PhotoPrism | XMP 侧车导入/导出；不默认改原图 | P1 | M |
| B4 | 堆栈/虚拟副本 | RAW+JPEG、连拍、编辑副本散落 | Lightroom、Immich、PhotoPrism | 自动堆栈 + 手动堆栈 + 虚拟副本 | P1 | M |
| B5 | 对比/筛选/连拍挑选 | 选片效率低 | Lightroom Compare/Survey、ACDSee Reject | 2–4 张对比、P/X、自动前进 | P1 | M |
| B6 | 版本历史/快照 | 调坏了回不去 | Lightroom、ACDSee | 编辑快照 + 命名版本 + 对比 | P1 | M |
| B7 | 外部编辑器 round-trip | 无法接 Photoshop/Affinity | Lightroom、ACDSee | 导出 TIFF/PSD、回写渲染副本 | P1 | M |

### C. 编辑与视频

> v1.5 状态：C1–C5 已具备专业工作流（RGB + 单通道曲线、8 色带 HSL 与三段色彩分级、径向/线性/颜色/亮度/画笔蒙版、修复 + 克隆、镜头预设与透视），并补齐预设、快照、选择性粘贴、分屏对比、吸管、拉直、LUT、胶片、虚化、画框、场景推荐、风格混合、电影感向导与海报模板；C6 视频裁剪导出、C7 生成式仍未做。

| ID | 缺口 | 用户影响 | 竞品参照 | 建议 | 优先级 | 成本 | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | 曲线/色阶 | 影调控制不足 | Lightroom、Apple、ACDSee | RGB/单通道曲线 + 直方图 | P1 | M | ◐ RGB + 单通道曲线 + 剪切提示；色阶端点待补 |
| C2 | HSL/色彩分级 | 风格化能力不足 | Lightroom、Apple、ACDSee | HSL + 阴影/高光色轮 | P1 | M | ● 8 色带 HSL + 三段色彩分级 |
| C3 | 局部蒙版/画笔/渐变 | 不能局部调整 | Lightroom、ACDSee、Google | 主体/天空/画笔/线性/径向/颜色/亮度范围 | P1 | L | ● 径向/线性/颜色/亮度/画笔；主体与天空待补 |
| C4 | 修复/克隆 | 不能去污/去物 | Lightroom、ACDSee、Apple | 修复画笔 + 克隆 + 内容感知（可选） | P1 | M | ● 点按修复 + 手动采样克隆；内容感知待补 |
| C5 | 镜头校正/透视/几何 | 广角/建筑照片不正 | Lightroom、ACDSee | 镜头配置文件 + 自动/手动透视 | P1 | M | ◐ 手动畸变 + 透视 + 自动拉直 + 镜头预设 |
| C6 | 视频快速编辑：裁剪/旋转/封面/导出/压缩 | 长视频无法处理 | Apple、Google、Immich | 入出点 + 裁剪 + 旋转 + 封面 + H.264/HEVC 导出 | P0 | M | ⏳ 未开始 |
| C7 | 生成式编辑（移除/扩展/重绘） | 与 Apple/Google/Lr 有代差 | Apple、Google、Lightroom、ACDSee | 本地模型可选，不做默认云；先做“移除”小场景 | P2 | XL | ⏳ 未开始 |

### D. 分享、协作与多端

> v1.2 状态：D 组全部未开始——没有共享相册、评论、只读 Web 画廊、手机入口、多用户与移动端。这是当前最大的产品短板。

| ID | 缺口 | 用户影响 | 竞品参照 | 建议 | 优先级 | 成本 |
| --- | --- | --- | --- | --- | --- | --- |
| D1 | 共享相册/评论/反应 | 只能发文件，不能一起看 | Apple、Google、Immich | 共享相册 + 评论/表情 + 下载开关 | P0 | L |
| D2 | 只读 Web 画廊/链接权限/过期 | 不能发“会更新的相册” | Google、Lightroom、PhotoPrism | 局域网/NAS 托管的只读 Web + 密码/过期 | P1 | M |
| D3 | 手机入口/局域网增量导入 | 新照片进不来 | Apple、Google、Eagle Viewer、ACDSee | 伴侣 App 或局域网导入 + 增量 + 查重 | P0 | L |
| D4 | 多用户/家庭权限 | 家庭共享做不了 | Google、Immich | 用户/角色/相册权限；先做“家庭成员”轻量版 | P2 | L |
| D5 | 水印/社交尺寸/拼图/相册书/联系表 | 交付/发布不方便 | Lightroom、Apple、Google | 导出预设 + 水印 + 拼图 + 联系表 | P1 | M |
| D6 | 相簿层级导出/影片配乐 | 迁移/表达不完整 | PowerPhotos、Apple、Google | 按相簿层级导出 + 回忆配乐/旁白 | P1 | S |

### E. 搜索与 AI

> v1.2 状态：◐ E6 有候选编号引用与工具结果，但没有全库 RAG / 向量检索；其余 E1–E5、E7 未开始。

| ID | 缺口 | 用户影响 | 竞品参照 | 建议 | 优先级 | 成本 |
| --- | --- | --- | --- | --- | --- | --- |
| E1 | 颜色/色调搜索 | 设计/灵感用户找不到“同色系” | Eagle、PhotoPrism | 主色/色调/黑白/饱和度过滤 | P1 | S |
| E2 | 人脸合并/拆分/命名确认 | 人物聚类错误无法修 | ACDSee、Apple、Google | 合并/拆分/批量确认/隐藏 | P1 | M |
| E3 | 标签纠错/主动学习 | 错标不能改，模型不会变好 | ACDSee、Mylio | 确认/否定/改标签 + 本地反馈 | P1 | M |
| E4 | 宠物本地识别 | 宠物照片无法按宠物聚合 | Apple、Google、Mylio | 宠物检测 + 聚类 + 命名 | P2 | M |
| E5 | 视频关键帧分析 | 视频在语义搜索里是黑盒 | Immich、PhotoPrism | 抽 3–5 帧复用照片管线 | P2 | M |
| E6 | 全库 RAG/引用来源 | 助手只能看 40 张候选 | Google Ask Photos | 检索 + 引用 + 分页迭代 | P1 | L |
| E7 | MCP/Shortcuts/插件/动作审计 | 无法接外部 Agent，动作不可回滚 | Eagle MCP、Lightroom 插件 | MCP Server + Shortcuts + 动作日志/回滚 | P1 | M |

### F. 平台与产品化

> v1.2 状态：◐ F2 部分完成（公证脚本、版本检查、本地诊断/导出），静默自动更新与崩溃符号化上传仍缺；F1、F3–F6 未开始。

| ID | 缺口 | 用户影响 | 竞品参照 | 建议 | 优先级 | 成本 |
| --- | --- | --- | --- | --- | --- | --- |
| F1 | 多语言（先英文） | 非中文用户无法用 | 所有竞品 | 字符串抽取 + 英文翻译 + 日期/数字格式 | P1 | M |
| F2 | 公证/自动更新/崩溃报告 | 不敢长期用，出问题无法定位 | 所有商业竞品 | 公证 + Sparkle + opt-in 崩溃收集 | P0 | M |
| F3 | 无障碍/VoiceOver | 部分用户无法使用 | Apple、Lightroom | 完整标签 + 键盘全操作 + 高对比度 | P1 | M |
| F4 | 多窗口/标签页/第二屏 | 跨相簿对照困难 | ACDSee Tabs、Lightroom | 标签页 + 分屏 + 第二显示器 | P1 | M |
| F5 | 性能基准/回归测试 | 百万级优势无法证明 | Lightroom、Apple | 1 万/10 万/100 万基准库 + CI 指标 | P1 | S |
| F6 | 隐私清单/沙盒/数据导出清单 | 企业/合规用户不放心 | 商业竞品 | 隐私清单 + 沙盒评估 + 全库导出清单 | P1 | S |

---

## 6. 建议路线（按结果分阶段）

> 不给时间承诺，只给“做完什么算完成”。

### Phase 1：可信赖（本轮已完成 MVP）

**目标**：用户敢把十年照片交给拾光。

**范围**：A1、A2、A3、B1、B2、F2。

**交付物**

- 图库保险库：第二副本、校验和、恢复向导、恢复演练报告。
- 图库体检 2.0：缺失原图、孤儿文件、DB 完整性、缩略图失效、备份状态。
- 查重 2.0：pHash + 相似堆栈 + 导入查重。
- 评分/旗标/色标 + 层级关键词 + 保存搜索。
- 公证、自动更新、崩溃报告。

**完成标准**

- 删除原图/损坏缩略图/断电后，能按报告恢复并校验通过。
- 10 万张库的查重召回率与误报率达到可公布基准。
- 评分/关键词/筛选可以完成一次 1000 张的选片工作流。
- 新用户从下载到打开图库不需要看文档。

> v1.2 完成情况：保险库（备份 / 逐文件校验 / 恢复）、查重 2.0（pHash 相似组）、导入查重与复制后校验、评分/旗标/色标与层级关键词展示、整理工作室、更新检查/本地诊断/公证脚本已落地。B2 的树状关键词与保存搜索、系统图库分页筛选、智能相簿元数据条件、静默自动更新仍未完成，已列入 0.5 的技术债。影院 / IPTV / 网络资源是与本路线并行落地的另一条产品线，见 0.0.1 与 3.6。

### Phase 2：可协作（下一轮）

**目标**：照片能进来、能出去、能一起看。

**范围**：D1、D2、D3、C6、A7、E1、E2、E3。

**交付物**

- 共享相册：链接权限、密码、过期、评论/反应、下载开关。
- 只读 Web 画廊：局域网/NAS 托管。
- 手机入口：伴侣 App 或局域网增量导入 + 查重。
- 视频快速编辑：裁剪/旋转/封面/导出/压缩。
- 导入预设 + 监控文件夹 + 相机卡导入。
- 颜色搜索 + 人脸合并/拆分 + 标签纠错。

**完成标准**

- 一次家庭旅行的照片可以从手机进、在 Mac 整理、发链接给家人评论。
- 1000 张手机照片导入成功率、查重率、耗时达到可公布基准。
- 一段 5 分钟视频可以剪成 30 秒并导出。

### Phase 3：专业化

**目标**：进阶用户/摄影爱好者愿意长期使用。

**范围**：C1–C5、B3–B7、A4–A6、F1、F3、F4。

**交付物**

- 编辑进阶与工作流已提前落地（曲线、HSL、分级、蒙版、修复、镜头/透视、预设、LUT、胶片、虚化、画框、快照与分屏）；本阶段补色阶端点、范围蒙版、画笔、克隆、镜头配置文件与 AI 降噪。
- XMP 侧车、堆栈/虚拟副本、对比/筛选、版本历史、外部编辑器。
- 图库合并/拆分、只读引用库、跨库搜索。
- 英文界面、VoiceOver、标签页/分屏/第二屏。

**完成标准**

- 一次 500 张 RAW 的选片、调色、导出可以全程在拾光完成。
- XMP 在 Lightroom / ACDSee / 拾光之间 round-trip 不丢关键词/评分。
- 多库用户可以在一个搜索框里找到所有库的照片。

### Phase 4：AI 深化

**目标**：形成“个人记忆图谱 + 可审计代理”的差异化。

**范围**：E5、E6、E7、D5、D6、C7（可选）。

**交付物**

- 全库 RAG：检索 + 引用来源 + 分页迭代。
- MCP Server / Shortcuts / 插件；动作日志与回滚。
- 视频关键帧分析、宠物识别、故事工作室（配乐/旁白/模板）。
- 本地生成式“移除”小场景（可选）。

**完成标准**

- 助手回答“去年在海边拍的狗”能列出照片并给出来源。
- 外部 Agent 可以通过 MCP 完成“建相簿 + 加关键词 + 导出”并可回滚。
- 一段旅行可以一键生成带配乐/标题的横竖版视频。

---

## 7. 容易被忽略的细节清单

| 领域 | 已有 | 部分 / 缺失（建议补） |
| --- | --- | --- |
| 导入 | 拖拽/文件/剪贴板/PhotoKit、实况配对、按文件夹建相簿、保留上层结构、SHA-256 查重、空间预检、复制后校验 | 相机卡摄取、监控文件夹、RAW+JPEG/HEIC+JPEG 配对、时区修正、断点续传、只读源提示 |
| 元数据 | 标题、日期、地点、关键词、收藏、隐藏、相机/镜头/曝光、评分/旗标/色标、`/` 层级关键词展示 | 同义词、树状关键词编辑、版权/作者、EXIF 写回、XMP 侧车、保存搜索、批量重命名、元数据导入/导出 |
| 浏览 | 四种网格、缩放、排序、筛选、框选、方向键、悬停信息 | 空格快速预览、标签页、分屏、第二屏、Compare/Survey、缩放对齐、参考图、直方图、颜色取样、裁剪叠加、网格叠加 |
| 搜索 | 文件名/标题/相机/地点/场景/OCR/人物/时间/类型、跨来源统一搜索 | 多图库同时搜、颜色/色调、拼音/错别字、否定词、同义词、组合条件、保存搜索、搜索历史、命中解释 |
| 人物 | 本地聚类、命名、同框、年度轨迹、光线偏好、常去之地、色彩气质、系统图库宠物相簿 | 合并/拆分、命名建议、批量确认、隐藏人物、本机宠物聚类、年龄变化、关系图谱、隐私开关 |
| 地图 | 聚合、图钉、视野统计、地点详情、足迹回放、旅行分段 | 离线地图、批量定位、拖动改点、轨迹编辑、GPX 导出、隐私打码、地点合并/拆分 |
| 编辑 | 基础调整、拉直、RGB + 单通道曲线、8 色带 HSL、三段色彩分级、径向/线性/颜色/亮度/画笔蒙版、点按修复与克隆、镜头预设/暗角/透视、LUT、胶片、虚化、画框、9 套预设 + 自定义预设、场景推荐、风格混合、电影感向导、海报模板、快照/选择性粘贴/分屏/吸管 | 色阶端点、主体/天空蒙版、镜头数据库与色差、AI 降噪、HDR/全景、天空替换、双重曝光、肤色精修、文字/拼图、持久化版本、软打样、外部编辑器与 XMP |
| 视频 | 30 种格式、倍速/连播/画中画/截帧/全屏、ffmpeg 转码、HDR/DV 色调映射、字幕、多音轨、章节 | 裁剪、旋转导出、封面帧、慢动作、稳定、音频编辑、压缩、视频关键帧分析、360/空间视频 |
| 输出 | 原格式/JPEG/HEIC/PNG/TIFF、质量/尺寸/命名、视频原文件、实况配对 | 文件名冲突策略、相簿层级导出、元数据保留开关、色彩配置、水印、社交尺寸、拼图、联系表、相册书、打印色彩配置 |
| 可靠性 | SQLite、迁移、缓存清理、压缩备份、删除清理清单、图库保险库（备份/校验/恢复）、导入查重与校验 | 真实大库恢复演练、DB 修复、孤儿清理、迁移回滚、索引重建、磁盘满提示、日志、崩溃符号化报告 |
| 安全 | Keychain、本地 AI、不写 Apple 原图/`Photos.sqlite`、AI 默认不发图 | 应用锁、锁定文件夹、加密保险库、云 AI 数据边界提示、日志脱敏、沙盒评估、隐私清单 |
| 国际化/无障碍 | 中文界面、部分 `accessibilityLabel`、动效预设 | 英文/多语言、RTL、完整 VoiceOver、键盘全操作、高对比度、减少动效审计 |
| 性能 | 百万级分页、系统索引、derivatives 复用、缩略图缓存 | 可重复基准、首屏/滚动/搜索延迟指标、内存峰值、冷启动、索引速度、CI 回归 |
| 平台 | macOS 14+、SwiftUI、Apple Silicon 原生、本地签名 / 可选公证、版本检查 | 静默自动更新、崩溃符号化上传、App Store / 官网分发、Intel 兼容声明 |
| 协作 | 系统分享文件 | 共享相册、评论/反应、链接权限/过期、多用户/家庭、活动日志、通知 |
| 影院 | 刮削（TMDB/豆瓣/NFO）、四视图、详情、继续观看、多版本、任务中心、多海报、NFO 导出 | 网络影院在线播放、蓝光原盘菜单 |
| 网络电视 | M3U 频道、分类、频道墙、播放、EPG 节目单、回看 | 录制 |
| 网络资源 | 多站点聚合、关注、演员/机构资料库 | 更多站点、跨站统一搜索 |

---

## 8. 竞品速写：各自最值得学的一件事

| 产品 | 强项 | 弱项 | 对拾光的启示 |
| --- | --- | --- | --- |
| Apple 照片 | 系统集成、共享相册、回忆、编辑、iCloud | 只服务 Apple 生态；专业元数据弱 | 共享/回忆/幻灯片是“大众刚需”；macOS 27 补星级评分说明评分不是专业专属 |
| Google 相册 | Ask Photos、生成式编辑、自动成片、跨设备 | 云锁定、隐私顾虑、无本地库 | 对话式搜索会成为预期；拾光可用“本地检索 + 引用”做差异化 |
| Lightroom Classic | 元数据、选片、RAW、蒙版、打印、插件 | 学习曲线、目录制、无视频 | 专业工作流的深度是护城河；拾光只需补“最小闭环”，不必全量 |
| Mylio Photos+ | 本地优先多设备、Vault、去重、空间、OCR | 界面/生态相对小众；高级功能订阅 | “云可选 + 多副本 + 跨设备”是可信赖的范式；NAS 是拾光的天然盟友 |
| Eagle 4 | 标签/智能文件夹/颜色搜索/插件/MCP/移动端 | 不是照片管理（无地点/人物/回忆）；编辑弱 | 插件、MCP、移动端能显著扩展边界；颜色搜索值得抄 |
| PowerPhotos 3.5 | 多库、合并/拆分、跨库搜索、重复、批量元数据、相簿层级导出 | 只服务 Apple 图库；无 AI | 图库生命周期本身就是产品；拾光可以做得更深 |
| ACDSee Mac | 引用浏览、评分/色标、批量、AI 人脸/关键词、蒙版、生成式 | 界面老派、生态偏 Windows；订阅/买断争议 | “不导入、直接浏览文件夹”是强需求；评分/色标/批量是及格线 |
| Immich | 自托管、手机备份、多用户、共享、堆栈、层级标签、XMP、API | 需要服务器运维；视频/编辑弱 | 功能上最接近“完整替代品”；拾光可做“单用户、Mac 原生、零运维”的版本 |
| PhotoPrism | 就地索引、标签、颜色/色度搜索、侧车、秘密链接 | 无原生移动端；交互偏 Web | 就地索引 + 侧车 + 颜色搜索是“资产库”的核心细节 |
| 国内云相册 | 自动备份、共享、AI 成片、清理、低门槛 | 隐私/关停风险、无本地控制 | 大众要的是“零操作备份 + 一键分享 + 自动成片”；时光相册停运是纯云模式的反面教材 |

---

## 9. 结论与建议

### 9.1 拾光的护城河

1. **多来源统一**：本地库 + 系统照片库 + NAS/网盘，共用一个整理与搜索心智。竞品要么只做本地，要么只做云，要么只做 Apple 图库。
2. **端侧智能 + 隐私**：SigLIP 2 / YOLO / Vision / 人脸 / OCR 全在本机；在“不想上传”的用户群里，这是硬差异。
3. **深度派生洞察**：人物、地点、旅行、重看、足迹回放、体检、美化。这些不是滤镜，是“让照片重新被看见”。
4. **系统照片库深集成**：读 `Photos.sqlite` + overlay + PhotoKit 写回。这是 macOS 上很难被复制的工程能力。
5. **百万级性能**：分页、索引、derivatives 复用、预热、缓存失效，说明架构上已经为大库设计。
6. **可执行的 AI 代理**：26 个工具、写操作确认、Keychain、按库隔离。比“只会聊天的助手”更实用。

### 9.2 不建议做的事

- **不要自建公网云相册**：存储、带宽、合规、多用户、CDN 是无底洞；用 NAS/WebDAV/对象存储做后端。
- **不要追生成式修图**：Apple/Google/Lightroom/ACDSee 已经把“移除/扩展/重绘”做成标配；拾光做不过，也没必要。
- **不要做全量专业 DAM**：Lightroom 的目录、插件、打印、色彩管理是几十年积累；拾光只补“选片 + 元数据 + 基础调色”的最小闭环。
- **不要为了“功能多”牺牲本地优先**：拾光的用户价值是“我的照片在我的盘上，AI 在我机器上”。云功能必须是可选。

### 9.3 如果只做三件事

1. ✅ **图库保险库 + 完整性校验 + 查重 2.0**：解决“敢不敢用”——v1.2 已完成，下一层是定时备份与真实大库恢复演练。
2. ◐ **评分/旗标/色标 + 层级关键词 + 保存搜索**：解决“能不能整理”——前三项已完成，还差树状关键词与保存搜索。
3. ⏳ **共享相册/只读 Web + 手机增量导入**：解决“能不能给家人看、新照片能不能进来”——仍未开始，是当前最大短板。

### 9.4 如果只做一件事

**把“给别人看”做出来：共享相册 / 只读 Web 画廊 + 手机入口。**  
资产安全已经补上第一层，整理字段也已就位；接下来决定产品规模的是“新照片能不能进来、家人能不能一起看”。

---

## 10. 附录

### 10.1 评级口径

- `●`：原生支持，功能完整，达到主流可用水平。
- `◐`：支持但有限，或需要手动步骤，或只覆盖部分场景。
- `○`：没有原生能力，需要外部工具/插件/脚本。
- `—`：产品定位不同，不适用。
- 表格是“功能覆盖”，不是“质量评分”；同一符号在不同产品上不代表同等体验。

### 10.2 主要资料来源

**Apple 照片**

- [在 Mac 上使用“照片”中的共享相簿（Apple 支持）](https://support.apple.com/zh-cn/124160)
- [macOS 27: What's new for the Photos app?（9to5Mac，2026-09-17）](https://9to5mac.com/2026/09/17/macos-27-whats-new-for-the-photos-app/)
- [macOS 27 Photos App New Features（Gadget Hacks）](https://apple.gadgethacks.com/news/macos-27-photos-app-new-features-whats-confirmed/)
- [Apply curves adjustments to a photo in Photos on Mac（Apple 支持）](https://support.apple.com/en-ph/guide/photos/pht7875d6b19/8.0/mac)
- [新一代 Apple Intelligence 今日推出（Apple Newsroom，2026-09）](https://www.apple.com/tw/newsroom/2026/09/next-generation-of-apple-intelligence-available-today/)

**Google 相册**

- [5 Google Photos updates to make the most of summer memories（Google Blog）](https://blog.google/products-and-platforms/products/photos/google-photos-updates/)
- [使用“问问 Google 相册”功能进行搜索、编辑和获取帮助（Google 支持）](https://support.google.com/photos/answer/15318661?hl=zh-Hans)
- [Set up partner sharing（Google 支持）](https://support.google.com/photos/answer/7378858?hl=en&co=GENIE.Platform%3DDesktop)
- [Hide sensitive photos & videos in Locked Folders（Google 支持）](https://support.google.com/photos/answer/10694388?hl=en)
- [Google Photos AI Features (2026 Guide)（FreakyJolly）](https://freakyjolly.com/google-photos-ai-features/)

**Lightroom**

- [Adobe Lightroom desktop release notes（2026-08）](https://helpx.adobe.com/in/lightroom/desktop/introduction/release-notes.html)
- [Adobe Lightroom Classic release notes](https://helpx.adobe.com/in/lightroom-classic/desktop/introduction-to-lightroom-classic/release-notes.html)
- [Lightroom Classic 15.4 duplicate detection（Lightroom Tools）](https://lightroom-tools.com/blog/lightroom-classic-duplicate-photos)
- [How to Master Lightroom Assisted Culling in 2026（Imagen）](https://imagen-ai.com/valuable-tips/adobe-lightroom-assisted-culling/)

**Mylio**

- [Mylio Features](https://mylio.com/features/)
- [Mylio SecureCloud](https://mylio.com/secure-cloud/)
- [Mylio Quick Start Guide v24.5（PDF）](https://download.mylio.com/QuickStart/mylio_photos_quickstart_guide_v24.5.pdf)
- [Mylio AI Face Recognition](https://mylio.com/face-recognition/)

**Eagle**

- [Eagle 4 官方站](https://en.eagle.cool/)
- [Eagle 4 Highlights](https://en.eagle.cool/blog/post/eagle4)
- [Eagle Viewer（App Store）](https://apps.apple.com/ca/app/eagle-viewer/id6751750244)

**PowerPhotos**

- [PowerPhotos 3.5（Fat Cat Software）](https://www.fatcatsoftware.com/powerphotos/)

**ACDSee**

- [ACDSee Photo Studio for Mac 27](https://www.acdsee.com/en/products/photo-studio-mac/)
- [ACDSee Photo Studio for Mac Features](https://www.acdsee.com/en/products/photo-studio-mac/features/)

**Immich / PhotoPrism**

- [Immich Features](https://immich.app/features/)
- [Immich Partner Sharing](https://docs.immich.app/features/partner-sharing/)
- [Immich Sharing](https://docs.v3.0.3.archive.immich.app/features/sharing/)
- [PhotoPrism Features](https://www.photoprism.app/features)

**国内云相册**

- [一刻相册（App Store）](https://apps.apple.com/cn/app/%E4%B8%80%E5%88%BB%E7%9B%B8%E5%86%8C-%E7%99%BE%E5%BA%A6%E7%BD%91%E7%9B%98%E5%87%BA%E5%93%81/id1467852587)
- [腾讯相册管家（App Store）](https://apps.apple.com/cn/app/%E8%85%BE%E8%AE%AF%E7%9B%B8%E5%86%8C%E7%AE%A1%E5%AE%B6-%E6%99%BA%E8%83%BD%E5%AE%89%E5%85%A8%E5%90%8C%E6%AD%A5%E6%95%B0%E6%8D%AE/id1139101653)
- [字节跳动关闭时光相册（36氪，2023-11）](https://www.36kr.com/p/2522317356492549)

### 10.3 待核实项

以下项目会随版本、地区、账号灰度变化，正式对外发布前建议逐项复核：

1. Apple 照片 macOS 27 的 Clean Up / Extend / Spatial Reframing 在中国区、Intel Mac 上的可用性。
2. Google 相册 Ask Photos、Gemini 编辑、Photo to Video、Wardrobe 的地区与账号条件。
3. Lightroom Classic 15.4 重复检测的“精确像素匹配”边界与 15.4.1 修复范围。
4. ACDSee Mac 27 的实际发售日、功能完整度与订阅/买断条款。
5. Eagle Mobile Companion / Eagle Viewer 的同步方式、平台覆盖与是否依赖第三方云。
6. Mylio Photos+ 的 SecureCloud / Mylio Drive / Vault 具体容量与地区可用性。
7. Immich / PhotoPrism 的版本差异（本文按 2026 官方功能页，未逐版本回归）。
8. 国内云相册的免费容量、压缩策略、关停/迁移条款。

### 10.4 版本记录

| 版本 | 日期 | 变更 |
| --- | --- | --- |
| v1.0 | 2026-11-18 | 初稿：能力盘点、竞品矩阵、差距清单、路线建议 |
| v1.1 | 2026-11-18 | 本轮落地保险库、查重 2.0、导入增强检测、元数据工作流、产品化；补充下一轮建议与技术债 |
| v1.2 | 2026-11-23 | 代码全量复核：确认保险库/校验/查重/导入查重/评分旗标色标/层级关键词展示/公证脚本已落地；修正矩阵与 4.x 中过时描述；新增 0.0.1 复核表与 3.6 影院 / IPTV / 网络资源快照；更新 9.3/9.4 结论 |
| v1.3 | 2026-11-24 | 编辑深度落地：曲线（RGB）、8 色带 HSL、径向/线性局部蒙版、点按修复、镜头畸变与透视、前后对比、实时直方图；同步 0.0.2 落地表、能力矩阵、3.3 编辑对比、4.8、C 组与最终清单 |
| v1.4 | 2026-11-24 | 编辑工作流与风格：单通道曲线、三段色彩分级、预设/批量/快照、选择性粘贴、分屏、吸管与剪切提示、拉直与自动水平、LUT、胶片、虚化、画框；同步 0.0.3、矩阵、3.3、4.8、C 组与版本记录 |
| v1.5 | 2026-11-24 | 专业蒙版与创意模板：颜色/亮度/画笔蒙版、克隆、镜头预设与暗角校正、场景推荐、风格混合、电影感向导、5 套海报模板与导出；同步 0.0.4、3.3、C 组与最终清单 |

---

> 本文所有“拾光已有能力”均以当前仓库 README 与代码为依据；“竞品能力”以官方功能页/发行说明/公开报道为依据。若与最新版本不一致，以官方最新资料为准。
