import Foundation

struct ProxyStatus: Codable {
    let running: Bool
    let connected: Bool
    let address: String
    let baseURL: String?
    let lastError: String?
    let lastChecked: String?

    enum CodingKeys: String, CodingKey {
        case running, connected, address
        case baseURL = "base_url"
        case lastError = "last_error"
        case lastChecked = "last_checked"
    }
}

struct ProxySettings: Codable {
    let address: String
    let secretSet: Bool
    let latencyTestURL: String
    let latencyTimeout: Int
    let latencyLow: Int
    let latencyMedium: Int

    enum CodingKeys: String, CodingKey {
        case address
        case secretSet = "secret_set"
        case latencyTestURL = "latency_test_url"
        case latencyTimeout = "latency_timeout"
        case latencyLow = "latency_low"
        case latencyMedium = "latency_medium"
    }
}

struct ProxySettingsResponse: Codable {
    let settings: ProxySettings
    let status: ProxyStatus
}

struct MihomoVersion: Codable {
    let meta: Bool?
    let version: String
    let premium: Bool?
    let foundation: Bool?
}

struct DelayHistory: Codable {
    let time: String?
    let delay: Int64
}

struct ProxyInfo: Codable, Identifiable {
    var id: String { name }
    let name: String
    let type: String
    let all: [String]?
    let now: String?
    let history: [DelayHistory]?
    let alive: Bool?
    let udp: Bool?
    let xudp: Bool?
    let provider: String?
    let providerName: String?

    var sourceProvider: String? { providerName ?? provider }

    enum CodingKeys: String, CodingKey {
        case name, type, all, now, history, alive, udp, xudp, provider
        case providerName = "provider-name"
    }
}

struct ProxiesResponse: Codable {
    let proxies: [String: ProxyInfo]
}

struct DelayResult: Codable {
    let delay: Int64?
    let message: String?
    let error: String?
}

struct GroupDelayResult: Codable {
    let delays: [String: Int64]
}

struct ConnectionInfo: Codable, Identifiable {
    let id: String
    let metadata: ConnectionMetadata
    let upload: Int64
    let download: Int64
    let start: String?
    let chains: [String]?
    let rule: String?
    let uploadSpeed: Int64?
    let downloadSpeed: Int64?
    let alive: Bool?
}

struct ConnectionMetadata: Codable {
    let netWork: String?
    let type: String?
    let sourceIP: String?
    let sourcePort: String?
    let destinationIP: String?
    let destinationPort: String?
    let host: String?
    let process: String?
    let processPath: String?
    let remoteDestination: String?

    enum CodingKeys: String, CodingKey {
        case netWork = "network"
        case type
        case sourceIP
        case sourcePort
        case destinationIP
        case destinationPort
        case host
        case process
        case processPath
        case remoteDestination
    }
}

struct ConnectionsResponse: Codable {
    let downloadTotal: Int64
    let uploadTotal: Int64
    let connections: [ConnectionInfo]
}

struct RuleInfo: Codable, Identifiable {
    var id: String { uuid ?? "\(index ?? -1)|\(type)|\(payload ?? "")|\(proxy ?? "")" }
    let type: String
    let payload: String?
    let proxy: String?
    let chains: [String]?
    let size: Int64?
    let uuid: String?
    let index: Int?
    let disabled: Bool?
}

struct RulesResponse: Codable {
    let rules: [RuleInfo]
}

struct ProxyProviderInfo: Codable, Identifiable {
    var id: String { name }
    let name: String
    let type: String?
    let vehicleType: String?
    let updatedAt: String?
    let testURL: String?
    let proxies: [ProxyInfo]?
    let proxyCount: Int
    let subscriptionInfo: SubscriptionInfo?

    enum CodingKeys: String, CodingKey {
        case name, type, vehicleType, updatedAt, proxies, subscriptionInfo
        case testURL = "testUrl"
        case proxyCount = "proxy_count"
    }
}

struct SubscriptionInfo: Codable {
    let download: Int64?
    let upload: Int64?
    let total: Int64?
    let expire: Int64?

    enum CodingKeys: String, CodingKey {
        case download = "Download"
        case upload = "Upload"
        case total = "Total"
        case expire = "Expire"
    }
}

struct ProxyProvidersResponse: Codable {
    let providers: [String: ProxyProviderInfo]
}

struct RuleProviderInfo: Codable, Identifiable {
    var id: String { name }
    let name: String
    let type: String?
    let behavior: String?
    let format: String?
    let ruleCount: Int?
    let updatedAt: String?
    let url: String?
    let vehicleType: String?
}

struct RuleProvidersResponse: Codable {
    let providers: [String: RuleProviderInfo]
}

struct MihomoConfig: Codable {
    struct Tun: Codable {
        let enable: Bool
    }

    let port: Int?
    let socksPort: Int?
    let redirPort: Int?
    let tproxyPort: Int?
    let mode: String?
    let modeList: [String]?
    let modes: [String]?
    let logLevel: String?
    let allowLan: Bool?
    let bindAddress: String?
    let ipv6: Bool?
    let tun: Tun?
    let mixedPort: Int?

    enum CodingKeys: String, CodingKey {
        case port, mode, modes, tun, ipv6
        case socksPort = "socks-port"
        case redirPort = "redir-port"
        case tproxyPort = "tproxy-port"
        case modeList = "mode-list"
        case logLevel = "log-level"
        case allowLan = "allow-lan"
        case bindAddress = "bind-address"
        case mixedPort = "mixed-port"
    }
}

struct DNSQueryResponse: Codable {
    struct Record: Codable, Identifiable {
        var id: String { "\(name ?? "")|\(type ?? 0)|\(data ?? "")" }
        let name: String?
        let type: Int?
        let ttl: Int?
        let data: String?

        enum CodingKeys: String, CodingKey {
            case name, type, data
            case ttl = "TTL"
        }
    }

    let status: Int?
    let answer: [Record]?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case answer = "Answer"
        case message
    }
}

struct ProxyLogEntry: Codable, Identifiable {
    var id: String { "\(time)|\(level)|\(payload)" }
    let time: String
    let level: String
    let payload: String
}

struct ProxyLogsResponse: Codable {
    let logs: [ProxyLogEntry]
    let count: Int
}
