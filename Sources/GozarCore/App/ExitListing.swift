import Foundation

public struct ExitListing: Decodable, Equatable, Sendable {
    public enum Kind: String, Decodable, Sendable { case ssh, xray }

    public enum Transport: String, Decodable, Sendable {
        case ssh, vless, vmess, trojan, ss

        public var label: String {
            switch self {
            case .ssh: "SSH"
            case .vless: "VLESS"
            case .vmess: "VMess"
            case .trojan: "Trojan"
            case .ss: "SS"
            }
        }
    }

    public struct Exit: Decodable, Equatable, Identifiable, Sendable {
        public let id: String
        public var name: String
        public let kind: Kind
        public let transport: Transport
        public let address: String
        public let port: Int
        public let subscription: String?
        public var stale: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, kind, address, port, subscription, stale
            case transport = "protocol"
        }

        public init(id: String, name: String, kind: Kind, transport: Transport, address: String, port: Int,
                    subscription: String? = nil, stale: Bool = false) {
            self.id = id
            self.name = name
            self.kind = kind
            self.transport = transport
            self.address = address
            self.port = port
            self.subscription = subscription
            self.stale = stale
        }

        public var endpoint: String { address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)" }
    }

    public struct Subscription: Decodable, Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let host: String
        public var count: Int
        public var updatedAt: String?
        public var error: String?

        enum CodingKeys: String, CodingKey {
            case id, name, host, count, error
            case updatedAt = "updated_at"
        }

        public init(id: String, name: String, host: String, count: Int, updatedAt: String?, error: String?) {
            self.id = id
            self.name = name
            self.host = host
            self.count = count
            self.updatedAt = updatedAt
            self.error = error
        }
    }

    public var active: String?
    public var exits: [Exit]
    public var subscriptions: [Subscription]

    public init(active: String? = nil, exits: [Exit] = [], subscriptions: [Subscription] = []) {
        self.active = active
        self.exits = exits
        self.subscriptions = subscriptions
    }

    public var activeExit: Exit? { exits.first { $0.id == active } }
}

public struct ExitTestResult: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let ok: Bool
    public let connectMs: Double?
    public let mbps: Double?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case id, ok, mbps, error
        case connectMs = "connect_ms"
    }

    public init(id: String, ok: Bool, connectMs: Double?, mbps: Double?, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.connectMs = connectMs
        self.mbps = mbps
        self.error = error
    }

    public static func best(in results: [Self]) -> String? {
        results.filter(\.ok).max { first, second in
            let lhsSpeed = first.mbps ?? 0
            let rhsSpeed = second.mbps ?? 0
            if lhsSpeed != rhsSpeed { return lhsSpeed < rhsSpeed }
            return (first.connectMs ?? .infinity) > (second.connectMs ?? .infinity)
        }?.id
    }
}
