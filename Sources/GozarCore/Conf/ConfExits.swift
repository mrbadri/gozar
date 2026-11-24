import Foundation

struct ConfExit: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case ssh, xray }

    let id: String
    var name: String
    let kind: Kind
    var host: String? = nil
    var port: Int? = nil
    var user: String? = nil
    var link: String? = nil
    var subscription: String? = nil
    var stale: Bool? = nil

    var keychainService: String { id == "relay" ? "vpnuser-relay" : "gozar-ssh" }
    var keychainAccount: String { id == "relay" ? user ?? "" : id }

    func parsedLink() throws -> ParsedLink {
        guard kind == .xray, let link else { throw ConfigError("exit \(id) is not an Xray exit") }
        return try ParsedLink(link)
    }

    func publicJSON() throws -> ConfJSON {
        let protocolName: String
        let address: String
        let port: Int
        switch kind {
        case .ssh:
            guard let host, let sshPort = self.port else { throw ConfigError("SSH exit \(id) is missing host or port") }
            protocolName = "ssh"
            address = host
            port = sshPort
        case .xray:
            let parsed = try parsedLink()
            protocolName = parsed.kind.rawValue
            address = parsed.address
            port = parsed.port
        }
        return .object([
            "id": .string(id), "name": .string(name), "kind": .string(kind.rawValue), "protocol": .string(protocolName),
            "address": .string(address), "port": .int(port), "subscription": subscription.map(ConfJSON.string) ?? .null,
            "stale": .bool(stale == true),
        ])
    }
}

private struct ConfSubscription: Codable {
    let id: String
    var name: String
    let url: String
    var updatedAt: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case id, name, url, error
        case updatedAt = "updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(error, forKey: .error)
    }

    var host: String { URLComponents(string: url)?.host ?? "" }

    func publicJSON(count: Int) -> ConfJSON {
        .object([
            "id": .string(id), "name": .string(name), "host": .string(host), "count": .int(count),
            "updated_at": updatedAt.map(ConfJSON.string) ?? .null, "error": error.map(ConfJSON.string) ?? .null,
        ])
    }
}

struct ConfExits {
    var active: String?
    var exits: [ConfExit] = []
    private var subscriptions: [ConfSubscription] = []

    var current: ConfExit? { exits.first { $0.id == active } }

    static func load(_ files: ConfFiles) throws -> Self {
        if files.hasExits {
            let file = try files.load(files.exits)
            guard let object = file.object, let exits = object["exits"]?.array,
                  let subscriptions = object["subscriptions"]?.array,
                  object["active"] == .null || object["active"]?.string != nil else {
                throw ConfigError("\(files.display(files.exits)): invalid exit list")
            }
            do {
                let decoder = JSONDecoder()
                let decoded = try decoder.decode([ConfExit].self, from: Data(ConfJSON.array(exits).rendered().utf8))
                let subs = try decoder.decode([ConfSubscription].self, from: Data(ConfJSON.array(subscriptions).rendered().utf8))
                let active = object["active"]?.string
                guard Set(decoded.map(\.id)).count == decoded.count, Set(subs.map(\.id)).count == subs.count,
                      active.map({ id in decoded.contains { $0.id == id } }) ?? decoded.isEmpty,
                      decoded.allSatisfy({ validID($0.id, prefix: $0.kind == .ssh ? "h" : "x") || ($0.id == "relay" && $0.kind == .ssh) }),
                      subs.allSatisfy({ validID($0.id, prefix: "s") }) else {
                    throw ConfigError("invalid exit IDs")
                }
                return Self(active: active, exits: decoded, subscriptions: subs)
            } catch {
                throw ConfigError("\(files.display(files.exits)): invalid exit list")
            }
        }
        guard files.exists(files.connection) else { return Self() }
        if let exit = try ConfConnection(files).migrationExit {
            return Self(active: exit.id, exits: [exit])
        }
        return Self()
    }

    static func migrate(_ files: ConfFiles) throws {
        guard !files.hasExits, let exits = try? Self.load(files), exits.current != nil else { return }
        try exits.save(files)
    }

    private static func validID(_ id: String, prefix: Character) -> Bool {
        id.count == 7 && id.first == prefix && id.dropFirst().allSatisfy { "0123456789abcdef".contains($0) }
    }

    private func nextID(prefix: String) -> String {
        let used = Set(exits.map(\.id) + subscriptions.map(\.id))
        while true {
            let id = prefix + String(format: "%06x", UInt32.random(in: 0...0xffffff))
            if !used.contains(id) { return id }
        }
    }

    func save(_ files: ConfFiles) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        func json<T: Encodable>(_ value: T) throws -> ConfJSON {
            try ConfJSON(parsing: String(decoding: encoder.encode(value), as: UTF8.self))
        }
        let state: ConfJSON = .object([
            "active": active.map(ConfJSON.string) ?? .null,
            "exits": try json(exits), "subscriptions": try json(subscriptions),
        ])
        try files.writePrivate(Data((state.dumped() + "\n").utf8), to: files.exits)
    }

    func exit(_ id: String) throws -> ConfExit {
        guard let index = exits.firstIndex(where: { $0.id == id }) else { throw ConfigError("no exit with that ID") }
        return exits[index]
    }

    func publicJSON() throws -> ConfJSON {
        .object([
            "active": active.map(ConfJSON.string) ?? .null,
            "exits": .array(try exits.map { try $0.publicJSON() }),
            "subscriptions": .array(subscriptions.map { subscription in
                subscription.publicJSON(count: exits.filter { $0.subscription == subscription.id }.count)
            }),
        ])
    }

    mutating func addLinks(_ links: [String], name: String?) throws -> [String] {
        let parsed = try links.map(ParsedLink.init)
        return zip(links, parsed).map { appendLink($0.0, parsed: $0.1, name: name, subscription: nil) }
    }

    private mutating func appendLink(_ raw: String, parsed: ParsedLink, name: String?, subscription: String?) -> String {
        let id = nextID(prefix: "x")
        exits.append(ConfExit(id: id, name: name ?? parsed.name, kind: .xray, link: raw, subscription: subscription))
        active = active ?? id
        return id
    }

    mutating func addSSH(host: String, port: String, user: String, name: String?) throws -> String {
        guard let host = normalizedExitHost(host) else { throw ConfigError("invalid SSH host") }
        guard let port = exitPort(port) else { throw ConfigError("invalid SSH port") }
        guard validSSHUser(user) else { throw ConfigError("invalid SSH user") }
        let id = nextID(prefix: "h")
        let displayHost = host.contains(":") ? "[\(host)]" : host
        exits.append(ConfExit(id: id, name: name ?? "\(displayHost):\(port)", kind: .ssh, host: host, port: port, user: user))
        active = active ?? id
        return id
    }

    mutating func edit(_ command: String, id: String, name: String?) throws -> ConfJSON {
        guard let index = exits.firstIndex(where: { $0.id == id }) else { throw ConfigError("no exit with that ID") }
        switch command {
        case "exit-rm":
            guard id != active else { throw ConfigError("cannot remove the active exit") }
            exits.remove(at: index)
        case "exit-rename":
            guard let name, !pythonStrip(name).isEmpty else { throw ConfigError("exit name cannot be empty") }
            exits[index].name = name
        case "exit-use":
            active = id
        default:
            throw ConfigError("unknown exit edit")
        }
        return .object(["id": .string(id), "active": active.map(ConfJSON.string) ?? .null])
    }

    mutating func addSubscription(url: String, name: String?, network: ConfNetwork, port: Int?) throws -> ConfJSON {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = nonempty(components.host),
              components.user == nil, components.password == nil, let url = components.url?.absoluteString else {
            throw ConfigError("subscription URL must be an HTTP or HTTPS URL")
        }
        let id = nextID(prefix: "s")
        let body = try fetch(url, network: network, port: port)
        let index = subscriptions.count
        subscriptions.append(ConfSubscription(id: id, name: name ?? host, url: url))
        let counts = refresh(index: index, body: body)
        return counts.json(ids: ["id": .string(id)])
    }

    mutating func updateSubscriptions(
        id: String?, network: ConfNetwork, port: Int?,
        save: (Self) throws -> Void
    ) throws -> ConfJSON {
        let indices: [Int]
        if let id {
            guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { throw ConfigError("no subscription with that ID") }
            indices = [index]
        } else {
            indices = Array(subscriptions.indices)
        }
        var total = RefreshCounts()
        var failures = 0
        for index in indices {
            do {
                let body = try fetch(subscriptions[index].url, network: network, port: port)
                total.add(refresh(index: index, body: body))
            } catch {
                subscriptions[index].error = error.localizedDescription
                failures += 1
            }
        }
        try save(self)
        if failures > 0 { throw ConfigError("could not refresh \(failures) subscription(s)") }
        let ids = id.map { ["id": ConfJSON.string($0)] } ?? ["ids": .strings(indices.map { subscriptions[$0].id })]
        var result: ConfObject = [:]
        for (key, value) in ids { result[key] = value }
        return total.json(ids: result)
    }

    mutating func removeSubscription(id: String) throws -> ConfJSON {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else {
            throw ConfigError("no subscription with that ID")
        }
        guard current?.subscription != id else { throw ConfigError("cannot remove the subscription of the active exit") }
        let previous = exits.count
        exits.removeAll { $0.subscription == id }
        subscriptions.remove(at: index)
        return .object(["id": .string(id), "removed": .int(previous - exits.count)])
    }

    private func fetch(_ url: String, network: ConfNetwork, port: Int?) throws -> String {
        guard let bytes = network.fetch(url, port, "v2rayNG/1.9.27", true),
              let text = String(data: bytes, encoding: .utf8) else {
            throw ConfigError("could not download subscription")
        }
        let clean = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        if !clean.contains("://"), let bytes = ParsedLink.decodeBase64(clean),
           let decoded = String(data: bytes, encoding: .utf8) { return decoded }
        return clean
    }

    private mutating func refresh(index: Int, body: String) -> RefreshCounts {
        let id = subscriptions[index].id
        var slots: [ParsedLink.Identity: Int] = [:]
        for (index, exit) in exits.enumerated() where exit.subscription == id {
            if let link = try? exit.parsedLink() { slots[link.identity] = slots[link.identity] ?? index }
        }
        var counts = RefreshCounts()
        var retained = Set<String>()
        var seen = Set<ParsedLink.Identity>()
        for line in body.components(separatedBy: ConfFiles.lineBreaks) {
            let raw = pythonStrip(line)
            guard !raw.isEmpty else { continue }
            guard let link = try? ParsedLink(raw) else { counts.ignored += 1; continue }
            guard seen.insert(link.identity).inserted else { continue }
            if let index = slots[link.identity] {
                exits[index].link = raw
                exits[index].stale = nil
                retained.insert(exits[index].id)
                counts.updated += 1
            } else {
                retained.insert(appendLink(raw, parsed: link, name: nil, subscription: id))
                counts.added += 1
            }
        }
        let prior = exits.count
        for index in exits.indices where exits[index].subscription == id && exits[index].id == active && !retained.contains(exits[index].id) {
            exits[index].stale = true
        }
        exits.removeAll { $0.subscription == id && $0.id != active && !retained.contains($0.id) }
        counts.removed = prior - exits.count
        subscriptions[index].updatedAt = ISO8601DateFormatter().string(from: Date())
        subscriptions[index].error = nil
        return counts
    }

    private struct RefreshCounts {
        var added = 0
        var updated = 0
        var removed = 0
        var ignored = 0

        mutating func add(_ other: Self) {
            added += other.added
            updated += other.updated
            removed += other.removed
            ignored += other.ignored
        }

        func json(ids: ConfObject) -> ConfJSON {
            var object = ids
            object["added"] = .int(added)
            object["updated"] = .int(updated)
            object["removed"] = .int(removed)
            object["ignored"] = .int(ignored)
            return .object(object)
        }
    }
}

func validSSHUser(_ user: String) -> Bool {
    user.range(of: #"\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z"#, options: .regularExpression) != nil
}

