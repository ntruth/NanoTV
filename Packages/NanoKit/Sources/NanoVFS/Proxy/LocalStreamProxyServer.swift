import Foundation
import Network
import NanoCore

/// 本地回环 HTTP 流式代理网关（127.0.0.1）
/// 核心作用：为方案 B（115/夸克/百度网盘直链）自动注入防盗链 Cookie / User-Agent / Referer，并透传 HTTP Range 分片请求实现 4K 秒拖
public actor LocalStreamProxyServer {
    public static let shared = LocalStreamProxyServer()

    public struct UpstreamRoute: Sendable {
        public let remoteURL: URL
        public let headers: [String: String]
        public let createdAt: Date
    }

    private var listener: NWListener?
    private var listeningPort: UInt16 = 0
    private var routes: [String: UpstreamRoute] = [:]

    public init() {}

    /// 注册一条需要注入特定请求头的网盘直链，返回本地 `http://127.0.0.1:{port}/stream/{token}` 播放地址
    public func registerStream(remoteURL: URL, headers: [String: String]) async throws -> URL {
        if listener == nil || listeningPort == 0 {
            try await startIfNeeded()
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        routes[token] = UpstreamRoute(remoteURL: remoteURL, headers: headers, createdAt: Date())
        return URL(string: "http://127.0.0.1:\(listeningPort)/stream/\(token)")!
    }

    public func startIfNeeded() async throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwListener = try NWListener(using: params, on: .any)

        nwListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.handleClientConnection(connection)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nwListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = nwListener.port?.rawValue {
                        Task { await self?.setPort(port) }
                    }
                    nwListener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    nwListener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            nwListener.start(queue: .global(qos: .userInitiated))
        }
        self.listener = nwListener
    }

    private func setPort(_ port: UInt16) {
        self.listeningPort = port
    }

    private func handleClientConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, let requestText = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task {
                await self.proxyUpstreamStream(requestText: requestText, clientConnection: connection)
            }
        }
    }

    private func proxyUpstreamStream(requestText: String, clientConnection: NWConnection) async {
        let lines = requestText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            clientConnection.cancel()
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            clientConnection.cancel()
            return
        }

        let path = String(parts[1])
        let token = path.replacingOccurrences(of: "/stream/", with: "").split(separator: "?").first.map(String.init) ?? ""
        guard let route = routes[token] else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            clientConnection.send(content: notFound.data(using: .utf8), completion: .contentProcessed { _ in
                clientConnection.cancel()
            })
            return
        }

        var upstreamReq = URLRequest(url: route.remoteURL)
        upstreamReq.httpMethod = String(parts[0])
        for (k, v) in route.headers {
            upstreamReq.setValue(v, forHTTPHeaderField: k)
        }
        // 透传播放器发来的 Range 请求头，支持拖动进度条与片头秒跳
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                let rangeVal = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
                upstreamReq.setValue(rangeVal, forHTTPHeaderField: "Range")
            }
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: upstreamReq)
            guard let httpResp = response as? HTTPURLResponse else {
                clientConnection.cancel()
                return
            }

            var headerBuilder = "HTTP/1.1 \(httpResp.statusCode) OK\r\n"
            let passthroughKeys = ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"]
            for key in passthroughKeys {
                if let val = httpResp.value(forHTTPHeaderField: key) {
                    headerBuilder += "\(key): \(val)\r\n"
                }
            }
            headerBuilder += "Connection: close\r\n\r\n"

            clientConnection.send(content: headerBuilder.data(using: .utf8), completion: .idempotent)

            var chunkBuffer = Data()
            chunkBuffer.reserveCapacity(65536)
            for try await byte in bytes {
                chunkBuffer.append(byte)
                if chunkBuffer.count >= 65536 {
                    let outData = chunkBuffer
                    chunkBuffer.removeAll(keepingCapacity: true)
                    try await sendChunk(outData, over: clientConnection)
                }
            }
            if !chunkBuffer.isEmpty {
                try await sendChunk(chunkBuffer, over: clientConnection)
            }
            clientConnection.cancel()
        } catch {
            clientConnection.cancel()
        }
    }

    private func sendChunk(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { sendErr in
                if let sendErr {
                    cont.resume(throwing: sendErr)
                } else {
                    cont.resume()
                }
            })
        }
    }
}
