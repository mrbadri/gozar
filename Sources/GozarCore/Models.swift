public enum Route: String, Codable, Sendable, Equatable {
    case vpn, direct, cisco
}

public struct Rule: Codable, Sendable, Equatable {
    public let name: String
    public let route: Route
    public let withoutCisco: Route?
    public let enabled: Bool
    public let note: String?
    public let domains: [String]
    public let hosts: [String]

    public init(
        name: String, route: Route, withoutCisco: Route? = nil, enabled: Bool = true,
        note: String? = nil, domains: [String] = [], hosts: [String] = []
    ) {
        self.name = name
        self.route = route
        self.withoutCisco = withoutCisco
        self.enabled = enabled
        self.note = note
        self.domains = domains
        self.hosts = hosts
    }

    enum CodingKeys: String, CodingKey {
        case name, route, enabled, note, domains, hosts
        case withoutCisco = "without_cisco"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try values.decode(String.self, forKey: .name),
            route: try values.decode(Route.self, forKey: .route),
            withoutCisco: try values.decodeIfPresent(Route.self, forKey: .withoutCisco),
            enabled: try values.contains(.enabled) ? values.decode(Bool.self, forKey: .enabled) : true,
            note: try values.decodeIfPresent(String.self, forKey: .note),
            domains: try values.contains(.domains) ? values.decode([String].self, forKey: .domains) : [],
            hosts: try values.contains(.hosts) ? values.decode([String].self, forKey: .hosts) : []
        )
    }
}

public struct RoutesFile: Codable, Sendable, Equatable {
    public let rules: [Rule]

    public init(rules: [Rule]) {
        self.rules = rules
    }
}

public struct RouterSettings: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let upstreamPort: Int
    public let controlPort: Int

    public init(enabled: Bool = false, upstreamPort: Int = 1081, controlPort: Int = 1090) {
        self.enabled = enabled
        self.upstreamPort = upstreamPort
        self.controlPort = controlPort
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case upstreamPort = "upstream_port"
        case controlPort = "control_port"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try values.contains(.enabled) ? values.decode(Bool.self, forKey: .enabled) : false,
            upstreamPort: try values.contains(.upstreamPort) ? values.decode(Int.self, forKey: .upstreamPort) : 1081,
            controlPort: try values.contains(.controlPort) ? values.decode(Int.self, forKey: .controlPort) : 1090
        )
    }
}

public struct ConnectionFile: Codable, Sendable, Equatable {
    public let relayHost: String
    public let relayPort: Int
    public let relayUser: String
    public let localSocksPort: Int
    public let router: RouterSettings

    public init(
        relayHost: String, relayPort: Int, relayUser: String,
        localSocksPort: Int = 1080, router: RouterSettings = .init()
    ) {
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.relayUser = relayUser
        self.localSocksPort = localSocksPort
        self.router = router
    }

    private struct Relay: Codable {
        let host: String
        let port: Int
        let user: String
    }

    enum CodingKeys: String, CodingKey {
        case relay, router
        case localSocksPort = "local_socks_port"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let relay = try values.decode(Relay.self, forKey: .relay)
        self.init(
            relayHost: relay.host, relayPort: relay.port, relayUser: relay.user,
            localSocksPort: try values.contains(.localSocksPort) ? values.decode(Int.self, forKey: .localSocksPort) : 1080,
            router: try values.contains(.router) ? values.decode(RouterSettings.self, forKey: .router) : .init()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Relay(host: relayHost, port: relayPort, user: relayUser), forKey: .relay)
        try values.encode(localSocksPort, forKey: .localSocksPort)
        try values.encode(router, forKey: .router)
    }
}

public struct RouteDecision: Codable, Sendable, Equatable {
    public let route: Route
    public let rule: String?
    public let pattern: String?

    public init(route: Route, rule: String? = nil, pattern: String? = nil) {
        self.route = route
        self.rule = rule
        self.pattern = pattern
    }

    enum CodingKeys: String, CodingKey { case route, rule, pattern }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(route, forKey: .route)
        try values.encode(rule, forKey: .rule)
        try values.encode(pattern, forKey: .pattern)
    }
}
