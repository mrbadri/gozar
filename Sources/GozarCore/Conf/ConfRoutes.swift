import Foundation

struct ConfRoutes {
    static let routeNames = ["vpn", "cisco", "direct"]
    private static let ruleKeys = ["domains", "enabled", "hosts", "name", "note", "route", "without_cisco"]

    private let files: ConfFiles

    init(_ files: ConfFiles) { self.files = files }

    func load() throws -> ConfObject {
        let data = try files.load(files.routes)
        let errors = Self.errors(in: data)
        if !errors.isEmpty {
            throw ConfigError(errors.map { "\(files.display(files.routes)): \($0)" }.joined(separator: "\n"))
        }
        return data.object ?? [:]
    }

    private func save(_ data: ConfObject) throws {
        let errors = Self.errors(in: .object(data))
        guard errors.isEmpty else { throw ConfigError(errors.joined(separator: "\n")) }
        try files.write(files.withGuide(data, schema: "routes.schema.json", guide: ConfFiles.routesGuide), to: files.routes)
    }

    static func rules(in data: ConfObject, includeDisabled: Bool = false) -> [ConfObject] {
        (data["rules"]?.array ?? []).compactMap(\.object).filter { includeDisabled || $0["enabled"]?.bool != false }
    }

    private static func domain(_ value: ConfJSON) throws -> (kind: RuleEngine.DomainKind, name: String) {
        guard let raw = value.string, !pythonStrip(raw).isEmpty else {
            throw ConfigError("empty domain \(value.pythonRepr)")
        }
        do {
            return try RuleEngine.parseDomain(raw)
        } catch {
            var name = pythonStrip(raw).lowercased()
            if name.contains("://") || name.contains("/") || name.contains("?") {
                name = hostOf(name)
                if name.hasPrefix("www.") { name = String(name.dropFirst(4)) }
            }
            if name.hasPrefix("*.") { name = String(name.dropFirst(2)) }
            else if name.hasPrefix(".") { name = String(name.dropFirst()) }
            while name.hasSuffix(".") { name.removeLast() }
            let hint: String
            if name.contains(" ") { hint = " (no spaces)" }
            else if name.contains("*") { hint = #" (a "*" only works at the start: "*.example.com")"# }
            else if name.contains("_") { hint = #" (domains can't have _; for a machine name use "hosts")"# }
            else { hint = "" }
            throw ConfigError("bad domain \(value.pythonRepr)\(hint)")
        }
    }

    private static func label(_ domain: (kind: RuleEngine.DomainKind, name: String)) -> String {
        domain.kind == .sub ? "*." + domain.name : domain.name
    }

    private static func validHost(_ value: String) -> Bool {
        value.range(of: #"\A[A-Za-z0-9.*/:_-]+\n?\z"#, options: .regularExpression) != nil
    }

    static func errors(in data: ConfJSON) -> [String] {
        guard let data = data.object, let rules = data["rules"]?.array else {
            return [#"needs a top-level "rules": [ … ] list"#]
        }
        var errors = data.keys.filter { !["$schema", "_guide", "rules"].contains($0) }.map {
            "unknown top-level key \"\($0)\" (only \"rules\"; your notes go in a rule's \"note\")"
        }
        for (index, value) in rules.enumerated() {
            guard let rule = value.object else {
                errors.append("rule \(index + 1): must be an object { … }")
                continue
            }
            let name = rule["name"] ?? .string("no name")
            let prefix = "rule \(index + 1) (\(name.string ?? name.pythonRepr)): "
            for key in rule.keys where !ruleKeys.contains(key) {
                let close = ruleKeys.first { $0.prefix(3) == key.prefix(3).lowercased() }
                let hint = close.map { " — did you mean \"\($0)\"?" } ?? " (allowed: \(ruleKeys.joined(separator: ", ")))"
                errors.append(prefix + "unknown key \"\(key)\"" + hint)
            }
            if pythonStrip(rule["name"]?.string ?? "").isEmpty { errors.append(prefix + #"needs a "name""#) }
            if let note = rule["note"], note.string == nil { errors.append(prefix + #""note" must be text in quotes"#) }
            let route = rule["route"] ?? .null
            if !routeNames.contains(route.string ?? "") {
                errors.append(prefix + #""route" must be "vpn", "cisco" or "direct", not "# + route.rendered(ascii: true))
            }
            if let without = rule["without_cisco"] {
                if route.string != "cisco" {
                    errors.append(prefix + #""without_cisco" only means something with "route": "cisco""#)
                } else if !["vpn", "direct"].contains(without.string ?? "") {
                    errors.append(prefix + #""without_cisco" must be "vpn" or "direct""#)
                }
            }
            if let enabled = rule["enabled"], enabled.bool == nil {
                errors.append(prefix + #""enabled" must be true or false (no quotes)"#)
            }
            for key in ["domains", "hosts"] {
                if let list = rule[key], list.array == nil {
                    errors.append(prefix + "\"\(key)\" must be a list: [\"a.com\", \"b.com\"]")
                }
            }
            if rule["domains"]?.truthy != true && rule["hosts"]?.truthy != true {
                errors.append(prefix + #"needs "domains" or "hosts" (a list)"#)
            }
            for value in rule["domains"]?.array ?? [] {
                do { _ = try domain(value) }
                catch { errors.append(prefix + error.localizedDescription) }
            }
            for value in rule["hosts"]?.array ?? [] where !validHost(value.string ?? "") {
                errors.append(prefix + "bad host \(value.pythonRepr)")
            }
        }
        return errors
    }

    private static func domains(_ rule: ConfObject) -> [(kind: RuleEngine.DomainKind, name: String)] {
        (rule["domains"]?.array ?? []).compactMap { try? domain($0) }
    }

    private static func items(_ rule: ConfObject) -> [String] {
        domains(rule).map(label) + (rule["hosts"]?.strings ?? [])
    }

    static func notes(_ data: ConfObject) -> [String] {
        let rules = rules(in: data)
        var output: [String] = []
        for rule in rules {
            for domain in rule["domains"]?.strings ?? [] {
                guard let parsed = try? Self.domain(.string(domain)) else { continue }
                let original = pythonStrip(domain).lowercased()
                if label(parsed) != original && ![parsed.name, "." + parsed.name].contains(original) {
                    output.append("\"\(domain)\" read as \"\(label(parsed))\" (rule \"\(name(rule))\")")
                }
            }
        }
        var seen: [String: String] = [:]
        for rule in rules {
            for item in items(rule) {
                let key = item.lowercased()
                if let first = seen[key], first != name(rule) {
                    output.append("\(item) is in both \"\(first)\" and \"\(name(rule))\"")
                } else {
                    seen[key] = name(rule)
                }
            }
        }
        let offVPN = rules.filter { route($0) != "vpn" }.flatMap { rule in
            domains(rule).map { ($0.name, name(rule)) }
        }
        for rule in rules where route(rule) == "vpn" {
            for domain in domains(rule).map(\.name) {
                for (parent, parentName) in offVPN where domain.hasSuffix("." + parent) {
                    output.append("\(domain) (\"\(name(rule))\", vpn) sits under \(parent) (\"\(parentName)\"): macOS can't carve a subdomain back into the VPN, so it goes the way of \(parent)")
                }
            }
        }
        return output
    }

    private static func name(_ rule: ConfObject) -> String { rule["name"]?.string ?? "" }
    private static func route(_ rule: ConfObject) -> String { rule["route"]?.string ?? "vpn" }

    private static func effective(_ rule: ConfObject, cisco: Bool) -> String {
        let route = Route(rawValue: route(rule)) ?? .vpn
        let fallback = rule["without_cisco"]?.string.flatMap(Route.init(rawValue:))
        return RuleEngine.effective(Rule(name: name(rule), route: route, withoutCisco: fallback), ciscoUp: cisco).rawValue
    }

    private static func match(_ data: ConfObject, host: String) -> (rule: ConfObject, pattern: String)? {
        let host = host.lowercased()
        let rules = rules(in: data)
        // The legacy CLI only interprets exact and wildcard hosts. CIDR belongs to the router.
        for rule in rules {
            for pattern in rule["hosts"]?.strings ?? [] {
                if pattern.lowercased() == host || pattern.hasPrefix("*.") && host.hasSuffix(pattern.dropFirst().lowercased()) {
                    return (rule, pattern)
                }
            }
        }
        var best: (ConfObject, String)?
        var bestLength = -1
        for rule in rules {
            for domain in domains(rule) where host.hasSuffix("." + domain.name) || (domain.kind == .tree && host == domain.name) {
                if domain.name.unicodeScalars.count > bestLength {
                    best = (rule, label(domain))
                    bestLength = domain.name.unicodeScalars.count
                }
            }
        }
        return best
    }

    static func currentRoute(_ data: ConfObject?, host: String, cisco: Bool) -> String {
        guard let data, let hit = match(data, host: host) else { return "vpn" }
        return effective(hit.rule, cisco: cisco)
    }

    func check(_ site: String, cisco: Bool, json: Bool) throws -> String {
        let data = try load()
        let host = hostOf(site)
        let hit = Self.match(data, host: host)
        let now = hit.map { Self.effective($0.rule, cisco: cisco) } ?? "vpn"
        if json {
            return ConfJSON.object([
                "host": .string(host), "route": .string(now),
                "rule": hit.map { .string(Self.name($0.rule)) } ?? .null,
                "pattern": hit.map { .string($0.pattern) } ?? .null,
                "rule_route": hit.map { .string(Self.route($0.rule)) } ?? .null,
                "cisco": .bool(cisco),
            ]).rendered()
        }
        guard let hit else { return "\(host) → vpn (not listed: everything else goes through the VPN)" }
        let route = Self.route(hit.rule)
        let extra = route == now ? "" : "  [rule says \(route); Cisco is \(cisco ? "connected" : "not connected")]"
        return "\(host) → \(now)  (rule \"\(Self.name(hit.rule))\", matches \(hit.pattern))\(extra)"
    }

    func list(cisco: Bool, json: Bool) throws -> String {
        let data = try load()
        let rules = Self.rules(in: data, includeDisabled: true)
        let path = files.display(files.routes)
        if json {
            let entries: [ConfJSON] = rules.map { rule in
                let enabled = rule["enabled"] ?? .bool(true)
                return .object([
                    "name": rule["name"] ?? .null, "route": rule["route"] ?? .null,
                    "without_cisco": rule["without_cisco"] ?? .null, "enabled": enabled, "note": rule["note"] ?? .null,
                    "domains": rule["domains"] ?? .array([]), "hosts": rule["hosts"] ?? .array([]),
                    "effective": .string(enabled.truthy ? Self.effective(rule, cisco: cisco) : "off"),
                ])
            }
            return ConfJSON.object(["path": .string(path), "cisco": .bool(cisco), "rules": .array(entries)]).rendered()
        }
        var output = [path, "Cisco: \(cisco ? "connected" : "not connected") · anything not listed → vpn\n"]
        for rule in rules {
            let name = Self.name(rule)
            guard rule["enabled"]?.bool != false else { output.append("  \(name): off (enabled: false)"); continue }
            let route = Self.route(rule)
            let how = route == "cisco" ? " (without Cisco: \(rule["without_cisco"]?.string ?? "direct"))" : ""
            output.append("  \(name): \(route)\(how) → now \(Self.effective(rule, cisco: cisco))")
            output.append("      " + Self.items(rule).joined(separator: ", "))
        }
        output += Self.notes(data).map { "\n  note: \($0)" }
        return output.joined(separator: "\n")
    }

    func sites() throws -> [String] { Self.rules(in: try load(), includeDisabled: true).flatMap(Self.items) }

    func bypass(cisco: Bool, router: Bool) throws -> [String] {
        var output = ConfFiles.fixedDirect
        if !router {
            for rule in Self.rules(in: try load()) where Self.effective(rule, cisco: cisco) != "vpn" {
                for domain in Self.domains(rule) {
                    if domain.kind == .tree { output.append(domain.name) }
                    output.append("*." + domain.name)
                }
                output += rule["hosts"]?.strings ?? []
            }
        }
        var seen = Set<String>()
        return output.filter { seen.insert($0).inserted }
    }

    private static func same(_ first: String, _ second: String) -> Bool {
        if let left = try? domain(.string(first)), let right = try? domain(.string(second)) {
            return label(left) == label(right)
        }
        return first.lowercased() == second.lowercased()
    }

    private static func remove(_ entry: String, from rules: inout [ConfObject]) {
        for index in rules.indices {
            for key in ["domains", "hosts"] {
                if let list = rules[index][key]?.strings {
                    rules[index][key] = .strings(list.filter { !same($0, entry) })
                }
            }
        }
    }

    private static func index(of name: String, in rules: [ConfObject]) -> Int? {
        rules.firstIndex { Self.name($0).lowercased() == name.lowercased() }
    }

    private static func add(_ raw: String, to rules: inout [ConfObject], name: String, route: String) throws -> String {
        let key: String
        let entry: String
        if raw.drop(while: { $0 == "*" || $0 == "." }).contains(".") || raw.hasPrefix("*.") {
            key = "domains"
            entry = label(try domain(.string(raw)))
        } else {
            guard validHost(raw) else { throw ConfigError("bad site \(ConfJSON.string(raw).pythonRepr)") }
            key = "hosts"
            entry = raw
        }
        remove(entry, from: &rules)
        let index: Int
        if let existing = Self.index(of: name, in: rules) {
            index = existing
        } else {
            index = rules.count
            rules.append(["name": .string(name), "route": .string(route)])
        }
        rules[index][key] = .strings((rules[index][key]?.strings ?? []) + [entry])
        return entry
    }

    private static func populated(_ rule: ConfObject) -> Bool {
        rule["domains"]?.truthy == true || rule["hosts"]?.truthy == true
    }

    private func withRules<T>(_ mutate: (inout [ConfObject]) throws -> T) throws -> T {
        try files.locked {
            var data = try load()
            var rules = Self.rules(in: data, includeDisabled: true)
            let result = try mutate(&rules)
            data["rules"] = .array(rules.map(ConfJSON.object))
            try save(data)
            return result
        }
    }

    func set(_ sites: [String], route: String, emit: (String) -> Void) throws {
        guard Self.routeNames.contains(route) || route == "none" else { throw ConfigError("route must be vpn, cisco or direct") }
        try withRules { rules in
            for raw in sites {
                var entry = pythonStrip(raw)
                if entry.contains("://") || entry.contains("/") {
                    entry = hostOf(entry)
                    if entry.hasPrefix("www.") { entry = String(entry.dropFirst(4)) }
                }
                let was = rules.flatMap { rule in
                    ((rule["domains"]?.strings ?? []) + (rule["hosts"]?.strings ?? []))
                        .filter { Self.same($0, entry) }.map { _ in Self.name(rule) }
                }.joined(separator: ", ")
                if route == "none" {
                    Self.remove(entry, from: &rules)
                    emit(was.isEmpty ? "\(entry): wasn't listed" : "\(entry): removed from \(was) → vpn")
                } else {
                    let added = try Self.add(entry, to: &rules, name: "Added with vpn set (\(route))", route: route)
                    emit("\(added) → \(route)" + (was.isEmpty ? "" : " (was in \(was))"))
                }
                rules = rules.filter(Self.populated)
            }
        }
    }

    func addTo(_ name: String, route: String, sites: [String]) throws -> String {
        try withRules { rules in
            for site in sites {
                var entry = site
                if entry.contains("://") {
                    entry = hostOf(entry)
                    if entry.hasPrefix("www.") { entry = String(entry.dropFirst(4)) }
                }
                _ = try Self.add(entry, to: &rules, name: name, route: route)
            }
            rules = rules.filter(Self.populated)
            guard let index = Self.index(of: name, in: rules) else { throw ConfigError("no rule named \"\(name)\"") }
            let rule = rules[index]
            return "Added \(sites.count) to rule \"\(Self.name(rule))\" → \(Self.route(rule))"
        }
    }

    func edit(_ command: String, name: String, options: [String: String]) throws -> String {
        try withRules { rules in
            guard let index = Self.index(of: name, in: rules) else { throw ConfigError("no rule named \"\(name)\"") }
            var rule = rules[index]
            switch command {
            case "rule-delete":
                rules.remove(at: index)
                return "Deleted rule \"\(Self.name(rule))\""
            case "rule-move":
                let destination = options["--to"].flatMap(Int.init) ?? -1
                guard rules.indices.contains(destination) else {
                    throw ConfigError("--to must be between 0 and \(rules.count - 1)")
                }
                rules.remove(at: index)
                rules.insert(rule, at: destination)
                return "Moved rule \"\(Self.name(rule))\" to index \(destination)"
            default:
                if let rename = options["--rename"] {
                    if rules.indices.contains(where: { $0 != index && Self.name(rules[$0]).lowercased() == rename.lowercased() }) {
                        throw ConfigError("rule \"\(rename)\" already exists")
                    }
                    rule["name"] = .string(rename)
                }
                if let enabled = options["--enabled"] { rule["enabled"] = .bool(enabled == "true") }
                if let note = options["--note"] { rule["note"] = .string(note) }
                let fallback = options["--without-cisco"]
                let route = options["--route"]
                if let fallback, fallback != "none" { rule["without_cisco"] = .string(fallback) }
                if let route { rule["route"] = .string(route) }
                if fallback == "none" || route == "direct" || route == "vpn" { rule["without_cisco"] = nil }
                rules[index] = rule
                return "Updated rule \"\(Self.name(rule))\""
            }
        }
    }
}

