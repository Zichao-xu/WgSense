import Foundation
import NetworkExtension
import os
import Security

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "com.wgsense.macos.PacketTunnel", category: "PacketTunnel")
    private lazy var adapter: WireGuardAdapter = {
        WireGuardAdapter(with: self) { [logger] level, message in
            switch level {
            case .verbose:
                logger.info("\(message, privacy: .public)")
            case .error:
                logger.error("\(message, privacy: .public)")
            }
        }
    }()

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let providerProtocol = protocolConfiguration as? NETunnelProviderProtocol,
              let configuration = Self.loadConfiguration(from: providerProtocol) else {
            completionHandler(PacketTunnelProviderError.invalidConfiguration)
            return
        }

        logger.info("Starting WgSense system VPN profile")

        do {
            let profileName = providerProtocol.providerConfiguration?["profileName"] as? String
            let tunnelConfiguration = try WireGuardQuickConfigParser(
                configuration: configuration,
                profileName: profileName
            ).parse()
            adapter.start(tunnelConfiguration: tunnelConfiguration) { [logger] error in
                if let error {
                    logger.error("WireGuard backend failed: \(String(describing: error), privacy: .public)")
                    completionHandler(PacketTunnelProviderError.backendStartFailed)
                    return
                }
                logger.info("WgSense system VPN tunnel is running")
                completionHandler(nil)
            }
        } catch {
            logger.error("Invalid WireGuard configuration: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("Stopping WgSense system VPN profile")
        adapter.stop { [logger] error in
            if let error {
                logger.error("WireGuard backend stop reported: \(String(describing: error), privacy: .public)")
            }
            completionHandler()
        }
    }

    private static func loadConfiguration(from providerProtocol: NETunnelProviderProtocol) -> String? {
        if let reference = providerProtocol.passwordReference {
            var result: CFTypeRef?
            let status = SecItemCopyMatching([
                kSecValuePersistentRef: reference,
                kSecReturnData: true
            ] as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return providerProtocol.providerConfiguration?["wgQuickConfig"] as? String
    }
}

enum PacketTunnelProviderError: LocalizedError {
    case invalidConfiguration
    case backendStartFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "WgSense VPN 配置无效"
        case .backendStartFailed:
            return "WgSense 系统 VPN 后端启动失败"
        }
    }
}

private struct WireGuardQuickConfigParser {
    let configuration: String
    let profileName: String?

    func parse() throws -> TunnelConfiguration {
        let sections = parseSections()
        guard sections.interfaces.count == 1 else { throw ParseError.invalidInterface }
        var interface = try makeInterface(from: sections.interfaces[0])
        let peers = try sections.peers.map(makePeer)
        if peers.isEmpty { throw ParseError.peerMissingPublicKey }
        return TunnelConfiguration(name: profileName, interface: interface, peers: peers)
    }

    private func makeInterface(from fields: [String: [String]]) throws -> InterfaceConfiguration {
        guard let key = singleValue("privatekey", in: fields),
              let privateKey = PrivateKey(base64Key: key) else {
            throw ParseError.interfaceMissingPrivateKey
        }
        var interface = InterfaceConfiguration(privateKey: privateKey)
        interface.addresses = splitList(values("address", in: fields)).compactMap(IPAddressRange.init(from:))
        if interface.addresses.isEmpty { throw ParseError.invalidAddress }
        interface.dns = splitList(values("dns", in: fields)).compactMap(DNSServer.init(from:))
        interface.dnsSearch = splitList(values("dns", in: fields)).filter { DNSServer(from: $0) == nil }
        if let mtu = singleValue("mtu", in: fields) {
            guard let parsed = UInt16(mtu) else { throw ParseError.invalidMTU }
            interface.mtu = parsed
        }
        if let listenPort = singleValue("listenport", in: fields) {
            guard let parsed = UInt16(listenPort) else { throw ParseError.invalidListenPort }
            interface.listenPort = parsed
        }
        return interface
    }

    private func makePeer(from fields: [String: [String]]) throws -> PeerConfiguration {
        guard let key = singleValue("publickey", in: fields),
              let publicKey = PublicKey(base64Key: key) else {
            throw ParseError.peerMissingPublicKey
        }
        var peer = PeerConfiguration(publicKey: publicKey)
        if let psk = singleValue("presharedkey", in: fields) {
            guard let parsed = PreSharedKey(base64Key: psk) else { throw ParseError.invalidPreSharedKey }
            peer.preSharedKey = parsed
        }
        peer.allowedIPs = splitList(values("allowedips", in: fields)).compactMap(IPAddressRange.init(from:))
        if peer.allowedIPs.isEmpty { throw ParseError.invalidAllowedIP }
        if let endpoint = singleValue("endpoint", in: fields) {
            guard let parsed = Endpoint(from: endpoint) else { throw ParseError.invalidEndpoint }
            peer.endpoint = parsed
        }
        if let keepalive = singleValue("persistentkeepalive", in: fields) {
            guard let parsed = UInt16(keepalive) else { throw ParseError.invalidPersistentKeepalive }
            peer.persistentKeepAlive = parsed
        }
        return peer
    }

    private func parseSections() -> (interfaces: [[String: [String]]], peers: [[String: [String]]]) {
        var currentName = ""
        var currentFields: [String: [String]] = [:]
        var interfaces: [[String: [String]]] = []
        var peers: [[String: [String]]] = []

        func flush() {
            switch currentName {
            case "interface":
                interfaces.append(currentFields)
            case "peer":
                peers.append(currentFields)
            default:
                break
            }
            currentFields = [:]
        }

        for rawLine in configuration.components(separatedBy: .newlines) {
            let line = clean(rawLine)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                flush()
                currentName = String(line.dropFirst().dropLast()).lowercased()
                continue
            }
            guard let (key, value) = keyValue(line) else { continue }
            currentFields[key.lowercased(), default: []].append(value)
        }
        flush()
        return (interfaces, peers)
    }

    private func clean(_ line: String) -> String {
        line.split(separator: "#", maxSplits: 1).first?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func keyValue(_ line: String) -> (String, String)? {
        let parts = line.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    private func singleValue(_ key: String, in fields: [String: [String]]) -> String? {
        fields[key]?.last
    }

    private func values(_ key: String, in fields: [String: [String]]) -> [String] {
        fields[key] ?? []
    }

    private func splitList(_ values: [String]) -> [String] {
        values.flatMap { value in
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }.filter { !$0.isEmpty }
    }

    enum ParseError: LocalizedError {
        case invalidInterface
        case interfaceMissingPrivateKey
        case invalidAddress
        case invalidListenPort
        case invalidMTU
        case peerMissingPublicKey
        case invalidPreSharedKey
        case invalidAllowedIP
        case invalidEndpoint
        case invalidPersistentKeepalive

        var errorDescription: String? {
            switch self {
            case .invalidInterface:
                return "WireGuard 配置必须包含一个 Interface"
            case .interfaceMissingPrivateKey:
                return "Interface 缺少有效 PrivateKey"
            case .invalidAddress:
                return "Interface 缺少有效 Address"
            case .invalidListenPort:
                return "ListenPort 无效"
            case .invalidMTU:
                return "MTU 无效"
            case .peerMissingPublicKey:
                return "Peer 缺少有效 PublicKey"
            case .invalidPreSharedKey:
                return "PreSharedKey 无效"
            case .invalidAllowedIP:
                return "Peer 缺少有效 AllowedIPs"
            case .invalidEndpoint:
                return "Endpoint 无效"
            case .invalidPersistentKeepalive:
                return "PersistentKeepalive 无效"
            }
        }
    }
}
