import Foundation
import LumaContentCore

/// 网络影院的智能助手工具：聚合列表、跨源搜索、续看与播放。
/// 影视源与网络资源完全独立：这里只读网络影院的影视源，写操作只有播放。
extension LibraryStore {
    func listNetworkCinemaSourcesTool() -> AIToolExecution {
        let sources = catalogModel.cinemaSources
        let items = sources.map { source -> [String: Any] in
            let health = catalogModel.health[source.id] ?? .unknown
            return [
                "source_id": source.id.uuidString,
                "name": source.name,
                "kind": source.kind.rawValue,
                "enabled": source.isEnabled,
                "health": health.title
            ]
        }
        return success(["count": items.count, "sources": items],
                       summary: nil,
                       photoIDs: [])
    }

    func listNetworkCinemaTool(_ args: [String: Any]) -> AIToolExecution {
        let tab = (AILibraryTools.string(args["tab"]) ?? "movies").lowercased()
        let wantTV = tab == "shows" || tab == "tv" || tab == "电视剧"
        let limit = min(500, max(1, AILibraryTools.integer(args["limit"], fallback: 100)))
        let list = networkCinemaModel.items
            .filter { $0.isTV == wantTV }
            .prefix(limit)
        guard !list.isEmpty else {
            return success(["count": 0, "items": []],
                           summary: "网络影院还没有聚合到\(wantTV ? "剧集" : "电影")",
                           photoIDs: [])
        }

        aiCatalogCandidates.removeAll()
        var items: [[String: Any]] = []
        for entry in list {
            let ref = "#\(items.count + 1)"
            aiCatalogCandidates[ref] = (entry.source.id, entry.item)
            aiCatalogCandidates["\(entry.source.id.uuidString)|\(entry.item.id)"] = (entry.source.id, entry.item)
            let enrichment = networkCinemaModel.enrichment(for: entry)
            var item: [String: Any] = [
                "ref": ref,
                "source_id": entry.source.id.uuidString,
                "source": entry.source.name,
                "item_id": entry.item.id,
                "title": enrichment?.title ?? entry.item.title,
                "is_tv": entry.isTV,
                "sources": networkCinemaModel.sources(for: entry).map(\.source.name)
            ]
            if let year = enrichment?.year { item["year"] = year }
            if let rating = enrichment?.rating { item["rating"] = rating }
            if !entry.item.remark.isEmpty { item["remark"] = entry.item.remark }
            items.append(item)
        }
        return success(["count": items.count, "items": items],
                       summary: "网络影院\(wantTV ? "剧集" : "电影") \(items.count) 部",
                       photoIDs: [])
    }

    /// 跨源搜索：只查作为网络影院来源的影视源，结果登记成 ref 供播放复用。
    func searchNetworkCinemaTool(_ args: [String: Any]) async -> AIToolExecution {
        guard let query = AILibraryTools.string(args["query"]) else {
            return failure("请提供要搜索的片名或剧名")
        }
        let perSource = min(60, max(1, AILibraryTools.integer(args["limit"], fallback: 30)))
        var targets = catalogModel.enabledCinemaSources
        if let raw = AILibraryTools.string(args["source"]) {
            guard let source = aiResolveCatalogSource(raw) else {
                return failure("没有找到源「\(raw)」，可先调用 list_network_cinema_sources")
            }
            guard source.kind.supportsNetworkCinema else {
                return failure("源「\(source.name)」不是影视源，不能用于网络影院")
            }
            guard source.isEnabled else {
                return failure("源「\(source.name)」未启用，请先在网络影院 › 影院管理里打开它")
            }
            targets = [source]
        }
        guard !targets.isEmpty else {
            return failure("还没有启用任何影视源，请先在网络影院 › 影院管理里启用")
        }

        aiCatalogCandidates.removeAll()
        var groups: [[String: Any]] = []
        var total = 0
        var failed = 0
        for source in targets {
            if Task.isCancelled { break }
            guard let provider = CatalogProviders.provider(for: source.kind) else {
                failed += 1
                continue
            }
            do {
                let page = try await provider.search(source: source, keyword: query, page: 1)
                let picked = Array(page.items.prefix(min(perSource, max(0, 200 - total))))
                guard !picked.isEmpty else { continue }
                var items: [[String: Any]] = []
                for item in picked {
                    total += 1
                    let ref = "#\(total)"
                    aiCatalogCandidates[ref] = (source.id, item)
                    aiCatalogCandidates["\(source.id.uuidString)|\(item.id)"] = (source.id, item)
                    var payload: [String: Any] = [
                        "ref": ref,
                        "source_id": source.id.uuidString,
                        "source": source.name,
                        "item_id": item.id,
                        "title": item.title
                    ]
                    if !item.remark.isEmpty { payload["remark"] = item.remark }
                    items.append(payload)
                }
                groups.append(["source_id": source.id.uuidString,
                               "source": source.name,
                               "items": items])
                if total >= 200 { break }
            } catch {
                failed += 1
            }
        }
        guard !groups.isEmpty else {
            if failed == targets.count {
                return failure("搜索「\(query)」失败：影视源都不可达")
            }
            return failure("网络影院没有找到匹配「\(query)」的条目")
        }
        return success(["query": query, "count": total, "failed_sources": failed, "groups": groups],
                       summary: "网络影院搜索「\(query)」：\(total) 条",
                       photoIDs: [])
    }

    func networkCinemaHistoryTool(_ args: [String: Any]) -> AIToolExecution {
        let limit = min(500, max(1, AILibraryTools.integer(args["limit"], fallback: 50)))
        let ids = catalogModel.cinemaSourceIDs
        let records = catalogModel.allContinueWatching
            .filter { ids.contains($0.sourceID) }
            .prefix(limit)
        guard !records.isEmpty else {
            return success(["count": 0, "items": []],
                           summary: "网络影院还没有续看记录",
                           photoIDs: [])
        }
        let names = Dictionary(uniqueKeysWithValues: catalogModel.sources.map { ($0.id, $0.name) })
        aiCatalogCandidates.removeAll()
        var items: [[String: Any]] = []
        for record in records {
            let ref = "#\(items.count + 1)"
            let item = CatalogItem(id: record.itemID, title: record.title,
                                   coverURL: record.coverURL, remark: "", categoryID: nil)
            aiCatalogCandidates[ref] = (record.sourceID, item)
            aiCatalogCandidates["\(record.sourceID.uuidString)|\(record.itemID)"] = (record.sourceID, item)
            items.append([
                "ref": ref,
                "source_id": record.sourceID.uuidString,
                "source": names[record.sourceID] ?? "",
                "item_id": record.itemID,
                "title": record.title,
                "episode": record.episode,
                "fraction": record.fraction,
                "last_seen": Self.aiDateFormatter.string(from: record.updatedAt)
            ])
        }
        return success(["count": items.count, "items": items],
                       summary: "网络影院续看 \(items.count) 条",
                       photoIDs: [])
    }

    func playNetworkCinemaTool(_ args: [String: Any]) -> AIToolExecution {
        guard let target = aiResolveCatalogCandidate(args) else {
            return failure("找不到要播放的条目，请先调用 list_network_cinema / search_network_cinema / network_cinema_history 获取 ref")
        }
        guard let source = catalogModel.sources.first(where: { $0.id == target.sourceID }),
              source.domain == .networkCinema else {
            return failure("这个条目不属于网络影院，无法用影院播放")
        }
        guard source.isEnabled else {
            return failure("源「\(source.name)」未启用")
        }
        catalogModel.playRemote(sourceID: source.id, item: target.item)
        return success(["source_id": source.id.uuidString, "item_id": target.item.id],
                       summary: "开始播放《\(target.item.title)》",
                       photoIDs: [])
    }
}
