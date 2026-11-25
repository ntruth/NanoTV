import SwiftUI
import AppKit

enum SettingsKeys {
    /// 设置窗口当前停留的分页：其它入口可以先写入目标页再打开设置。
    static let selectedTab = "settings.selectedTab"
    /// 是否在侧边栏显示「网络电视」：关闭后整个入口隐藏，频道也不参与搜索。
    /// 这一项同时也是「网络电视」模块的总开关（`AppModule.television`）。
    static let showTelevision = "settings.modules.television"
    /// 其余模块开关：图库（始终开启，仅占位）/ 网络存储 / 网络资源 / 网络影院。
    static let moduleLibraries = "settings.modules.library"
    static let moduleCloud = "settings.modules.cloud"
    static let moduleCatalog = "settings.modules.catalog"
    static let moduleCinema = "settings.modules.cinema"
    static let appearance = "settings.appearance"
    static let accent = "settings.accent"
    static let photoOpenMode = "settings.photoOpenMode"
    static let viewerLayout = "settings.viewerLayout"
    static let showInfoOnOpen = "settings.showInfoOnOpen"
    static let viewerFilmstrip = "settings.viewerFilmstrip"
    /// 查看器是否用当前照片的模糊影像铺满舞台背景。
    static let viewerBackdrop = "settings.viewerBackdrop"
    static let grouping = "settings.grouping"
    /// 网格堆叠形态（关闭 / 仅连拍 / 连拍与同场景）。
    static let stackMode = "settings.stackMode"
    static let thumbSize = "settings.thumbSize"
    /// 网络影院海报每行张数（默认 8）。
    static let cinemaGridColumns = "settings.cinemaGridColumns"
    /// 新打开的侧边栏页面（媒体类型 / 相簿 / 文件夹…）图片列表默认每行张数。
    static let defaultGridColumns = "settings.defaultGridColumns"
    /// 相簿 / 媒体类型 / 场景 / 更多项目等卡片墙默认每行张数。
    static let defaultCardColumns = "settings.defaultCardColumns"
    /// 每个侧边栏页面各自的卡片墙每行张数，JSON 字典。
    static let cardColumns = "settings.cardColumns"
    /// 旧版按 pt 记录页面尺寸；改为按「每行张数」后每个图库执行一次清理。
    static let gridColumnsMigration = "settings.gridColumnsMigration"
    /// 每个侧边栏页面各自的缩略图尺寸（滑杆位置），JSON 字典。
    static let thumbSizes = "settings.thumbSizes"
    static let thumbnailAspect = "settings.thumbnailAspect"
    static let albumDisplayStyle = "settings.albumDisplayStyle"
    static let sortKey = "settings.sortKey"
    /// 「位置」页的地点聚合层级（省 / 市 / 区县 / 街道）。
    static let placeGranularity = "settings.placeGranularity"
    /// 「人物」页的聚合筛选（全部 / 已命名 / 待命名 / 宠物）。
    static let peopleFilter = "settings.peopleFilter"
    /// 「人物」总览的头像形状（圆形 / 圆角方形）。
    static let peopleDisplayStyle = "settings.peopleDisplayStyle"
    /// 「整理工作室」的浏览维度（评分 / 旗标 / 色标 / 关键词）。
    static let organizeDimension = "settings.organizeDimension"
    /// 「个人收藏」的浏览方式（全部 / 年 / 类型 / 地点 / 相机 / 人物）。
    static let favoritesViewMode = "settings.favoritesViewMode"
    /// 侧边栏当前停留的页面：下次打开从这个页面继续。
    static let sidebarItem = "settings.sidebarItem"
    static let motion = "settings.motion"
    static let cardCornerRadius = "settings.cardCornerRadius"
    static let hoverLift = "settings.hoverLift"
    static let metadata = "settings.metadata"
    static let sortAscending = "settings.sortAscending"
    static let autoPlayVideo = "settings.autoPlayVideo"
    static let autoPlayNextVideo = "settings.autoPlayNextVideo"
    static let viewFullHDR = "settings.viewFullHDR"
    static let videoMuted = "settings.video.mutedByDefault"
    static let videoLoop = "settings.video.loopByDefault"
    /// 视频快进 / 快退的步长（秒）：图库视频用 ↑ / ↓，网络资源用 ← / →。
    static let videoSeekStep = "settings.video.seekStep"
    /// 视频控制条的位置：底部悬浮 / 顶栏融合。
    static let videoControlPlacement = "settings.video.controlPlacement"
    /// HDR / 杜比视界片源的播放策略：自动 / 映射到 SDR / 保持原样。
    static let videoHDRMode = "settings.video.hdrMode"
    /// 网络缓冲档位：省流 / 均衡 / 流畅。
    static let videoBufferProfile = "settings.video.bufferProfile"
    /// 远端弱网自适应：网络变慢时临时降档，恢复后回到所选档位。
    static let videoAdaptiveBuffering = "settings.video.adaptiveBuffering"
    /// 视频转码 / 边下边播缓存的总容量上限（GB）。
    static let videoCacheLimitGB = "settings.video.cacheLimitGB"
    /// 按片源帧率切换显示器刷新率（24p → 24Hz）。
    static let videoMatchDisplayRate = "settings.video.matchDisplayRate"
    /// 高倍速播放时保持音调不变。
    static let videoPreservePitch = "settings.video.preservePitch"
    /// 音轨在一次 HLS 会话里全部装好，切换时不重启转码。
    static let videoInstantAudioSwitch = "settings.video.instantAudioSwitch"
    /// 多声道输出：自动保留源声道 / 强制立体声。
    static let audioDownmix = "settings.video.audioDownmix"
    /// 重编码目标编码：兼容 H.264 / 高效 HEVC / 低功耗 HEVC。
    static let videoTranscodeMode = "settings.video.transcodeMode"
    /// 画面显示方式：适应 / 填充 / 拉伸 / 原始像素。
    static let videoFramingMode = "settings.video.framingMode"
    /// 显示层比例预设：源比例 / 16:9 / 4:3 / 2.35:1 / 1:1。
    static let videoAspectPreset = "settings.video.aspectPreset"
    /// 比例裁剪后的平移（-1...1）。
    static let videoPanX = "settings.video.panX"
    static let videoPanY = "settings.video.panY"
    /// 每部影片记住的手动字幕选择。
    static func rememberedSubtitle(_ photoID: String) -> String {
        "settings.video.subtitleMemory.\(photoID)"
    }
    /// 本地 / SMB 视频自动挂载内嵌字幕轨。
    static let videoAutoEmbeddedSubtitles = "settings.video.autoEmbeddedSubtitles"
    /// 自动挂载视频同目录下的同名外挂字幕。
    static let videoAutoSiblingSubtitles = "settings.video.autoSiblingSubtitles"
    /// 播放后自动在线搜索并匹配一条字幕。
    static let videoAutoOnlineSubtitles = "settings.video.autoOnlineSubtitles"
    /// 把播放状态交给系统「正在播放」，支持控制中心与键盘媒体键。
    static let videoSystemMediaIntegration = "settings.video.systemMediaIntegration"
    /// 进度条悬停 / 拖动时显示该时间点的画面预览。
    static let videoScrubPreview = "settings.video.scrubPreview"
    /// 网络资源海报缓存上限（GB）。
    static let posterCacheLimitGB = "settings.catalog.posterCacheLimitGB"
    /// 缓存上限默认值迁移标记（海报 10 GB / 视频 50 GB）。
    static let cacheLimitDefaultsVersion = "settings.cacheLimitDefaults.v2"
    /// 外挂字幕字号。
    static let subtitleFontSize = "settings.video.subtitleFontSize"
    /// 默认音轨偏好：original（原声）/ zh / en。
    static let videoPreferredAudio = "settings.video.preferredAudio"
    /// 默认字幕策略：auto（自动挂载）/ off（不自动挂）。
    static let videoPreferredSubtitle = "settings.video.preferredSubtitle"
    /// 退出时记住倍速。
    static let videoRememberSpeed = "settings.video.rememberSpeed"
    /// 上次使用的倍速。
    static let videoLastSpeed = "settings.video.lastSpeed"
    /// 优先系统硬解：关闭后强制走转封装 / 软解路径。
    static let videoPreferHardwareDecoding = "settings.video.preferHardwareDecoding"
    /// 是否允许画中画。
    static let videoPiPEnabled = "settings.video.pipEnabled"
    /// 全局跳过片头秒数：剧集没有单独设置时用它兜底。
    static let cinemaSkipIntroSeconds = "settings.cinema.skipIntroSeconds"
    /// 全局跳过片尾秒数。
    static let cinemaSkipOutroSeconds = "settings.cinema.skipOutroSeconds"
    /// 刮削请求超时（秒）。
    static let cinemaRequestTimeout = "settings.cinema.requestTimeout"
    /// 日志详细程度：important / standard / verbose。
    static let cinemaLogLevel = "settings.cinema.logLevel"
    /// 刮削成功后导出 NFO 到同目录（默认关）。
    static let cinemaExportNFO = "settings.cinema.exportNFO"
    /// 外挂字幕是否显示半透明底色。
    static let subtitleBackground = "settings.video.subtitleBackground"
    /// 外挂字幕颜色：white / yellow / cyan / green。
    static let subtitleColor = "settings.video.subtitleColor"
    /// 外挂字幕位置：bottom / lower / middle。
    static let subtitlePosition = "settings.video.subtitlePosition"
    static let trashRetentionDays = "settings.trash.retentionDays"
    static let importCreateAlbums = "settings.import.createAlbums"
    static let importPreserveStructure = "settings.import.preserveStructure"
    static let importSkipDuplicates = "settings.import.skipDuplicates"
    static let importVerifyCopies = "settings.import.verifyCopies"
    /// 旧版全局设置已迁入当前图库的一次性标记（仅 UserDefaults）。
    static let libraryScopeMigrationDone = "settings.libraryScopeMigrationDone"
    /// 本地模型清单地址（可替换为私有镜像或测试源）。
    static let modelManifestURL = "settings.model.manifestURL"

    // MARK: 影院刮削
    static let cinemaProvider = "settings.cinema.provider"
    /// 刮削源尝试顺序（rawValue 数组），第一位即首选源。
    static let cinemaSourceOrder = "settings.cinema.sourceOrder"
    // 以下 5 个敏感键只用于把旧版 `UserDefaults` 明文迁移进统一凭据保险库；
    // 新代码通过 `CinemaKeychain` 读写，不再访问这些键。
    static let cinemaAPIKey = "settings.cinema.apiKey"
    static let cinemaLanguage = "settings.cinema.language"
    static let cinemaAPIBase = "settings.cinema.apiBase"
    static let cinemaImageBase = "settings.cinema.imageBase"
    static let cinemaAutoScrape = "settings.cinema.autoScrape"
    static let cinemaDoubanBase = "settings.cinema.doubanBase"
    static let cinemaDoubanCookie = "settings.cinema.doubanCookie"
    static let cinemaTVDBKey = "settings.cinema.tvdbKey"
    static let cinemaTVDBPin = "settings.cinema.tvdbPin"
    static let cinemaSubtitleAPIKey = "settings.cinema.subtitleAPIKey"
    /// 在线字幕来源开关：OpenSubtitles / Assrt（伪射手）。
    static let subtitleProviderOpenSubtitles = "settings.subtitle.provider.openSubtitles"
    static let subtitleProviderAssrt = "settings.subtitle.provider.assrt"
    static let cinemaParentalLevel = "settings.cinema.parentalLevel"
    /// 刮削并发数：同时处理多少个视频，默认 3。
    static let cinemaScrapeConcurrency = "settings.cinema.scrapeConcurrency"

    /// 单个本地能力是否启用。模型文件存放在本机 Application Support，开关只表示用不用。
    static func modelEnabled(_ id: String) -> String {
        "settings.model.\(id).enabled"
    }
}

// MARK: - 缩略图元数据

/// 网格缩略图上要显示的元数据，可在「显示 › 元数据」或设置中逐项开关。
