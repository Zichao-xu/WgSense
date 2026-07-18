import Foundation

struct DaemonControlAPIClient {
    private let api: DaemonAPIClient

    init(api: DaemonAPIClient = DaemonAPIClient()) {
        self.api = api
    }

    func status(timeout: TimeInterval = 20) async throws -> DaemonStatus {
        try await api.decode(DaemonStatus.self, path: "api/status", timeout: timeout)
    }

    func profiles() async throws -> [String] {
        try await api.decode([String].self, path: "api/profiles")
    }

    func logs(limit: Int) async throws -> DaemonLogsResponse {
        try await api.decode(
            DaemonLogsResponse.self,
            path: "api/logs",
            queryItems: [URLQueryItem(name: "n", value: "\(limit)")]
        )
    }

    func traffic() async throws -> TrafficStats {
        try await api.decode(TrafficStats.self, path: "api/traffic")
    }

    func command(_ endpoint: String, timeout: TimeInterval = 5) async throws {
        _ = try await api.request("api/\(endpoint)", method: "POST", timeout: timeout)
    }

    func shutdownAppOwnedDaemon() async throws {
        _ = try await api.request("api/shutdown", method: "POST", timeout: 2)
    }

    func importProfile(name: String, content: String) async throws {
        _ = try await api.request(
            "api/profile/import",
            method: "POST",
            body: ["name": name, "content": content]
        )
    }

    func exportProfile(name: String) async throws -> ProfileExportResponse {
        try await api.decode(
            ProfileExportResponse.self,
            path: "api/profile/export",
            queryItems: [URLQueryItem(name: "name", value: name)]
        )
    }

    func saveProfile(_ profile: WGProfile) async throws {
        let body: [String: Any] = [
            "Name": profile.name,
            "Interface": [
                "PrivateKey": profile.privateKey,
                "Address": profile.address,
                "DNS": profile.dns,
                "MTU": profile.mtu
            ],
            "Peers": [[
                "PublicKey": profile.publicKey,
                "PresharedKey": profile.presharedKey,
                "Endpoint": profile.endpoint,
                "AllowedIPs": profile.allowedIPs
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) },
                "PersistentKeepaliveInterval": profile.keepalive
            ]]
        ]
        _ = try await api.request("api/profile/save", method: "POST", body: body)
    }

    func deleteProfile(name: String) async throws {
        _ = try await api.request(
            "api/profile/delete",
            method: "POST",
            queryItems: [URLQueryItem(name: "name", value: name)]
        )
    }

    func syncConfig(
        trustedNetworkPrefixes: [String],
        autoConnectUntrusted: Bool,
        intervalSeconds: Int,
        autoUpGraceSeconds: Int,
        healthCheckTarget: String
    ) async throws {
        let body: [String: Any] = [
            "trusted_network_prefixes": trustedNetworkPrefixes,
            "home_network_prefixes": trustedNetworkPrefixes,
            "auto_connect_untrusted": autoConnectUntrusted,
            "auto_connect_away": autoConnectUntrusted,
            "interval_seconds": intervalSeconds,
            "auto_up_grace_seconds": autoUpGraceSeconds,
            "health_check_target": healthCheckTarget,
            "health_check_interval_seconds": 30
        ]
        _ = try await api.request("api/config", method: "POST", body: body)
    }
}
