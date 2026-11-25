import AppKit
import Foundation
import Photos

/// 原生系统图库的缩略图来源。
///
/// 与手动解码 derivative 文件相比，交给系统「照片」取图有三个好处：
/// 1. 直接复用 Apple 已经生成好的缩略图，HEIC / RAW / 视频封面都不必现场解码；
/// 2. `PHCachingImageManager` 可以按窗口预热，滚动时命中系统缓存；
/// 3. iCloud 未下载、共享相簿的项目由 Photos 自己取资源，不会出现永久空白格。
///
/// 只在「当前容器就是系统照片库 + 已授权」时启用。若资产标识连续解析不到，
/// 会判定为「当前打开的并不是系统照片库」并自动挂起，调用方回退本地解码。
final class PhotoKitThumbnailProvider: @unchecked Sendable {
    static let shared = PhotoKitThumbnailProvider()

    private let lock = NSLock()
    private let imageManager = PHCachingImageManager()
    /// UUID → PHAsset。数量上限按几十万图库滚动一遍的量级设置。
    private let assetCache = NSCache<NSString, PHAsset>()
    /// 查不到的 UUID：避免每次滚动回来都重新发一次 PhotoKit 请求。
    private let missCache = NSCache<NSString, NSNull>()
    /// 当前正在预取的资产（与档位），切换档位或换库时统一停止。
    private var cachingAssets: [PHAsset] = []
    private var cachingSize = 0
    private let cachingLimit = 600
    /// 连续解析失败次数：用于识别「打开的不是系统照片库」。
    private var consecutiveMisses = 0
    private var consecutiveHits = 0
    private var suspended = false

    private init() {
        assetCache.countLimit = 20_000
        missCache.countLimit = 4_000
    }

    static var isAuthorized: Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return true
        default: return false
        }
    }

    var isAvailable: Bool {
        lock.lock()
        let suspended = self.suspended
        lock.unlock()
        return !suspended && Self.isAuthorized
    }

    /// 切换图库时清空：资产标识、查不到标记与预取队列都只对当前图库有效。
    func reset() {
        lock.lock()
        cachingAssets.removeAll()
        cachingSize = 0
        consecutiveMisses = 0
        consecutiveHits = 0
        suspended = false
        assetCache.removeAllObjects()
        missCache.removeAllObjects()
        lock.unlock()
        imageManager.stopCachingImagesForAllAssets()
    }

    // MARK: - 取图

    /// 从系统「照片」取一张缩略图。
    /// - Parameters:
    ///   - maxPixel: 目标像素边长（已经是像素，不是 pt）。
    ///   - degradedAllowed: 快速层用 `fastFormat`，接受系统缓存里的低清图；目标层要最终图。
    func thumbnail(for photo: PhotoItem, maxPixel: Int, degradedAllowed: Bool = false) async -> NSImage? {
        guard maxPixel > 0, photo.isSystem, isAvailable,
              let asset = asset(for: photo.id) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = degradedAllowed ? .fastFormat : .highQualityFormat
        options.resizeMode = .fast
        // 只有用户真正看到的格子才允许走网络；预取与快速层不消耗流量。
        options.isNetworkAccessAllowed = !degradedAllowed
        options.version = .current
        let size = CGSize(width: maxPixel, height: maxPixel)
        let box = ImageRequestBox(manager: imageManager)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                var resumed = false
                let resumeLock = NSLock()
                let requestID = imageManager.requestImage(for: asset,
                                                          targetSize: size,
                                                          contentMode: .aspectFit,
                                                          options: options) { image, info in
                    // 目标层只认最终图，跳过先到的降级图。
                    if !degradedAllowed,
                       (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                        return
                    }
                    resumeLock.lock()
                    if resumed {
                        resumeLock.unlock()
                        return
                    }
                    resumed = true
                    resumeLock.unlock()
                    continuation.resume(returning: image)
                }
                box.set(requestID)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// 按窗口预取：把即将进入视野的资产交给 `PHCachingImageManager` 预热。
    /// 只预热快速层尺寸，单张成本远低于解码原图。
    func prefetch(photos: [PhotoItem], maxPixel: Int) {
        guard maxPixel > 0, isAvailable else { return }
        let ids = photos.lazy.filter(\.isSystem).prefix(200).map(\.id)
        guard !ids.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var found: [PHAsset] = []
            found.reserveCapacity(ids.count)
            for id in ids {
                // 连续解析失败会挂起：立刻停止这一批，别继续发无意义的 PhotoKit 请求。
                guard self.isAvailable else { return }
                if let asset = self.asset(for: id) { found.append(asset) }
            }
            guard !found.isEmpty else { return }
            self.startCaching(found, maxPixel: maxPixel)
        }
    }

    // MARK: - 资产解析

    private func asset(for id: UUID) -> PHAsset? {
        let key = id.uuidString as NSString
        if let asset = assetCache.object(forKey: key) { return asset }
        if missCache.object(forKey: key) != nil { return nil }
        // 系统照片的 localIdentifier 形如 UUID/L0/001；少数项目后缀不同。
        let candidates = ["\(key)/L0/001", "\(key)/L0/000"]
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: candidates, options: nil)
        if let asset = assets.firstObject {
            assetCache.setObject(asset, forKey: key)
            noteHit()
            return asset
        }
        missCache.setObject(NSNull(), forKey: key)
        noteMiss()
        return nil
    }

    private func noteHit() {
        lock.lock()
        consecutiveHits += 1
        consecutiveMisses = 0
        lock.unlock()
    }

    private func noteMiss() {
        lock.lock()
        consecutiveMisses += 1
        // 一个能解析的资产都没有时，说明当前打开的不是系统「照片」图库：挂起并回退本地解码。
        if consecutiveMisses >= 30, consecutiveHits == 0 {
            suspended = true
            assetCache.removeAllObjects()
            missCache.removeAllObjects()
        }
        lock.unlock()
    }

    // MARK: - 预取队列

    private func startCaching(_ assets: [PHAsset], maxPixel: Int) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.version = .current
        let size = CGSize(width: maxPixel, height: maxPixel)

        lock.lock()
        if cachingSize != maxPixel {
            // 缩略图档位变了：之前的预取全部作废，避免两个尺寸同时驻留。
            let previous = cachingAssets
            let previousSize = cachingSize
            cachingAssets.removeAll()
            cachingSize = maxPixel
            lock.unlock()
            if !previous.isEmpty, previousSize > 0 {
                imageManager.stopCachingImages(for: previous,
                                               targetSize: CGSize(width: previousSize, height: previousSize),
                                               contentMode: .aspectFit,
                                               options: options)
            }
            lock.lock()
        }
        let known = Set(cachingAssets.map(\.localIdentifier))
        var additions: [PHAsset] = []
        for asset in assets where !known.contains(asset.localIdentifier) {
            cachingAssets.append(asset)
            additions.append(asset)
        }
        var evicted: [PHAsset] = []
        if cachingAssets.count > cachingLimit {
            let extra = cachingAssets.count - cachingLimit
            evicted = Array(cachingAssets.prefix(extra))
            cachingAssets.removeFirst(extra)
        }
        lock.unlock()

        if !evicted.isEmpty {
            imageManager.stopCachingImages(for: evicted,
                                           targetSize: size,
                                           contentMode: .aspectFit,
                                           options: options)
        }
        if !additions.isEmpty {
            imageManager.startCachingImages(for: additions,
                                            targetSize: size,
                                            contentMode: .aspectFit,
                                            options: options)
        }
    }
}

/// 把 PhotoKit 的请求 ID 包起来，让 SwiftUI 的 `.task` 取消能真正取消系统取图。
private final class ImageRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var manager: PHImageManager?
    private var requestID: PHImageRequestID?
    private var cancelled = false

    init(manager: PHImageManager) {
        self.manager = manager
    }

    func set(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { manager?.cancelImageRequest(id) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = requestID
        lock.unlock()
        if let id { manager?.cancelImageRequest(id) }
    }
}
