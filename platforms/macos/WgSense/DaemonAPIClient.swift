import Foundation

struct DaemonAPIClient {
    let baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:8765")!) {
        self.baseURL = baseURL
    }

    func request(
        _ path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        timeout: TimeInterval = 20
    ) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { throw DaemonAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DaemonAPIError.response(Self.errorMessage(from: data, fallback: "daemon API 请求失败"))
        }
        return data
    }

    func decode<Response: Decodable>(
        _ type: Response.Type,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        timeout: TimeInterval = 20
    ) async throws -> Response {
        let data = try await request(path, method: method, queryItems: queryItems, body: body, timeout: timeout)
        return try JSONDecoder().decode(type, from: data)
    }

    static func errorMessage(from data: Data, fallback: String) -> String {
        let backendMessage = try? JSONDecoder().decode(DaemonAPIErrorBody.self, from: data).error
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return backendMessage ?? raw ?? fallback
    }

    static func connectionMessage(_ error: Error) -> String {
        if let urlError = error as? URLError,
           [.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .timedOut].contains(urlError.code) {
            return "daemon 未连接"
        }
        return error.localizedDescription
    }
}

enum DaemonAPIError: LocalizedError {
    case invalidURL
    case response(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "daemon API 地址无效"
        case .response(let message):
            return message
        }
    }
}

private struct DaemonAPIErrorBody: Decodable {
    let error: String
}
