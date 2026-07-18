import Foundation

struct ProxyAPIClient {
    private let api: DaemonAPIClient

    init(api: DaemonAPIClient = DaemonAPIClient()) {
        self.api = api
    }

    func status() async throws -> ProxyStatus {
        try await api.decode(ProxyStatus.self, path: "api/proxy/status")
    }

    func settings() async throws -> ProxySettingsResponse {
        try await api.decode(ProxySettingsResponse.self, path: "api/proxy/settings")
    }

    func saveSettings(
        address: String,
        secret: String?,
        latencyTestURL: String,
        latencyTimeout: Int,
        latencyLow: Int,
        latencyMedium: Int
    ) async throws -> ProxySettingsResponse {
        var body: [String: Any] = [
            "address": address,
            "latency_test_url": latencyTestURL,
            "latency_timeout": latencyTimeout,
            "latency_low": latencyLow,
            "latency_medium": latencyMedium
        ]
        if let secret { body["secret"] = secret }
        return try await api.decode(
            ProxySettingsResponse.self,
            path: "api/proxy/settings",
            method: "PATCH",
            body: body
        )
    }

    func version() async throws -> MihomoVersion {
        try await api.decode(MihomoVersion.self, path: "api/proxy/version")
    }

    func proxies() async throws -> ProxiesResponse {
        try await api.decode(ProxiesResponse.self, path: "api/proxy/proxies")
    }

    func selectProxy(group: String, name: String) async throws {
        try await command(
            "api/proxy/select",
            body: ["group": group, "name": name]
        )
    }

    func delay(name: String) async throws -> DelayResult {
        try await api.decode(
            DelayResult.self,
            path: "api/proxy/delay",
            queryItems: [URLQueryItem(name: "name", value: name)]
        )
    }

    func groupDelay(group: String) async throws -> GroupDelayResult {
        try await api.decode(
            GroupDelayResult.self,
            path: "api/proxy/delay",
            queryItems: [URLQueryItem(name: "group", value: group)]
        )
    }

    func connections() async throws -> ConnectionsResponse {
        try await api.decode(ConnectionsResponse.self, path: "api/proxy/connections")
    }

    func closeConnection(id: String) async throws {
        try await command(
            "api/proxy/connection-close",
            queryItems: [URLQueryItem(name: "id", value: id)]
        )
    }

    func closeAllConnections() async throws {
        try await command("api/proxy/connections-close-all")
    }

    func rules() async throws -> RulesResponse {
        try await api.decode(RulesResponse.self, path: "api/proxy/rules")
    }

    func proxyProviders() async throws -> ProxyProvidersResponse {
        try await api.decode(ProxyProvidersResponse.self, path: "api/proxy/providers")
    }

    func ruleProviders() async throws -> RuleProvidersResponse {
        try await api.decode(RuleProvidersResponse.self, path: "api/proxy/rule-providers")
    }

    func config() async throws -> MihomoConfig {
        try await api.decode(MihomoConfig.self, path: "api/proxy/configs")
    }

    func updateProvider(name: String) async throws {
        try await command(
            "api/proxy/provider-update",
            queryItems: [URLQueryItem(name: "name", value: name)]
        )
    }

    func healthCheckProvider(name: String) async throws {
        try await command(
            "api/proxy/provider-healthcheck",
            queryItems: [URLQueryItem(name: "name", value: name)]
        )
    }

    func updateRuleProvider(name: String) async throws {
        try await command(
            "api/proxy/rule-provider-update",
            queryItems: [URLQueryItem(name: "name", value: name)]
        )
    }

    func patchConfig(_ values: [String: Any]) async throws {
        try await command("api/proxy/configs", method: "PATCH", body: values)
    }

    func performAction(_ action: String) async throws {
        try await command("api/proxy/action", body: ["action": action])
    }

    func dnsQuery(name: String, type: String) async throws -> DNSQueryResponse {
        try await api.decode(
            DNSQueryResponse.self,
            path: "api/proxy/dns-query",
            queryItems: [URLQueryItem(name: "name", value: name), URLQueryItem(name: "type", value: type)]
        )
    }

    func logs(limit: Int) async throws -> ProxyLogsResponse {
        try await api.decode(
            ProxyLogsResponse.self,
            path: "api/proxy/logs",
            queryItems: [URLQueryItem(name: "n", value: "\(limit)")]
        )
    }

    private func command(
        _ path: String,
        method: String = "POST",
        queryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws {
        _ = try await api.request(path, method: method, queryItems: queryItems, body: body)
    }
}
