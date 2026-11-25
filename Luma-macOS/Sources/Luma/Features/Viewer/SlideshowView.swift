import SwiftUI
import AppKit

/// 全窗口幻灯片：自动轮播、暂停、上一张/下一张与间隔设置。
struct SlideshowView: View {
    @EnvironmentObject private var store: LibraryStore

    @AppStorage("slideshowInterval") private var interval: Double = 3
    @AppStorage("slideshowKenBurns") private var kenBurnsEnabled = true
    @State private var index = 0
    @State private var isPlaying = true
    @State private var progress: Double = 0
    @State private var image: NSImage?
    @State private var currentID: UUID?
    /// 分页模式下当前播放的照片：相邻项由 SQLite 给出，可以播放全部照片而不只窗口。
    @State private var pagedCurrent: PhotoItem?
    @State private var keyMonitor: Any?
    @State private var kenBurnsPhase = false

    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var items: [PhotoItem] { store.visiblePhotos }

    private var current: PhotoItem? {
        if store.isPagedScope { return pagedCurrent }
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                    .scaleEffect(kenBurnsEnabled ? (kenBurnsPhase ? 1.10 : 1.02) : 1)
                    .offset(x: kenBurnsEnabled ? (kenBurnsPhase ? 14 : -14) : 0,
                            y: kenBurnsEnabled ? (kenBurnsPhase ? -8 : 8) : 0)
                    .animation(.easeInOut(duration: max(4, interval * 1.4)), value: kenBurnsPhase)
                    .transition(.opacity)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(18)
        }
        .onAppear {
            if store.isSystemPagedScope {
                pagedCurrent = store.selection.first.flatMap { store.anyPhoto(id: $0) }
                    ?? store.systemWindowPhotos.first
            } else if store.isPagedScope {
                pagedCurrent = store.selection.first.flatMap { store.anyPhoto(id: $0) }
                    ?? store.windowPhotos.first
                if pagedCurrent == nil, let query = store.pagedQuery {
                    pagedCurrent = store.metadataStore?.photo(atOffset: 0, in: query)
                }
            } else if let target = store.selection.first,
                      let start = items.firstIndex(where: { $0.id == target }) {
                index = start
            }
            loadImage()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onReceive(timer) { _ in
            tick()
        }
        .onChange(of: index) { _, _ in
            loadImage()
        }
        .onChange(of: pagedCurrent?.id) { _, _ in
            loadImage()
        }
    }

    // MARK: - 控制条

    private var topBar: some View {
        HStack {
            Text("幻灯片")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            if !items.isEmpty {
                Text("\(min(index + 1, items.count)) / \(items.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.14), in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("退出幻灯片 (Esc)")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: max(0, proxy.size.width * min(1, progress)))
                }
            }
            .frame(height: 3)

            HStack(spacing: 18) {
                controlButton("backward.end.fill", help: "上一张 (←)") {
                    advance(-1)
                }

                controlButton(isPlaying ? "pause.fill" : "play.fill",
                              help: isPlaying ? "暂停 (空格)" : "播放 (空格)") {
                    isPlaying.toggle()
                }

                controlButton("forward.end.fill", help: "下一张 (→)") {
                    advance(1)
                }

                controlButton(kenBurnsEnabled ? "wand.and.stars" : "sparkles",
                              help: kenBurnsEnabled ? "关闭 Ken Burns 动态效果" : "开启 Ken Burns 动态效果") {
                    kenBurnsEnabled.toggle()
                }

                Spacer()

                Menu {
                    ForEach([2.0, 3.0, 5.0, 10.0], id: \.self) { value in
                        Button("\(Int(value)) 秒") {
                            interval = value
                            progress = 0
                        }
                    }
                } label: {
                    Text("\(Int(interval)) 秒")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    let window = NSApp.keyWindow
                    window?.toggleFullScreen(nil)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("全屏")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
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

    // MARK: - 播放

    private func tick() {
        guard isPlaying, image != nil else { return }
        progress += 0.05 / max(0.5, interval)
        if progress >= 1 {
            advance(1)
        }
    }

    private func advance(_ delta: Int) {
        if store.isSystemPagedScope, let id = current?.id,
           let query = store.systemPagedQuery, let systemIndex = store.systemIndex {
            guard let next = systemIndex.neighbor(of: id, delta: delta > 0 ? 1 : -1, in: query) else {
                return
            }
            withAnimation(.easeInOut(duration: 0.28)) {
                pagedCurrent = next
            }
            progress = 0
            return
        }
        if store.isPagedScope, let id = current?.id, let query = store.pagedQuery {
            guard let next = store.metadataStore?.neighbor(of: id, delta: delta > 0 ? 1 : -1, in: query) else {
                return
            }
            withAnimation(.easeInOut(duration: 0.28)) {
                pagedCurrent = next
            }
            progress = 0
            return
        }
        guard !items.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            index = (index + delta + items.count) % items.count
        }
        progress = 0
    }

    private func loadImage() {
        guard let photo = current else {
            image = nil
            currentID = nil
            return
        }
        let target = photo
        currentID = photo.id
        image = nil
        Task { @MainActor in
            let loaded: NSImage? = await Task.detached(priority: .userInitiated) {
                target.isVideo
                    ? ImageLoader.thumbnail(for: target)
                    : ImageLoader.displayImage(for: target, maxPixel: 3000)
            }.value
            guard currentID == target.id else { return }
            image = loaded
            progress = 0
            kenBurnsPhase = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                kenBurnsPhase = true
            }
        }
    }

    // MARK: - 键盘

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = NSApp.keyWindow, event.window === window else { return event }
            guard window.attachedSheet == nil else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == 53 {
                close()
                return nil
            }
            if flags.contains(.command) {
                return event
            }
            // 可自定义快捷键允许 ⌥ / ⌃ / ⇧ 组合。
            if ShortcutStore.matches(event, .slideshowPrevious) {
                advance(-1)
                return nil
            }
            if ShortcutStore.matches(event, .slideshowNext) {
                advance(1)
                return nil
            }
            if ShortcutStore.matches(event, .slideshowToggle) {
                isPlaying.toggle()
                return nil
            }
            guard flags.intersection([.option, .control]).isEmpty else { return event }

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

    private func close() {
        store.showSlideshow = false
    }
}
