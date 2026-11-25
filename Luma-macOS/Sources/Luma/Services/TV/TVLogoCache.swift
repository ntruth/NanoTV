import AppKit
import Foundation
import LumaContentCore

/// 台标缓存：只声明「台标放哪、从哪拉」，内存 / 磁盘 / 并发合并全部交给 `ArtworkCache`。
/// 这样台标不再维护第五套 NSCache 与解码逻辑。
actor TVLogoCache {
    static let shared = TVLogoCache()

    func image(for urlString: String, maxPixelSize: Int = 160) async -> NSImage? {
        guard !urlString.isEmpty else { return nil }
        // key 带上尺寸：同一张台标在源列表与频道墙可能解成两种大小，互不挤占。
        let key = "tv-logo:\(urlString)|\(maxPixelSize)"
        return await ArtworkCache.shared.image(for: key,
                                               diskURL: Self.diskURL(for: urlString),
                                               maxPixelSize: maxPixelSize) {
            await Self.fetch(urlString)
        }
    }

    /// 清空内存与磁盘：设置里「清除台标缓存」或排查坏图时使用。
    func clearAll() async {
        await ArtworkCache.shared.removeAll()
        try? FileManager.default.removeItem(at: Self.directory)
    }

    func diskSize() -> Int64 {
        ArtworkCache.diskSize(at: Self.directory)
    }

    // MARK: - 网络与路径

    private static func fetch(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let response = try await HTTPSourceTransport.shared.send(
                HTTPTransportRequest(url: url, timeout: 20),
                profile: .luma,
                retryPolicy: HTTPRetryPolicy(maxRetries: 1, baseDelay: 0.4)
            )
            return response.data
        } catch {
            return nil
        }
    }

    private static var directory: URL {
        LibraryPaths.tvLogosDir
    }

    private static func diskURL(for urlString: String) -> URL {
        directory.appendingPathComponent("\(fnv1a64(urlString)).img")
    }

    /// 跨启动稳定的短哈希：直接用 String.hashValue 每个进程都不同，不能做文件名。
    private static func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
