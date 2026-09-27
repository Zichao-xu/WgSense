import Foundation

// Mihomo 控制器 API 的数据模型。字段按真实返回数据编写（2026-09-27 实测 alpha-smart 内核）。
// 解码一律宽松：Mihomo 不同版本/不同节点类型的字段形态不一致，单个字段异常不能让整表解码失败。

/// 未连通 / 未测速的延迟值（与原版 NOT_CONNECTED 一致）。
let mihomoNotConnected = 0

struct MihomoDelayHistory: Codable, Equatable {
    var time: String
    var delay: Int
}

struct MihomoProxy: Decodable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var type: String
    var all: [String]?
    var now: String?
    var fixed: String?
    var history: [MihomoDelayHistory]
    /// 按测速地址分开的历史：`extra[url].history`。部分节点返回 `[]` 而不是对象。
    var extra: [String: [MihomoDelayHistory]]
    var udp: Bool
    var xudp: Bool
    var testUrl: String?
    var icon: String?
    var hidden: Bool
    var providerName: String?

    var isGroup: Bool { !(all ?? []).isEmpty }

    enum CodingKeys: String, CodingKey {
        case name, type, all, now, fixed, history, extra, udp, xudp, testUrl, icon, hidden
        case providerName = "provider-name"
    }

    private struct ExtraEntry: Decodable { var history: [MihomoDelayHistory]? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        all = try? c.decode([String].self, forKey: .all)
        now = (try? c.decode(String.self, forKey: .now)).flatMap { $0.isEmpty ? nil : $0 }
        fixed = (try? c.decode(String.self, forKey: .fixed)).flatMap { $0.isEmpty ? nil : $0 }
        history = (try? c.decode([MihomoDelayHistory].self, forKey: .history)) ?? []
        if let dict = try? c.decode([String: ExtraEntry].self, forKey: .extra) {
            extra = dict.compactMapValues { $0.history }
        } else {
            extra = [:]
        }
        udp = (try? c.decode(Bool.self, forKey: .udp)) ?? false
        xudp = (try? c.decode(Bool.self, forKey: .xudp)) ?? false
        testUrl = (try? c.decode(String.self, forKey: .testUrl)).flatMap { $0.isEmpty ? nil : $0 }
        icon = (try? c.decode(String.self, forKey: .icon)).flatMap { $0.isEmpty ? nil : $0 }
        hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false
        providerName = (try? c.decode(String.self, forKey: .providerName)).flatMap { $0.isEmpty ? nil : $0 }
    }

    init(name: String, type: String) {
        self.name = name
        self.type = type
        history = []
        extra = [:]
        udp = false
        xudp = false
        hidden = false
    }
}

struct MihomoProxiesResponse: Decodable {
    var proxies: [String: MihomoProxy]
}

struct MihomoSubscriptionInfo: Decodable, Equatable {
    var upload: Int64
    var download: Int64
    var total: Int64
    var expire: Int64

    enum CodingKeys: String, CodingKey {
        case upload = "Upload", download = "Download", total = "Total", expire = "Expire"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        upload = (try? c.decode(Int64.self, forKey: .upload)) ?? 0
        download = (try? c.decode(Int64.self, forKey: .download)) ?? 0
        total = (try? c.decode(Int64.self, forKey: .total)) ?? 0
        expire = (try? c.decode(Int64.self, forKey: .expire)) ?? 0
    }
}

struct MihomoProxyProvider: Decodable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var type: String
    var vehicleType: String
    var updatedAt: String?
    var testUrl: String?
    var proxies: [MihomoProxy]
    var subscriptionInfo: MihomoSubscriptionInfo?

    enum CodingKeys: String, CodingKey {
        case name, type, vehicleType, updatedAt, testUrl, proxies, subscriptionInfo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        vehicleType = (try? c.decode(String.self, forKey: .vehicleType)) ?? ""
        updatedAt = try? c.decode(String.self, forKey: .updatedAt)
        testUrl = (try? c.decode(String.self, forKey: .testUrl)).flatMap { $0.isEmpty ? nil : $0 }
        proxies = (try? c.decode([MihomoProxy].self, forKey: .proxies)) ?? []
        subscriptionInfo = try? c.decode(MihomoSubscriptionInfo.self, forKey: .subscriptionInfo)
    }
}

struct MihomoProvidersResponse: Decodable {
    var providers: [String: MihomoProxyProvider]
}

struct MihomoRuntimeConfig: Decodable, Equatable {
    var mode: String
    var modeList: [String]?

    enum CodingKeys: String, CodingKey {
        case mode
        case modeList = "mode-list"
        case modes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(String.self, forKey: .mode)) ?? "rule"
        modeList = (try? c.decode([String].self, forKey: .modeList)) ?? (try? c.decode([String].self, forKey: .modes))
    }
}

struct MihomoVersionInfo: Decodable, Equatable {
    var version: String
    var meta: Bool?
}

struct MihomoDelayResponse: Decodable {
    var delay: Int
}

/// Smart 组权重：`/group/weights`。
struct MihomoNodeRank: Decodable, Equatable {
    var name: String
    var rank: String

    enum CodingKeys: String, CodingKey { case name = "Name", rank = "Rank" }
}

struct MihomoSmartWeightsResponse: Decodable {
    var weights: [String: [MihomoNodeRank]?]
}

// MARK: - 连接（WebSocket 推送）

struct MihomoConnection: Decodable, Equatable, Identifiable {
    var id: String
    var chains: [String]
    var upload: Int64
    var download: Int64
    var rule: String?
    var rulePayload: String?
    var start: String?

    init(from decoder: Decoder) throws {
        enum K: String, CodingKey { case id, chains, upload, download, rule, rulePayload, start }
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        chains = (try? c.decode([String].self, forKey: .chains)) ?? []
        upload = (try? c.decode(Int64.self, forKey: .upload)) ?? 0
        download = (try? c.decode(Int64.self, forKey: .download)) ?? 0
        rule = try? c.decode(String.self, forKey: .rule)
        rulePayload = try? c.decode(String.self, forKey: .rulePayload)
        start = try? c.decode(String.self, forKey: .start)
    }
}

struct MihomoConnectionsSnapshot: Decodable {
    var downloadTotal: Int64
    var uploadTotal: Int64
    var connections: [MihomoConnection]?
    var memory: Int64?
}

struct MihomoTraffic: Decodable, Equatable {
    var up: Int64
    var down: Int64
}

struct MihomoMemory: Decodable, Equatable {
    var inuse: Int64
}
