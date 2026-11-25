import AppKit

/// 打印视图：每张照片一页，等比缩放居中，并在底部显示文件名。
final class PhotoPrintView: NSView {
    private struct Page {
        let image: NSImage
        let title: String
    }

    private let pages: [Page]
    private var currentPage = 0

    init(items: [PhotoItem]) {
        pages = items.compactMap { photo -> Page? in
            guard let image = ImageLoader.fullNSImage(for: photo) else { return nil }
            return Page(image: image, title: photo.originalName)
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 595, height: 842))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(1, pages.count))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        currentPage = max(0, page - 1)
        return bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        guard pages.indices.contains(currentPage) else { return }
        let page = pages[currentPage]

        let captionHeight: CGFloat = 24
        let content = bounds.insetBy(dx: 18, dy: 18)
        let imageArea = NSRect(x: content.minX,
                               y: content.minY,
                               width: content.width,
                               height: max(1, content.height - captionHeight))

        let imageSize = page.image.size
        if imageSize.width > 0, imageSize.height > 0 {
            let scale = min(imageArea.width / imageSize.width,
                            imageArea.height / imageSize.height)
            let drawSize = NSSize(width: imageSize.width * scale,
                                  height: imageSize.height * scale)
            let rect = NSRect(x: imageArea.midX - drawSize.width / 2,
                              y: imageArea.midY - drawSize.height / 2,
                              width: drawSize.width,
                              height: drawSize.height)
            page.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true,
                            hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let caption = page.title as NSString
        let textSize = caption.size(withAttributes: attributes)
        caption.draw(at: NSPoint(x: content.midX - textSize.width / 2,
                                 y: content.maxY - textSize.height),
                     withAttributes: attributes)
    }
}
