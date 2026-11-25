import SwiftUI
import AppKit

// MARK: - 海报模板

enum PosterTemplate: String, CaseIterable, Identifiable {
    case magazine
    case journal
    case polaroid
    case dateStamp
    case handwritten

    var id: String { rawValue }

    var title: String {
        switch self {
        case .magazine: return "杂志封面"
        case .journal: return "旅行手账"
        case .polaroid: return "拍立得"
        case .dateStamp: return "日期印章"
        case .handwritten: return "手写标注"
        }
    }

    /// 宽 / 高。
    var aspect: CGFloat {
        switch self {
        case .magazine: return 4.0 / 5.0
        case .journal: return 3.0 / 4.0
        case .polaroid: return 4.0 / 5.0
        case .dateStamp: return 3.0 / 2.0
        case .handwritten: return 4.0 / 5.0
        }
    }
}

struct PosterOptions: Equatable {
    var title: String
    var subtitle: String
    var location: String
    var date: String
    var signature: String

    var isEmptyTitle: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 海报画布

struct PosterCanvas: View {
    let image: NSImage?
    let template: PosterTemplate
    let options: PosterOptions

    private let paper = Color(red: 0.96, green: 0.945, blue: 0.92)
    private let ink = Color(red: 0.16, green: 0.15, blue: 0.13)
    private let accent = Color(red: 0.78, green: 0.36, blue: 0.18)
    private let handFont = "Kaiti SC"
    private let handFontAlt = "Hannotate SC"

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                background(width: width, height: height)
                switch template {
                case .magazine: magazine(width: width, height: height)
                case .journal: journal(width: width, height: height)
                case .polaroid: polaroid(width: width, height: height)
                case .dateStamp: dateStamp(width: width, height: height)
                case .handwritten: handwritten(width: width, height: height)
                }
            }
            .frame(width: width, height: height)
            .clipped()
        }
    }

    @ViewBuilder
    private func background(width: CGFloat, height: CGFloat) -> some View {
        switch template {
        case .magazine, .journal, .polaroid:
            paper
        case .dateStamp, .handwritten:
            Color.black
        }
    }

    private func photo(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.08)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func magazine(width: CGFloat, height: CGFloat) -> some View {
        let pad = width * 0.065
        return VStack(alignment: .leading, spacing: width * 0.02) {
            Text(options.subtitle.isEmpty ? "LUMA · MEMORIES" : options.subtitle.uppercased())
                .font(.system(size: width * 0.025, weight: .semibold))
                .tracking(width * 0.004)
                .foregroundStyle(ink.opacity(0.65))

            Text(options.isEmptyTitle ? "拾光" : options.title)
                .font(.custom("Songti SC", size: width * 0.1))
                .fontWeight(.bold)
                .foregroundStyle(ink)
                .lineLimit(2)
                .minimumScaleFactor(0.6)

            photo(width: width - pad * 2, height: height * 0.52)
                .overlay(Rectangle().stroke(ink.opacity(0.18), lineWidth: 0.8))

            HStack {
                Text(options.location.isEmpty ? "LOCAL EDITION" : options.location)
                    .lineLimit(1)
                Spacer()
                Text(options.date)
            }
            .font(.system(size: width * 0.021, weight: .medium))
            .tracking(width * 0.002)
            .foregroundStyle(ink.opacity(0.7))

            Spacer(minLength: 0)
        }
        .padding(pad)
    }

    private func journal(width: CGFloat, height: CGFloat) -> some View {
        let pad = width * 0.07
        return VStack(alignment: .leading, spacing: width * 0.025) {
            HStack(alignment: .firstTextBaseline) {
                Text(options.isEmptyTitle ? "旅途手记" : options.title)
                    .font(.custom(handFont, size: width * 0.075))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Spacer()
                Text(options.date)
                    .font(.system(size: width * 0.022, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.55))
            }

            photo(width: width - pad * 2, height: height * 0.56)
                .overlay(Rectangle().stroke(Color.white.opacity(0.9), lineWidth: width * 0.014))
                .shadow(color: .black.opacity(0.12), radius: width * 0.01, x: 0, y: width * 0.006)
                .rotationEffect(.degrees(-0.8))

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: width * 0.012) {
                    if !options.location.isEmpty {
                        Text(options.location)
                            .font(.custom(handFont, size: width * 0.038))
                            .foregroundStyle(ink.opacity(0.8))
                    }
                    if !options.signature.isEmpty {
                        Text(options.signature)
                            .font(.custom(handFontAlt, size: width * 0.03))
                            .foregroundStyle(accent)
                    }
                }
                Spacer()
                ZStack {
                    Circle()
                        .stroke(accent.opacity(0.65), lineWidth: 1)
                        .frame(width: width * 0.11, height: width * 0.11)
                    Text("拾光")
                        .font(.custom(handFont, size: width * 0.03))
                        .foregroundStyle(accent.opacity(0.8))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(pad)
    }

    private func polaroid(width: CGFloat, height: CGFloat) -> some View {
        let pad = width * 0.075
        return VStack(spacing: 0) {
            photo(width: width - pad * 2, height: height * 0.7)
                .padding(.top, pad)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: width * 0.01) {
                Text(options.isEmptyTitle ? "那一年的夏天" : options.title)
                    .font(.custom(handFont, size: width * 0.062))
                    .foregroundStyle(ink.opacity(0.85))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if !options.date.isEmpty {
                    Text(options.date)
                        .font(.system(size: width * 0.022, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, pad)
            .padding(.bottom, pad * 1.1)
        }
        .background(Color.white)
    }

    private func dateStamp(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            photo(width: width, height: height)
                .padding(width * 0.035)
            VStack(alignment: .leading, spacing: width * 0.008) {
                if !options.isEmptyTitle {
                    Text(options.title)
                        .font(.system(size: width * 0.04, weight: .semibold))
                        .foregroundStyle(.white)
                }
                if !options.location.isEmpty {
                    Text(options.location)
                        .font(.system(size: width * 0.022))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(width * 0.06)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(options.date)
                    .font(.system(size: width * 0.04, weight: .bold, design: .monospaced))
                if !options.signature.isEmpty {
                    Text(options.signature)
                        .font(.custom(handFontAlt, size: width * 0.028))
                }
            }
            .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.2))
            .padding(.horizontal, width * 0.018)
            .padding(.vertical, width * 0.01)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(Color(red: 1, green: 0.55, blue: 0.2).opacity(0.8), lineWidth: 1))
            .padding(width * 0.06)
        }
    }

    private func handwritten(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            photo(width: width, height: height)
            LinearGradient(colors: [.clear, .black.opacity(0.65)],
                           startPoint: .center,
                           endPoint: .bottom)
            VStack(alignment: .leading, spacing: width * 0.012) {
                Text(options.isEmptyTitle ? "记一笔" : options.title)
                    .font(.custom(handFont, size: width * 0.08))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                HStack(spacing: width * 0.03) {
                    if !options.location.isEmpty {
                        Text(options.location)
                    }
                    if !options.date.isEmpty {
                        Text(options.date)
                    }
                    if !options.signature.isEmpty {
                        Text(options.signature)
                    }
                }
                .font(.custom(handFontAlt, size: width * 0.03))
                .foregroundStyle(.white.opacity(0.8))
            }
            .padding(width * 0.08)
        }
    }
}

// MARK: - 导出

enum PosterExporter {
    @MainActor
    static func render(image: NSImage, template: PosterTemplate,
                       options: PosterOptions, width: CGFloat) -> NSImage? {
        let height = width / template.aspect
        let canvas = PosterCanvas(image: image, template: template, options: options)
            .frame(width: width, height: height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

// MARK: - 面板

struct EditPosterPanel: View {
    let preview: NSImage?
    @Binding var template: PosterTemplate
    @Binding var title: String
    @Binding var subtitle: String
    @Binding var location: String
    @Binding var date: String
    @Binding var signature: String
    let isExporting: Bool
    let onExport: () -> Void
    let onQuickExport: () -> Void
    let onCopy: () -> Void
    let onShare: () -> Void

    private var options: PosterOptions {
        PosterOptions(title: title, subtitle: subtitle, location: location,
                      date: date, signature: signature)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("模板")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(PosterTemplate.allCases) { item in
                    Button {
                        template = item
                    } label: {
                        Text(item.title)
                            .font(.system(size: 10.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(template == item ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.07)))
                            .foregroundStyle(template == item ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            PosterCanvas(image: preview, template: template, options: options)
                .frame(width: 276, height: 276 / template.aspect)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5))

            TextField("标题", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
            TextField("副标题 / 英文小字", text: $subtitle)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
            TextField("地点", text: $location)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
            TextField("日期", text: $date)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
            TextField("签名 / 手写批注", text: $signature)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))

            HStack(spacing: 8) {
                Button(isExporting ? "生成中…" : "导出 PNG", action: onExport)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isExporting)
                Button("存到桌面", action: onQuickExport)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isExporting)
            }

            HStack(spacing: 8) {
                Button("复制图片", action: onCopy)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isExporting)
                Button("分享…", action: onShare)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isExporting)
            }

            Text("导出使用当前所有调整，并按 2 倍像素渲染；模板文字不会写进照片配方，随时可以换一套。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
