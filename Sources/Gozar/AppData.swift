import Foundation
import GozarCore
import Security

struct VPNStatus: Decodable {
    struct Router: Decodable {
        var enabled: Bool
        var running: Bool
        var controlPort: Int?

        enum CodingKeys: String, CodingKey {
            case enabled, running
            case controlPort = "control_port"
        }
    }

    var loop = false
    var socks = false
    var exitIP: String?
    var proxy = false
    var cisco = false
    var ciscoCopy: Bool?
    var router = Router(enabled: false, running: false)
    var via: String?
    var stopped: String?
    var notes: [String] = []

    enum CodingKeys: String, CodingKey {
        case loop, socks, proxy, cisco, router, via, stopped, notes
        case exitIP = "exit_ip"
        case ciscoCopy = "cisco_copy"
    }
}

struct RulesListing: Decodable {
    let rules: [Rule]
}

struct CLICheck: Decodable {
    let host: String
    let route: Route
    let rule: String?
    let pattern: String?

    var decision: RouteDecision { .init(route: route, rule: rule, pattern: pattern) }
}

struct DomainDiscovery: Decodable {
    struct Entry: Decodable {
        let host: String
        let route: Route

        enum CodingKeys: String, CodingKey { case host, domain, route }

        init(host: String, route: Route) {
            self.host = host
            self.route = route
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            host = try fields.decodeIfPresent(String.self, forKey: .host) ?? fields.decode(String.self, forKey: .domain)
            route = try fields.decode(Route.self, forKey: .route)
        }
    }

    struct Listed: Decodable {
        let name: String
        let domains: [Entry]
    }

    let site: String
    let title: String?
    let via: Route
    let listed: Listed?
    let live: [Entry]?
    let suggested: [String]
}

struct ConnectionDraft: Equatable {
    var relayHost = ""
    var relayUser = ""
    var relayPort = "47853"
    var localPort = "1080"
    var keepaliveInterval = "5"
    var keepaliveMissed = "3"
    var routerEnabled = false
    var upstreamPort = "1081"
    var controlPort = "1090"

    init() {}

    init(_ data: Data) throws {
        let raw = try Self.dictionary(data)
        let relay = raw["relay"] as? [String: Any] ?? [:]
        let keepalive = raw["keepalive"] as? [String: Any] ?? [:]
        let router = raw["router"] as? [String: Any] ?? [:]
        relayHost = relay["host"] as? String ?? ""
        relayPort = String(relay["port"] as? Int ?? 47853)
        relayUser = relay["user"] as? String ?? ""
        localPort = String(raw["local_socks_port"] as? Int ?? 1080)
        keepaliveInterval = String(keepalive["interval_seconds"] as? Int ?? 5)
        keepaliveMissed = String(keepalive["max_missed"] as? Int ?? 3)
        routerEnabled = router["enabled"] as? Bool ?? false
        upstreamPort = String(router["upstream_port"] as? Int ?? 1081)
        controlPort = String(router["control_port"] as? Int ?? 1090)
    }

    func applying(to data: Data) throws -> Data {
        guard let localPort = Int(localPort), let interval = Int(keepaliveInterval), interval >= 0,
              let missed = Int(keepaliveMissed), missed >= 0,
              let upstream = Int(upstreamPort), let control = Int(controlPort) else {
            throw AppError(L.invalidNumber)
        }
        var raw = try Self.dictionary(data)
        raw["local_socks_port"] = localPort
        var keepalive = raw["keepalive"] as? [String: Any] ?? [:]
        keepalive["interval_seconds"] = interval
        keepalive["max_missed"] = missed
        raw["keepalive"] = keepalive
        var router = raw["router"] as? [String: Any] ?? [:]
        router["enabled"] = routerEnabled
        router["upstream_port"] = upstream
        router["control_port"] = control
        raw["router"] = router
        return try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) + Data([10])
    }

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError(L.noConnectionConfig)
        }
        return raw
    }
}

enum Keychain {
    static let grafanaService = "gozar-grafana"
    static let grafanaAccount = "token"
    static let relayService = "vpnuser-relay"
    static let sshService = "gozar-ssh"

    static func get(service: String, account: String) throws -> String? {
        var query = base(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        try check(code)
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func set(_ secret: String, service: String, account: String) throws {
        let query = base(service, account)
        let value = [kSecValueData as String: Data(secret.utf8)]
        let code = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if code == errSecItemNotFound {
            try check(SecItemAdd(query.merging(value) { _, new in new } as CFDictionary, nil))
        } else {
            try check(code)
        }
    }

    private static func base(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func check(_ code: OSStatus) throws {
        guard code == errSecSuccess else {
            throw AppError(SecCopyErrorMessageString(code, nil) as String? ?? "Keychain (\(code))")
        }
    }
}

extension Route {
    static let ordered: [Route] = [.vpn, .direct, .cisco]
}

extension RouterTotals {
    subscript(_ route: Route) -> RouteTotals {
        switch route {
        case .vpn: vpn
        case .direct: direct
        case .cisco: cisco
        }
    }

    var rateDown: Double { vpn.rateDown + direct.rateDown + cisco.rateDown }
    var rateUp: Double { vpn.rateUp + direct.rateUp + cisco.rateUp }
}

