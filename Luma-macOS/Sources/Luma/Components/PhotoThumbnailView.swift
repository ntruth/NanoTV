import SwiftUI
import AppKit

/// 缩略图用途：按实际显示尺寸决定解码像素，避免一律解码 1200px。
enum ThumbnailPurpose {
    /// 网格单元格：像素由格子尺寸推导，走“快速层 + 目标档位”两层加载。
    case grid(maxPixel: CGFloat)
    /// 封面、头像、卡片等按显示边长（pt）取图。
    case cover(CGFloat)
    /// 胶片条等小图，按显示高度（pt）取图。
    case filmstrip(CGFloat)
    /// 导入窗口预览。
    case preview(CGFloat)

    /// Retina 2x 估算，最终会被 ImageLoader 收敛到固定档位。
    static let scale: CGFloat = 2

    var maxPixel: CGFloat {
        switch self {
        case .grid(let pixels):
            return pixels
        case .cover(let side), .filmstrip(let side), .preview(let side):
            return side * Self.scale
        }
    }

    var isTwoTier: Bool {
        if case .grid = self { return true }
        return false
    }
}

/// 缩略图取图的唯一实现：缓存命中、快速层、目标档位解码与取消都在这里，
/// 视图组件与网格单元格共用，避免各处重复写解码顺序。
@MainActor
enum PhotoThumbnailLoader {
    /// 返回目标档位图像；`onQuick` 会在快速层就绪时先回调（仅 `.grid` 有快速层）。
    static func load(photo: PhotoItem,
                     purpose: ThumbnailPurpose,
                     store: LibraryStore,
                     onQuick: (NSImage) -> Void = { _ in }) async -> NSImage? {
        // 已刮削的视频优先显示海报 / 背景图，所有网盘与本地库通用。
        if photo.isVideo, let artwork = store.cinemaGridArtwork(for: photo),
           let image = await CinemaArtworkCache.shared.image(for: artwork) {
            return image
        }
        let maxPixel = purpose.maxPixel
        if photo.isCloud {
            // 云盘两层加载：先读 192px 快速层（纯本地），目标图仍按需走网络。
            if purpose.isTwoTier,
               ImageLoader.pixelBucket(for: maxPixel) > ImageLoader.gridQuickPixel,
               let quick = await store.cloudQuickThumbnail(for: photo,
                                                           maxPixel: CGFloat(ImageLoader.gridQuickPixel)) {
                guard !Task.isCancelled else { return nil }
                onQuick(quick)
            }
            return await store.cloudThumbnail(for: photo)
        }
        // 本地视频缺封面（导入时尚不支持 MKV）时，用内置 ffmpeg 补一帧。
        if photo.isVideo {
            await ImageLoader.LocalVideoPoster.ensure(for: photo)
        }
        if let cached = ImageLoader.cachedGridImage(for: photo, maxPixel: maxPixel) {
            return cached
        }
        // 原生系统图库：优先由系统「照片」给出缩略图（含预取、iCloud 与共享相簿资源）。
        if photo.isSystem, store.usesPhotoKitThumbnails {
            let bucket = ImageLoader.pixelBucket(for: maxPixel)
            if purpose.isTwoTier, bucket > ImageLoader.gridQuickPixel {
                if let quick = await PhotoKitThumbnailProvider.shared.thumbnail(
                    for: photo,
                    maxPixel: ImageLoader.gridQuickPixel,
                    degradedAllowed: true
                ) {
                    guard !Task.isCancelled else { return nil }
                    ImageLoader.storeGridThumbnail(quick, for: photo,
                                                   maxPixel: CGFloat(ImageLoader.gridQuickPixel))
                    onQuick(quick)
                }
            }
            if let image = await PhotoKitThumbnailProvider.shared.thumbnail(for: photo, maxPixel: bucket) {
                guard !Task.isCancelled else { return nil }
                ImageLoader.storeGridThumbnail(image, for: photo, maxPixel: maxPixel)
                return image
            }
            // 系统取不到（该项目不在当前系统照片库等）：继续走本地 derivative / 现场解码。
        }
        if purpose.isTwoTier,
           ImageLoader.pixelBucket(for: maxPixel) > ImageLoader.gridQuickPixel {
            let quick = await Task.detached(priority: .userInitiated) {
                ImageLoader.gridThumbnail(for: photo, maxPixel: CGFloat(ImageLoader.gridQuickPixel))
            }.value
            guard !Task.isCancelled else { return nil }
            if let quick { onQuick(quick) }
        }
        return await Task.detached(priority: .utility) {
            ImageLoader.gridThumbnail(for: photo, maxPixel: maxPixel)
        }.value
    }
}

/// 统一缩略图组件：异步加载、取消、缓存命中与“先低清后目标档位”的降级都在这里。
struct PhotoThumbnailView: View {
    @EnvironmentObject private var store: LibraryStore
    let photo: PhotoItem
    var purpose: ThumbnailPurpose = .cover(220)
    var contentMode: ContentMode = .fill

    @State private var image: NSImage?
    @State private var didFail = false

    private var loadKey: String {
        "\(photo.cacheKey)|\(Int(purpose.maxPixel.rounded()))|\(photo.isCloud)"
    }

    var body: some View {
        ZStack {
            // 与网格单元格一致的占位渐变，避免封面加载时是一块死灰。
            LinearGradient(colors: [Color(nsColor: .quaternaryLabelColor).opacity(0.22),
                                    Color(nsColor: .quaternaryLabelColor).opacity(0.10)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if didFail || photo.isVideo {
                Image(systemName: photo.isVideo ? "video" : "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .animation(.easeOut(duration: 0.18), value: image != nil)
        .task(id: loadKey) { await load() }
    }

    private func load() async {
        didFail = false
        let loaded = await PhotoThumbnailLoader.load(photo: photo, purpose: purpose, store: store) { quick in
            image = quick
        }
        guard !Task.isCancelled else { return }
        // 目标档位失败时保留已经出图的快速层。
        if let loaded { image = loaded }
        didFail = image == nil
    }
}
