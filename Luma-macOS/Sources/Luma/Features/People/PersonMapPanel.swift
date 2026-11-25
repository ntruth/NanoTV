import SwiftUI
import MapKit

/// 人物详情的「地图」：只把这个人物带定位的照片铺在地图上。
/// 复用「位置」页的底图、聚合图钉与足迹回放，尺度自动贴合个人足迹，不展示其他人的照片。
struct PersonMapPanel: View {
    enum Source: Hashable {
        case local(LocalPerson)
        case system(SystemPersonInfo)
        /// 网盘人物：同样是端侧聚类得到的 LocalPerson，但照片来自当前网盘列表。
        case cloud(LocalPerson)

        /// 只用稳定标识参与比较：人物的头像裁切 / 人脸向量变化不应触发地图重载。
        var key: String {
            switch self {
            case .local(let person): return "local-\(person.id.uuidString)-\(person.assetIDs.count)"
            case .system(let person): return "system-\(person.id)"
            case .cloud(let person): return "cloud-\(person.id.uuidString)-\(person.assetIDs.count)"
            }
        }

        static func == (lhs: Source, rhs: Source) -> Bool { lhs.key == rhs.key }

        func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    let source: Source
    let name: String

    @StateObject private var camera = MapCameraController()
    @State private var photos: [PhotoItem] = []
    @State private var isLoading = true
    @State private var showFootprint = false
    @AppStorage("map.style") private var styleRaw = MapStyleMode.map.rawValue
    @AppStorage("map.provider") private var providerRaw = MapProvider.apple.rawValue
    @AppStorage("map.baiduAccessKey") private var baiduKey = ""

    private var style: MapStyleMode { MapStyleMode(rawValue: styleRaw) ?? .map }
    private var provider: MapProvider { MapProvider(rawValue: providerRaw) ?? .apple }
    private var clusters: [PlaceCluster] { PlaceClusterBuilder.clusters(from: photos) }

    var body: some View {
        // 地图铺满人物页剩下的全部空间：不套卡片、不加内外边距，避免留下空白。
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: source) { await load() }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在整理 TA 的足迹…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.035))
        } else if photos.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "mappin.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text("这些照片里还没有位置信息")
                    .font(.system(size: 14, weight: .semibold))
                Text("当 TA 的照片带有 GPS 或地点元数据时，足迹会自动出现在这里。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.035))
        } else {
            mapStack
        }
    }

    private var mapStack: some View {
        ZStack(alignment: .topLeading) {
            MapCanvasView(photos: photos,
                          dataVersion: "\(source.key)|\(photos.count)",
                          provider: provider,
                          style: style,
                          baiduKey: baiduKey,
                          controller: camera,
                          onOpen: { id in store.openViewer(id) })

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    legendBadge
                    footprintButton
                    Spacer(minLength: 8)
                    styleSwitch
                }
                .padding(14)

                Spacer(minLength: 0)

                HStack {
                    Spacer(minLength: 8)
                    zoomControls
                }
                .padding(14)
            }

            if showFootprint {
                FootprintPlaybackView(photos: photos) {
                    showFootprint = false
                }
                .transition(.opacity)
                .zIndex(6)
            }
        }
    }

    // MARK: - 浮层

    private var legendBadge: some View {
        HStack(spacing: 7) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 11))
            Text("\(photos.count.formatted()) 张 · \(clusters.count) 个地点")
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .help("只统计 \(name) 带定位的照片")
    }

    private var footprintButton: some View {
        Button {
            showFootprint = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.circle")
                    .font(.system(size: 11))
                Text("足迹回放")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("按时间顺序把 \(name) 的照片地点播成一条足迹")
    }

    private var styleSwitch: some View {
        HStack(spacing: 2) {
            ForEach([MapStyleMode.map, .satellite]) { item in
                Button {
                    styleRaw = item.rawValue
                } label: {
                    Text(item.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(style == item ? Color.primary : Color.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background {
                            if style == item {
                                Capsule().fill(Color.primary.opacity(0.12))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(item == .map ? "街道底图" : "卫星底图")
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8))
        .animation(settings.motion.hover, value: style)
    }

    private var zoomControls: some View {
        VStack(spacing: 1) {
            Button { camera.zoom(factor: 0.55) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("放大")

            Divider().frame(width: 18)

            Button { camera.zoom(factor: 1.8) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("缩小")

            Divider().frame(width: 18)

            Button { camera.fit(clusters) } label: {
                Image(systemName: "scope")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("回到 TA 的全部足迹")
        }
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    // MARK: - 数据

    private func load() async {
        isLoading = true
        showFootprint = false
        let loaded: [PhotoItem]
        switch source {
        case .local(let person):
            loaded = store.personMapPhotos(local: person)
        case .system(let person):
            loaded = await store.personMapPhotos(system: person)
        case .cloud(let person):
            loaded = store.personMapPhotos(cloud: person)
        }
        guard !Task.isCancelled else { return }
        photos = loaded
        isLoading = false
    }
}
