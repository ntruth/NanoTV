import AppKit
import SwiftUI
import AVKit
import AVFoundation
import Combine

/// 预告片请求：详情页只带「片名 + 年份 + 类型」，由播放层自己去豆瓣找片源。
struct CinemaTrailerRequest: Identifiable, Hashable {
    let title: String
    let originalTitle: String?
    let year: Int?
    let isTV: Bool

    var id: String {
        [title, originalTitle ?? "", year.map(String.init) ?? "", isTV ? "tv" : "movie"]
            .joined(separator: "|")
    }
}

/// 播放层的前景色：深色下是白，浅色下是近黑的墨色。
private let trailerInk = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor.white
        : NSColor(calibratedWhite: 0.10, alpha: 1)
})

/// 播放层背景：深色下保持影院暗色，浅色下切到窗口底色，和详情页同一套。
private let trailerBackdrop = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(calibratedRed: 0.03, green: 0.033, blue: 0.042, alpha: 1)
        : NSColor.windowBackgroundColor
})

/// 背景角落的暗角：浅色下只留极淡的一层，避免整页发灰。
private let trailerShade = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor.black.withAlphaComponent(0.35)
        : NSColor.black.withAlphaComponent(0.04)
})

/// 详情页内的预告片播放层：铺满页面、不打开浏览器，底色跟随页面外观。
/// 片源来自豆瓣的 mp4 直链，多条时底部给一排切换胶囊。
struct CinemaTrailerOverlay: View {
    let request: CinemaTrailerRequest
    var onClose: () -> Void

    @StateObject private var playback = CinemaTrailerPlayback()
    @State private var trailers: [DoubanTrailerClient.Trailer] = []
    @State private var selectedID: String?
    @State private var loading = true
    @State private var reloadToken = 0

    private var selected: DoubanTrailerClient.Trailer? {
        trailers.first { $0.id == selectedID } ?? trailers.first
    }

    var body: some View {
        GeometryReader { proxy in
            // 画面宽度同时受可视区宽高约束：宽屏尽量铺满，矮窗口自动缩小到能完整显示 16:9。
            let horizontal: CGFloat = 34
            let vertical: CGFloat = 28
            let chrome: CGFloat = trailers.count > 1 ? 180 : 134
            let availableWidth = max(320, proxy.size.width - horizontal * 2)
            let widthByHeight = max(320, (proxy.size.height - chrome) * 16.0 / 9.0)
            let contentWidth = min(availableWidth, widthByHeight)

            ZStack {
                backdrop
                VStack(spacing: 16) {
                    header
                    stage
                    if trailers.count > 1 {
                        picker
                    }
                }
                .frame(width: contentWidth)
                .padding(.vertical, vertical)
            }
        }
        .task(id: reloadToken) { await load() }
        .onDisappear { playback.stop() }
    }

    // MARK: 背景

    private var backdrop: some View {
        ZStack {
            trailerBackdrop.opacity(0.975)
            RadialGradient(colors: [LumaBrand.amber.opacity(0.10), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 620)
            RadialGradient(colors: [trailerShade, .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 720)
        }
        .ignoresSafeArea()
    }

    // MARK: 抬头

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(LumaBrand.amber)
                        .frame(width: 5, height: 5)
                    Text("预告片")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(LumaBrand.amber)
                }
                Text(request.title)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(trailerInk)
                    .lineLimit(1)
                if let selected {
                    Text([selected.title, selected.runtime].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(trailerInk.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            sourceChip
            closeButton
        }
    }

    private var sourceChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "globe.asia.australia.fill")
                .font(.system(size: 9.5, weight: .semibold))
            Text("国内源 · 豆瓣")
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(LumaBrand.amber)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(LumaBrand.amber.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().strokeBorder(LumaBrand.amber.opacity(0.30), lineWidth: 0.7)
        }
        .help("预告片来自豆瓣，App 内直接播放")
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(trailerInk.opacity(0.9))
                .frame(width: 32, height: 32)
                .background(trailerInk.opacity(0.12), in: Circle())
                .overlay {
                    Circle().strokeBorder(trailerInk.opacity(0.10), lineWidth: 0.6)
                }
        }
        .buttonStyle(.plain)
        .help("关闭预告片（Esc）")
    }

    // MARK: 画面

    private var stage: some View {
        ZStack {
            Color.black.opacity(0.88)
            if loading {
                placeholder(icon: nil, title: "正在查找预告片…",
                            detail: "豆瓣 · 国内源，通常一两秒")
            } else if selected != nil {
                if let player = playback.player {
                    TrailerSurfaceView(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder(icon: "film", title: "预告片暂时无法播放",
                                detail: "片源地址可能已过期，重新试一次。",
                                retry: true)
                }
            } else {
                placeholder(icon: "film", title: "没有找到这部作品的预告片",
                            detail: "豆瓣还没有收录它的预告片，稍后可以再试。",
                            retry: true)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
    }

    private func placeholder(icon: String?,
                             title: String,
                             detail: String,
                             retry: Bool = false) -> some View {
        VStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(LumaBrand.amber.opacity(0.8))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.8))
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
            if retry {
                Button {
                    reloadToken &+= 1
                } label: {
                    Label("再试一次", systemImage: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(LumaBrand.amber.opacity(0.16), in: Capsule())
                        .foregroundStyle(LumaBrand.amber)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(24)
        .multilineTextAlignment(.center)
    }

    // MARK: 多条预告片

    private var picker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(trailers) { trailer in
                    let active = trailer.id == selected?.id
                    Button {
                        guard !active else { return }
                        selectedID = trailer.id
                        playback.load(trailer)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: active ? "play.fill" : "play")
                                .font(.system(size: 8.5, weight: .bold))
                            Text(trailer.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                            if let runtime = trailer.runtime {
                                Text(runtime)
                                    .font(.system(size: 10, design: .monospaced))
                                    .opacity(0.6)
                            }
                        }
                        .foregroundStyle(active ? Color.black : trailerInk.opacity(0.88))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(active ? LumaBrand.amber : trailerInk.opacity(0.10),
                                    in: Capsule())
                        .overlay {
                            if !active {
                                Capsule().strokeBorder(trailerInk.opacity(0.08), lineWidth: 0.6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
    }

    // MARK: 加载

    private func load() async {
        loading = true
        let list = await DoubanTrailerClient.trailers(title: request.title,
                                                      originalTitle: request.originalTitle,
                                                      year: request.year,
                                                      isTV: request.isTV)
        guard !Task.isCancelled else { return }
        trailers = list
        if let first = list.first {
            selectedID = first.id
            playback.load(first)
        } else {
            selectedID = nil
            playback.stop()
        }
        loading = false
    }
}

/// 持有 AVPlayer 与自定义资源加载器：豆瓣直链必须带 Referer，
/// 交给 `CloudAssetResourceLoader` 代理读取，播放器侧不用关心请求头。
final class CinemaTrailerPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?

    private var loader: CloudAssetResourceLoader?

    func load(_ trailer: DoubanTrailerClient.Trailer) {
        stop()
        guard let made = CloudAssetResourceLoader.makeAsset(
            upstreamURL: trailer.url,
            headers: ["Referer": trailer.referer, "User-Agent": Self.userAgent],
            trustSelfSigned: false,
            pathExtension: "mp4"
        ) else { return }
        loader = made.loader
        let player = AVPlayer(playerItem: AVPlayerItem(asset: made.asset))
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player
        player.play()
    }

    func stop() {
        player?.pause()
        player = nil
        loader?.invalidate()
        loader = nil
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

private struct TrailerSurfaceView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
