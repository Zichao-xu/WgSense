import Foundation

// 多后端：与原版一致，可保存多个 Clash/Mihomo 控制器并切换。
// 连接信息存 UserDefaults；密钥存 Application Support 下仅本人可读（0600）的文件。
//
// 不用钥匙串：App 是临时签名，每次编译/升级签名都会变，钥匙串会因此每次弹框要登录密码，
// 而且弹框会卡住启动。0600 文件与原有 proxy.json 的安全等级一致。

struct MihomoBackend: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var label: String = ""
    var scheme: String = "http"
    var host: String
    var port: Int
    /// 二级路径（原版 secondaryPath）：以 / 开头，没有则为空。
    var secondaryPath: String = ""

    var displayName: String {
        label.isEmpty ? "\(host):\(port)" : label
    }

    var baseURL: URL? {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.port = port
        comps.path = secondaryPath
        return comps.url
    }

    /// WebSocket 使用 ws/wss。
    var webSocketBase: URL? {
        var comps = URLComponents()
        comps.scheme = scheme == "https" ? "wss" : "ws"
        comps.host = host
        comps.port = port
        comps.path = secondaryPath
        return comps.url
    }
}

@MainActor
final class MihomoBackendStore: ObservableObject {
    static let shared = MihomoBackendStore()

    @Published private(set) var backends: [MihomoBackend] = []
    @Published var activeID: UUID? {
        didSet { UserDefaults.standard.set(activeID?.uuidString, forKey: Self.activeKey) }
    }

    var active: MihomoBackend? {
        backends.first { $0.id == activeID } ?? backends.first
    }

    private static let listKey = "proxyPanel.backends"
    private static let activeKey = "proxyPanel.activeBackend"

    private init() {
        load()
        if backends.isEmpty { importLegacyProxySettings() }
    }

    // MARK: 增删改

    func save(_ backend: MihomoBackend, secret: String?) {
        if let index = backends.firstIndex(where: { $0.id == backend.id }) {
            backends[index] = backend
        } else {
            backends.append(backend)
        }
        if let secret { MihomoKeychain.setSecret(secret, for: backend.id) }
        if activeID == nil { activeID = backend.id }
        persist()
    }

    func remove(_ backend: MihomoBackend) {
        backends.removeAll { $0.id == backend.id }
        MihomoKeychain.deleteSecret(for: backend.id)
        if activeID == backend.id { activeID = backends.first?.id }
        persist()
    }

    func secret(for backend: MihomoBackend) -> String {
        if let stored = MihomoKeychain.secret(for: backend.id) { return stored }
        // 兜底：地址与 WgSense 原有代理设置一致时沿用其密钥，并补存。
        if let legacy = Self.legacySettings(), legacy.host == backend.host, legacy.port == backend.port,
           let secret = legacy.secret, !secret.isEmpty {
            MihomoKeychain.setSecret(secret, for: backend.id)
            return secret
        }
        return ""
    }

    private static func legacySettings() -> (host: String, port: Int, secret: String?)? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/wgsense/proxy.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = json["address"] as? String,
              let comps = URLComponents(string: address), let host = comps.host else { return nil }
        let scheme = comps.scheme ?? "http"
        return (host, comps.port ?? (scheme == "https" ? 443 : 80), json["secret"] as? String)
    }

    // MARK: 持久化

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.listKey),
           let list = try? JSONDecoder().decode([MihomoBackend].self, from: data) {
            backends = list
        }
        if let raw = UserDefaults.standard.string(forKey: Self.activeKey) {
            activeID = UUID(uuidString: raw)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(backends) {
            UserDefaults.standard.set(data, forKey: Self.listKey)
        }
    }

    /// 首次运行：从 WgSense 原有代理设置（~/.local/share/wgsense/proxy.json）导入第一个后端。
    private func importLegacyProxySettings() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/wgsense/proxy.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = json["address"] as? String,
              let comps = URLComponents(string: address),
              let host = comps.host else { return }
        let scheme = comps.scheme ?? "http"
        let backend = MihomoBackend(
            label: "OpenClash",
            scheme: scheme,
            host: host,
            port: comps.port ?? (scheme == "https" ? 443 : 80),
            secondaryPath: comps.path == "/" ? "" : comps.path
        )
        save(backend, secret: json["secret"] as? String)
        activeID = backend.id
    }
}

enum MihomoKeychain {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WgSense", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("mihomo-backend-secrets.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private static func store(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        let url = fileURL
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func secret(for id: UUID) -> String? { load()[id.uuidString] }

    static func setSecret(_ secret: String, for id: UUID) {
        var dict = load()
        dict[id.uuidString] = secret.isEmpty ? nil : secret
        store(dict)
    }

    static func deleteSecret(for id: UUID) {
        var dict = load()
        dict.removeValue(forKey: id.uuidString)
        store(dict)
    }
}
