import Foundation

// 直连 Mihomo 控制器（与原版一致），不再经 WgSense 后台服务转发：
// 多后端、测速参数（url/timeout）、WebSocket 推送都需要完整的控制器接口。

struct MihomoAPIError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { message.isEmpty ? "HTTP \(status)" : message }
}

struct MihomoAPI {
    let backend: MihomoBackend
    let secret: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: 基础

    /// 路径段转义：节点/组名可能含 `/`、空格、`|` 等，必须逐段编码后再拼接。
    static func seg(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? name
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Any? = nil, timeout: TimeInterval = 15) throws -> URLRequest {
        guard let base = backend.baseURL?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              var comps = URLComponents(string: base + "/" + path) else {
            throw MihomoAPIError(status: 0, message: "后端地址无效")
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw MihomoAPIError(status: 0, message: "后端地址无效") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if !secret.isEmpty { req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    @discardableResult
    private func send(_ req: URLRequest) async throws -> (Data, Int) {
        let (data, resp) = try await Self.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 15) async throws -> T {
        let (data, status) = try await send(request(path, query: query, timeout: timeout))
        guard (200..<300).contains(status) else {
            throw MihomoAPIError(status: status, message: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func command(_ path: String, method: String, query: [URLQueryItem] = [], body: Any? = nil) async throws {
        let (data, status) = try await send(request(path, method: method, query: query, body: body))
        guard (200..<300).contains(status) else {
            throw MihomoAPIError(status: status, message: String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: 代理

    func version() async throws -> MihomoVersionInfo { try await decode(MihomoVersionInfo.self, "version") }
    func proxies() async throws -> MihomoProxiesResponse { try await decode(MihomoProxiesResponse.self, "proxies") }
    func providers() async throws -> MihomoProvidersResponse { try await decode(MihomoProvidersResponse.self, "providers/proxies") }
    func config() async throws -> MihomoRuntimeConfig { try await decode(MihomoRuntimeConfig.self, "configs") }

    func select(group: String, name: String) async throws {
        try await command("proxies/\(Self.seg(group))", method: "PUT", body: ["name": name])
    }

    /// 解除 UrlTest/Fallback 等组的手动固定（原版 deleteFixedProxyAPI）。
    func deleteFixed(group: String) async throws {
        try await command("proxies/\(Self.seg(group))", method: "DELETE")
    }

    func patchConfig(_ values: [String: Any]) async throws {
        try await command("configs", method: "PATCH", body: values)
    }

    /// 单节点测速。返回 (延迟, 是否成功)；失败不抛错，与原版按 status 判断一致。
    func delay(proxy: String, url: String, timeout: Int) async -> (delay: Int, ok: Bool) {
        await delayRequest("proxies/\(Self.seg(proxy))/delay", url: url, timeout: timeout)
    }

    /// 提供商内节点测速（原版对订阅节点优先走这个接口）。
    func providerDelay(provider: String, proxy: String, url: String, timeout: Int) async -> (delay: Int, ok: Bool) {
        await delayRequest("providers/proxies/\(Self.seg(provider))/\(Self.seg(proxy))/healthcheck", url: url, timeout: timeout)
    }

    private func delayRequest(_ path: String, url: String, timeout: Int) async -> (delay: Int, ok: Bool) {
        guard let req = try? request(path, query: [
            URLQueryItem(name: "url", value: url),
            URLQueryItem(name: "timeout", value: "\(timeout)"),
        ], timeout: TimeInterval(timeout) / 1000 + 5) else { return (mihomoNotConnected, false) }
        guard let (data, status) = try? await send(req), status == 200,
              let result = try? JSONDecoder().decode(MihomoDelayResponse.self, from: data) else {
            return (mihomoNotConnected, false)
        }
        return (result.delay, true)
    }

    /// 组测速：返回各成员延迟。
    func groupDelay(group: String, url: String, timeout: Int) async throws -> [String: Int] {
        try await decode([String: Int].self, "group/\(Self.seg(group))/delay", query: [
            URLQueryItem(name: "url", value: url),
            URLQueryItem(name: "timeout", value: "\(timeout)"),
        ], timeout: TimeInterval(timeout) / 1000 + 10)
    }

    func smartWeights() async throws -> MihomoSmartWeightsResponse {
        try await decode(MihomoSmartWeightsResponse.self, "group/weights")
    }

    func updateProvider(_ name: String) async throws {
        try await command("providers/proxies/\(Self.seg(name))", method: "PUT")
    }

    func healthCheckProvider(_ name: String) async throws {
        _ = try await send(request("providers/proxies/\(Self.seg(name))/healthcheck", timeout: 60))
    }

    func closeConnection(_ id: String) async throws {
        try await command("connections/\(Self.seg(id))", method: "DELETE")
    }

    // MARK: WebSocket

    /// 连接流：Mihomo 每秒推送一次全量快照。断线后指数退避重连，直到调用方取消。
    func connectionsStream() -> AsyncStream<MihomoConnectionsSnapshot> {
        webSocketStream(path: "connections", as: MihomoConnectionsSnapshot.self)
    }

    func trafficStream() -> AsyncStream<MihomoTraffic> {
        webSocketStream(path: "traffic", as: MihomoTraffic.self)
    }

    func memoryStream() -> AsyncStream<MihomoMemory> {
        webSocketStream(path: "memory", as: MihomoMemory.self)
    }

    private func webSocketStream<T: Decodable & Sendable>(path: String, as type: T.Type) -> AsyncStream<T> {
        let backend = backend
        let secret = secret
        return AsyncStream { continuation in
            let task = Task {
                var backoff: UInt64 = 1
                while !Task.isCancelled {
                    guard let base = backend.webSocketBase?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                          var comps = URLComponents(string: base + "/" + path) else { break }
                    if !secret.isEmpty { comps.queryItems = [URLQueryItem(name: "token", value: secret)] }
                    guard let url = comps.url else { break }
                    let socket = Self.session.webSocketTask(with: url)
                    socket.resume()
                    do {
                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            let data: Data
                            switch message {
                            case .string(let text): data = Data(text.utf8)
                            case .data(let raw): data = raw
                            @unknown default: continue
                            }
                            if let value = try? JSONDecoder().decode(T.self, from: data) {
                                continuation.yield(value)
                                backoff = 1
                            }
                        }
                    } catch {
                        socket.cancel(with: .goingAway, reason: nil)
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                    backoff = min(backoff * 2, 30)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
