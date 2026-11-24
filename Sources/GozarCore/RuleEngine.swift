import Foundation

public struct RuleEngine: Sendable {
    public enum DomainKind: String, Sendable {
        case tree, sub
    }

    private struct Match: Sendable {
        let ruleIndex: Int
        let pattern: String
    }

    private struct HostMatch: Sendable {
        let order: Int
        let match: Match
    }

    private struct Suffix: Sendable {
        var children: [String: Int] = [:]
        var host: HostMatch?
        var domain: Match?
        var apex: Match?
    }

    private let rules: [Rule]
    private var suffixes = [Suffix()]
    private var exactHosts: [String: HostMatch] = [:]
    private var networks: [IPv4Network: HostMatch] = [:]
    private var prefixLengths: [Int] = []

    public init(rules: [Rule]) throws {
        self.rules = rules
        var order = 0
        var lengths = Set<Int>()
        for (index, rule) in rules.enumerated() where rule.enabled {
            for pattern in rule.hosts {
                let host = pattern.lowercased()
                let entry = HostMatch(order: order, match: Match(ruleIndex: index, pattern: pattern))
                order += 1
                exactHosts[host] = exactHosts[host] ?? entry
                if host.hasPrefix("*.") {
                    let suffix = suffixIndex(for: String(host.dropFirst(2)))
                    suffixes[suffix].host = suffixes[suffix].host ?? entry
                } else if let network = IPv4Network(pattern) {
                    networks[network] = networks[network] ?? entry
                    lengths.insert(network.prefixLength)
                }
            }
            for domain in rule.domains {
                let (kind, name) = try Self.parseDomain(domain)
                let suffix = suffixIndex(for: name)
                let entry = Match(ruleIndex: index, pattern: kind == .sub ? "*." + name : name)
                suffixes[suffix].domain = suffixes[suffix].domain ?? entry
                if kind == .tree {
                    suffixes[suffix].apex = suffixes[suffix].apex ?? entry
                }
            }
        }
        prefixLengths = lengths.sorted()
    }

    private static func labels(_ hostname: String) -> [String] {
        hostname.unicodeScalars.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    private mutating func suffixIndex(for name: String) -> Int {
        var index = 0
        for label in Self.labels(name).reversed() {
            if let next = suffixes[index].children[label] {
                index = next
            } else {
                let next = suffixes.count
                suffixes[index].children[label] = next
                suffixes.append(Suffix())
                index = next
            }
        }
        return index
    }

    public static func parseDomain(_ raw: String) throws -> (kind: DomainKind, name: String) {
        var scalars = raw.unicodeScalars[...]
        while let first = scalars.first, isPythonWhitespace(first) { scalars.removeFirst() }
        while let last = scalars.last, isPythonWhitespace(last) { scalars.removeLast() }
        var name = String(scalars).lowercased()
        guard !name.isEmpty else { throw ConfigError("empty domain") }

        let scheme = name.range(of: "://", options: .literal)
        if scheme != nil || name.unicodeScalars.contains(where: { $0 == "/" || $0 == "?" }) {
            if let scheme {
                name = String(name[scheme.upperBound...])
            }
            if let end = name.unicodeScalars.firstIndex(where: { $0 == "/" || $0 == "?" }) {
                name = String(name[..<end])
            }
            if let user = name.unicodeScalars.lastIndex(of: "@") {
                name = String(name.unicodeScalars[name.unicodeScalars.index(after: user)...])
            }
            if let port = name.unicodeScalars.firstIndex(of: ":") {
                name = String(name[..<port])
            }
            if name.hasPrefix("www.") { name = String(name.dropFirst(4)) }
        }

        var kind = DomainKind.tree
        if name.hasPrefix("*.") {
            kind = .sub
            name = String(name.dropFirst(2))
        } else if name.hasPrefix(".") {
            kind = .sub
            name = String(name.dropFirst())
        }
        var domain = name.unicodeScalars[...]
        while domain.last == "." { domain.removeLast() }
        name = String(domain)
        guard name.range(of: domainPattern, options: .regularExpression) != nil else {
            throw ConfigError("bad domain \(String(reflecting: raw))")
        }
        return (domain.contains(".") ? kind : .sub, name)
    }

    private static func isPythonWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1c...0x1f).contains(scalar.value)
    }

    private static let domainPattern = #"\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\n?\z"#

    public func match(_ host: String) -> (rule: Rule, pattern: String)? {
        matchLowercase(host.lowercased(), address: IPv4Network.address(host))
    }

    private func matchLowercase(_ host: String, address: UInt32?) -> (rule: Rule, pattern: String)? {
        var bestHost = exactHosts[host]
        if let address {
            for length in prefixLengths {
                let network = IPv4Network(address: address, prefixLength: length)
                if let hit = networks[network], hit.order < (bestHost?.order ?? Int.max) {
                    bestHost = hit
                }
            }
        }

        // Walk the suffix table from shortest to longest, keeping the most specific domain.
        let parts = Self.labels(host)
        var index = 0
        var bestDomain: Match?
        for (offset, label) in parts.reversed().enumerated() {
            guard let next = suffixes[index].children[label] else { break }
            index = next
            let isSubdomain = offset + 1 < parts.count
            let suffix = suffixes[index]
            if isSubdomain, let hit = suffix.host, hit.order < (bestHost?.order ?? Int.max) {
                bestHost = hit
            }
            if let hit = isSubdomain ? suffix.domain : suffix.apex {
                bestDomain = hit
            }
        }
        guard let result = bestHost?.match ?? bestDomain else { return nil }
        return (rules[result.ruleIndex], result.pattern)
    }

    public static func effective(_ rule: Rule, ciscoUp: Bool) -> Route {
        switch (rule.route, ciscoUp) {
        case (.cisco, false): return rule.withoutCisco ?? .direct
        case (.direct, true): return .cisco
        default: return rule.route
        }
    }

    public func decide(_ host: String, ciscoUp: Bool) -> RouteDecision {
        let host = host.lowercased()
        let address = IPv4Network.address(host)
        let localPattern: String?
        switch host {
        case "localhost", "::1": localPattern = host
        case _ where host.utf8.suffix(6).elementsEqual(".local".utf8): localPattern = "*.local"
        default:
            localPattern = address.flatMap { address in
                Self.localNetworks.first { $0.network.contains(address) }?.pattern
            }
        }
        if let localPattern {
            return RouteDecision(route: .direct, rule: "Local network", pattern: localPattern)
        }
        guard let hit = matchLowercase(host, address: address) else { return RouteDecision(route: .vpn) }
        return RouteDecision(route: Self.effective(hit.rule, ciscoUp: ciscoUp), rule: hit.rule.name, pattern: hit.pattern)
    }

    private static let localNetworks = [
        "127.0.0.0/8", "169.254.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
    ].compactMap { pattern in IPv4Network(pattern).map { (pattern: pattern, network: $0) } }
}

private struct IPv4Network: Hashable, Sendable {
    let prefixLength: Int
    private let prefix: UInt32

    init(address: UInt32, prefixLength: Int) {
        self.prefixLength = prefixLength
        prefix = address & (UInt32.max << (32 - prefixLength))
    }

    init?(_ cidr: String) {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let address = Self.address(parts[0]),
              parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(parts[1]), (0...32).contains(length) else { return nil }
        self.init(address: address, prefixLength: length)
    }

    static func address(_ text: some StringProtocol) -> UInt32? {
        let octets = text.utf8.split(separator: 46, omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var address: UInt32 = 0
        for octet in octets {
            guard (1...3).contains(octet.count), octet.count == 1 || octet.first != 48,
                  octet.allSatisfy({ (48...57).contains($0) }),
                  let number = UInt8(String(decoding: octet, as: UTF8.self)) else { return nil }
            address = (address << 8) | UInt32(number)
        }
        return address
    }

    func contains(_ address: UInt32) -> Bool {
        self == IPv4Network(address: address, prefixLength: prefixLength)
    }
}
