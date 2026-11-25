import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 站内照片拖拽：用纯文本承载一组照片 ID，避免额外注册自定义 UTI。
enum PhotoDrag {
    static let prefix = "luma-photo-ids:"

    static func provider(for ids: Set<UUID>) -> NSItemProvider {
        let body = ids.map(\.uuidString).joined(separator: ",")
        return NSItemProvider(object: NSString(string: prefix + body))
    }

    static func loadIDs(from providers: [NSItemProvider], completion: @escaping ([UUID]) -> Void) {
        guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else {
            completion([])
            return
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            let text = object as? String
            DispatchQueue.main.async {
                guard let text, text.hasPrefix(prefix) else {
                    completion([])
                    return
                }
                let ids = text.dropFirst(prefix.count)
                    .split(separator: ",")
                    .compactMap { UUID(uuidString: String($0)) }
                completion(ids)
            }
        }
    }
}

/// 拖拽预览：缩略图 + 数量徽标，让拖动过程更接近系统「照片」。
struct PhotoDragPreview: View {
    let image: NSImage?
    let count: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.25))
                }
            }
            .frame(width: 92, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.65), lineWidth: 1)
            }

            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .padding(5)
            }
        }
    }
}
