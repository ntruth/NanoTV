import AppKit
import SwiftUI

/// 资料库头像：优先使用 SQLite 里内置的 base64 小图；
/// 没有图时用名字生成一张稳定的渐变字母头像，保证列表和档案页视觉一致。
struct CatalogAvatarView: View {
    let name: String
    var base64: String?
    var size: CGFloat = 32
    var ringColor: Color?

    /// 解码后的小图缓存：列表滚动时不重复解码，同时限制总数避免常驻内存过大。
    private static let cache = MemoryImageCache(totalCostLimit: 24 * 1024 * 1024, countLimit: 512)

    private static let palette: [(Color, Color)] = [
        (Color(red: 0.98, green: 0.47, blue: 0.42), Color(red: 0.86, green: 0.24, blue: 0.38)),
        (Color(red: 0.45, green: 0.72, blue: 0.98), Color(red: 0.22, green: 0.44, blue: 0.86)),
        (Color(red: 0.98, green: 0.72, blue: 0.35), Color(red: 0.90, green: 0.46, blue: 0.20)),
        (Color(red: 0.55, green: 0.86, blue: 0.68), Color(red: 0.18, green: 0.63, blue: 0.48)),
        (Color(red: 0.78, green: 0.62, blue: 0.98), Color(red: 0.50, green: 0.32, blue: 0.86)),
        (Color(red: 0.99, green: 0.60, blue: 0.76), Color(red: 0.85, green: 0.28, blue: 0.52)),
        (Color(red: 0.42, green: 0.83, blue: 0.88), Color(red: 0.15, green: 0.55, blue: 0.70)),
    ]

    private var image: NSImage? {
        guard let base64, !base64.isEmpty else { return nil }
        let key = base64 as NSString
        if let cached = Self.cache.object(forKey: key) { return cached }
        guard let data = Data(base64Encoded: base64), let image = NSImage(data: data) else {
            return nil
        }
        Self.cache.setObject(image, forKey: key, cost: Int(size * size * 4))
        return image
    }

    private var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let latin = trimmed.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0)
                           || CharacterSet.whitespaces.contains($0)
                           || "-_.".unicodeScalars.contains($0))
        }
        if latin {
            let words = trimmed.split { $0 == " " || $0 == "-" || $0 == "_" }
            if words.count >= 2 {
                return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
            }
            return String(trimmed.prefix(2)).uppercased()
        }
        return String(trimmed.prefix(2))
    }

    private var gradient: (Color, Color) {
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 100_000 }
        return Self.palette[seed % Self.palette.count]
    }

    var body: some View {
        let pair = gradient
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [pair.0, pair.1],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(initials)
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(ringColor ?? Color.white.opacity(0.18), lineWidth: 0.8)
        }
        .accessibilityLabel(Text(name))
    }
}
