import AppKit

/// 海报的内存缓存：同一张封面在同一会话里不再重复读盘 / 解码。
/// 只放缩略图与少量大图，超出上限按插入顺序淘汰，避免长期运行占满内存。
final class CatalogArtworkMemory: @unchecked Sendable {
    static let shared = CatalogArtworkMemory()

    private let lock = NSLock()
    private var images: [String: NSImage] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 180) {
        self.limit = limit
    }

    func image(for key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[key]
    }

    func store(_ image: NSImage, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if images[key] == nil {
            order.append(key)
        }
        images[key] = image
        while order.count > limit {
            images.removeValue(forKey: order.removeFirst())
        }
    }

    func remove(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        images.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        images.removeAll()
        order.removeAll()
    }
}
