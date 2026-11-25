import Foundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import AVFoundation
import Network
import NetFS


/// 只依赖已下载的字节片段，解析 JPEG 尺寸、渐进式标记与 EXIF 内嵌缩略图。
enum JPEGMetadata {
    struct Info {
        var width: Int?
        var height: Int?
        var isProgressive = false
        var exifThumbnail: Data?
    }

    static func parse(_ data: Data) -> Info {
        var info = Info()
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return info }

        var index = 2
        while index + 4 <= bytes.count {
            guard bytes[index] == 0xFF else {
                index += 1
                continue
            }
            let marker = bytes[index + 1]
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                index += 2
                continue
            }
            // SOS 之后是熵编码数据，不再解析段结构；EOI 直接结束。
            if marker == 0xDA || marker == 0xD9 { break }

            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2, index + 2 + length <= bytes.count else { break }
            let payloadStart = index + 4
            let payloadEnd = index + 2 + length

            switch marker {
            case 0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF:
                if payloadEnd - payloadStart >= 5 {
                    info.height = Int(bytes[payloadStart + 1]) << 8 | Int(bytes[payloadStart + 2])
                    info.width = Int(bytes[payloadStart + 3]) << 8 | Int(bytes[payloadStart + 4])
                }
                info.isProgressive = marker == 0xC2
            case 0xE1:
                if info.exifThumbnail == nil, payloadEnd - payloadStart > 6,
                   bytes[payloadStart] == 0x45, bytes[payloadStart + 1] == 0x78,
                   bytes[payloadStart + 2] == 0x69, bytes[payloadStart + 3] == 0x66,
                   bytes[payloadStart + 4] == 0x00, bytes[payloadStart + 5] == 0x00 {
                    let tiff = Array(bytes[(payloadStart + 6)..<payloadEnd])
                    info.exifThumbnail = exifThumbnail(fromTIFF: tiff)
                }
            default:
                break
            }
            index = payloadEnd
        }
        return info
    }

    private static func exifThumbnail(fromTIFF tiff: [UInt8]) -> Data? {
        guard tiff.count > 8 else { return nil }
        let littleEndian: Bool
        if tiff[0] == 0x49, tiff[1] == 0x49 {
            littleEndian = true
        } else if tiff[0] == 0x4D, tiff[1] == 0x4D {
            littleEndian = false
        } else {
            return nil
        }

        func u16(_ offset: Int) -> Int {
            guard offset + 2 <= tiff.count else { return 0 }
            return littleEndian
                ? Int(tiff[offset]) | Int(tiff[offset + 1]) << 8
                : Int(tiff[offset]) << 8 | Int(tiff[offset + 1])
        }

        func u32(_ offset: Int) -> Int {
            guard offset + 4 <= tiff.count else { return 0 }
            if littleEndian {
                return Int(tiff[offset]) | Int(tiff[offset + 1]) << 8
                    | Int(tiff[offset + 2]) << 16 | Int(tiff[offset + 3]) << 24
            }
            return Int(tiff[offset]) << 24 | Int(tiff[offset + 1]) << 16
                | Int(tiff[offset + 2]) << 8 | Int(tiff[offset + 3])
        }

        guard u16(2) == 42 else { return nil }
        var ifdOffset = u32(4)
        guard ifdOffset >= 8, ifdOffset + 2 <= tiff.count else { return nil }

        let firstCount = u16(ifdOffset)
        let nextIFDOffset = ifdOffset + 2 + firstCount * 12
        guard nextIFDOffset + 2 <= tiff.count else { return nil }
        ifdOffset = u32(nextIFDOffset)
        guard ifdOffset + 2 <= tiff.count else { return nil }

        let count = u16(ifdOffset)
        var thumbOffset = 0
        var thumbLength = 0
        for i in 0..<count {
            let entry = ifdOffset + 2 + i * 12
            guard entry + 12 <= tiff.count else { break }
            let tag = u16(entry)
            let value = u32(entry + 8)
            if tag == 0x0201 { thumbOffset = value }
            if tag == 0x0202 { thumbLength = value }
        }
        guard thumbOffset > 0, thumbLength > 4,
              thumbOffset + thumbLength <= tiff.count else { return nil }
        let thumbnail = Data(tiff[thumbOffset..<(thumbOffset + thumbLength)])
        guard thumbnail.count > 4, thumbnail[0] == 0xFF, thumbnail[1] == 0xD8 else { return nil }
        return thumbnail
    }
}

// MARK: - 缩略图加载

actor CloudConcurrencyGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if active < limit, waiters.isEmpty {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        active += 1
    }

    func release() {
        active = max(0, active - 1)
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        }
    }
}

actor CloudThumbnailLoader {
    static let shared = CloudThumbnailLoader()

    private var running: [String: Task<CloudThumbnailResult, Never>] = [:]
    private static let gate = CloudConcurrencyGate(limit: 3)

    func thumbnail(for photo: PhotoItem, mount: CloudMount, password: String) async -> CloudThumbnailResult {
        let empty = CloudThumbnailResult(image: nil, size: nil, duration: nil)
        guard let path = photo.cloudPath else { return empty }
        let cacheURL = CloudPaths.thumbnailURL(mountID: mount.id, path: path)
        if let image = NSImage(contentsOf: cacheURL) {
            return CloudThumbnailResult(image: image, size: nil, duration: nil)
        }
        let key = cacheURL.path
        // 刚失败过的项目不再重复打远端：滚动回来时直接显示占位。
        if await CloudThumbnailFailureCache.shared.isFailing(key) { return empty }
        if let task = running[key] {
            return await task.value
        }
        let isVideo = photo.isVideo
        let task = Task<CloudThumbnailResult, Never> {
            await Self.gate.acquire()
            let result = await Self.generate(cacheURL: cacheURL,
                                             mount: mount,
                                             path: path,
                                             password: password,
                                             isVideo: isVideo)
            // 目标图生成成功后顺手产出 192px 快速层：滚动时先出小图，不必等 900px 解码。
            if result.image != nil {
                Self.writeQuickLayer(cacheURL: cacheURL, mountID: mount.id, path: path)
            }
            await Self.gate.release()
            return result
        }
        running[key] = task
        let result = await task.value
        running[key] = nil
        if result.image == nil {
            await CloudThumbnailFailureCache.shared.markFailure(key)
        } else {
            await CloudThumbnailFailureCache.shared.clear(key)
        }
        return result
    }

    /// 阿里 / 百度 / 夸克没有服务端缩略图时：用 ffmpeg 直接读直链抽一帧。
    func remotePoster(for photo: PhotoItem, stream: CloudStreamResource,
                      trustSelfSigned: Bool) async -> CloudThumbnailResult {
        let empty = CloudThumbnailResult(image: nil, size: nil, duration: nil)
        guard let mountID = photo.cloudMountID, let path = photo.cloudPath else { return empty }
        let cacheURL = CloudPaths.thumbnailURL(mountID: mountID, path: path)
        if let image = NSImage(contentsOf: cacheURL) {
            return CloudThumbnailResult(image: image, size: nil, duration: nil)
        }
        let key = "poster|\(cacheURL.path)"
        if await CloudThumbnailFailureCache.shared.isFailing(key) { return empty }
        if let task = running[key] { return await task.value }
        let url = stream.url
        let headers = stream.headers
        let task = Task<CloudThumbnailResult, Never> {
            await Self.gate.acquire()
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let ok = VideoSupport.makeRemoteThumbnail(url: url, headers: headers,
                                                      trustSelfSigned: trustSelfSigned,
                                                      destination: cacheURL)
            var size: CGSize?
            var duration: Double?
            var image: NSImage?
            if ok {
                image = NSImage(contentsOf: cacheURL)
                let meta = VideoSupport.ffprobeMetadata(url: url, headers: headers,
                                                        tlsInsecure: trustSelfSigned)
                if meta.size.width > 0 { size = meta.size }
                if meta.duration > 0 { duration = meta.duration }
                Self.writeQuickLayer(cacheURL: cacheURL, mountID: mountID, path: path)
            }
            await Self.gate.release()
            return CloudThumbnailResult(image: image, size: size, duration: duration)
        }
        running[key] = task
        let result = await task.value
        running[key] = nil
        if result.image == nil {
            await CloudThumbnailFailureCache.shared.markFailure(key)
        } else {
            await CloudThumbnailFailureCache.shared.clear(key)
        }
        return result
    }

    private static func generate(cacheURL: URL, mount: CloudMount, path: String,
                                 password: String, isVideo: Bool) async -> CloudThumbnailResult {
        let empty = CloudThumbnailResult(image: nil, size: nil, duration: nil)
        if mount.kind == .smb {
            return await generateSMB(cacheURL: cacheURL, mount: mount, path: path,
                                     password: password, isVideo: isVideo)
        }
        guard let client = WebDAVClient(baseURLString: mount.baseURL,
                                        username: mount.username,
                                        password: password,
                                        allowsSelfSignedCertificate: mount.trustSelfSigned) else { return empty }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        if isVideo {
            guard let url = client.fileURL(path: path) else { return empty }
            // WebDAV 必须带 Basic 认证头、NAS 常是自签名证书，AVFoundation 直连都拿不到数据，
            // 统一由资源读取器代取。
            var keeper: CloudAssetResourceLoader?
            let asset: AVURLAsset
            if let made = CloudAssetResourceLoader.makeAsset(upstreamURL: url,
                                                             headers: client.requestHeaders,
                                                             trustSelfSigned: mount.trustSelfSigned,
                                                             pathExtension: (path as NSString).pathExtension) {
                asset = made.asset
                keeper = made.loader
            } else {
                asset = AVURLAsset(url: url, options: [CloudPlayback.headerFieldsKey: client.requestHeaders])
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1200, height: 1200)
            // 远程资源只求拿到任意一帧，避免为精确时间反复跳读。
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            let seconds = duration > 1 ? min(1, duration / 10) : 0.1
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let generated = try? await generator.image(at: time) {
                keeper?.invalidate()
                let cgImage = generated.image
                ImportService.writeJPEG(cgImage, to: cacheURL, quality: 0.85)
                let image = NSImage(cgImage: cgImage,
                                    size: NSSize(width: cgImage.width, height: cgImage.height))
                return CloudThumbnailResult(image: image, size: nil,
                                            duration: duration > 0 ? duration : nil)
            }
            keeper?.invalidate()
            // MKV 等容器 AVFoundation 无法解析：让 ffmpeg 直接读远端抽一帧。
            if VideoSupport.makeRemoteThumbnail(url: url, headers: client.requestHeaders,
                                                trustSelfSigned: mount.trustSelfSigned,
                                                destination: cacheURL),
               let image = NSImage(contentsOf: cacheURL) {
                let meta = VideoSupport.ffprobeMetadata(url: url, headers: client.requestHeaders)
                Diagnostics.record("WebDAV 视频缩略图改用 ffmpeg \(path)")
                return CloudThumbnailResult(image: image,
                                            size: meta.size.width > 0 ? meta.size : nil,
                                            duration: meta.duration > 0 ? meta.duration : nil)
            }
            Diagnostics.record("WebDAV 视频缩略图失败 \(path)")
            return empty
        }

        // 1) 只取前 256KB：若包含 EXIF 内嵌缩略图，直接使用，避免整张原图下行。
        //    EXIF 扫描通常会先取同一段数据，这里优先复用，避免同一张图请求两次。
        let probeKey = "\(mount.id.uuidString)|\(path)"
        var probe: (data: Data, partial: Bool)?
        if let cached = await CloudProbeCache.shared.probe(for: probeKey) {
            probe = (cached.data, cached.partial)
        } else if let fetched = try? await client.data(path: path, byteRange: 0...262_143) {
            probe = fetched
            await CloudProbeCache.shared.store(.init(data: fetched.data, partial: fetched.partial),
                                               for: probeKey)
        }
        if let probe {
            if !probe.partial {
                if let result = Self.makeThumbnail(from: probe.data, cacheURL: cacheURL) {
                    return result
                }
            } else {
                let info = JPEGMetadata.parse(probe.data)
                if let thumbnail = info.exifThumbnail,
                   let result = Self.makeThumbnail(from: thumbnail,
                                                   cacheURL: cacheURL,
                                                   originalSize: Self.pixelSize(width: info.width,
                                                                                height: info.height)) {
                    return result
                }
                if info.isProgressive,
                   let result = Self.makeThumbnail(from: probe.data, cacheURL: cacheURL) {
                    return result
                }
            }
        }

        // 2) 没有内嵌缩略图（或服务器不支持 Range）：仅对当前项下载完整文件。
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-cloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try await client.download(path: path, to: temp)
        } catch {
            return empty
        }
        let size = ImageLoader.sourcePixelSize(url: temp)
        ImportService.makeImageThumbnail(url: temp, destination: cacheURL, maxPixel: 900)
        guard let image = NSImage(contentsOf: cacheURL) else { return empty }
        return CloudThumbnailResult(image: image, size: size, duration: nil)
    }

    /// SMB 已由系统挂载为本地文件系统，直接读取文件生成缩略图，不经过网络请求层。
    private static func generateSMB(cacheURL: URL, mount: CloudMount, path: String,
                                    password: String, isVideo: Bool) async -> CloudThumbnailResult {
        let empty = CloudThumbnailResult(image: nil, size: nil, duration: nil)
        guard let client = SMBClient(mount: mount, password: password),
              (try? await client.ensureMounted()) != nil,
              let file = client.fileURL(path: path) else { return empty }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if isVideo {
            ImportService.makeVideoThumbnail(url: file, destination: cacheURL)
            guard let image = NSImage(contentsOf: cacheURL) else { return empty }
            return CloudThumbnailResult(image: image, size: nil, duration: nil)
        }
        let size = ImageLoader.sourcePixelSize(url: file)
        ImportService.makeImageThumbnail(url: file, destination: cacheURL, maxPixel: 900)
        guard let image = NSImage(contentsOf: cacheURL) else { return empty }
        return CloudThumbnailResult(image: image, size: size, duration: nil)
    }

    private static func makeThumbnail(from data: Data, cacheURL: URL,
                                      originalSize: CGSize? = nil) -> CloudThumbnailResult? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        ImportService.writeJPEG(cgImage, to: cacheURL, quality: 0.88)
        let size = originalSize ?? Self.pixelSize(source: source)
        return CloudThumbnailResult(image: NSImage(contentsOf: cacheURL), size: size, duration: nil)
    }

    /// 从已生成的 900px 缓存产出 192px 快速层；失败不影响主链路。
    private static func writeQuickLayer(cacheURL: URL, mountID: UUID, path: String) {
        let quickURL = CloudPaths.quickThumbnailURL(mountID: mountID, path: path)
        guard let source = CGImageSourceCreateWithURL(cacheURL as CFURL, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ImageLoader.gridQuickPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let quick = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return
        }
        ImportService.writeJPEG(quick, to: quickURL, quality: 0.75)
    }

    private static func pixelSize(source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        return pixelSize(width: width, height: height)
    }

    private static func pixelSize(width: Int?, height: Int?) -> CGSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}
