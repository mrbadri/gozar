import Foundation

public struct StatePaths: Sendable, Equatable {
    public let stateDir: URL

    public init(stateDir: URL) {
        self.stateDir = stateDir
    }

    public static func resolve() -> StatePaths {
        if let path = ProcessInfo.processInfo.environment["LAPTOP_VPN_STATE"], !path.isEmpty {
            return StatePaths(stateDir: URL(fileURLWithPath: path, isDirectory: true))
        }
        return StatePaths(stateDir: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/laptop-vpn", isDirectory: true))
    }

    public var routes: URL { stateDir.appendingPathComponent("routes.json") }
    public var connection: URL { stateDir.appendingPathComponent("connection.json") }
    public var sshLog: URL { stateDir.appendingPathComponent("ssh.log") }
    public var routerLog: URL { stateDir.appendingPathComponent("router.log") }
    public var routerPID: URL { stateDir.appendingPathComponent("router.pid") }
    public var routerToken: URL { stateDir.appendingPathComponent("router.token") }
    public var routerInfo: URL { stateDir.appendingPathComponent("router.json") }
}

public struct ConfigError: LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct ConfigStore: Sendable {
    public let paths: StatePaths

    public init(paths: StatePaths = .resolve()) {
        self.paths = paths
    }

    public func loadRoutes() throws -> RoutesFile {
        let routes: RoutesFile = try load(from: paths.routes)
        for (index, rule) in routes.rules.enumerated() {
            let context = "\(paths.routes.path): rule \(index + 1) (\(rule.name))"
            guard !rule.name.isEmpty, !rule.domains.isEmpty || !rule.hosts.isEmpty else {
                throw ConfigError("\(context): each rule needs a name and at least one domain or host")
            }
            if let fallback = rule.withoutCisco, rule.route != .cisco || fallback == .cisco {
                throw ConfigError("\(context): without_cisco must be vpn or direct and requires a cisco route")
            }
            for domain in rule.domains {
                do {
                    _ = try RuleEngine.parseDomain(domain)
                } catch {
                    throw ConfigError("\(context): \(error.localizedDescription)")
                }
            }
            for host in rule.hosts where host.range(of: #"\A[A-Za-z0-9.*/:_-]+\n?\z"#, options: .regularExpression) == nil {
                throw ConfigError("\(context): bad host \(String(reflecting: host))")
            }
        }
        return routes
    }

    public func loadConnection() throws -> ConnectionFile {
        let connection: ConnectionFile = try load(from: paths.connection)
        let ports = [connection.localSocksPort, connection.router.upstreamPort, connection.router.controlPort]
        guard (1...65_535).contains(connection.relayPort) else {
            throw ConfigError("\(paths.connection.path): relay.port must be between 1 and 65535")
        }
        guard ports.allSatisfy({ (1024...65_535).contains($0) }), Set(ports).count == ports.count else {
            throw ConfigError("\(paths.connection.path): local_socks_port, upstream_port, and control_port must be distinct and between 1024 and 65535")
        }
        return connection
    }

    private func load<Value: Decodable>(from url: URL) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        } catch let error as DecodingError {
            throw ConfigError("\(url.path): \(error)")
        } catch {
            throw ConfigError("\(url.path): \(error.localizedDescription)")
        }
    }

    /// Retain the returned timer while watching and cancel it to stop polling.
    public func watch(onChange: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let files = [paths.routes, paths.connection]
        var previous = files.map(FileStamp.init)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ir.mrbadri.gozar.config"))
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler {
            let current = files.map(FileStamp.init)
            if current != previous {
                previous = current
                onChange()
            }
        }
        timer.resume()
        return timer
    }

    private struct FileStamp: Equatable {
        let modified: Date?
        let inode: UInt64?

        init(_ url: URL) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            modified = attributes?[.modificationDate] as? Date
            inode = attributes?[.systemFileNumber] as? UInt64
        }
    }
}
