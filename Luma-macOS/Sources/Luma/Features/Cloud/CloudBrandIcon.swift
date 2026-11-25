import SwiftUI
import AppKit

/// 官方网盘品牌标识。图标取自各产品官方的 512pt 应用图标，
/// 放在 `Resources/CloudIcons`，构建时随 App 内置。
enum CloudBrand: String, CaseIterable {
    case aliyun
    case baidu
    case quark
    case pan115

    var assetName: String { rawValue }

    /// 图标资源缺失时的兜底符号（仅在开发期资源未拷贝时出现）。
    var fallbackSymbol: String {
        switch self {
        case .aliyun: return "cloud"
        case .baidu: return "cloud.fill"
        case .quark: return "square.stack.3d.up.fill"
        case .pan115: return "externaldrive.fill"
        }
    }
}

/// 网盘产品图标：圆角方形裁切，尺寸与侧边栏 / 向导卡片保持一致。
struct CloudBrandIcon: View {
    let brand: CloudBrand
    var size: CGFloat = 26

    private var cornerRadius: CGFloat { size * 0.225 }

    var body: some View {
        Group {
            if let image = CloudBrandAssets.image(for: brand) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        // 白底图标放在浅色卡片上时，用极细描边勾勒边界。
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
            } else {
                Image(systemName: brand.fallbackSymbol)
                    .font(.system(size: size * 0.78))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
    }
}

private enum CloudBrandAssets {
    private static var cache: [CloudBrand: NSImage] = [:]

    static func image(for brand: CloudBrand) -> NSImage? {
        if let cached = cache[brand] { return cached }
        guard let url = fileURL(for: brand),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[brand] = image
        return image
    }

    private static func fileURL(for brand: CloudBrand) -> URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("CloudIcons/\(brand.assetName).png") {
            candidates.append(bundled)
        }
        // `swift run` 没有资源副本，回退读仓库里的 Resources/CloudIcons。
        if Bundle.main.bundleURL.pathExtension.lowercased() != "app" {
            candidates.append(sourceRoot.appendingPathComponent("\(brand.assetName).png"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Sources/Luma/Features/Cloud → 仓库根目录 / Resources/CloudIcons。
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Cloud
            .deletingLastPathComponent()   // Features
            .deletingLastPathComponent()   // Luma
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // 仓库根目录
            .appendingPathComponent("Resources/CloudIcons", isDirectory: true)
    }
}
