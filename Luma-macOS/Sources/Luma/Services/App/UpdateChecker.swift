import Foundation

/// 轻量更新检查：读取 GitHub Releases 最新版本，不引入 Sparkle 等第三方依赖。
/// 只负责“发现新版本 + 打开发布页”，下载安装仍由用户完成。
struct UpdateInfo {
    let version: String
    let title: String
    let notes: String
    let pageURL: URL
    let publishedAt: Date?
}

enum UpdateChecker {
    static let repository = "houshanren/luma"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func fetchLatest() async throws -> UpdateInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Luma/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = json["html_url"] as? String,
              let pageURL = URL(string: page) else {
            return nil
        }
        let name = json["name"] as? String ?? tag
        let notes = json["body"] as? String ?? ""
        let published = (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return UpdateInfo(version: version, title: name, notes: notes,
                          pageURL: pageURL, publishedAt: published)
    }

    /// 语义化版本比较：只比较数字段，忽略预发布后缀。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = numericComponents(candidate)
        let right = numericComponents(current)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func numericComponents(_ version: String) -> [Int] {
        version.split(separator: "-").first?
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 } ?? []
    }
}
