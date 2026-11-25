import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PlaybackCore

/// 在线字幕搜索上下文：当前影片的片名与季集号。
struct CinemaSubtitleQuery: Equatable {
    var title: String
    var season: Int?
    var episode: Int?

    var isTV: Bool { season != nil || episode != nil }
}

/// 顶栏与画面内控制条共享的播放 UI 状态：音轨列表、外挂字幕与偏移。
/// 播放页（VideoPlayerStage）负责真正重建流 / 切换 AV 音轨，这里只保存展示状态。
@MainActor
final class VideoPlaybackUI: ObservableObject {
    struct AudioChoice: Identifiable, Equatable {
        let index: Int
        let title: String
        var id: Int { index }
    }

    @Published private(set) var audioChoices: [AudioChoice] = []
    @Published private(set) var selectedAudioIndex = 0
    @Published private(set) var subtitleCues: [SubtitleCue] = []
    @Published private(set) var subtitleName: String?
    /// 本次播放里用户是否亲手选过字幕：恢复记忆时不能覆盖当次的新选择。
    private(set) var hasManualSubtitleChoice = false
    /// 源文件里的内嵌字幕轨（ffprobe 拿到）；文本轨可提取成 cue。
    @Published private(set) var embeddedTracks: [SubtitleTrackInfo] = []
    @Published private(set) var embeddedTrackOrdinal: Int?
    @Published private(set) var embeddedLoading = false
    /// 外挂字幕时间轴偏移（秒），正值表示字幕延后出现。
    @Published var subtitleOffset: Double = 0
    /// 正在烧录的图形字幕文件名；nil 表示未开启烧录。
    @Published private(set) var burnSubtitleName: String?
    /// 已复制到临时目录的烧录字幕路径（交给 ffmpeg 的 subtitles 滤镜）。
    private(set) var burnSubtitleURL: URL?
    /// 正在烧录的内嵌图形字幕轨（PGS / VobSub）；与 burnSubtitleURL 二选一。
    @Published private(set) var burnSubtitleStream: Int?
    /// 当前片源章节：章节菜单与进度条刻度共用（蓝光播放列表 / Matroska）。
    @Published private(set) var chapters: [VideoChapter] = []
    /// 蓝光盘内元数据标题：章节菜单的标题行（标准里没有逐章文本名）。
    @Published private(set) var discTitle: String?
    /// 蓝光多角度：可用视角数（1 = 普通影片）与当前选择。
    @Published private(set) var angleCount = 1
    @Published private(set) var selectedAngle = 1
    /// 片源是 HDR / 杜比视界且本机可映射：播放器内才会出现色调映射开关。
    @Published private(set) var hdrToneMapAvailable = false
    /// 本次播放是否已开启 HDR → SDR 色调映射。
    @Published private(set) var hdrToneMapEnabled = false

    /// 从影院进入播放时写入；在线字幕搜索据此拿到片名与季集号。
    var subtitleQuery: CinemaSubtitleQuery?
    @Published private(set) var onlineSubtitles: [CinemaSubtitleMatch] = []
    @Published private(set) var onlineSubtitleLoading = false
    @Published private(set) var onlineSubtitleHint: String?

    /// HLS 模式切换音轨需要重建流，由播放页注册。
    var onSelectStreamAudio: ((Int) -> Void)?
    /// 提取内嵌字幕轨：由播放页注册，参数是字幕轨序号。
    var onSelectEmbeddedSubtitle: ((SubtitleTrackInfo) -> Void)?
    /// 音频延迟调整后需要重建流。
    var onAudioDelayChanged: (() -> Void)?
    /// 烧录字幕变化时需要重建转码流，由播放页注册。
    var onBurnSubtitleChanged: (() -> Void)?
    /// 章节跳转：参数是片源时间轴上的秒数。
    var onSeekChapter: ((Double) -> Void)?
    /// HDR 色调映射开关：由播放页按新策略重建流。
    var onToggleHDRToneMapping: ((Bool) -> Void)?
    /// 蓝光多角度切换：参数是 1 起的视角序号。
    var onSelectAngle: ((Int) -> Void)?
    /// 用户手动选了字幕（内嵌 / 外挂）：由播放页按影片记住，下次打开恢复。
    var onSubtitleSelectionRemembered: ((RememberedSubtitle) -> Void)?
    /// 解析失败等提示，由播放页转成 toast。
    var onMessage: ((String) -> Void)?

    private var loadToken = 0
    /// 当前片源地址：手动选中的外挂字幕只有位于同目录时才值得记住文件名。
    private var currentSourceURL: URL?
    /// 自动在线匹配每次播放只尝试一次，失败也不反复请求。
    private var autoOnlineTried = false

    var hasSubtitle: Bool { subtitleName != nil }
    /// 是否正在烧录字幕（外挂文件或内嵌图形轨）：两种都必须转码，不能走原生直连 / 缓存。
    var isBurningSubtitle: Bool { burnSubtitleURL != nil || burnSubtitleStream != nil }

    func reset() {
        loadToken &+= 1
        currentSourceURL = nil
        audioChoices = []
        selectedAudioIndex = 0
        subtitleCues = []
        subtitleName = nil
        hasManualSubtitleChoice = false
        embeddedTracks = []
        embeddedTrackOrdinal = nil
        embeddedLoading = false
        subtitleOffset = 0
        burnSubtitleName = nil
        burnSubtitleURL = nil
        burnSubtitleStream = nil
        chapters = []
        discTitle = nil
        angleCount = 1
        selectedAngle = 1
        hdrToneMapAvailable = false
        hdrToneMapEnabled = false
        subtitleQuery = nil
        autoOnlineTried = false
        onlineSubtitles = []
        onlineSubtitleLoading = false
        onlineSubtitleHint = nil
        onSelectStreamAudio = nil
        onSelectEmbeddedSubtitle = nil
        onAudioDelayChanged = nil
        onSeekChapter = nil
        onToggleHDRToneMapping = nil
        onSelectAngle = nil
        onSubtitleSelectionRemembered = nil
    }

    func updateChapters(_ list: [VideoChapter], discTitle: String? = nil) {
        chapters = list.sorted { $0.start < $1.start }
        self.discTitle = discTitle
    }

    func updateAngles(count: Int, selected: Int) {
        angleCount = max(1, count)
        selectedAngle = min(max(1, selected), angleCount)
    }

    func selectAngle(_ angle: Int) {
        let target = min(max(1, angle), angleCount)
        guard target != selectedAngle else { return }
        selectedAngle = target
        onSelectAngle?(target)
    }

    func updateHDRToneMap(available: Bool, enabled: Bool) {
        hdrToneMapAvailable = available
        hdrToneMapEnabled = available && enabled
    }

    func setHDRToneMap(_ enabled: Bool) {
        guard hdrToneMapAvailable, hdrToneMapEnabled != enabled else { return }
        hdrToneMapEnabled = enabled
        onToggleHDRToneMapping?(enabled)
    }

    /// 当前时间所在章节（章节菜单勾选用）。
    func currentChapterIndex(at time: Double) -> Int? {
        chapters.lastIndex { $0.start <= time + 0.4 }
    }

    func updateAudio(choices: [AudioChoice], selected: Int) {
        audioChoices = choices
        // 选中项必须落在列表里：音轨序号来自 ffprobe / AVPlayer 两套统计口径，
        // 偶尔会和传进来的下标错开，直接 clamp 会让菜单里一条都不打勾。
        if choices.contains(where: { $0.index == selected }) {
            selectedAudioIndex = selected
        } else {
            selectedAudioIndex = choices.first?.index ?? selected
        }
    }

    func selectAudio(_ index: Int) {
        guard index != selectedAudioIndex, audioChoices.contains(where: { $0.index == index }) else { return }
        selectedAudioIndex = index
        onSelectStreamAudio?(index)
    }

    /// 当前时间点应显示的字幕（已套用偏移）。正值 = 字幕延后出现。
    func cue(at time: Double) -> SubtitleCue? {
        SubtitleLoader.cue(at: time - subtitleOffset, in: subtitleCues)
    }

    func adjustOffset(_ delta: Double) {
        let value = (subtitleOffset + delta) * 10
        subtitleOffset = value.rounded() / 10
    }

    func resetOffset() {
        subtitleOffset = 0
    }

    func clearSubtitle() {
        loadToken &+= 1
        subtitleCues = []
        subtitleName = nil
    }

    // MARK: 内嵌字幕

    /// ffprobe 探测到的内嵌字幕轨；文本轨可提取成 cue，图形轨（PGS）只能烧录。
    /// 菜单按默认中文偏好排序（简体 > 繁体 > 中文 > 其他），序号仍用原始轨道号。
    func updateEmbeddedTracks(_ tracks: [SubtitleTrackInfo]) {
        embeddedTracks = tracks.sorted { lhs, rhs in
            let left = SubtitlePreference.rank(language: lhs.language, title: lhs.title)
            let right = SubtitlePreference.rank(language: rhs.language, title: rhs.title)
            if left != right { return left < right }
            // forced 轨只翻译对白以外的内容，排在完整轨之后；同语言优先容器默认轨。
            if lhs.isForced != rhs.isForced { return !lhs.isForced }
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.ordinal < rhs.ordinal
        }
    }

    /// 选中内嵌轨。`remember` = false 用于自动挂载 / 恢复记忆，不覆盖用户的手动选择。
    func selectEmbeddedTrack(_ track: SubtitleTrackInfo, remember: Bool = true) {
        guard !embeddedLoading, !track.isImage else { return }
        embeddedLoading = true
        embeddedTrackOrdinal = track.ordinal
        if remember {
            hasManualSubtitleChoice = true
            onSubtitleSelectionRemembered?(RememberedSubtitle(kind: .embedded, ordinal: track.ordinal))
        }
        onSelectEmbeddedSubtitle?(track)
    }

    /// 播放页把提取出来的 cue 交回来：复用外挂字幕的覆盖层渲染。
    func applyEmbeddedSubtitle(name: String, cues: [SubtitleCue]) {
        embeddedLoading = false
        guard !cues.isEmpty else {
            embeddedTrackOrdinal = nil
            onMessage?("这条内嵌字幕无法转成文本，请改用字幕烧录")
            return
        }
        loadToken &+= 1
        subtitleCues = cues
        subtitleName = name
        subtitleOffset = 0
    }

    func failEmbeddedSubtitle(_ message: String) {
        embeddedLoading = false
        embeddedTrackOrdinal = nil
        onMessage?(message)
    }

    func clearEmbeddedSubtitle() {
        embeddedTrackOrdinal = nil
        embeddedLoading = false
        clearSubtitle()
    }

    // MARK: 烧录字幕（PGS / SUP / ASS）

    /// 直接烧录内嵌图形字幕轨（PGS / VobSub）：不需要用户另选 .sup 文件。
    /// 烧录期间视频必须重编码，切换音轨 / 拖动都会复用新的转码流。
    func burnEmbeddedTrack(_ track: SubtitleTrackInfo) {
        guard track.isImage else { return }
        burnSubtitleURL = nil
        burnSubtitleName = track.displayName
        burnSubtitleStream = track.ordinal
        onMessage?("已开启图形字幕烧录：\(track.displayName)，正在重新转码")
        onBurnSubtitleChanged?()
    }

    /// 选一个字幕文件交给 ffmpeg 烧进画面：PGS / SUP 等图形字幕无法走原生字幕轨。
    /// 选完后由播放页重建转码流，可能比普通播放慢一点。
    func pickBurnInSubtitle() {
        let panel = NSOpenPanel()
        panel.title = "选择要烧录的字幕"
        panel.allowedContentTypes = ["sup", "pgs", "ass", "ssa", "srt", "vtt"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 复制到纯 ASCII 临时路径：ffmpeg 的 subtitles 滤镜对空格 / 冒号 / 中文很敏感。
        let ext = url.pathExtension.isEmpty ? "ass" : url.pathExtension.lowercased()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-burn-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: temp)
        } catch {
            onMessage?("无法读取这个字幕文件：\(error.localizedDescription)")
            return
        }
        burnSubtitleStream = nil
        burnSubtitleURL = temp
        burnSubtitleName = url.lastPathComponent
        onMessage?("已开启字幕烧录：\(url.lastPathComponent)，正在重新转码")
        onBurnSubtitleChanged?()
    }

    func clearBurnInSubtitle() {
        guard burnSubtitleURL != nil || burnSubtitleStream != nil else { return }
        burnSubtitleURL = nil
        burnSubtitleStream = nil
        burnSubtitleName = nil
        onMessage?("已关闭字幕烧录")
        onBurnSubtitleChanged?()
    }

    /// 载入一条字幕文件。`rememberFileName` 非空时记为这部电影的手动选择，下次打开自动恢复。
    func loadSubtitle(url: URL, rememberFileName: String? = nil) {
        loadToken &+= 1
        let token = loadToken
        let name = url.lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            let cues = SubtitleLoader.load(url: url)
            Task { @MainActor [weak self] in
                guard let self, token == self.loadToken else { return }
                guard !cues.isEmpty else {
                    self.onMessage?("未能解析该字幕文件")
                    return
                }
                self.subtitleCues = cues
                self.subtitleName = name
                self.subtitleOffset = 0
                if let rememberFileName {
                    self.hasManualSubtitleChoice = true
                    self.onSubtitleSelectionRemembered?(
                        RememberedSubtitle(kind: .external, fileName: rememberFileName))
                }
            }
        }
    }

    /// 同目录同名的外挂字幕自动挂载（本地 / SMB 可直接命中）。
    /// 目录扫描必须离开主线程：图库一个 originals 分片目录可能有几万个文件，
    /// 在外置盘上同步枚举会让打开视频时整个界面卡住好几秒。
    func loadSiblingIfAvailable(sourceURL: URL?) {
        currentSourceURL = sourceURL
        // 同目录外挂字幕默认不自动挂载：由设置 › 影院 › 字幕里的开关控制。
        guard AppSettings.shared.autoSiblingSubtitles else { return }
        guard subtitleCues.isEmpty, subtitleName == nil, let sourceURL else { return }
        let token = loadToken
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let sibling = SubtitleLoader.preferredSibling(of: sourceURL) else { return }
            Task { @MainActor in
                guard let self, token == self.loadToken, self.subtitleCues.isEmpty else { return }
                self.loadSubtitle(url: sibling)
            }
        }
    }

    func pickSubtitle() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let types = SubtitleLoader.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if types.count == SubtitleLoader.supportedExtensions.count {
            panel.allowedContentTypes = types
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 只有和片源同目录时才记文件名：下次还能在同一位置找到它。
        let sameFolder = url.deletingLastPathComponent().standardizedFileURL
            == currentSourceURL?.deletingLastPathComponent().standardizedFileURL
        loadSubtitle(url: url, rememberFileName: sameFolder ? url.lastPathComponent : nil)
    }

    // MARK: 在线字幕

    /// 当前配置的字幕来源：OpenSubtitles 与伪射手各自独立开关。
    private var providerConfiguration: SubtitleProviderService.Configuration {
        let settings = AppSettings.shared
        return SubtitleProviderService.Configuration(
            openSubtitles: OpenSubtitlesClient.Credentials(apiKey: settings.cinemaSubtitleAPIKey,
                                                           username: settings.cinemaSubtitleUsername,
                                                           password: settings.cinemaSubtitlePassword),
            openSubtitlesEnabled: settings.subtitleProviderOpenSubtitlesEnabled,
            assrtToken: settings.assrtSubtitleToken,
            assrtEnabled: settings.subtitleProviderAssrtEnabled)
    }

    /// 影院 / 网络资源播放时有片名就可以搜；没配置来源时仍然显示入口，点了给明确提示。
    var canSearchOnlineSubtitles: Bool {
        subtitleQuery != nil
    }

    func searchOnlineSubtitles() {
        guard let query = subtitleQuery, !onlineSubtitleLoading else { return }
        onlineSubtitleLoading = true
        onlineSubtitleHint = nil
        onlineSubtitles = []
        let configuration = providerConfiguration
        guard configuration.hasAnyProvider else {
            onlineSubtitleLoading = false
            onlineSubtitleHint = "还没有配置字幕来源，去设置 › 影院 › 字幕里添加"
            return
        }
        Task { @MainActor in
            defer { onlineSubtitleLoading = false }
            let matches = await SubtitleProviderService.searchAll(title: query.title,
                                                                   isTV: query.isTV,
                                                                   season: query.season,
                                                                   episode: query.episode,
                                                                   configuration: configuration)
            onlineSubtitles = matches
            onlineSubtitleHint = matches.isEmpty ? "没有找到匹配的字幕" : nil
        }
    }

    func downloadOnlineSubtitle(_ match: CinemaSubtitleMatch) {
        guard !onlineSubtitleLoading else { return }
        onlineSubtitleLoading = true
        let configuration = providerConfiguration
        Task { @MainActor in
            defer { onlineSubtitleLoading = false }
            do {
                let url = try await SubtitleProviderService.download(match, configuration: configuration)
                loadSubtitle(url: url)
                onlineSubtitleHint = "已载入 \(match.languageTitle) · \(match.provider.title)"
            } catch {
                onlineSubtitleHint = error.localizedDescription
                onMessage?(error.localizedDescription)
            }
        }
    }

    /// 自动在线匹配：仅在设置开启、还没有任何字幕时执行一次，失败不打扰用户。
    func autoMatchOnlineSubtitleIfNeeded() async {
        let settings = AppSettings.shared
        guard settings.autoOnlineSubtitles, !autoOnlineTried else { return }
        guard !hasSubtitle, let query = subtitleQuery else { return }
        let configuration = providerConfiguration
        guard configuration.hasAnyProvider else { return }
        autoOnlineTried = true

        let matches = await SubtitleProviderService.searchAll(title: query.title,
                                                              isTV: query.isTV,
                                                              season: query.season,
                                                              episode: query.episode,
                                                              configuration: configuration)
        // 搜索期间同目录 / 内嵌字幕可能已经挂上：保持优先级，不覆盖。
        guard !hasSubtitle, let best = matches.first else { return }
        guard let url = try? await SubtitleProviderService.download(best, configuration: configuration),
              !hasSubtitle else { return }
        loadSubtitle(url: url)
    }
}
