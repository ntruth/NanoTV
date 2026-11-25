import SwiftUI
import AppKit

final class AppSettings: ObservableObject {
    /// 全局唯一实例；服务层（如 LibraryStore）读取业务设置时使用，避免绕过设置模型。
    static let shared = AppSettings()

    /// 当前图库设置表的读写入口，由 LibraryStore 在打开/切换图库时注入。
    /// 图库级设置随图库保存；为 nil 时（尚未打开图库）退回 UserDefaults。
    var libraryReader: ((String) -> String?)?
    var libraryWriter: ((String, String?) -> Void)?
    /// 正在把图库里的值灌回属性时，跳过写回，避免无意义的重写。
    private var isApplyingLibraryScope = false

    @Published var appearance: AppAppearance {
        didSet { persistTheme(appearance.rawValue, for: SettingsKeys.appearance) }
    }

    @Published var accent: AppAccent {
        didSet { persistTheme(accent.rawValue, for: SettingsKeys.accent) }
    }

    @Published var photoOpenMode: PhotoOpenMode {
        didSet { UserDefaults.standard.set(photoOpenMode.rawValue, forKey: SettingsKeys.photoOpenMode) }
    }

    /// 查看器的呈现方式（窗口内 / 全屏）。
    @Published var viewerLayout: ViewerLayout {
        didSet { UserDefaults.standard.set(viewerLayout.rawValue, forKey: SettingsKeys.viewerLayout) }
    }

    @Published var showInfoOnOpen: Bool {
        didSet { UserDefaults.standard.set(showInfoOnOpen, forKey: SettingsKeys.showInfoOnOpen) }
    }

    /// 查看器底部是否显示缩略图胶片条。
    @Published var viewerFilmstrip: Bool {
        didSet { UserDefaults.standard.set(viewerFilmstrip, forKey: SettingsKeys.viewerFilmstrip) }
    }

    /// 查看器是否用当前照片的模糊影像铺满舞台背景（关闭后为纯色，翻页更省资源）。
    @Published var viewerBackdrop: Bool {
        didSet { UserDefaults.standard.set(viewerBackdrop, forKey: SettingsKeys.viewerBackdrop) }
    }

    @Published var motion: MotionPreset {
        didSet { UserDefaults.standard.set(motion.rawValue, forKey: SettingsKeys.motion) }
    }

    @Published var cardCornerRadius: Double {
        didSet { UserDefaults.standard.set(cardCornerRadius, forKey: SettingsKeys.cardCornerRadius) }
    }

    @Published var hoverLift: Bool {
        didSet { UserDefaults.standard.set(hoverLift, forKey: SettingsKeys.hoverLift) }
    }

    /// 新打开的图片列表（照片网格）默认每行几张；已单独调整过的页面保持各自记忆。
    @Published var defaultGridColumns: Int {
        didSet { UserDefaults.standard.set(defaultGridColumns, forKey: SettingsKeys.defaultGridColumns) }
    }

    /// 相簿 / 媒体类型 / 场景 / 更多项目等卡片墙默认每行几个。
    @Published var defaultCardColumns: Int {
        didSet { UserDefaults.standard.set(defaultCardColumns, forKey: SettingsKeys.defaultCardColumns) }
    }

    @Published var autoPlayVideo: Bool {
        didSet { UserDefaults.standard.set(autoPlayVideo, forKey: SettingsKeys.autoPlayVideo) }
    }

    @Published var viewFullHDR: Bool {
        didSet { UserDefaults.standard.set(viewFullHDR, forKey: SettingsKeys.viewFullHDR) }
    }

    /// 视频默认以静音状态开始播放。
    @Published var muteVideoByDefault: Bool {
        didSet { UserDefaults.standard.set(muteVideoByDefault, forKey: SettingsKeys.videoMuted) }
    }

    /// 视频播放结束后自动连播下一个视频（跳过照片）。
    @Published var autoPlayNextVideo: Bool {
        didSet { UserDefaults.standard.set(autoPlayNextVideo, forKey: SettingsKeys.autoPlayNextVideo) }
    }

    /// 视频默认循环播放。
    @Published var loopVideoByDefault: Bool {
        didSet { UserDefaults.standard.set(loopVideoByDefault, forKey: SettingsKeys.videoLoop) }
    }

    /// 按片源帧率切换显示器刷新率：24p 片源优先 24Hz，减少 3:2 pulldown 抖动。
    @Published var matchDisplayFrameRate: Bool {
        didSet { UserDefaults.standard.set(matchDisplayFrameRate, forKey: SettingsKeys.videoMatchDisplayRate) }
    }

    /// 高倍速播放时保持音调不变（频谱算法），关闭后在 2× 以上会出现「快放」失真。
    @Published var preservePitchAtSpeed: Bool {
        didSet { UserDefaults.standard.set(preservePitchAtSpeed, forKey: SettingsKeys.videoPreservePitch) }
    }

    /// 音轨即时切换：多音轨在一次 HLS 会话里装好，切换只让播放器换轨。
    @Published var instantAudioSwitch: Bool {
        didSet { UserDefaults.standard.set(instantAudioSwitch, forKey: SettingsKeys.videoInstantAudioSwitch) }
    }

    /// 多声道输出方式：自动保留源声道，或强制降混成立体声。
    @Published var audioDownmix: AudioDownmixMode {
        didSet { UserDefaults.standard.set(audioDownmix.rawValue, forKey: SettingsKeys.audioDownmix) }
    }

    /// 需要重编码时的目标编码：兼容 H.264 / 高效 HEVC / 低功耗 HEVC。
    @Published var videoTranscodeMode: VideoTranscodeMode {
        didSet {
            UserDefaults.standard.set(videoTranscodeMode.rawValue,
                                      forKey: SettingsKeys.videoTranscodeMode)
        }
    }

    /// 画面显示方式：适应 / 填充 / 拉伸 / 原始像素。
    @Published var videoFramingMode: VideoFramingMode {
        didSet {
            UserDefaults.standard.set(videoFramingMode.rawValue,
                                      forKey: SettingsKeys.videoFramingMode)
        }
    }

    /// 显示层比例预设：源比例 / 16:9 / 4:3 / 2.35:1 / 1:1。
    @Published var videoAspectPreset: VideoAspectPreset {
        didSet {
            UserDefaults.standard.set(videoAspectPreset.rawValue,
                                      forKey: SettingsKeys.videoAspectPreset)
        }
    }

    /// 比例裁剪后的平移：-1...1，0 为居中。
    @Published var videoPanX: Double {
        didSet { UserDefaults.standard.set(videoPanX, forKey: SettingsKeys.videoPanX) }
    }

    @Published var videoPanY: Double {
        didSet { UserDefaults.standard.set(videoPanY, forKey: SettingsKeys.videoPanY) }
    }

    /// 本地 / SMB 视频打开时自动挂载中文字幕轨。
    @Published var autoEmbeddedSubtitles: Bool {
        didSet { UserDefaults.standard.set(autoEmbeddedSubtitles, forKey: SettingsKeys.videoAutoEmbeddedSubtitles) }
    }

    /// 打开视频时自动载入同目录下的同名外挂字幕。
    @Published var autoSiblingSubtitles: Bool {
        didSet { UserDefaults.standard.set(autoSiblingSubtitles, forKey: SettingsKeys.videoAutoSiblingSubtitles) }
    }

    /// 打开视频后按片名自动在线搜索并载入一条字幕。
    @Published var autoOnlineSubtitles: Bool {
        didSet { UserDefaults.standard.set(autoOnlineSubtitles, forKey: SettingsKeys.videoAutoOnlineSubtitles) }
    }

    /// 把播放状态交给系统「正在播放」，支持控制中心与键盘媒体键。
    @Published var systemMediaIntegration: Bool {
        didSet { UserDefaults.standard.set(systemMediaIntegration, forKey: SettingsKeys.videoSystemMediaIntegration) }
    }

    /// 进度条悬停 / 拖动时显示该时间点的画面预览。
    @Published var scrubPreviewEnabled: Bool {
        didSet { UserDefaults.standard.set(scrubPreviewEnabled, forKey: SettingsKeys.videoScrubPreview) }
    }

    /// 视频快进 / 快退的步长（秒）：图库视频用 ↑ / ↓，网络资源用 ← / →。
    @Published var videoSeekStep: Double {
        didSet { UserDefaults.standard.set(videoSeekStep, forKey: SettingsKeys.videoSeekStep) }
    }

    /// 视频控制条的位置：底部悬浮，或融合进画面上方的顶栏。
    @Published var videoControlPlacement: VideoControlPlacement {
        didSet {
            UserDefaults.standard.set(videoControlPlacement.rawValue,
                                      forKey: SettingsKeys.videoControlPlacement)
        }
    }

    /// HDR / 杜比视界片源的播放策略：自动 / 映射到 SDR / 保持 HDR。
    @Published var videoHDRMode: VideoHDRMode {
        didSet {
            UserDefaults.standard.set(videoHDRMode.rawValue, forKey: SettingsKeys.videoHDRMode)
        }
    }

    /// 网络缓冲档位：省流 / 均衡 / 流畅。默认流畅，优先保证连续播放。
    @Published var videoBufferProfile: BufferProfile {
        didSet {
            UserDefaults.standard.set(videoBufferProfile.rawValue, forKey: SettingsKeys.videoBufferProfile)
        }
    }

    /// 远端弱网自适应：默认关闭；开启后网络变慢时在所选档位内临时降档。
    @Published var videoAdaptiveBuffering: Bool {
        didSet {
            UserDefaults.standard.set(videoAdaptiveBuffering, forKey: SettingsKeys.videoAdaptiveBuffering)
        }
    }

    /// 设置页的四选一：自适应 / 流畅 / 均衡 / 省流。
    /// 自适应 = 以流畅为上限 + 开启弱网降档；其余三项 = 固定档位且关闭自适应。
    var videoBufferMode: VideoBufferMode {
        get {
            videoAdaptiveBuffering ? .adaptive : VideoBufferMode(profile: videoBufferProfile)
        }
        set {
            videoAdaptiveBuffering = newValue.isAdaptive
            videoBufferProfile = newValue.profile
        }
    }

    /// 视频转码 / 边下边播缓存容量上限（GB）；超过后按最近最少使用淘汰。
    @Published var videoCacheLimitGB: Int {
        didSet { UserDefaults.standard.set(videoCacheLimitGB, forKey: SettingsKeys.videoCacheLimitGB) }
    }

    /// 网络资源海报缓存上限（GB）：超限按最久未使用删到 90%。
    @Published var posterCacheLimitGB: Int {
        didSet { UserDefaults.standard.set(posterCacheLimitGB, forKey: SettingsKeys.posterCacheLimitGB) }
    }

    /// 外挂字幕字号。
    @Published var subtitleFontSize: Double {
        didSet { UserDefaults.standard.set(subtitleFontSize, forKey: SettingsKeys.subtitleFontSize) }
    }

    /// 外挂字幕是否显示半透明底色。
    @Published var subtitleBackground: Bool {
        didSet { UserDefaults.standard.set(subtitleBackground, forKey: SettingsKeys.subtitleBackground) }
    }

    /// 外挂字幕颜色（white / yellow / cyan / green）。
    @Published var subtitleColor: String {
        didSet { UserDefaults.standard.set(subtitleColor, forKey: SettingsKeys.subtitleColor) }
    }

    /// 外挂字幕位置（bottom / lower / middle）。
    @Published var subtitlePosition: String {
        didSet { UserDefaults.standard.set(subtitlePosition, forKey: SettingsKeys.subtitlePosition) }
    }

    /// 默认音轨：original（原声优先）/ zh（国语优先）/ en（英语优先）。
    @Published var videoPreferredAudio: String {
        didSet { UserDefaults.standard.set(videoPreferredAudio, forKey: SettingsKeys.videoPreferredAudio) }
    }

    /// 默认字幕：auto（按内嵌中文轨自动挂载）/ off（不自动挂载）。
    @Published var videoPreferredSubtitle: String {
        didSet { UserDefaults.standard.set(videoPreferredSubtitle, forKey: SettingsKeys.videoPreferredSubtitle) }
    }

    /// 退出播放器时记住倍速；下次打开沿用。
    @Published var videoRememberSpeed: Bool {
        didSet { UserDefaults.standard.set(videoRememberSpeed, forKey: SettingsKeys.videoRememberSpeed) }
    }

    /// 上次使用的播放倍速（仅当「记忆倍速」开启时生效）。
    @Published var videoLastSpeed: Double {
        didSet { UserDefaults.standard.set(videoLastSpeed, forKey: SettingsKeys.videoLastSpeed) }
    }

    /// 优先系统硬解；关闭后强制走转封装 / 软解，解决个别显卡花屏。
    @Published var videoPreferHardwareDecoding: Bool {
        didSet {
            UserDefaults.standard.set(videoPreferHardwareDecoding,
                                      forKey: SettingsKeys.videoPreferHardwareDecoding)
        }
    }

    /// 是否在播放器里提供画中画。
    @Published var videoPiPEnabled: Bool {
        didSet { UserDefaults.standard.set(videoPiPEnabled, forKey: SettingsKeys.videoPiPEnabled) }
    }

    /// 全局跳过片头秒数：剧集没有单独设置时的兜底，0 表示不跳过。
    @Published var cinemaSkipIntroSeconds: Int {
        didSet { UserDefaults.standard.set(cinemaSkipIntroSeconds, forKey: SettingsKeys.cinemaSkipIntroSeconds) }
    }

    /// 全局跳过片尾秒数。
    @Published var cinemaSkipOutroSeconds: Int {
        didSet { UserDefaults.standard.set(cinemaSkipOutroSeconds, forKey: SettingsKeys.cinemaSkipOutroSeconds) }
    }

    /// 刮削请求超时（秒）：豆瓣 / TMDB 搜索与详情共用。
    @Published var cinemaRequestTimeout: Double {
        didSet { UserDefaults.standard.set(cinemaRequestTimeout, forKey: SettingsKeys.cinemaRequestTimeout) }
    }

    /// 日志详细程度：important / standard / verbose。
    @Published var cinemaLogLevel: String {
        didSet { UserDefaults.standard.set(cinemaLogLevel, forKey: SettingsKeys.cinemaLogLevel) }
    }

    /// 刮削成功后把 NFO 写到同目录（仅本地 / SMB），默认关闭。
    @Published var cinemaExportNFO: Bool {
        didSet { UserDefaults.standard.set(cinemaExportNFO, forKey: SettingsKeys.cinemaExportNFO) }
    }

    /// 「最近删除」自动清理的保留天数；0 表示不自动清理。（随图库保存）
    @Published var trashRetentionDays: Int {
        didSet { persistLibraryInt(SettingsKeys.trashRetentionDays, trashRetentionDays) }
    }

    /// 导入时把文件夹末级目录创建为相簿。（随图库保存）
    @Published var importCreateAlbumsFromFolders: Bool {
        didSet { persistLibraryFlag(SettingsKeys.importCreateAlbums, importCreateAlbumsFromFolders) }
    }

    /// 导入时保留上层文件夹结构。（随图库保存）
    @Published var importPreserveFolderStructure: Bool {
        didSet { persistLibraryFlag(SettingsKeys.importPreserveStructure, importPreserveFolderStructure) }
    }

    /// 导入时跳过字节完全相同的文件。（随图库保存）
    @Published var importSkipExactDuplicates: Bool {
        didSet { persistLibraryFlag(SettingsKeys.importSkipDuplicates, importSkipExactDuplicates) }
    }

    /// 导入完成后重新校验目标文件哈希。（随图库保存）
    @Published var importVerifyCopies: Bool {
        didSet { persistLibraryFlag(SettingsKeys.importVerifyCopies, importVerifyCopies) }
    }

    /// 网格缩略图上显示的元数据。（随图库保存）
    @Published var metadata: MetadataOptions {
        didSet { persistLibraryJSON(SettingsKeys.metadata, metadata) }
    }

    // MARK: 影院刮削

    /// 刮削数据源的优先级：TMDB（官方 API）优先，豆瓣作为备用同时参与。
    @Published var cinemaProvider: CinemaProvider {
        didSet { UserDefaults.standard.set(cinemaProvider.rawValue, forKey: SettingsKeys.cinemaProvider) }
    }

    /// 刮削源的尝试顺序：第一项就是首选源，设置页拖动后立即生效。
    @Published var cinemaSourceOrder: [CinemaProvider] {
        didSet {
            UserDefaults.standard.set(cinemaSourceOrder.map(\.rawValue),
                                      forKey: SettingsKeys.cinemaSourceOrder)
            // 首选源与顺序保持一致：影院页的「XX 优先」等旧读取方不用改。
            if let first = cinemaSourceOrder.first, first != cinemaProvider {
                cinemaProvider = first
            }
        }
    }

    /// TMDB API Key（v3）或 Read Access Token（v4，以 eyJ 开头）。只写统一凭据保险库。
    @Published var cinemaAPIKey: String {
        didSet { persistSecret(cinemaAPIKey, for: .tmdbAPIKey) }
    }

    /// 刮削语言，如 zh-CN / en-US / ja-JP。
    @Published var cinemaLanguage: String {
        didSet { UserDefaults.standard.set(cinemaLanguage, forKey: SettingsKeys.cinemaLanguage) }
    }

    /// TMDB API 地址，可替换为镜像 / 代理。
    @Published var cinemaAPIBase: String {
        didSet { UserDefaults.standard.set(cinemaAPIBase, forKey: SettingsKeys.cinemaAPIBase) }
    }

    /// 海报与背景图地址前缀，默认 image.tmdb.org。
    @Published var cinemaImageBase: String {
        didSet { UserDefaults.standard.set(cinemaImageBase, forKey: SettingsKeys.cinemaImageBase) }
    }

    /// 进入影院或扫描完网盘后自动刮削新视频。
    @Published var cinemaAutoScrape: Bool {
        didSet { UserDefaults.standard.set(cinemaAutoScrape, forKey: SettingsKeys.cinemaAutoScrape) }
    }

    /// 刮削并发数：同时请求多个视频，默认 3；网络或片源较弱时可调低。
    @Published var cinemaScrapeConcurrency: Int {
        didSet {
            let clamped = min(6, max(1, cinemaScrapeConcurrency))
            UserDefaults.standard.set(clamped, forKey: SettingsKeys.cinemaScrapeConcurrency)
            if clamped != cinemaScrapeConcurrency { cinemaScrapeConcurrency = clamped }
        }
    }

    /// 豆瓣接口地址，可换成镜像 / 反代前缀。
    @Published var cinemaDoubanBase: String {
        didSet { UserDefaults.standard.set(cinemaDoubanBase, forKey: SettingsKeys.cinemaDoubanBase) }
    }

    /// 可选的豆瓣登录 Cookie，用于降低被限流的概率。只写统一凭据保险库。
    @Published var cinemaDoubanCookie: String {
        didSet { persistSecret(cinemaDoubanCookie, for: .doubanCookie) }
    }

    /// TheTVDB API Key（v4）：作为第三顺位刮削源。只写统一凭据保险库。
    @Published var cinemaTVDBKey: String {
        didSet { persistSecret(cinemaTVDBKey, for: .tvdbKey) }
    }

    /// TheTVDB 订阅者 PIN，可选；普通 Key 留空即可。只写统一凭据保险库。
    @Published var cinemaTVDBPin: String {
        didSet { persistSecret(cinemaTVDBPin, for: .tvdbPIN) }
    }

    /// OpenSubtitles API Key：在线字幕搜索与下载。只写统一凭据保险库。
    @Published var cinemaSubtitleAPIKey: String {
        didSet { persistSecret(cinemaSubtitleAPIKey, for: .subtitleAPIKey) }
    }

    /// OpenSubtitles 账号（下载配额用）；账号与密码只写统一凭据保险库。
    @Published var cinemaSubtitleUsername: String {
        didSet { persistSecret(cinemaSubtitleUsername, for: .subtitleUsername) }
    }

    @Published var cinemaSubtitlePassword: String {
        didSet { persistSecret(cinemaSubtitlePassword, for: .subtitlePassword) }
    }

    /// Assrt（伪射手）访问令牌：国内字幕源，只写统一凭据保险库。
    @Published var assrtSubtitleToken: String {
        didSet { persistSecret(assrtSubtitleToken, for: .subtitleAssrtToken) }
    }

    /// 在线字幕来源开关：关掉后不再参与搜索与自动匹配。
    @Published var subtitleProviderOpenSubtitlesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(subtitleProviderOpenSubtitlesEnabled,
                                      forKey: SettingsKeys.subtitleProviderOpenSubtitles)
        }
    }

    @Published var subtitleProviderAssrtEnabled: Bool {
        didSet {
            UserDefaults.standard.set(subtitleProviderAssrtEnabled,
                                      forKey: SettingsKeys.subtitleProviderAssrt)
        }
    }

    /// 读取保险库期间屏蔽 didSet 回写，避免「刚读出来又写回去」。
    private var isRestoringSecrets = false

    /// 写入敏感设置：统一进凭据保险库，值没变化时不重复写钥匙串。
    private func persistSecret(_ value: String, for account: CinemaKeychain.Account) {
        guard !isRestoringSecrets else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != CinemaKeychain.value(for: account) else { return }
        CinemaKeychain.set(trimmed, for: account)
    }

    /// 启动时一次性把钥匙串里的敏感设置读进内存。之后设置页、字幕搜索、刮削都只读内存，
    /// 同一进程不会再重复访问钥匙串，系统授权框因此最多只出现一次。
    private func loadSecretsFromVault() {
        migrateLegacySecretsFromUserDefaults()
        isRestoringSecrets = true
        cinemaAPIKey = CinemaKeychain.value(for: .tmdbAPIKey)
        cinemaDoubanCookie = CinemaKeychain.value(for: .doubanCookie)
        cinemaTVDBKey = CinemaKeychain.value(for: .tvdbKey)
        cinemaTVDBPin = CinemaKeychain.value(for: .tvdbPIN)
        cinemaSubtitleAPIKey = CinemaKeychain.value(for: .subtitleAPIKey)
        cinemaSubtitleUsername = CinemaKeychain.value(for: .subtitleUsername)
        cinemaSubtitlePassword = CinemaKeychain.value(for: .subtitlePassword)
        assrtSubtitleToken = CinemaKeychain.value(for: .subtitleAssrtToken)
        isRestoringSecrets = false
    }

    /// 旧版把这些密钥明文存在 UserDefaults：只搬一次，确认写进保险库后再删除明文。
    private func migrateLegacySecretsFromUserDefaults() {
        let defaults = UserDefaults.standard
        let pairs: [(String, CinemaKeychain.Account)] = [
            (SettingsKeys.cinemaAPIKey, .tmdbAPIKey),
            (SettingsKeys.cinemaDoubanCookie, .doubanCookie),
            (SettingsKeys.cinemaTVDBKey, .tvdbKey),
            (SettingsKeys.cinemaTVDBPin, .tvdbPIN),
            (SettingsKeys.cinemaSubtitleAPIKey, .subtitleAPIKey)
        ]
        for (key, account) in pairs {
            let legacy = (defaults.string(forKey: key) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !legacy.isEmpty, !CinemaKeychain.has(account) else {
                defaults.removeObject(forKey: key)
                continue
            }
            // 只有确认写进钥匙串才删除明文，避免钥匙串不可用时把用户已有配置弄丢。
            if CinemaKeychain.set(legacy, for: account) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// 家长控制档位：按分级限制影院可见内容。
    @Published var cinemaParentalLevel: CinemaParentalLevel {
        didSet { UserDefaults.standard.set(cinemaParentalLevel.rawValue, forKey: SettingsKeys.cinemaParentalLevel) }
    }

    init() {
        let defaults = UserDefaults.standard
        // 默认浅色 + 蓝色强调色：建库首屏与圆环以这组配色为基准，用户可随时改。
        appearance = AppAppearance(rawValue: defaults.string(forKey: SettingsKeys.appearance) ?? "") ?? .light
        accent = AppAccent(rawValue: defaults.string(forKey: SettingsKeys.accent) ?? "") ?? .blue
        photoOpenMode = PhotoOpenMode(rawValue: defaults.string(forKey: SettingsKeys.photoOpenMode) ?? "") ?? .viewer
        viewerLayout = ViewerLayout(rawValue: defaults.string(forKey: SettingsKeys.viewerLayout) ?? "") ?? .window
        showInfoOnOpen = defaults.bool(forKey: SettingsKeys.showInfoOnOpen)
        viewerFilmstrip = defaults.object(forKey: SettingsKeys.viewerFilmstrip) as? Bool ?? false
        viewerBackdrop = defaults.object(forKey: SettingsKeys.viewerBackdrop) as? Bool ?? true
        motion = MotionPreset(rawValue: defaults.string(forKey: SettingsKeys.motion) ?? "") ?? .silky
        cardCornerRadius = defaults.object(forKey: SettingsKeys.cardCornerRadius) as? Double ?? 14
        hoverLift = defaults.object(forKey: SettingsKeys.hoverLift) as? Bool ?? true
        defaultGridColumns = defaults.object(forKey: SettingsKeys.defaultGridColumns) as? Int ?? 8
        defaultCardColumns = defaults.object(forKey: SettingsKeys.defaultCardColumns) as? Int ?? 5
        autoPlayVideo = defaults.object(forKey: SettingsKeys.autoPlayVideo) as? Bool ?? true
        autoPlayNextVideo = defaults.object(forKey: SettingsKeys.autoPlayNextVideo) as? Bool ?? true
        viewFullHDR = defaults.object(forKey: SettingsKeys.viewFullHDR) as? Bool ?? true
        muteVideoByDefault = defaults.object(forKey: SettingsKeys.videoMuted) as? Bool ?? false
        loopVideoByDefault = defaults.object(forKey: SettingsKeys.videoLoop) as? Bool ?? false
        matchDisplayFrameRate = defaults.object(forKey: SettingsKeys.videoMatchDisplayRate) as? Bool ?? true
        preservePitchAtSpeed = defaults.object(forKey: SettingsKeys.videoPreservePitch) as? Bool ?? true
        instantAudioSwitch = defaults.object(forKey: SettingsKeys.videoInstantAudioSwitch) as? Bool ?? true
        audioDownmix = AudioDownmixMode(rawValue: defaults.string(forKey: SettingsKeys.audioDownmix) ?? "")
            ?? .source
        videoTranscodeMode = VideoTranscodeMode(
            rawValue: defaults.string(forKey: SettingsKeys.videoTranscodeMode) ?? "") ?? .compatibility
        videoFramingMode = VideoFramingMode(
            rawValue: defaults.string(forKey: SettingsKeys.videoFramingMode) ?? "") ?? .fit
        videoAspectPreset = VideoAspectPreset(
            rawValue: defaults.string(forKey: SettingsKeys.videoAspectPreset) ?? "") ?? .source
        videoPanX = defaults.object(forKey: SettingsKeys.videoPanX) as? Double ?? 0
        videoPanY = defaults.object(forKey: SettingsKeys.videoPanY) as? Double ?? 0
        autoEmbeddedSubtitles = defaults.object(forKey: SettingsKeys.videoAutoEmbeddedSubtitles) as? Bool ?? false
        // 自动挂载一律默认关闭：用户主动到「字幕」里打开才生效。
        autoSiblingSubtitles = defaults.object(forKey: SettingsKeys.videoAutoSiblingSubtitles) as? Bool ?? false
        autoOnlineSubtitles = defaults.object(forKey: SettingsKeys.videoAutoOnlineSubtitles) as? Bool ?? false
        systemMediaIntegration = defaults.object(forKey: SettingsKeys.videoSystemMediaIntegration) as? Bool ?? true
        // 悬停关键帧默认关闭：不主动解码预览帧，想要的人再到设置里打开。
        scrubPreviewEnabled = defaults.object(forKey: SettingsKeys.videoScrubPreview) as? Bool ?? false
        videoSeekStep = defaults.object(forKey: SettingsKeys.videoSeekStep) as? Double ?? 5
        videoControlPlacement = VideoControlPlacement(
            rawValue: defaults.string(forKey: SettingsKeys.videoControlPlacement) ?? "") ?? .topIntegrated
        videoHDRMode = VideoHDRMode(
            rawValue: defaults.string(forKey: SettingsKeys.videoHDRMode) ?? "") ?? .automatic
        videoBufferProfile = BufferProfile(
            rawValue: defaults.string(forKey: SettingsKeys.videoBufferProfile) ?? "") ?? .defaultProfile
        videoAdaptiveBuffering = defaults.object(forKey: SettingsKeys.videoAdaptiveBuffering) as? Bool ?? false
        var videoLimit = defaults.object(forKey: SettingsKeys.videoCacheLimitGB) as? Int ?? 50
        var posterLimit = defaults.object(forKey: SettingsKeys.posterCacheLimitGB) as? Int ?? 10
        // 旧的默认值（海报 2 / 5 GB、视频 20 GB）升到新默认 10 / 50 GB；手动选过的其它值保持不动。
        if defaults.string(forKey: SettingsKeys.cacheLimitDefaultsVersion) != "2" {
            if [2, 5].contains(posterLimit) { posterLimit = 10 }
            if videoLimit == 20 { videoLimit = 50 }
            defaults.set(posterLimit, forKey: SettingsKeys.posterCacheLimitGB)
            defaults.set(videoLimit, forKey: SettingsKeys.videoCacheLimitGB)
            defaults.set("2", forKey: SettingsKeys.cacheLimitDefaultsVersion)
        }
        videoCacheLimitGB = videoLimit
        posterCacheLimitGB = posterLimit
        subtitleFontSize = defaults.object(forKey: SettingsKeys.subtitleFontSize) as? Double ?? 15
        subtitleBackground = defaults.object(forKey: SettingsKeys.subtitleBackground) as? Bool ?? true
        subtitleColor = defaults.string(forKey: SettingsKeys.subtitleColor) ?? "white"
        subtitlePosition = defaults.string(forKey: SettingsKeys.subtitlePosition) ?? "bottom"
        videoPreferredAudio = defaults.string(forKey: SettingsKeys.videoPreferredAudio) ?? "original"
        videoPreferredSubtitle = defaults.string(forKey: SettingsKeys.videoPreferredSubtitle) ?? "auto"
        videoRememberSpeed = defaults.object(forKey: SettingsKeys.videoRememberSpeed) as? Bool ?? false
        videoLastSpeed = defaults.object(forKey: SettingsKeys.videoLastSpeed) as? Double ?? 1
        videoPreferHardwareDecoding = defaults.object(forKey: SettingsKeys.videoPreferHardwareDecoding) as? Bool ?? true
        videoPiPEnabled = defaults.object(forKey: SettingsKeys.videoPiPEnabled) as? Bool ?? true
        cinemaSkipIntroSeconds = defaults.object(forKey: SettingsKeys.cinemaSkipIntroSeconds) as? Int ?? 0
        cinemaSkipOutroSeconds = defaults.object(forKey: SettingsKeys.cinemaSkipOutroSeconds) as? Int ?? 0
        cinemaRequestTimeout = defaults.object(forKey: SettingsKeys.cinemaRequestTimeout) as? Double ?? 15
        cinemaLogLevel = defaults.string(forKey: SettingsKeys.cinemaLogLevel) ?? "standard"
        cinemaExportNFO = defaults.object(forKey: SettingsKeys.cinemaExportNFO) as? Bool ?? false
        // 默认优先 TMDB：没填 Key 时自动跳过，改用豆瓣匹配。
        let initialProvider = CinemaProvider(rawValue: defaults.string(forKey: SettingsKeys.cinemaProvider) ?? "") ?? .tmdb
        cinemaProvider = initialProvider
        let savedOrder = (defaults.array(forKey: SettingsKeys.cinemaSourceOrder) as? [String] ?? [])
            .compactMap(CinemaProvider.init(rawValue:))
        var sourceOrder: [CinemaProvider]
        if savedOrder.isEmpty {
            sourceOrder = [initialProvider] + CinemaProvider.allCases.filter { $0 != initialProvider }
        } else {
            sourceOrder = savedOrder
            for provider in CinemaProvider.allCases where !sourceOrder.contains(provider) {
                sourceOrder.append(provider)
            }
        }
        cinemaSourceOrder = sourceOrder
        if let first = sourceOrder.first { cinemaProvider = first }
        // 敏感项一律不回退到 UserDefaults：由 loadSecretsFromVault() 统一从保险库灌入。
        cinemaAPIKey = ""
        cinemaLanguage = defaults.string(forKey: SettingsKeys.cinemaLanguage) ?? "zh-CN"
        cinemaAPIBase = defaults.string(forKey: SettingsKeys.cinemaAPIBase) ?? "https://api.themoviedb.org/3"
        cinemaImageBase = defaults.string(forKey: SettingsKeys.cinemaImageBase) ?? "https://image.tmdb.org/t/p"
        cinemaAutoScrape = defaults.object(forKey: SettingsKeys.cinemaAutoScrape) as? Bool ?? true
        cinemaScrapeConcurrency = min(6, max(1, defaults.object(forKey: SettingsKeys.cinemaScrapeConcurrency) as? Int ?? 3))
        cinemaDoubanBase = defaults.string(forKey: SettingsKeys.cinemaDoubanBase) ?? "https://movie.douban.com"
        cinemaDoubanCookie = ""
        cinemaTVDBKey = ""
        cinemaTVDBPin = ""
        cinemaSubtitleAPIKey = ""
        cinemaSubtitleUsername = ""
        cinemaSubtitlePassword = ""
        assrtSubtitleToken = ""
        subtitleProviderOpenSubtitlesEnabled =
            defaults.object(forKey: SettingsKeys.subtitleProviderOpenSubtitles) as? Bool ?? true
        subtitleProviderAssrtEnabled =
            defaults.object(forKey: SettingsKeys.subtitleProviderAssrt) as? Bool ?? true
        cinemaParentalLevel = CinemaParentalLevel(
            rawValue: defaults.object(forKey: SettingsKeys.cinemaParentalLevel) as? Int ?? 0
        ) ?? .off
        trashRetentionDays = defaults.object(forKey: SettingsKeys.trashRetentionDays) as? Int ?? 30
        importCreateAlbumsFromFolders = defaults.object(forKey: SettingsKeys.importCreateAlbums) as? Bool ?? true
        importPreserveFolderStructure = defaults.object(forKey: SettingsKeys.importPreserveStructure) as? Bool ?? true
        importSkipExactDuplicates = defaults.object(forKey: SettingsKeys.importSkipDuplicates) as? Bool ?? true
        importVerifyCopies = defaults.object(forKey: SettingsKeys.importVerifyCopies) as? Bool ?? true
        if let data = defaults.data(forKey: SettingsKeys.metadata),
           let decoded = try? JSONDecoder().decode(MetadataOptions.self, from: data) {
            metadata = decoded
            // 旧版默认会把标题/关键词/文件类型等文字叠在缩略图上；
            // 若用户从未改动过（仍是旧默认组合），这里一次性收起，避免网格过于拥挤。
            if metadata.title, metadata.keywords, metadata.edited,
               metadata.fileType, metadata.location, !metadata.resolution,
               !metadata.fileSize, !metadata.camera, !metadata.source,
               !metadata.capturedDate {
                metadata = MetadataOptions()
            }
        } else {
            metadata = MetadataOptions()
        }
        // 所有敏感项只在这里访问一次钥匙串。
        loadSecretsFromVault()
    }

    /// 从当前图库读取图库级设置；缺少的键使用默认值，避免把上一个图库的值带过来。
    func reloadLibraryScopedValues() {
        guard libraryReader != nil else { return }
        isApplyingLibraryScope = true
        defer { isApplyingLibraryScope = false }
        // 外观与强调色跟随图库：本库没存过时沿用 UserDefaults 里的最近值，
        // 这样在「还没有图库」的建库向导里选好的主题，新建后会原样保留。
        let storedAppearance = libraryReader?(SettingsKeys.appearance)
            ?? UserDefaults.standard.string(forKey: SettingsKeys.appearance)
        appearance = AppAppearance(rawValue: storedAppearance ?? "") ?? .light
        let storedAccent = libraryReader?(SettingsKeys.accent)
            ?? UserDefaults.standard.string(forKey: SettingsKeys.accent)
        accent = AppAccent(rawValue: storedAccent ?? "") ?? .blue
        importCreateAlbumsFromFolders = libraryBool(SettingsKeys.importCreateAlbums, fallback: true)
        importPreserveFolderStructure = libraryBool(SettingsKeys.importPreserveStructure, fallback: true)
        importSkipExactDuplicates = libraryBool(SettingsKeys.importSkipDuplicates, fallback: true)
        importVerifyCopies = libraryBool(SettingsKeys.importVerifyCopies, fallback: true)
        trashRetentionDays = libraryInt(SettingsKeys.trashRetentionDays, fallback: 30)
        metadata = libraryDecoded(SettingsKeys.metadata, as: MetadataOptions.self) ?? MetadataOptions()
    }

    private func libraryBool(_ key: String, fallback value: Bool) -> Bool {
        guard let raw = libraryReader?(key) else { return value }
        return raw == "1" || raw.lowercased() == "true"
    }

    private func libraryInt(_ key: String, fallback value: Int) -> Int {
        guard let raw = libraryReader?(key), let int = Int(raw) else { return value }
        return int
    }

    private func libraryDecoded<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let raw = libraryReader?(key), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func persistLibraryFlag(_ key: String, _ value: Bool) {
        guard !isApplyingLibraryScope else { return }
        if libraryWriter != nil {
            libraryWriter?(key, value ? "1" : "0")
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private func persistLibraryInt(_ key: String, _ value: Int) {
        guard !isApplyingLibraryScope else { return }
        if libraryWriter != nil {
            libraryWriter?(key, String(value))
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private func persistLibraryJSON<T: Encodable>(_ key: String, _ value: T) {
        guard !isApplyingLibraryScope else { return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        if libraryWriter != nil {
            libraryWriter?(key, String(data: data, encoding: .utf8))
        } else {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 正在用「新建图库」向导配置一个还没有创建出来的库：
    /// 此时改主题只记到 UserDefaults，不能写进当前还在使用的旧图库。
    var defersThemeToNewLibrary = false

    /// 外观 / 强调色跟着当前图库保存：有图库时写进图库自己的设置表，
    /// 同时留一份到 UserDefaults，作为「还没设置过主题的库」的继承值。
    private func persistTheme(_ rawValue: String, for key: String) {
        guard !isApplyingLibraryScope else { return }
        if libraryWriter != nil, !defersThemeToNewLibrary {
            libraryWriter?(key, rawValue)
        }
        UserDefaults.standard.set(rawValue, forKey: key)
    }

    /// 刚切到的库还没存过主题时，把当前主题写进去：
    /// 新建库会带上向导里选好的配色，之后切走再回来也还是它自己的。
    func seedThemeForCurrentLibraryIfNeeded() {
        guard let reader = libraryReader, let writer = libraryWriter else { return }
        guard !isApplyingLibraryScope else { return }
        if reader(SettingsKeys.appearance) == nil {
            writer(SettingsKeys.appearance, appearance.rawValue)
        }
        if reader(SettingsKeys.accent) == nil {
            writer(SettingsKeys.accent, accent.rawValue)
        }
    }

    var cardRadius: CGFloat { CGFloat(cardCornerRadius) }

    /// 全 App 的统一强调色：控件 tint 与 `Color.accentColor`（选中框、高亮、强调文字）都用它。
    var accentColor: Color { accent.color ?? .accentColor }

    /// 侧边栏的小封面按比例缩小圆角，避免 18pt 图标过于圆。
    var smallCoverRadius: CGFloat { min(8, max(2, CGFloat(cardCornerRadius) * 0.45)) }
}

/// 每部影片记住的手动字幕选择：内嵌轨按序号，外挂字幕按文件名。
struct RememberedSubtitle: Codable, Equatable {
    enum Kind: String, Codable {
        case embedded
        case external
    }

    var kind: Kind
    /// 内嵌字幕轨序号（ffprobe 的字幕流序号）。
    var ordinal: Int?
    /// 同目录外挂字幕的文件名。
    var fileName: String?
}

extension AppSettings {
    func rememberedSubtitle(for photoID: UUID) -> RememberedSubtitle? {
        guard let data = UserDefaults.standard.data(
            forKey: SettingsKeys.rememberedSubtitle(photoID.uuidString)) else { return nil }
        return try? JSONDecoder().decode(RememberedSubtitle.self, from: data)
    }

    func rememberSubtitle(_ value: RememberedSubtitle, for photoID: UUID) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: SettingsKeys.rememberedSubtitle(photoID.uuidString))
    }

    func forgetSubtitle(for photoID: UUID) {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.rememberedSubtitle(photoID.uuidString))
    }
}
