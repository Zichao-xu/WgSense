import Foundation

// 测速台的数据模型（规格见 docs/speedtest-spec.md）。
//
// 一次测量 = 执行端 A + 路径 B + 目标 C。执行端在哪台机器上跑 speedlab.sh，
// 目标是公网（HTTP 多源测速）或名册里另一个端点（iperf3）。

// MARK: - 端点

enum SLEndpointKind: String, Codable {
    /// 这台 Mac。
    case local
    /// 能 SSH 上去的机器：可当执行端，也可临时起 iperf3 服务端当目标。
    case ssh
    /// 只知道地址的 WG peer：只能当目标，要求它自己开着 iperf3 服务端。
    case peer
    /// 公网测速源。
    case publicNet
}

struct SLEndpoint: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var kind: SLEndpointKind
    var host: String = ""
    var sshPort: Int = 22
    var sshUser: String = "root"
    /// 来源注记：本机 / 代理后端 / WG peer / 手动添加。
    var origin: String = ""

    var canRun: Bool { kind == .local || kind == .ssh }
    var isPublic: Bool { kind == .publicNet }

    static let local = SLEndpoint(id: "local", name: "本机", kind: .local, origin: "本机")
    static let publicNet = SLEndpoint(id: "public", name: "公网", kind: .publicNet, origin: "国内测速源")

    static func ssh(name: String, host: String, port: Int, user: String, origin: String) -> SLEndpoint {
        SLEndpoint(id: "ssh:\(user)@\(host):\(port)", name: name, kind: .ssh, host: host, sshPort: port, sshUser: user, origin: origin)
    }

    static func peer(name: String, ip: String) -> SLEndpoint {
        SLEndpoint(id: "peer:\(ip)", name: name, kind: .peer, host: ip, origin: "WG peer")
    }

    /// 台账里的地址注记。
    var address: String {
        switch kind {
        case .local: return "localhost"
        case .ssh: return "\(sshUser)@\(host):\(sshPort)"
        case .peer: return host
        case .publicNet: return "auto"
        }
    }
}

// MARK: - 路径与参数

enum SLPathMode: String, Codable, CaseIterable, Identifiable {
    /// 绑物理网卡 + 真 DNS：绕开隧道、代理与 fake-ip，测的是宽带本身。
    case direct
    /// 系统默认路由与 DNS：测的是这台机器上网的实际体验（可能经隧道/代理）。
    case system
    var id: String { rawValue }
    var title: String { self == .direct ? "宽带直连" : "系统默认" }
}

enum SLDirections: String, Codable, CaseIterable, Identifiable {
    case both, down, up
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return "双向"
        case .down: return "仅下行"
        case .up: return "仅上行"
        }
    }
    var script: String {
        switch self {
        case .both: return "dl ul"
        case .down: return "dl"
        case .up: return "ul"
        }
    }
}

enum SLUnit: String, Codable, CaseIterable, Identifiable {
    case mbps, mBps
    var id: String { rawValue }
    var title: String { self == .mbps ? "Mbps" : "MB/s" }
    func value(_ mbps: Double) -> Double { self == .mbps ? mbps : mbps / 8 }
}

struct SLParams: Codable, Equatable {
    /// 每个方向的秒数。
    var duration: Int = 10
    var directions: SLDirections = .both
    var httpDownThreads: Int = 12
    var httpUpThreads: Int = 4
    var iperfStreams: Int = 4
    var iperfPort: Int = 5201
    var unit: SLUnit = .mbps
}

// MARK: - 测量过程

enum SLPhase: String, Codable {
    case prepare, idle, pick, dl, ul, done
    var title: String {
        switch self {
        case .prepare: return "准备"
        case .idle: return "空载延迟"
        case .pick: return "选源"
        case .dl: return "下行"
        case .ul: return "上行"
        case .done: return "完成"
        }
    }
}

/// 执行端脚本的一行事件（`@{"ev":…}`）。
struct SLEvent: Decodable {
    var ev: String
    var k: String?
    var v: String?
    var ph: String?
    var rx: Double?
    var tx: Double?
    var rtt: Double?
    var msg: String?
    var name: String?
    var ip: String?
    /// src：该候选源是否入选；conn：第几条连接。
    var keep: Bool?
    var n: Int?

    static func parse(_ line: Substring) -> SLEvent? {
        guard line.first == "@" else { return nil }
        return try? JSONDecoder().decode(SLEvent.self, from: Data(line.dropFirst().utf8))
    }
}

/// 一个方向的统计：稳定值取预热 2 秒后的中位数；
/// 最后 4 秒里九成采样贴着中位数（±5%）= 平顶：被运营商限速，或到了网口上限。
struct SLStat: Codable, Equatable {
    var stable: Double
    var peak: Double
    var flat: Bool
    var loadedRTT: Double?

    /// - tick: 采样间隔（秒）。
    static func from(_ series: [Double], rtts: [Double], tick: Double) -> SLStat? {
        guard !series.isEmpty else { return nil }
        let perSecond = max(1, Int((1 / max(tick, 0.05)).rounded()))
        let warmup = 2 * perSecond
        let body = series.count > warmup + 2 * perSecond ? Array(series.dropFirst(warmup)) : series
        let median = Self.median(body)
        let tail = body.suffix(4 * perSecond)
        let close = tail.filter { median > 0 && abs($0 - median) / median < 0.05 }.count
        let flat = tail.count >= 3 * perSecond && median > 1 && Double(close) >= Double(tail.count) * 0.9
        // 峰值也取 1 秒滑动平均，不让单个采样的毛刺当峰值
        var peak = 0.0
        if series.count >= perSecond {
            for i in 0...(series.count - perSecond) {
                peak = max(peak, series[i..<(i + perSecond)].reduce(0, +) / Double(perSecond))
            }
        } else {
            peak = series.max() ?? 0
        }
        return SLStat(stable: median, peak: peak, flat: flat,
                      loadedRTT: rtts.isEmpty ? nil : Self.median(rtts))
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

// MARK: - 动效时间线（HUD 只读这些带时刻的事件）

/// 候选源的试跑结果。
struct SLSourceResult: Identifiable, Equatable {
    var id: String { dir + url }
    var dir: String
    var url: String
    var mbps: Double
    var keep: Bool
    var at: Date
    var host: String { URL(string: url)?.host ?? url }
    /// 短名：去掉通用后缀后的最后一段。baidupcs.com → baidupcs，dldir1.qq.com → qq，test.ustc.edu.cn → ustc。
    var shortName: String {
        let generic: Set<String> = ["com", "cn", "net", "org", "edu", "gov", "ac", "io", "co"]
        let parts = host.split(separator: ".").map(String.init)
        return parts.dropLast().last(where: { !generic.contains($0) }) ?? host
    }
}

/// 一次连接中途断开后重连。
struct SLConnEvent: Equatable {
    var dir: String
    var n: Int
    var at: Date
}

/// 带到达时刻的采样。
struct SLTimedSample: Equatable {
    var v: Double
    var rtt: Double?
    var at: Date
}

// MARK: - 结果与历史

struct SLResult: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var runner: String
    var target: String
    var path: String
    var engine: String
    var down: SLStat?
    var up: SLStat?
    var idleRTT: Double?
    /// 物理口协商速率（Mbps），读不到为空。
    var linkMbps: Int?
    var linkText: String = ""
    var exit: String = ""
    var sources: [String] = []
    var downSeries: [Double] = []
    var upSeries: [Double] = []
    /// 采样间隔（秒）；旧记录没有这个字段，按 1 秒算。
    var tick: Double?
    var error: String?

    /// 场景键：同一组 A/B/C 的历史互相比较。
    var sceneKey: String { "\(runner)|\(path)|\(target)" }
}

// MARK: - 场景

struct SLScene: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var runnerID: String
    var targetID: String
    var path: SLPathMode
    var builtIn = false
}
