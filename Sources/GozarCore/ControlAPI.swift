import Foundation

public struct ConnStat: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        case connecting, open, closed, failed
    }

    public let id: Int
    public let host: String
    public let port: Int
    public let route: Route
    public let rule: String?
    public let startedAt: Date
    public var connectMs: Double?
    public var endedAt: Date?
    public var state: State
    public var error: String?
    public var bytesUp: UInt64
    public var bytesDown: UInt64
    public var rateUp: Double
    public var rateDown: Double

    public init(
        id: Int, host: String, port: Int, route: Route, rule: String? = nil, startedAt: Date,
        connectMs: Double? = nil, endedAt: Date? = nil, state: State = .connecting, error: String? = nil,
        bytesUp: UInt64 = 0, bytesDown: UInt64 = 0, rateUp: Double = 0, rateDown: Double = 0
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.route = route
        self.rule = rule
        self.startedAt = startedAt
        self.connectMs = connectMs
        self.endedAt = endedAt
        self.state = state
        self.error = error
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.rateUp = rateUp
        self.rateDown = rateDown
    }

    enum CodingKeys: String, CodingKey {
        case id, host, port, route, rule, state, error
        case startedAt = "started_at"
        case connectMs = "connect_ms"
        case endedAt = "ended_at"
        case bytesUp = "bytes_up"
        case bytesDown = "bytes_down"
        case rateUp = "rate_up"
        case rateDown = "rate_down"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(host, forKey: .host)
        try values.encode(port, forKey: .port)
        try values.encode(route, forKey: .route)
        try values.encode(rule, forKey: .rule)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(connectMs, forKey: .connectMs)
        try values.encode(endedAt, forKey: .endedAt)
        try values.encode(state, forKey: .state)
        try values.encode(error, forKey: .error)
        try values.encode(bytesUp, forKey: .bytesUp)
        try values.encode(bytesDown, forKey: .bytesDown)
        try values.encode(rateUp, forKey: .rateUp)
        try values.encode(rateDown, forKey: .rateDown)
    }
}

public struct DomainStat: Codable, Sendable, Equatable, Identifiable {
    public let domain: String
    public let hosts: [String]
    public let route: Route
    public let rule: String?
    public let connections: Int
    public let open: Int
    public let failed: Int
    public let bytesUp: UInt64
    public let bytesDown: UInt64
    public let rateUp: Double
    public let rateDown: Double
    public let connectMsAvg: Double?
    public let connectMsP90: Double?
    public let lastSeen: Date

    public var id: String { domain }

    public init(
        domain: String, hosts: [String], route: Route, rule: String? = nil, connections: Int, open: Int,
        failed: Int, bytesUp: UInt64, bytesDown: UInt64, rateUp: Double, rateDown: Double,
        connectMsAvg: Double? = nil, connectMsP90: Double? = nil, lastSeen: Date
    ) {
        self.domain = domain
        self.hosts = hosts
        self.route = route
        self.rule = rule
        self.connections = connections
        self.open = open
        self.failed = failed
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.rateUp = rateUp
        self.rateDown = rateDown
        self.connectMsAvg = connectMsAvg
        self.connectMsP90 = connectMsP90
        self.lastSeen = lastSeen
    }

    enum CodingKeys: String, CodingKey {
        case domain, hosts, route, rule, connections, open, failed
        case bytesUp = "bytes_up"
        case bytesDown = "bytes_down"
        case rateUp = "rate_up"
        case rateDown = "rate_down"
        case connectMsAvg = "connect_ms_avg"
        case connectMsP90 = "connect_ms_p90"
        case lastSeen = "last_seen"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(domain, forKey: .domain)
        try values.encode(hosts, forKey: .hosts)
        try values.encode(route, forKey: .route)
        try values.encode(rule, forKey: .rule)
        try values.encode(connections, forKey: .connections)
        try values.encode(open, forKey: .open)
        try values.encode(failed, forKey: .failed)
        try values.encode(bytesUp, forKey: .bytesUp)
        try values.encode(bytesDown, forKey: .bytesDown)
        try values.encode(rateUp, forKey: .rateUp)
        try values.encode(rateDown, forKey: .rateDown)
        try values.encode(connectMsAvg, forKey: .connectMsAvg)
        try values.encode(connectMsP90, forKey: .connectMsP90)
        try values.encode(lastSeen, forKey: .lastSeen)
    }
}

public struct RouteTotals: Codable, Sendable, Equatable {
    public var connections: Int
    public var open: Int
    public var failed: Int
    public var bytesUp: UInt64
    public var bytesDown: UInt64
    public var rateUp: Double
    public var rateDown: Double

    public init(
        connections: Int = 0, open: Int = 0, failed: Int = 0, bytesUp: UInt64 = 0, bytesDown: UInt64 = 0,
        rateUp: Double = 0, rateDown: Double = 0
    ) {
        self.connections = connections
        self.open = open
        self.failed = failed
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.rateUp = rateUp
        self.rateDown = rateDown
    }

    enum CodingKeys: String, CodingKey {
        case connections, open, failed
        case bytesUp = "bytes_up"
        case bytesDown = "bytes_down"
        case rateUp = "rate_up"
        case rateDown = "rate_down"
    }
}

public struct RouterTotals: Codable, Sendable, Equatable {
    public var vpn: RouteTotals
    public var direct: RouteTotals
    public var cisco: RouteTotals

    public init(vpn: RouteTotals = .init(), direct: RouteTotals = .init(), cisco: RouteTotals = .init()) {
        self.vpn = vpn
        self.direct = direct
        self.cisco = cisco
    }
}

public struct ProbeStat: Codable, Sendable, Equatable {
    public let name: String
    public let target: String
    public let lastMs: Double?
    public let medianMs: Double?
    public let loss: Double
    public let samples: Int
    public let lastError: String?

    public init(
        name: String, target: String, lastMs: Double? = nil, medianMs: Double? = nil, loss: Double,
        samples: Int, lastError: String? = nil
    ) {
        self.name = name
        self.target = target
        self.lastMs = lastMs
        self.medianMs = medianMs
        self.loss = loss
        self.samples = samples
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case name, target, loss, samples
        case lastMs = "last_ms"
        case medianMs = "median_ms"
        case lastError = "last_error"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(target, forKey: .target)
        try values.encode(lastMs, forKey: .lastMs)
        try values.encode(medianMs, forKey: .medianMs)
        try values.encode(loss, forKey: .loss)
        try values.encode(samples, forKey: .samples)
        try values.encode(lastError, forKey: .lastError)
    }
}

public struct RouterStatus: Codable, Sendable, Equatable {
    public let version: String
    public let startedAt: Date
    public let listenPort: Int
    public let upstreamPort: Int
    public let upstreamUp: Bool
    public let ciscoUp: Bool
    public let rulesLoadedAt: Date?
    public let rulesError: String?
    public let open: Int
    public let total: Int
    public let totals: RouterTotals
    public let probes: [ProbeStat]

    public init(
        version: String, startedAt: Date, listenPort: Int, upstreamPort: Int, upstreamUp: Bool,
        ciscoUp: Bool, rulesLoadedAt: Date? = nil, rulesError: String? = nil, open: Int, total: Int,
        totals: RouterTotals, probes: [ProbeStat]
    ) {
        self.version = version
        self.startedAt = startedAt
        self.listenPort = listenPort
        self.upstreamPort = upstreamPort
        self.upstreamUp = upstreamUp
        self.ciscoUp = ciscoUp
        self.rulesLoadedAt = rulesLoadedAt
        self.rulesError = rulesError
        self.open = open
        self.total = total
        self.totals = totals
        self.probes = probes
    }

    enum CodingKeys: String, CodingKey {
        case version, open, total, totals, probes
        case startedAt = "started_at"
        case listenPort = "listen_port"
        case upstreamPort = "upstream_port"
        case upstreamUp = "upstream_up"
        case ciscoUp = "cisco_up"
        case rulesLoadedAt = "rules_loaded_at"
        case rulesError = "rules_error"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(listenPort, forKey: .listenPort)
        try values.encode(upstreamPort, forKey: .upstreamPort)
        try values.encode(upstreamUp, forKey: .upstreamUp)
        try values.encode(ciscoUp, forKey: .ciscoUp)
        try values.encode(rulesLoadedAt, forKey: .rulesLoadedAt)
        try values.encode(rulesError, forKey: .rulesError)
        try values.encode(open, forKey: .open)
        try values.encode(total, forKey: .total)
        try values.encode(totals, forKey: .totals)
        try values.encode(probes, forKey: .probes)
    }
}

public struct OpenUpdate: Codable, Sendable, Equatable {
    public let id: Int
    public let bytesUp: UInt64
    public let bytesDown: UInt64
    public let rateUp: Double
    public let rateDown: Double

    public init(id: Int, bytesUp: UInt64, bytesDown: UInt64, rateUp: Double, rateDown: Double) {
        self.id = id
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.rateUp = rateUp
        self.rateDown = rateDown
    }

    enum CodingKeys: String, CodingKey {
        case id
        case bytesUp = "bytes_up"
        case bytesDown = "bytes_down"
        case rateUp = "rate_up"
        case rateDown = "rate_down"
    }
}

public struct Tick: Codable, Sendable, Equatable {
    public let at: Date
    public let totals: RouterTotals
    public let openUpdates: [OpenUpdate]

    public init(at: Date, totals: RouterTotals, openUpdates: [OpenUpdate]) {
        self.at = at
        self.totals = totals
        self.openUpdates = openUpdates
    }

    enum CodingKeys: String, CodingKey {
        case at, totals
        case openUpdates = "open_updates"
    }
}

public struct RouterInfo: Codable, Sendable, Equatable {
    public let controlPort: Int
    public let pid: Int
    public let startedAt: Date

    public init(controlPort: Int, pid: Int, startedAt: Date) {
        self.controlPort = controlPort
        self.pid = pid
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case pid
        case controlPort = "control_port"
        case startedAt = "started_at"
    }
}

public struct RouteCheck: Codable, Sendable, Equatable {
    public let route: Route
    public let rule: String?
    public let pattern: String?
    public let ciscoUp: Bool

    public var decision: RouteDecision { RouteDecision(route: route, rule: rule, pattern: pattern) }

    public init(decision: RouteDecision, ciscoUp: Bool) {
        route = decision.route
        rule = decision.rule
        pattern = decision.pattern
        self.ciscoUp = ciscoUp
    }

    enum CodingKeys: String, CodingKey {
        case route, rule, pattern
        case ciscoUp = "cisco_up"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(route, forKey: .route)
        try values.encode(rule, forKey: .rule)
        try values.encode(pattern, forKey: .pattern)
        try values.encode(ciscoUp, forKey: .ciscoUp)
    }
}

public enum RouterEvent: Sendable, Equatable {
    case open(ConnStat)
    case close(ConnStat)
    case tick(Tick)
}

public enum ControlAPI {
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(date.formatted(dateStyle))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            // Discovery metadata can use ISO8601 timestamps without fractions.
            if let date = try? dateStyle.parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected an ISO8601 date")
        }
        return decoder
    }
}
