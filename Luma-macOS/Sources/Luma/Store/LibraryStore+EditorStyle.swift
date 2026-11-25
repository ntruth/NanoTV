import Foundation
import CoreImage

extension LibraryStore {
    /// 把当前编辑风格套用到选中的其它照片（不包含正在编辑的那一张）。
    @MainActor
    func applyStyleToSelection(_ style: EditState, strength: Double) {
        let ids = commandTargetIDs.filter { $0 != editorID }
        guard !ids.isEmpty else {
            showToast("先选中要套用的照片")
            return
        }
        Task {
            let applied = await applyStyle(style, strength: strength, to: Array(ids))
            if applied > 0 {
                showToast("已把风格套用到 \(applied) 张照片")
            } else {
                showToast("选中的照片不支持套用风格")
            }
        }
    }

    @MainActor
    private func applyStyle(_ style: EditState, strength: Double, to ids: [UUID]) async -> Int {
        let wanted = Set(ids)
        let targets = photos.filter {
            wanted.contains($0.id) && !$0.isVideo && !$0.isSystem && !$0.isDeleted
        }
        guard !targets.isEmpty else { return 0 }

        var renders: [StyleRender] = []
        renders.reserveCapacity(targets.count)
        let chunkSize = 4
        var index = 0
        while index < targets.count {
            if Task.isCancelled { break }
            let end = min(index + chunkSize, targets.count)
            let chunk = Array(targets[index..<end])
            let part = await Task.detached(priority: .userInitiated) {
                Self.renderStyle(checkpoint: chunk, style: style, strength: strength)
            }.value
            renders.append(contentsOf: part)
            index = end
        }
        guard !renders.isEmpty else { return 0 }

        LibraryPaths.prepare()
        for render in renders {
            guard let position = photos.firstIndex(where: { $0.id == render.id }) else { continue }
            let filename = render.id.uuidString + ".jpg"
            let url = LibraryPaths.edited.appendingPathComponent(filename)
            try? render.data.write(to: url, options: .atomic)

            var updated = photos[position]
            updated.editedFilename = filename
            updated.pixelWidth = render.width
            updated.pixelHeight = render.height
            updated.editRecipe = render.recipe
            updated.rotation = nil
            ImportService.makeImageThumbnail(url: url, destination: LibraryPaths.thumbnailURL(for: updated))
            updated.editVersion += 1
            photos[position] = updated
            ImageLoader.invalidate(photo: updated)
        }
        save()
        return renders.count
    }

    private struct StyleRender: Sendable {
        let id: UUID
        let data: Data
        let width: Int
        let height: Int
        let recipe: String
    }

    nonisolated private static func renderStyle(checkpoint: [PhotoItem],
                                                style: EditState,
                                                strength: Double) -> [StyleRender] {
        checkpoint.compactMap { photo in
            guard !photo.isVideo, !photo.isReadOnly, !photo.isDeleted else { return nil }
            let hasRecipe = photo.hasEdits && photo.editRecipe != nil
            let baseURL = hasRecipe ? LibraryPaths.originalURL(for: photo)
                                    : LibraryPaths.sourceURL(for: photo)
            guard let base = PhotoRenderer.loadBase(url: baseURL) else { return nil }
            var state = hasRecipe
                ? (photo.editRecipe.flatMap(EditState.init(jsonString:)) ?? EditState())
                : EditState()
            if !hasRecipe {
                state.rotation = photo.rotationAngle
            }
            let next = state.applying(style: style, strength: strength)
            guard let image = PhotoRenderer.renderCG(base: base, state: next, maxPixel: nil),
                  let data = Self.jpegData(from: image),
                  let recipe = next.jsonString else { return nil }
            return StyleRender(id: photo.id, data: data, width: image.width,
                               height: image.height, recipe: recipe)
        }
    }
}
