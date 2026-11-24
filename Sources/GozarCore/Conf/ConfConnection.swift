import Foundation

struct ConfConnection {
    private let files: ConfFiles
    private let data: ConfObject

    init(_ files: ConfFiles, useDefault: Bool = false) throws {
        self.files = files
        let file = useDefault && !files.exists(files.connection)
            ? files.defaults.appendingPathComponent("connection.default.json") : files.connection
        guard let data = try files.load(file).object else {
            throw ConfigError("\(files.display(files.connection)): must be an object")
        }
        self.data = data

        var errors: [String] = []
        func checkInts(_ object: ConfObject, _ keys: [String], prefix: String = "") {
            for key in keys {
                if let value = object[key], !value.isInteger && value.bool == nil {
                    errors.append("\"\(prefix)\(key)\" must be a whole number without quotes")
                }
            }
        }
        if !files.hasExits {
            if let relay = data["relay"]?.object {
                for key in ["host", "port", "user"] {
                    let value = relay[key] ?? .null
                    if key == "port" {
                        if !value.isInteger && value.bool == nil {
                            errors.append(#""relay.port" must be a number without quotes"#)
                        }
                    } else if value.string == nil {
                        errors.append("\"relay.\(key)\" must be a text in quotes")
                    }
                }
            } else {
                errors.append(#"needs "relay": { "host": …, "port": …, "user": … }"#)
            }
        }
        checkInts(data, ["connect_timeout_seconds", "reconnect_delay_seconds"])
        if let settings = (data["keepalive"] ?? .object([:])).object {
            checkInts(settings, ["interval_seconds", "max_missed"], prefix: "keepalive.")
        } else {
            errors.append(#""keepalive" must be an object"#)
        }
        if let ciphers = data["ciphers"], ciphers.array?.isEmpty != false {
            errors.append(#""ciphers" must be a non-empty list"#)
        }
        if let router = (data["router"] ?? .object([:])).object {
            errors += router.keys.filter { !["enabled", "upstream_port", "control_port"].contains($0) }.map {
                "unknown key \"router.\($0)\""
            }
            if let enabled = router["enabled"], enabled.bool == nil {
                errors.append(#""router.enabled" must be true or false (no quotes)"#)
            }
            let ports: [(String, ConfJSON)] = [
                ("local_socks_port", data["local_socks_port"] ?? .int(1080)),
                ("router.upstream_port", router["upstream_port"] ?? .int(1081)),
                ("router.control_port", router["control_port"] ?? .int(1090)),
            ]
            for (name, port) in ports where !(port.int.map { (1024...65535).contains($0) } ?? false) {
                errors.append("\"\(name)\" must be an integer between 1024 and 65535")
            }
            if ports.allSatisfy({ $0.1.isInteger }), Set(ports.map { $0.1.rendered() }).count != ports.count {
                errors.append(#""local_socks_port", "router.upstream_port" and "router.control_port" must be distinct"#)
            }
        } else {
            errors.append(#""router" must be an object"#)
        }
        let allowed = ["$schema", "_guide", "relay", "local_socks_port", "keepalive", "connect_timeout_seconds",
                       "reconnect_delay_seconds", "ciphers", "router"]
        errors += data.keys.filter { !allowed.contains($0) }.map { "unknown key \"\($0)\"" }
        if !errors.isEmpty {
            throw ConfigError(errors.map { "\(files.display(files.connection)): \($0)" }.joined(separator: "\n"))
        }
    }

    var migrationExit: ConfExit? {
        guard let relay = data["relay"]?.object, let host = relay["host"]?.string,
              let port = relay["port"]?.int, let user = relay["user"]?.string else { return nil }
        return ConfExit(id: "relay", name: "سرور اصلی", kind: .ssh, host: host, port: port, user: user)
    }

    var socksPort: Int { data["local_socks_port"]?.int ?? 1080 }
    private var routerEnabled: Bool { data["router"]?.object?["enabled"]?.bool ?? false }
    private var upstreamPort: Int { data["router"]?.object?["upstream_port"]?.int ?? 1081 }
    var tunnelPort: Int { routerEnabled ? upstreamPort : socksPort }

    func environment(active: ConfExit?, xrayBinary: URL?, writeXrayConfig: Bool) throws -> [String] {
        let keepalive = data["keepalive"]?.object
        let router = data["router"]?.object
        let legacy = data["relay"]?.object
        if let ciphers = data["ciphers"]?.array, ciphers.contains(where: { $0.string == nil }) {
            throw ConfigError(#""ciphers" must contain text in quotes"#)
        }
        let ssh = active?.kind == .ssh ? active : nil
        func legacyValue(_ key: String) -> String { legacy?[key].map { $0.string ?? $0.pythonRepr } ?? "" }
        func number(_ value: ConfJSON?, _ fallback: Int) -> String { value?.pythonRepr ?? String(fallback) }
        var assignments: [(String, String)] = [
            ("HOST", ssh?.host ?? legacyValue("host")),
            ("PORT", ssh?.port.map(String.init) ?? legacyValue("port")),
            ("USER_NAME", ssh?.user ?? legacyValue("user")),
            ("SOCKS_PORT", String(socksPort)),
            ("ROUTER_ENABLED", routerEnabled ? "1" : "0"),
            ("UPSTREAM_PORT", String(upstreamPort)),
            ("CONTROL_PORT", number(router?["control_port"], 1090)),
            ("KEEPALIVE_INTERVAL", number(keepalive?["interval_seconds"], 5)),
            ("KEEPALIVE_MISSED", number(keepalive?["max_missed"], 3)),
            ("CONNECT_TIMEOUT", number(data["connect_timeout_seconds"], 15)),
            ("RECONNECT_DELAY", number(data["reconnect_delay_seconds"], 3)),
            ("CIPHERS", (data["ciphers"]?.strings ?? ["aes128-gcm@openssh.com", "chacha20-poly1305@openssh.com"])
                .joined(separator: ",")),
        ]
        if let active {
            assignments += [("EXIT_ID", active.id), ("EXIT_KIND", active.kind.rawValue)]
            switch active.kind {
            case .ssh:
                assignments += [("KEYCHAIN_SERVICE", active.keychainService), ("KEYCHAIN_ACCOUNT", active.keychainAccount)]
            case .xray:
                if writeXrayConfig {
                    let config = try active.parsedLink().configuration(port: tunnelPort)
                    try files.writePrivate(config, to: files.xray)
                }
                assignments += [("XRAY_CONFIG", files.display(files.xray)), ("XRAY_BIN", xrayBinary?.path ?? "")]
            }
        }
        return assignments.map { "\($0.0)=\(shellQuote($0.1))" }
    }
}

