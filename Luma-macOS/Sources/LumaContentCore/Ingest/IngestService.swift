import Foundation

/// 入库请求：从外部源把媒体收进当前图库。
/// 电视录制、影院缓存、资源站保存都走这一个入口，避免各自复制「下载 → 转封装 → 导入 → 落盘」。
public struct IngestRequest: Sendable {
    public enum Payload: Sendable {
        /// 已经落盘的本地文件（临时文件也可以）。
        case localFile(URL)
        /// 远端媒体：视频先转封装 / 下载，再走图库导入。
        case remoteVideo(RemoteMedia)
        /// 远端直播流：只录固定时长（秒），复制封装后导入图库。
        case remoteClip(RemoteMedia, seconds: Int)
        /// 内存里的图片数据（站点配图、截图等）。
        case imageData(Data, fileExtension: String)
    }

    public var payload: Payload
    /// 写入图库后使用的标题；为空时沿用文件名。
    public var title: String?
    /// 导入后放进哪个相簿文件夹（可选）。
    public var folderName: String?

    public init(payload: Payload, title: String? = nil, folderName: String? = nil) {
        self.payload = payload
        self.title = title
        self.folderName = folderName
    }
}

/// 远端媒体描述：地址、请求头与证书策略。
public struct RemoteMedia: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var trustSelfSigned: Bool

    public init(url: URL, headers: [String: String] = [:], trustSelfSigned: Bool = false) {
        self.url = url
        self.headers = headers
        self.trustSelfSigned = trustSelfSigned
    }
}

/// 入库结果：只回传新条目 ID 与标题，不把图库模型暴露给调用方。
public struct IngestResult: Sendable {
    public var itemID: String?
    public var title: String

    public init(itemID: String? = nil, title: String) {
        self.itemID = itemID
        self.title = title
    }
}

/// 入库服务：当前图库是唯一能写入的会话，因此这个协议只由 library 实现。
/// 其它源（电视录制、影院缓存、资源站保存）拿到的是同一个入口。
@MainActor
public protocol IngestService: AnyObject {
    func ingest(_ request: IngestRequest) async throws -> IngestResult
}
