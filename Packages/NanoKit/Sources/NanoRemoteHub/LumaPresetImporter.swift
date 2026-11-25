import Foundation
import NanoCore

/// 兼容 `format: "luma.sources"`（Luma-网络电视 / Luma-网络影院 / Luma-网络资源）的双端（macOS + Apple TV）解析导入器
public struct LumaPresetImporter: Sendable {
    public struct ImportedLumaBundle: Sendable {
        public var tvSubscriptions: [IPTVSubscriptionSource]
        public var remoteSites: [RemoteResourceSite]

        public init(tvSubscriptions: [IPTVSubscriptionSource] = [], remoteSites: [RemoteResourceSite] = []) {
            self.tvSubscriptions = tvSubscriptions
            self.remoteSites = remoteSites
        }
    }

    /// 自动从 `NanoKit` 内置资源包读取已同步的 3 份片源 JSON（macOS 与 Apple TV 开箱即用）
    public static func loadBundledPresets() -> ImportedLumaBundle {
        var combined = ImportedLumaBundle()
        let presetNames = ["Luma-television", "Luma-networkCinema", "Luma-catalog"]

        for name in presetNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let parsed = try? parseLumaSourcesJSON(data) else {
                continue
            }
            combined.tvSubscriptions.append(contentsOf: parsed.tvSubscriptions)
            combined.remoteSites.append(contentsOf: parsed.remoteSites)
        }
        return combined
    }

    /// 解析任意标准 `luma.sources` 格式 JSON 数据（支持 `television` / `networkCinema` / `catalog`）
    public static func parseLumaSourcesJSON(_ data: Data) throws -> ImportedLumaBundle {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["format"] as? String) == "luma.sources",
              let items = root["items"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }

        let scope = (root["scope"] as? String) ?? ""
        var result = ImportedLumaBundle()

        if scope == "television" {
            for item in items {
                guard let name = item["name"] as? String,
                      let urlString = item["urlString"] as? String,
                      !urlString.isEmpty else { continue }
                let id = (item["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
                let enabled = (item["isEnabled"] as? Bool) ?? true
                let count = (item["lastChannelCount"] as? Int) ?? 0
                result.tvSubscriptions.append(
                    IPTVSubscriptionSource(
                        id: id,
                        name: name,
                        m3uURL: urlString,
                        isEnabled: enabled,
                        channelCount: count,
                        lastSyncedAt: Date()
                    )
                )
            }
            return result
        }

        // 处理 networkCinema (网络影院) 与 catalog (网络资源，自动标记隐私保护以适配客厅 Apple TV)
        let isPrivateScope = (scope == "catalog")
        for item in items {
            guard let name = item["name"] as? String else { continue }
            let rawAPI = (item["configURL"] as? String) ?? (item["baseURL"] as? String) ?? ""
            guard !rawAPI.isEmpty else { continue }

            let id = (item["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            let kind = ((item["kind"] as? String) ?? "").lowercased()
            let enabled = (item["isEnabled"] as? Bool) ?? true
            let categoriesArr = (item["categories"] as? [[String: Any]]) ?? []
            let catCount = countNestedCategories(categoriesArr)

            let engineType: RemoteSiteEngineType
            if kind == "maccms" {
                engineType = .macCMSJson
            } else if kind == "fongmi" || kind == "tvbox" {
                engineType = .fongMiTVBox
            } else {
                engineType = .customWebRule
            }

            result.remoteSites.append(
                RemoteResourceSite(
                    id: id,
                    key: kind.isEmpty ? id.uuidString : kind,
                    name: name,
                    engineType: engineType,
                    apiURL: rawAPI,
                    isEnabled: enabled,
                    isSearchable: true,
                    isPrivate: isPrivateScope,
                    healthStatus: .online,
                    categoryCount: max(1, catCount)
                )
            )
        }

        return result
    }

    private static func countNestedCategories(_ categories: [[String: Any]]) -> Int {
        var total = 0
        for cat in categories {
            if let children = cat["children"] as? [[String: Any]], !children.isEmpty {
                total += children.count
            } else {
                total += 1
            }
        }
        return total
    }
}
