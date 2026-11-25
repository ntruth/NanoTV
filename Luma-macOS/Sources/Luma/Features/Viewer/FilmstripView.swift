import SwiftUI
import AppKit

struct FilmstripView: View {
    let items: [PhotoItem]
    let currentID: UUID
    /// 非 nil 表示连拍组内选择模式：点缩略图勾选，并显示勾选标记。
    var selection: Set<UUID>?
    let onSelect: (UUID) -> Void

    /// 与系统「照片」胶片条一致：等高的窄条，铺满整行，单屏可见更多张。
    private let itemHeight: CGFloat = 42
    private let spacing: CGFloat = 3

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item.id)
                        } label: {
                            FilmstripThumb(photo: item,
                                           height: itemHeight,
                                           isCurrent: item.id == currentID)
                                .overlay(alignment: .topTrailing) {
                                    if let selection {
                                        let picked = selection.contains(item.id)
                                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(picked ? Color.accentColor : Color.white)
                                            .shadow(color: .black.opacity(0.55), radius: 2, y: 0.5)
                                            .padding(2)
                                    }
                                }
                                .opacity(selection != nil && selection?.contains(item.id) != true ? 0.55 : 1)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: itemHeight + 12)
            // 两端淡出，滚动时不会出现生硬的截断边缘。
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.012),
                    .init(color: .black, location: 0.988),
                    .init(color: .clear, location: 1)
                ], startPoint: .leading, endPoint: .trailing)
            )
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            )
            .onAppear {
                proxy.scrollTo(currentID, anchor: .center)
            }
            .onChange(of: currentID) { _, id in
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

struct FilmstripThumb: View {
    @EnvironmentObject private var settings: AppSettings
    let photo: PhotoItem
    var height: CGFloat = 42
    let isCurrent: Bool

    private var corner: CGFloat { max(3, settings.smallCoverRadius - 1) }

    /// 按原始比例取宽度（竖图更窄、横图更宽），与系统「照片」胶片条一致；异常值夹在合理区间。
    private var width: CGFloat {
        let w = photo.pixelWidth
        let h = photo.pixelHeight
        guard w > 0, h > 0 else { return height }
        let raw = height * CGFloat(w) / CGFloat(h)
        return min(max(raw, height * 0.62), height * 1.9)
    }

    var body: some View {
        ZStack {
            PhotoThumbnailView(photo: photo, purpose: .filmstrip(height))
            if photo.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(isCurrent ? Color.white : Color.white.opacity(0.12),
                              lineWidth: isCurrent ? 2 : 0.6)
        }
        .shadow(color: .black.opacity(isCurrent ? 0.28 : 0), radius: 5, y: 2)
        .opacity(isCurrent ? 1 : 0.75)
    }
}
