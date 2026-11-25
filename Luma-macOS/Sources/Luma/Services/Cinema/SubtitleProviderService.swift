import Foundation
import PlaybackCore

/// 在线字幕来源聚合：按设置里启用的来源并发搜索，统一排序后交给播放器。
enum SubtitleProviderService {
    struct Configuration {
        var openSubtitles: OpenSubtitlesClient.Credentials
        var openSubtitlesEnabled: Bool
        var assrtToken: String
        var assrtEnabled: Bool

        var openSubtitlesReady: Bool {
            openSubtitlesEnabled
                && !openSubtitles.trimmedKey.isEmpty
        }

        var assrtReady: Bool {
            assrtEnabled
                && !assrtToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var hasAnyProvider: Bool { openSubtitlesReady || assrtReady }
    }

    static func searchAll(title: String,
                          isTV: Bool,
                          season: Int?,
                          episode: Int?,
                          configuration: Configuration) async -> [CinemaSubtitleMatch] {
        var results: [CinemaSubtitleMatch] = []
        await withTaskGroup(of: [CinemaSubtitleMatch].self) { group in
            if configuration.openSubtitlesReady {
                group.addTask {
                    (try? await OpenSubtitlesClient.search(query: title,
                                                           isTV: isTV,
                                                           season: season,
                                                           episode: episode,
                                                           credentials: configuration.openSubtitles)) ?? []
                }
            }
            if configuration.assrtReady {
                group.addTask {
                    (try? await AssrtSubtitleClient.search(query: title,
                                                           token: configuration.assrtToken)) ?? []
                }
            }
            for await part in group {
                results += part
            }
        }

        // 默认中文偏好（简体 > 繁体 > 中文 > 其他），其次按下载量；同分时 OpenSubtitles 排前，结果更稳定。
        return results.sorted { lhs, rhs in
            let leftRank = SubtitlePreference.rank(language: lhs.language, title: lhs.title)
            let rightRank = SubtitlePreference.rank(language: rhs.language, title: rhs.title)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftDownloads = lhs.downloads ?? 0
            let rightDownloads = rhs.downloads ?? 0
            if leftDownloads != rightDownloads { return leftDownloads > rightDownloads }
            return lhs.provider.rawValue < rhs.provider.rawValue
        }
    }

    static func download(_ match: CinemaSubtitleMatch,
                         configuration: Configuration) async throws -> URL {
        switch match.provider {
        case .openSubtitles:
            return try await OpenSubtitlesClient.download(match, credentials: configuration.openSubtitles)
        case .assrt:
            return try await AssrtSubtitleClient.download(match, token: configuration.assrtToken)
        }
    }
}
