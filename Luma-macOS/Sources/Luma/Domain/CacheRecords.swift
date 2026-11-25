import Foundation

/// 网盘照片的持久化缓存行：EXIF、端侧识别结果、特征向量、查看记录都写在这里。
/// 以 `mountID + path` 为键，远端文件大小变化时整行作废。
struct CloudAssetCacheRow {
    var path: String
    var size: Int64?
    var remoteModified: Date?
    var exif: CloudPhotoEXIF?
    var labels: String?
    var text: String?
    var feature: Data?
    var viewedAt: Date?
    var metadataAt: Date?
    var analyzedAt: Date?
    var peopleAt: Date?
}

/// 派生报告的缓存键：本地 / 系统图库 / 网盘各自独立，互不串结果。
enum DerivedReportKey {
    static func local(_ kind: String) -> String { "local|\(kind)" }
    static func system(_ path: String, _ kind: String) -> String { "system|\(path)|\(kind)" }
    static func cloud(_ mountID: UUID, _ path: String, _ kind: String) -> String {
        "cloud|\(mountID.uuidString)|\(path)|\(kind)"
    }
    static func cloudMountPrefix(_ mountID: UUID) -> String { "cloud|\(mountID.uuidString)|" }
    static func systemPrefix(_ path: String) -> String { "system|\(path)|" }
}
