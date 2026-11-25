import Foundation

/// 字幕语言偏好：产品默认面向中文用户，不提供设置项。
///
/// 只负责「排序」，不改变可用性：自动挂载、在线搜索结果、字幕菜单都按同一套顺序，
/// 简体中文 > 繁体中文 > 其他中文 > 英语 > 其他已知语言 > 未知。
public enum SubtitlePreference {
    /// 在线字幕站的语言参数：与偏好顺序一致（简体 → 繁体 → 英语）。
    public static let searchLanguageList = "zh-cn,zh-tw,en"

    /// 分数越低越优先。`language` 用 ffprobe / 字幕站的语言码，`title` 补充轨道名里的关键词。
    public static func rank(language: String?, title: String? = nil) -> Int {
        let lang = (language ?? "").lowercased()
        let name = (title ?? "").lowercased()
        let text = lang + " " + name

        if isSimplifiedChinese(text) { return 0 }
        if isTraditionalChinese(text) { return 1 }
        if isChinese(text) { return 2 }
        // 中英双语通常同时含「中」与英文：仍按中文优先（上面已命中）。
        if isEnglish(text) { return 4 }
        if lang.isEmpty || lang == "und" || lang == "unknown" || lang == "zxx" { return 6 }
        return 5
    }

    /// 从候选里挑最佳：同分保持原顺序（探测顺序通常就是片源默认顺序）。
    public static func bestIndex(languages: [String?], titles: [String?] = []) -> Int? {
        guard !languages.isEmpty else { return nil }
        var bestIndex: Int?
        var bestRank = Int.max
        for (index, language) in languages.enumerated() {
            let title = index < titles.count ? titles[index] : nil
            let value = rank(language: language, title: title)
            if value < bestRank {
                bestRank = value
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// 外挂字幕文件的语言排名：`movie.zh-Hans.srt` 取 `zh-Hans`，`movie.srt` 视为中性。
    /// 文件名里没有语言标记时给 3 分：低于英语、高于模型未知，同目录只有它时自然被选中。
    public static func rank(externalFileName: String, baseName: String) -> Int {
        let stem = (externalFileName as NSString).deletingPathExtension
        guard stem.hasPrefix(baseName) else { return 6 }
        let suffix = String(stem.dropFirst(baseName.count))
        guard !suffix.isEmpty else { return 3 }
        return rank(language: suffix)
    }

    private static func isSimplifiedChinese(_ text: String) -> Bool {
        ["zh-hans", "zh-cn", "zh_cn", "zhs", "chs", "简", "简中", "简体"]
            .contains(where: { text.contains($0) })
    }

    private static func isTraditionalChinese(_ text: String) -> Bool {
        ["zh-hant", "zh-tw", "zh-hk", "zh_tw", "zht", "cht", "繁", "繁體", "繁体"]
            .contains(where: { text.contains($0) })
    }

    private static func isChinese(_ text: String) -> Bool {
        if ["中", "粤", "粵", "chinese"].contains(where: { text.contains($0) }) { return true }
        // 语言码按词匹配：避免片名里的普通字母（如 "Zhukov"）被误判成中文。
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return tokens.contains(where: { ["zh", "chi", "zho", "cmn", "yue"].contains($0) })
    }

    private static func isEnglish(_ text: String) -> Bool {
        if text.contains("english") { return true }
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return tokens.contains("en") || tokens.contains("eng")
    }
}
