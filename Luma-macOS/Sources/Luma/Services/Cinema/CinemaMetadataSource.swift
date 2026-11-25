import Foundation

/// 刮削数据源：TMDB 与豆瓣都归一到 `CinemaMatch`，上层只做标题打分。
protocol CinemaMetadataSource {
    var provider: CinemaProvider { get }
    func search(query: String, isTV: Bool, year: Int?) async throws -> [CinemaMatch]
    /// 详情补全（合集 / 演职员 / 预告 / 分级）。只有 TMDB 实现，其他源走默认 nil。
    func details(id: Int, isTV: Bool) async throws -> CinemaDetails?
}

extension CinemaMetadataSource {
    func details(id: Int, isTV: Bool) async throws -> CinemaDetails? { nil }
}
