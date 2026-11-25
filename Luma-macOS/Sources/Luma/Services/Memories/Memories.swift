import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumaContentCore

/// 回忆影片的风格模板：控制 Ken Burns 的方向、幅度与画面比例。
enum MemoryStyle: String, CaseIterable, Identifiable, Hashable {
    case classic
    case cinematic
    case fresh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "经典"
        case .cinematic: return "电影"
        case .fresh: return "清新"
        }
    }

    var icon: String {
        switch self {
        case .classic: return "photo.on.rectangle"
        case .cinematic: return "film"
        case .fresh: return "sun.max"
        }
    }

    /// 起始 / 结束缩放（Ken Burns）。
    var zoomRange: (start: CGFloat, end: CGFloat) {
        switch self {
        case .classic: return (1.0, 1.12)
        case .cinematic: return (1.16, 1.02)
        case .fresh: return (1.02, 1.07)
        }
    }

    /// 平移幅度（相对画面宽度的比例）。
    var panAmount: CGFloat {
        switch self {
        case .classic: return 0.02
        case .cinematic: return 0.04
        case .fresh: return 0.012
        }
    }

    /// 电影风格增加上下黑边。
    var showsLetterbox: Bool { self == .cinematic }
}

/// 自动生成的回忆影片。
struct PhotoMemory: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case month
        case place
        case favorites
        case throwback
    }

    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
    let photos: [PhotoItem]
    var style: MemoryStyle = .classic
}

enum MemoryBuilder {
    static func build(from photos: [PhotoItem], limit: Int = 10) -> [PhotoMemory] {
        let candidates = photos.filter { $0.deletedAt == nil && !$0.isHidden && !$0.isVideo }
        guard candidates.count >= 12 else { return [] }

        let calendar = Calendar.current
        var memories: [PhotoMemory] = []

        // 1. 按月：每个月至少 12 张照片。
        var byMonth: [String: [PhotoItem]] = [:]
        for photo in candidates {
            let comps = calendar.dateComponents([.year, .month], from: photo.capturedAt)
            let key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            byMonth[key, default: []].append(photo)
        }
        for (key, items) in byMonth where items.count >= 12 {
            let sorted = items.sorted { $0.capturedAt < $1.capturedAt }
            let coverDate = sorted.first?.capturedAt ?? Date()
            memories.append(PhotoMemory(id: "month-" + key,
                                        title: monthTitle(coverDate),
                                        subtitle: "\(items.count) 张照片",
                                        kind: .month,
                                        photos: evenlySample(sorted, limit: 30)))
        }

        // 2. 按地点：同一城市至少 15 张。
        var byPlace: [String: [PhotoItem]] = [:]
        for photo in candidates {
            guard let city = photo.placeCity ?? photo.placeProvince, !city.isEmpty else { continue }
            byPlace[city, default: []].append(photo)
        }
        for (city, items) in byPlace where items.count >= 15 {
            let sorted = items.sorted { $0.capturedAt < $1.capturedAt }
            memories.append(PhotoMemory(id: "place-" + city,
                                        title: city,
                                        subtitle: "\(items.count) 张照片",
                                        kind: .place,
                                        photos: evenlySample(sorted, limit: 24)))
        }

        // 3. 个人收藏。
        let favorites = candidates.filter { $0.isFavorite }
        if favorites.count >= 10 {
            let sorted = favorites.sorted { $0.capturedAt > $1.capturedAt }
            memories.append(PhotoMemory(id: "favorites",
                                        title: "个人收藏",
                                        subtitle: "\(favorites.count) 张照片",
                                        kind: .favorites,
                                        photos: evenlySample(sorted, limit: 24)))
        }

        // 4. 往年今日：按年分组，每个有照片的年份各生成一条回忆（最多取最近 3 年）。
        let today = calendar.dateComponents([.month, .day, .year], from: Date())
        var throwbackByYear: [Int: [PhotoItem]] = [:]
        for photo in candidates {
            let comps = calendar.dateComponents([.month, .day, .year], from: photo.capturedAt)
            guard comps.month == today.month, comps.day == today.day,
                  let year = comps.year, year != today.year else { continue }
            throwbackByYear[year, default: []].append(photo)
        }
        for (year, items) in throwbackByYear.sorted(by: { $0.key > $1.key }).prefix(3) {
            let yearsAgo = max(1, (today.year ?? year) - year)
            let sorted = items.sorted { $0.capturedAt > $1.capturedAt }
            memories.append(PhotoMemory(id: "throwback-\(year)",
                                        title: yearsAgo == 1 ? "去年的今天" : "\(yearsAgo) 年前的今天",
                                        subtitle: "\(items.count) 张照片",
                                        kind: .throwback,
                                        photos: evenlySample(sorted, limit: 20),
                                        style: .cinematic))
        }

        // 往年今日置顶，其余按时间从新到旧。
        let ordered = memories.sorted { lhs, rhs in
            if (lhs.kind == .throwback) != (rhs.kind == .throwback) {
                return lhs.kind == .throwback
            }
            return (lhs.photos.first?.capturedAt ?? .distantPast) > (rhs.photos.first?.capturedAt ?? .distantPast)
        }
        return Array(ordered.prefix(limit))
    }

    private static func monthTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: date)
    }

    /// 在保持时间顺序的前提下均匀取样，避免回忆过长。
    private static func evenlySample(_ items: [PhotoItem], limit: Int) -> [PhotoItem] {
        guard items.count > limit, limit > 1 else { return items }
        let step = Double(items.count - 1) / Double(limit - 1)
        var result: [PhotoItem] = []
        for index in 0..<limit {
            let position = min(items.count - 1, Int((Double(index) * step).rounded()))
            result.append(items[position])
        }
        return result
    }
}

/// 全窗口回忆影片：Ken Burns 推进 + 交叉淡入淡出。
struct MemoryMovieView: View {
    @EnvironmentObject private var store: LibraryStore

    let memory: PhotoMemory

    @State private var index = 0
    @State private var isPlaying = true
    @State private var progress: Double = 0
    @State private var images: [Int: NSImage] = [:]
    @State private var keyMonitor: Any?
    @State private var kenBurnsScale: CGFloat = 1
    @State private var kenBurnsOffset: CGSize = .zero
    @State private var style: MemoryStyle = .classic
    @State private var isExporting = false
    @State private var exportProgress: Double = 0

    private let slideDuration: Double = 4.0
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var photos: [PhotoItem] { memory.photos }
    private var current: PhotoItem? {
        photos.indices.contains(index) ? photos[index] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = images[index] {
                GeometryReader { proxy in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(kenBurnsScale)
                        .offset(kenBurnsOffset)
                        .clipped()
                }
                .ignoresSafeArea()
                .id(index)
                .transition(.opacity)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            if style.showsLetterbox {
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        Color.black.frame(height: proxy.size.height * 0.09)
                        Spacer(minLength: 0)
                        Color.black.frame(height: proxy.size.height * 0.09)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(20)

            if isExporting {
                exportOverlay
            }
        }
        .onAppear {
            style = memory.style
            preload(after: 0)
            loadImage(at: 0)
            startKenBurns()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onReceive(timer) { _ in
            guard isPlaying, !isExporting else { return }
            progress += 0.05 / slideDuration
            if progress >= 1 {
                advance(1)
            }
        }
        .onChange(of: index) { _, newValue in
            loadImage(at: newValue)
            preload(after: newValue)
            startKenBurns()
        }
    }

    private var exportOverlay: some View {
        VStack(spacing: 12) {
            ProgressView(value: exportProgress)
                .frame(width: 240)
                .tint(.white)
            Text("正在导出回忆影片… \(Int(exportProgress * 100))%")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
            Text("导出期间请保持窗口打开")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 22, y: 10)
    }

    /// 按当前风格推进 Ken Burns，切换风格或换页都会重新开始这一段动画。
    private func startKenBurns() {
        let range = style.zoomRange
        kenBurnsScale = range.start
        kenBurnsOffset = .zero
        let horizontal: CGFloat = index % 2 == 0 ? 1 : -1
        let vertical: CGFloat = index % 4 < 2 ? 1 : -1
        let travel = style.panAmount * 900
        withAnimation(.easeInOut(duration: slideDuration)) {
            kenBurnsScale = range.end
            kenBurnsOffset = CGSize(width: horizontal * travel, height: vertical * travel * 0.5)
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text(memory.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()

            Menu {
                ForEach(MemoryStyle.allCases) { option in
                    Button {
                        style = option
                        startKenBurns()
                    } label: {
                        if option == style {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Label(option.title, systemImage: option.icon)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: style.icon)
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(style.title)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.14), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("回忆风格")

            Button {
                exportMovie()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isExporting)
            .help("导出为视频…")

            Button {
                store.activeMemory = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.16), in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(isExporting)
            .help("退出回忆 (Esc)")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: max(0, proxy.size.width * min(1, progress)))
                }
            }
            .frame(height: 3)

            HStack(spacing: 18) {
                controlButton("backward.end.fill", help: "上一张 (←)") { advance(-1) }
                controlButton(isPlaying ? "pause.fill" : "play.fill",
                              help: isPlaying ? "暂停 (空格)" : "播放 (空格)") {
                    isPlaying.toggle()
                }
                controlButton("forward.end.fill", help: "下一张 (→)") { advance(1) }
                Spacer()
                if !photos.isEmpty {
                    Text("\(min(index + 1, photos.count)) / \(photos.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .disabled(isExporting)
    }

    /// 把当前回忆渲染为无声 mp4，尺寸 1280×720、24fps。
    private func exportMovie() {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = memory.title + ".mp4"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let wasPlaying = isPlaying
        isPlaying = false
        isExporting = true
        exportProgress = 0
        // 渲染 + 编码是分钟级任务：登记到统一任务中心，导出期间切页也能看到进度。
        let jobID = store.beginSourceJob(
            SourceJob(sourceID: .library((LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
                .standardizedFileURL.path),
                      kind: .export,
                      title: "导出回忆影片",
                      isCancellable: false)
        )

        let snapshot = memory
        let chosenStyle = style
        Task {
            do {
                try await MemoryExporter.export(memory: snapshot, style: chosenStyle, to: url) { value in
                    Task { @MainActor in
                        exportProgress = value
                        store.updateSourceJob(jobID,
                                              message: "正在导出 \(Int((value * 100).rounded()))%",
                                              fraction: value)
                    }
                }
                await MainActor.run {
                    isExporting = false
                    isPlaying = wasPlaying
                    store.finishSourceJob(jobID, message: "已导出 \(url.lastPathComponent)")
                    store.showToast("已导出「\(url.lastPathComponent)」")
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    isPlaying = wasPlaying
                    store.failSourceJob(jobID, message: error.localizedDescription)
                    store.showToast("导出失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func controlButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.12), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func advance(_ delta: Int) {
        guard !photos.isEmpty else { return }
        progress = 0
        withAnimation(.easeInOut(duration: 0.6)) {
            index = (index + delta + photos.count) % photos.count
        }
    }

    private func loadImage(at position: Int) {
        guard images[position] == nil, photos.indices.contains(position) else { return }
        let photo = photos[position]
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageLoader.displayImage(for: photo, maxPixel: 2600)
            }.value
            if let loaded {
                images[position] = loaded
            }
        }
    }

    private func preload(after position: Int) {
        guard !photos.isEmpty else { return }
        let next = (position + 1) % photos.count
        loadImage(at: next)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = NSApp.keyWindow, event.window === window else { return event }
            guard window.attachedSheet == nil else { return event }
            // 导出期间不响应快捷键，避免误关窗口打断写入。
            if isExporting { return nil }

            if event.keyCode == 53 {
                store.activeMemory = nil
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.contains(.command), flags.intersection([.option, .control]).isEmpty else {
                return event
            }
            switch event.keyCode {
            case 123, 126:
                advance(-1)
                return nil
            case 124, 125:
                advance(1)
                return nil
            case 49:
                isPlaying.toggle()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
