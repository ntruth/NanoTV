import Foundation

/// 三类来源的配置分享范围：一个文件只装同一类，导入时也只接受对应类型，
/// 避免把影视源混进网络资源，或把电视源当成影视源。
enum SourceTransferScope: String, Codable {
    case catalogResource
    case networkCinema
    case television

    var title: String {
        switch self {
        case .catalogResource: return "网络资源"
        case .networkCinema: return "网络影院"
        case .television: return "网络电视"
        }
    }

    /// 导出文件名的前缀，例如「Luma-网络资源-2026-11-25.json」。
    var fileNamePrefix: String { "Luma-\(title)" }
}

/// 分享文件外壳：格式标记 + 版本 + 所属范围，方便以后兼容旧文件。
struct SourceTransferFile<Item: Codable>: Codable {
    var format = "luma.sources"
    var version = 1
    var scope: SourceTransferScope
    var exportedAt: Date
    var items: [Item]

    init(scope: SourceTransferScope, items: [Item]) {
        self.scope = scope
        self.exportedAt = Date()
        self.items = items
    }
}

/// 导入结果：菜单据此提示「新增多少 / 跳过多少 / 失败原因」。
struct SourceTransferOutcome {
    var added = 0
    var skipped = 0
    var error: String?

    static func failure(_ message: String) -> SourceTransferOutcome {
        SourceTransferOutcome(error: message)
    }

    var summary: String {
        if let error { return error }
        if added == 0 {
            return skipped > 0 ? "没有新增：\(skipped) 个已经存在" : "文件里没有可导入的配置"
        }
        return skipped > 0
            ? "已导入 \(added) 个，跳过 \(skipped) 个已存在"
            : "已导入 \(added) 个"
    }
}

/// 分享文件的编解码：日期用 ISO8601，文件里的小数不参与，方便人工查看。
enum SourceTransferJSON {
    struct DecodeError: Error {
        let message: String
    }

    static func encode<Item: Codable>(_ scope: SourceTransferScope, items: [Item]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(SourceTransferFile(scope: scope, items: items))
    }

    static func decode<Item: Codable>(_ type: Item.Type,
                                      from data: Data,
                                      expecting scope: SourceTransferScope) -> Result<[Item], DecodeError> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(SourceTransferFile<Item>.self, from: data) else {
            return .failure(DecodeError(message: "文件格式不正确，或者不是拾光导出的配置。"))
        }
        guard file.scope == scope else {
            return .failure(DecodeError(
                message: "这是「\(file.scope.title)」的配置，请到「\(file.scope.title)」页面接入。"))
        }
        guard file.version <= 1 else {
            return .failure(DecodeError(message: "配置版本过新，请更新拾光后再导入。"))
        }
        return .success(file.items)
    }
}

extension CatalogDomain {
    /// 网络资源与网络影院共用同一套来源模型，但分享文件要分开。
    var transferScope: SourceTransferScope {
        switch self {
        case .networkResource: return .catalogResource
        case .networkCinema: return .networkCinema
        }
    }
}
