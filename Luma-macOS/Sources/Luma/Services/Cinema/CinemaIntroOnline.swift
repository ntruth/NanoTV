import Foundation

/// 在线片头片尾：TheIntroDB（introdb.app）的社区时间轴。
/// 它的分段接口只认 IMDb ID，所以先用 TMDB 的 external_ids 换一次，再按季集查询。
@MainActor
enum CinemaIntroOnline {
    struct Segments {
        var introEnd: Double?
        var outroStart: Double?
    }

    private static let session = URLSession(configuration: .ephemeral)
    /// 一部剧只查一次：同一季集重复进入详情页时不再走网络。
    private static var cache: [String: Segments] = [:]

    /// 查在线分段并换算成应用里的「片头跳过秒数 / 片尾剩余秒数」。
    /// - Parameter duration: 这一集的时长；片尾要拿绝对起点换算成「还剩多少秒」。
    static func mark(tmdb: TMDBClient,
                     tmdbID: Int,
                     season: Int,
                     episode: Int,
                     duration: Double) async -> CinemaIntroMark? {
        guard let imdb = try? await tmdb.externalImdbID(id: tmdbID, isTV: true),
              !imdb.isEmpty else { return nil }
        guard let segments = await segments(imdbID: imdb, season: season, episode: episode) else {
            return nil
        }

        // 片头：跳到分段结束点。动画等长短不一的片头留出 5–600 秒的合理区间。
        var intro = 0
        if let end = segments.introEnd, end >= 5, end <= 600 {
            intro = Int(end.rounded())
        }
        // 片尾：社区给的是绝对起点，按时长换成剩余秒数。
        var outro = 0
        if duration > 60, let start = segments.outroStart {
            let remaining = duration - start
            if remaining >= 5, remaining <= 600 {
                outro = Int(remaining.rounded())
            }
        }
        guard intro > 0 || outro > 0 else { return nil }
        return CinemaIntroMark(introSeconds: intro, outroSeconds: outro)
    }

    private static func segments(imdbID: String,
                                 season: Int,
                                 episode: Int) async -> Segments? {
        let key = "\(imdbID)|\(season)|\(episode)"
        if let cached = cache[key] {
            return cached.introEnd == nil && cached.outroStart == nil ? nil : cached
        }

        var components = URLComponents(string: "https://api.introdb.app/segments")
        components?.queryItems = [
            URLQueryItem(name: "imdb_id", value: imdbID),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode))
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        var result = Segments()
        if let intro = object["intro"] as? [String: Any] {
            result.introEnd = (intro["end_sec"] as? NSNumber)?.doubleValue
        }
        if let outro = object["outro"] as? [String: Any] {
            result.outroStart = (outro["start_sec"] as? NSNumber)?.doubleValue
        }
        // 空结果也缓存：避免每打开一次详情就再请求一遍不存在的剧集。
        cache[key] = result
        return result.introEnd == nil && result.outroStart == nil ? nil : result
    }
}
