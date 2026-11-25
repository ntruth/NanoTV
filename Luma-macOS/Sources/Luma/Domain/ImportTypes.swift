import Foundation
import AppKit

struct ImportCandidate: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileCount: Int
    let cover: NSImage?
    let previewURLs: [URL]
}

struct ImportOptions {
    var createAlbumsFromFolders: Bool = true
    var preserveFolderStructure: Bool = true
    var targetAlbumID: UUID?
    /// 导入前计算 SHA-256，跳过与图库中已有文件字节完全相同的项目。
    var skipExactDuplicates: Bool = true
    /// 复制完成后重新计算目标文件哈希，确认写入完整。
    var verifyCopies: Bool = true
}

struct ImportProgress {
    var total: Int
    var completed: Int
    var currentName: String
    var importedCount: Int = 0
    var skippedDuplicates: Int = 0
    var failedCount: Int = 0
    var verifiedCount: Int = 0
    var isCancelled: Bool = false

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}
