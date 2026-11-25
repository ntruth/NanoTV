import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 使用苹果官方 PhotosUI（PHPickerViewController）安全挑选系统「照片」中的项目。
/// PHPicker 在独立进程中运行，只把用户明确选择的文件交给我们，无需申请整个图库的访问权限。
struct PhotoPickerSheet: NSViewControllerRepresentable {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, dismiss: dismiss)
    }

    func makeNSViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = 0
        configuration.filter = .any(of: [.images, .videos])
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateNSViewController(_ nsViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let store: LibraryStore
        private let dismiss: DismissAction

        init(store: LibraryStore, dismiss: DismissAction) {
            self.store = store
            self.dismiss = dismiss
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            dismiss()
            guard !results.isEmpty else { return }
            let providers = results.map { $0.itemProvider }
            Task {
                let urls = await Self.copyToTemporary(providers)
                await MainActor.run {
                    guard !urls.isEmpty else {
                        store.showToast("没有读取到可导入的项目")
                        return
                    }
                    store.prepareImport(urls)
                }
            }
        }

        private static func copyToTemporary(_ providers: [NSItemProvider]) async -> [URL] {
            let fileManager = FileManager.default
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("LumaPicker-\(UUID().uuidString)", isDirectory: true)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            var urls: [URL] = []
            for (index, provider) in providers.enumerated() {
                guard let typeIdentifier = preferredTypeIdentifier(for: provider) else { continue }
                let ext = UTType(typeIdentifier)?.preferredFilenameExtension ?? "dat"
                let destination = directory
                    .appendingPathComponent("picker-\(index)-\(UUID().uuidString).\(ext)")
                if let url = try? await loadFile(provider,
                                                 typeIdentifier: typeIdentifier,
                                                 destination: destination) {
                    urls.append(url)
                }
            }
            return urls
        }

        private static func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
            let candidates = provider.registeredTypeIdentifiers
            let preferred: [UTType] = [.heic, .jpeg, .png, .tiff, .image,
                                       .quickTimeMovie, .mpeg4Movie, .movie]
            for type in preferred {
                if let match = candidates.first(where: { UTType($0)?.conforms(to: type) == true }) {
                    return match
                }
            }
            return candidates.first { identifier in
                guard let type = UTType(identifier) else { return false }
                return type.conforms(to: .image) || type.conforms(to: .movie)
            }
        }

        private static func loadFile(_ provider: NSItemProvider,
                                     typeIdentifier: String,
                                     destination: URL) async throws -> URL {
            try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                    guard let url else {
                        continuation.resume(throwing: error ?? PickerError.unavailable)
                        return
                    }
                    do {
                        try FileManager.default.copyItem(at: url, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private enum PickerError: Error {
        case unavailable
    }
}
