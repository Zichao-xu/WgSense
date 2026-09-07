import Foundation

struct DaemonStatus: Codable {
    var trusted_network: Bool?
    var at_home: Bool
    var state: String
    var paused: Bool
    var desired_vpn_enabled: Bool?
    var desired_guard_enabled: Bool?
    var service: String
    var passive: Bool?
    var auto_connect_untrusted: Bool?
    var auto_connect_away: Bool?
    var app_owned: Bool?
    var health_failures: Int?
    var auto_failures: Int?
    var next_auto_attempt: String?
    var last_health_check: String?
    var last_auto_up: String?
    var tunnel_interface: String?
    var last_handshake: String?
    var last_handshake_age_seconds: Int?
    var peer_tx_bytes: UInt64?
    var peer_rx_bytes: UInt64?

    var isTrustedNetwork: Bool { trusted_network ?? at_home }
}

struct TrafficStats: Codable {
    var tx_speed: Double
    var rx_speed: Double
    var tx_bytes: UInt64
    var rx_bytes: UInt64
}

struct DaemonLogsResponse: Codable {
    let lines: [String]
    let count: Int
}

struct ProfileExportResponse: Codable {
    let name: String
    let content: String
}

struct WGProfile: Codable {
    var name: String = ""
    var privateKey: String = ""
    var address: String = ""
    var dns: String = ""
    var mtu: Int = 1420
    var publicKey: String = ""
    var presharedKey: String = ""
    var endpoint: String = ""
    var allowedIPs: String = "0.0.0.0/0, ::/0"
    var keepalive: Int = 25

    var wireGuardConfig: String {
        """
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(address)
        DNS = \(dns)
        MTU = \(mtu)

        [Peer]
        PublicKey = \(publicKey)
        PresharedKey = \(presharedKey)
        Endpoint = \(endpoint)
        AllowedIPs = \(allowedIPs)
        PersistentKeepalive = \(keepalive)
        """
    }
}
