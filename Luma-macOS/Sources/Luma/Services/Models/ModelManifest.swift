import Foundation

/// 模型清单：既支持「一个压缩包」，也支持「多个文件分别下载」。
/// 清单本身随 App 内置（只有几 KB），模型文件走国内镜像，换源不需要发版。
struct ModelManifest: Codable {
    struct Component: Codable, Identifiable {
        struct File: Codable {
            let name: String
            /// 按优先级排列的下载地址；失败自动切下一个。
            let urls: [String]
            let size: Int64
            let sha256: String
            /// 目前只支持 zip，用系统 ditto 解压。
            let archive: String?
        }

        let id: String
        let version: String
        /// 整个组件的总字节数（多文件时是各文件之和）。
        let size: Int64
        /// 旧版单包格式；新清单用 files。
        let sha256: String?
        let sources: [String]
        let files: [File]?
        let minAppVersion: String?
    }

    let version: Int
    let components: [Component]
}

/// 安装完成标记，写在组件目录里；缺少它表示目录可能是半成品。
struct ModelReadyMarker: Codable {
    let version: String
    let sha256: String
    let installedAt: Date
}
