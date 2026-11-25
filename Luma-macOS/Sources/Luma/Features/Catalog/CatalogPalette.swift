import SwiftUI
import CoreImage

/// 封面主色：给详情页的模糊底图加一层来自作品本身的色调。
/// 结果按 URL 缓存在内存里，失败就不再重试。
enum CatalogPalette {
    private static var cache: [String: Color] = [:]
    private static var misses: Set<String> = []
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// 已经算过的封面主色，同步读取（滚动回来时不用再等网络）。
    static func cached(source: CatalogSource, urlString: String, vivid: Bool = false) -> Color? {
        cache[cacheKey(source: source, urlString: urlString, vivid: vivid)]
    }

    /// `vivid` 用于卡片描边：平均色往往偏暗，直接画在深色背景上几乎看不见，
    /// 所以抬高亮度下限，只保留封面的色相与饱和度倾向。
    static func color(source: CatalogSource, urlString: String,
                      vivid: Bool = false) async -> Color? {
        let key = cacheKey(source: source, urlString: urlString, vivid: vivid)
        if let cached = cache[key] { return cached }
        guard !urlString.isEmpty, !misses.contains(key),
              let provider = CatalogProviders.provider(for: source.kind) else { return nil }
        do {
            let data = try await provider.coverData(source: source, urlString: urlString)
            guard let image = CIImage(data: data), !image.extent.isEmpty,
                  let filter = CIFilter(name: "CIAreaAverage",
                                        parameters: [kCIInputImageKey: image,
                                                     kCIInputExtentKey: CIVector(cgRect: image.extent)]),
                  let output = filter.outputImage else {
                misses.insert(key)
                return nil
            }
            var bitmap = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &bitmap, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            let color = refined(red: Double(bitmap[0]) / 255,
                                green: Double(bitmap[1]) / 255,
                                blue: Double(bitmap[2]) / 255,
                                vivid: vivid)
            if cache.count >= 60 { cache.removeAll() }
            cache[key] = color
            return color
        } catch {
            misses.insert(key)
            return nil
        }
    }

    private static func cacheKey(source: CatalogSource, urlString: String,
                                 vivid: Bool) -> String {
        "\(source.id.uuidString)|\(urlString)|\(vivid ? "stroke" : "tint")"
    }

    /// 平均色通常发灰：抬高饱和度与亮度，作为底纹才看得见。
    private static func refined(red: Double, green: Double, blue: Double,
                                vivid: Bool) -> Color {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        var hue: Double = 0
        if delta > 0.0001 {
            if maxValue == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        if vivid {
            // 描边色：暗封面（夜景、黑底海报）也要亮到能在深色界面里看清。
            let saturation = min(0.86, max(0.46, delta / max(maxValue, 0.001)))
            let brightness = min(0.92, max(0.64, maxValue * 0.95 + 0.24))
            return Color(hue: hue, saturation: saturation, brightness: brightness)
        }
        let saturation = min(0.78, max(0.34, delta / max(maxValue, 0.001)))
        let brightness = min(0.72, max(0.34, maxValue * 0.92))
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

/// 卡片封面的主色：悬停时异步取一次，之后一直复用。
/// 用来让描边 / 光晕跟着封面本身的色系走，而不是固定品牌色。
@MainActor
final class CatalogCoverTint: ObservableObject {
    @Published private(set) var color: Color?

    private var isLoading = false

    func load(source: CatalogSource, urlString: String) {
        guard color == nil, !isLoading, !urlString.isEmpty else { return }
        if let cached = CatalogPalette.cached(source: source, urlString: urlString, vivid: true) {
            color = cached
            return
        }
        isLoading = true
        Task { [weak self] in
            let result = await CatalogPalette.color(source: source, urlString: urlString,
                                                    vivid: true)
            guard let self else { return }
            self.isLoading = false
            if let result {
                withAnimation(.easeOut(duration: 0.2)) { self.color = result }
            }
        }
    }
}
