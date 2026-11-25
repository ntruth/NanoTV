import Foundation

/// 搜索会话复用：点进某条结果看完再退回来时，继续用同一份检索结果，
/// 不整轮重搜（影院 / 网络影院 / 资源都是联网检索，重跑既慢又浪费）。
///
/// 搜索页销毁后 `SearchCenter` 由这里持有；回来后按关键词与来源集合取回原实例，
/// 正在跑的检索也不会被打断，回来时通常已经是完整结果。
@MainActor
final class SearchSessionStore {
    static let shared = SearchSessionStore()

    /// 最多保留几轮搜索：够覆盖「点进详情 → 返回」的来回，又不至于一直攒着占内存。
    private let capacity = 4
    private var order: [String] = []
    private var centers: [String: SearchCenter] = [:]

    /// 取回关键词相同的检索会话；没有才新建。
    func center(for query: String,
                scopes: [SearchSourceKind],
                make: () -> SearchCenter) -> SearchCenter {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 用户继续输入时同一个 center 会改写 query，所以按内容匹配，而不是只认建会话时的键。
        if let existing = centers.values.first(where: {
            $0.query == trimmed && $0.scopes == scopes
        }) {
            touch(existing)
            return existing
        }
        let center = make()
        centers[Self.key(center.query, scopes)] = center
        touch(center)
        trimIfNeeded()
        return center
    }

    /// 清空搜索：这一轮结果不再需要。
    func remove(query: String, scopes: [SearchSourceKind]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.key(trimmed, scopes)
        centers[key]?.cancel()
        centers[key] = nil
        order.removeAll { $0 == key }
    }

    private static func key(_ query: String, _ scopes: [SearchSourceKind]) -> String {
        query + "|" + scopes.map(\.rawValue).joined(separator: ",")
    }

    private func touch(_ center: SearchCenter) {
        let key = Self.key(center.query, center.scopes)
        // 继续输入后 query 变了，旧键指向的还是同一个会话，顺手换掉，避免攒下一堆别名。
        let staleKeys = centers.filter { $0.value === center && $0.key != key }.map(\.key)
        for staleKey in staleKeys {
            centers[staleKey] = nil
            order.removeAll { $0 == staleKey }
        }
        order.removeAll { $0 == key }
        centers[key] = center
        order.append(key)
    }

    private func trimIfNeeded() {
        while order.count > capacity {
            let key = order.removeFirst()
            centers[key]?.cancel()
            centers[key] = nil
        }
    }
}
