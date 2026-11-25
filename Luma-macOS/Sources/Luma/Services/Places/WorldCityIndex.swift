import Foundation

/// 境外坐标的离线兜底城市库（GeoNames cities15000，随 App 打包）。
///
/// 系统的 `CLGeocoder` 在当前网络环境下只对中国大陆坐标返回结果，
/// 境外坐标（如 13.4°N, 103.9°E）一律返回 `kCLErrorDomain 8`，
/// 拍照地点就只能退回坐标卡片。这里按最近城市补一个国家 / 城市级地名，
/// 全程离线，不上传坐标。
final class WorldCityIndex {
    static let shared = WorldCityIndex()

    private struct City: Decodable {
        let n: String   // 展示名（中文优先）
        let l: String   // 本地名
        let cc: String  // 国家代码
        let la: Double
        let lo: Double
        let p: Int
    }

    private struct Payload: Decodable {
        let source: String
        let cities: [City]
    }

    /// 1° 网格：查询时只扫临近格，避免每张照片都遍历三万多条。
    private static let cellSize = 1.0
    private static let ringLimit = 3
    private static let maxDistanceKm = 150.0
    private static let latCount = 180
    private static let lonCount = 360

    private let lock = NSLock()
    private var loaded = false
    private var grid: [Int: [Int]] = [:]
    private var cities: [City] = []
    private var countryNames: [String: String] = [:]
    private let locale = Locale(identifier: "zh_CN")

    private init() {}

    /// 最近城市地名：距离为主，人口作为轻微权重，避免把「巴黎」识别成紧邻的小镇。
    func place(latitude: Double, longitude: Double) async -> PlaceInfo? {
        await loadIfNeeded()
        return lookup(latitude: latitude, longitude: longitude)
    }

    // MARK: - 查询（同步执行，锁不会出现在 async 上下文里）

    private func lookup(latitude: Double, longitude: Double) -> PlaceInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard !cities.isEmpty else { return nil }

        let centerLat = Self.cellIndex(latitude)
        let centerLon = Self.lonIndex(longitude)
        var bestScore = Double.infinity
        var bestDistance = Double.infinity
        var bestCity: City?

        for ring in 0...Self.ringLimit {
            for latOffset in -ring...ring {
                for lonOffset in -ring...ring {
                    // 只看当前这一圈，内圈上一轮已经扫过。
                    guard max(abs(latOffset), abs(lonOffset)) == ring else { continue }
                    let latIndex = centerLat + latOffset
                    guard latIndex >= 0, latIndex < Self.latCount else { continue }
                    let lonIndex = (centerLon + lonOffset + Self.lonCount) % Self.lonCount
                    guard let indices = grid[latIndex * Self.lonCount + lonIndex] else { continue }
                    for index in indices {
                        let city = cities[index]
                        let distance = Self.distanceKm(latitude: latitude, longitude: longitude,
                                                       to: city)
                        guard distance <= Self.maxDistanceKm else { continue }
                        let score = distance - 3 * log10(Double(max(city.p, 1)))
                        if score < bestScore || (score == bestScore && distance < bestDistance) {
                            bestScore = score
                            bestDistance = distance
                            bestCity = city
                        }
                    }
                }
            }
        }

        guard let bestCity else { return nil }
        let country = countryName(for: bestCity.cc)
        return PlaceInfo(country: country, province: nil, city: bestCity.n,
                         district: nil, poi: nil)
    }

    private func countryName(for code: String) -> String? {
        guard !code.isEmpty else { return nil }
        if let cached = countryNames[code] { return cached }
        let name = locale.localizedString(forRegionCode: code)
        countryNames[code] = name
        return name
    }

    // MARK: - 加载

    private func loadIfNeeded() async {
        if isLoaded() { return }
        await Task.detached(priority: .utility) { [self] in load() }.value
    }

    private func isLoaded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loaded
    }

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let url = LumaModelResources.file("Places/world-cities.json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.cities.isEmpty else { return }
        cities = payload.cities
        grid.reserveCapacity(payload.cities.count)
        for (index, city) in payload.cities.enumerated() {
            let key = Self.cellIndex(city.la) * Self.lonCount + Self.lonIndex(city.lo)
            grid[key, default: []].append(index)
        }
    }

    // MARK: - 网格

    private static func cellIndex(_ latitude: Double) -> Int {
        min(latCount - 1, max(0, Int((latitude + 90) / cellSize)))
    }

    private static func lonIndex(_ longitude: Double) -> Int {
        min(lonCount - 1, max(0, Int((longitude + 180) / cellSize)))
    }

    private static func distanceKm(latitude: Double, longitude: Double, to city: City) -> Double {
        let meanLatitude = (latitude + city.la) / 2 * .pi / 180
        let dy = (city.la - latitude) * 111.32
        let dx = (city.lo - longitude) * 111.32 * cos(meanLatitude)
        return (dx * dx + dy * dy).squareRoot()
    }
}
