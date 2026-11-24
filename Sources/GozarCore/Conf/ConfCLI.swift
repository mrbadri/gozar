import Foundation

public struct ConfCLI {
    public struct Result {
        public let code: Int32
        public let stdout: String
        public let stderr: String
    }

    private static let modern = Set([
        "exits", "exit-add", "exit-add-ssh", "exit-rm", "exit-rename", "exit-use", "sub-add", "sub-update", "sub-rm",
        "exit-test", "xray-config", "domains",
    ])

    public static func run(_ args: [String], executable: URL, environment: [String: String]) -> Result {
        run(args, executable: executable, environment: environment, network: ConfNetwork())
    }

    static func run(_ args: [String], executable: URL, environment: [String: String], network: ConfNetwork) -> Result {
        var stdout = ""
        var stderr = ""
        var command = ""
        var jsonError = false
        func printOut(_ line: String) { stdout += line + "\n" }
        func printError(_ line: String) { stderr += line + "\n" }
        func result(_ code: Int32) -> Result { Result(code: code, stdout: stdout, stderr: stderr) }
        do {
            let arguments = try globalOptions(args)
            guard let first = arguments.command.first else {
                printError("usage: gozarctl [--conf-dir DIR] COMMAND [ARGS]")
                return result(2)
            }
            command = first
            let args = Array(arguments.command.dropFirst())
            let state = environment["LAPTOP_VPN_STATE"]
            let isModern = modern.contains(command)
            jsonError = isModern && args.prefix(while: { $0 != "--" }).contains("--json")
            let defaults = try confDirectory(arguments.defaults ?? environment["LAPTOP_VPN_CONF_DIR"], executable: executable)
            let files = ConfFiles(state: state, defaults: defaults)
            if isModern {
                let xray = xrayBinary(executable: executable, environment: environment)
                let value = try runModern(command, args: args, files: files, xray: xray, network: network)
                if jsonError || command == "domains" || command == "xray-config" || command == "exit-test" {
                    printOut(command == "xray-config" ? value.dumped() : value.rendered())
                } else {
                    printOut(text(command, value: value))
                }
            } else {
                switch command {
                case "init":
                    try files.createState()
                    try files.locked {
                        for note in try files.initialize() { printError(note) }
                        try ConfExits.migrate(files)
                    }
                case "validate":
                    _ = try ConfConnection(files)
                    for note in try ConfRoutes.notes(ConfRoutes(files).load()) { printError("note: \(note)") }
                case "check", "routes", "bypass":
                    let routes = ConfRoutes(files)
                    let args = try ConfArguments(args, required: command == "check" ? ["site"] : [],
                                                 options: [.init(name: "--cisco"),
                                                           .init(name: command == "bypass" ? "--router" : "--json")])
                    let cisco = args.flags.contains("--cisco")
                    let json = args.flags.contains("--json")
                    if command == "check" {
                        try printOut(routes.check(args.positionals[0], cisco: cisco, json: json))
                    } else if command == "routes" {
                        try printOut(routes.list(cisco: cisco, json: json))
                    } else {
                        try printOut(routes.bypass(cisco: cisco, router: args.flags.contains("--router")).joined(separator: "\n"))
                    }
                case "set":
                    guard let route = args.last else { throw ConfigError("route must be vpn, cisco or direct") }
                    try ConfRoutes(files).set(Array(args.dropLast()), route: route, emit: printOut)
                case "unset":
                    try ConfRoutes(files).set(args, route: "none", emit: printOut)
                case "sites":
                    for site in try ConfRoutes(files).sites() { printOut(site) }
                case "add-to", "rule-set", "rule-delete", "rule-move":
                    try printOut(editRule(command, args: args, files: files))
                case "conn-env":
                    let xray = xrayBinary(executable: executable, environment: environment)
                    let readOnly = args.contains("--defaults")
                    let load = {
                        let connection = try ConfConnection(files, useDefault: readOnly)
                        let exits = try ConfExits.load(files)
                        let active = exits.current ?? (files.hasExits ? nil : connection.migrationExit)
                        return try connection.environment(active: active, xrayBinary: xray, writeXrayConfig: !readOnly)
                    }
                    let lines = files.exists(files.state) ? try files.locked(load) : try load()
                    for line in lines { printOut(line) }
                default:
                    printError("vpnconf: unknown command \(command)")
                    return result(2)
                }
            }
            return result(0)
        } catch ConfArguments.Help.requested {
            if let help = ConfHelp.legacy[command] { printOut(help) }
            else { printOut("usage: gozarctl \(command) [--json] [ARGS]") }
            return result(0)
        } catch {
            let message = error.localizedDescription
            printError("config error:\n\(message)")
            if jsonError { printOut(ConfJSON.object(["error": .string(message)]).rendered()) }
            return result(1)
        }
    }

    private static func editRule(_ command: String, args: [String], files: ConfFiles) throws -> String {
        let routes = ConfRoutes(files)
        if command == "add-to" {
            let args = try ConfArguments(args, required: ["name", "route", "sites"], variadic: true,
                                         positionalChoices: [1: ConfRoutes.routeNames])
            return try routes.addTo(args.positionals[0], route: args.positionals[1], sites: Array(args.positionals.dropFirst(2)))
        }
        let options: [ConfArguments.Option]
        switch command {
        case "rule-set":
            options = [
                .init(name: "--route", type: "string", choices: ConfRoutes.routeNames),
                .init(name: "--without-cisco", type: "string", choices: ["direct", "vpn", "none"]),
                .init(name: "--enabled", type: "string", choices: ["true", "false"]),
                .init(name: "--rename", type: "string"), .init(name: "--note", type: "string"),
            ]
        case "rule-move":
            options = [.init(name: "--to", type: "int", required: true)]
        default:
            options = []
        }
        let args = try ConfArguments(args, required: ["name"], options: options)
        return try routes.edit(command, name: args.positionals[0], options: args.options)
    }

    private static func runModern(
        _ command: String, args: [String], files: ConfFiles, xray: URL?, network: ConfNetwork
    ) throws -> ConfJSON {
        let json = ConfArguments.Option(name: "--json")
        let name = ConfArguments.Option(name: "--name", type: "string")
        let seconds = ConfArguments.Option(name: "--seconds", type: "int")
        func parse(_ required: [String] = [], optional: Int = 0, many: Bool = false,
                   options: [ConfArguments.Option] = []) throws -> ConfArguments {
            try ConfArguments(args, required: required, optional: optional, variadic: many,
                              options: [json] + options, redact: true)
        }
        func mutate(_ mutation: (inout ConfExits) throws -> ConfJSON) throws -> ConfJSON {
            try files.createState()
            return try files.locked {
                var state = try ConfExits.load(files)
                let value = try mutation(&state)
                try state.save(files)
                return value
            }
        }
        func displayName(_ args: ConfArguments) throws -> String? {
            if let name = args.options["--name"] {
                guard !pythonStrip(name).isEmpty else { throw ConfigError("name cannot be empty") }
                return name
            }
            return nil
        }
        switch command {
        case "exits":
            _ = try parse()
            return try ConfExits.load(files).publicJSON()
        case "exit-add":
            let args = try parse(["LINK"], many: true, options: [name])
            let label = try displayName(args)
            return try mutate { .object(["ids": .strings(try $0.addLinks(args.positionals, name: label))]) }
        case "exit-add-ssh":
            let args = try parse(["HOST", "PORT", "USER"], options: [name])
            let label = try displayName(args)
            return try mutate {
                let id = try $0.addSSH(host: args.positionals[0], port: args.positionals[1], user: args.positionals[2], name: label)
                return .object(["ids": .strings([id])])
            }
        case "exit-rm", "exit-rename", "exit-use":
            let args = try parse(command == "exit-rename" ? ["ID", "NAME"] : ["ID"])
            return try mutate { try $0.edit(command, id: args.positionals[0], name: args.positionals.dropFirst().first) }
        case "sub-add":
            let args = try parse(["URL"], options: [name])
            let label = try displayName(args)
            return try mutate {
                try $0.addSubscription(url: args.positionals[0], name: label, network: network, port: network.socksPort(files))
            }
        case "sub-update":
            let args = try parse(optional: 1)
            try files.createState()
            return try files.locked {
                var state = try ConfExits.load(files)
                return try state.updateSubscriptions(id: args.positionals.first, network: network, port: network.socksPort(files)) {
                    try $0.save(files)
                }
            }
        case "sub-rm":
            let args = try parse(["ID"])
            return try mutate { try $0.removeSubscription(id: args.positionals[0]) }
        case "xray-config":
            let args = try parse(["ID"], options: [.init(name: "--port", type: "int", required: true)])
            guard let port = args.options["--port"].flatMap(Int.init), (1...65535).contains(port) else {
                throw ConfigError("port must be between 1 and 65535")
            }
            let link = try ConfExits.load(files).exit(args.positionals[0]).parsedLink()
            let config = try link.configuration(port: port)
            return try ConfJSON(parsing: String(decoding: config, as: UTF8.self))
        case "exit-test":
            let args = try parse(many: true, options: [.init(name: "--all"), seconds])
            let isAll = args.flags.contains("--all")
            guard isAll == args.positionals.isEmpty else { throw ConfigError("provide exit IDs or --all") }
            guard let seconds = Int(args.options["--seconds"] ?? "8"), (1...Int(Int32.max)).contains(seconds) else {
                throw ConfigError("--seconds must be a positive integer")
            }
            let state = try ConfExits.load(files)
            let exits = isAll ? state.exits : try args.positionals.map(state.exit)
            let tester = ConfExitTest(xrayBinary: xray, knownHosts: files.state.appendingPathComponent("known_hosts"))
            return .array(tester.run(exits: exits, seconds: seconds).map(\.json))
        case "domains":
            let args = try parse(["SITE"], options: [name, .init(name: "--cisco"), .init(name: "--all"), .init(name: "--quick")])
            return try ConfDomains(files: files, network: network).report(
                site: args.positionals[0], cisco: args.flags.contains("--cisco"), name: args.options["--name"],
                all: args.flags.contains("--all")
            )
        default:
            throw ConfigError("unknown command")
        }
    }

    private static func text(_ command: String, value: ConfJSON) -> String {
        let object = value.object ?? [:]
        switch command {
        case "exits":
            let active = object["active"]?.string
            let exits = (object["exits"]?.array ?? []).compactMap(\.object).map { exit in
                let id = exit["id"]?.string ?? ""
                let status = id == active ? "*" : " "
                let name = exit["name"]?.string ?? ""
                let proto = exit["protocol"]?.string ?? ""
                let host = exit["address"]?.string ?? ""
                let address = host.contains(":") ? "[\(host)]" : host
                let port = exit["port"]?.int ?? 0
                let stale = exit["stale"]?.bool == true ? " (stale)" : ""
                return "\(status) \(id)  \(name)  \(proto)  \(address):\(port)\(stale)"
            }
            let subs = (object["subscriptions"]?.array ?? []).compactMap(\.object).map { sub in
                let id = sub["id"]?.string ?? ""
                let name = sub["name"]?.string ?? ""
                let count = sub["count"]?.int ?? 0
                let outcome = sub["error"]?.string.map { " (\($0))" } ?? ""
                return "  \(id)  \(name)  \(count) exits\(outcome)"
            }
            if exits.isEmpty && subs.isEmpty { return "No exits configured." }
            return (exits + subs).joined(separator: "\n")
        case "exit-add", "exit-add-ssh":
            return object["ids"]?.strings.joined(separator: "\n") ?? ""
        case "sub-add", "sub-update":
            let ids = object["id"]?.string ?? object["ids"]?.strings.joined(separator: ", ") ?? ""
            return "\(ids): \(object["added"]?.int ?? 0) added, \(object["updated"]?.int ?? 0) updated, \(object["removed"]?.int ?? 0) removed, \(object["ignored"]?.int ?? 0) ignored"
        case "sub-rm":
            return "Removed \(object["id"]?.string ?? "") and \(object["removed"]?.int ?? 0) exit(s)"
        case "exit-rm":
            return "Removed exit \(object["id"]?.string ?? "")"
        case "exit-rename":
            return "Renamed exit \(object["id"]?.string ?? "")"
        default:
            return "Active exit: \(object["active"]?.string ?? "")"
        }
    }

    private static func globalOptions(_ args: [String]) throws -> (command: [String], defaults: String?) {
        var index = 0
        var command: [String] = []
        var defaults: String?
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg == "--" {
                command += args[(index - 1)...]
                break
            }
            if arg == "--conf-dir" {
                guard index < args.count, !args[index].isEmpty else { throw ConfigError("--conf-dir requires a directory") }
                defaults = args[index]
                index += 1
            } else if arg.hasPrefix("--conf-dir=") {
                defaults = String(arg.dropFirst("--conf-dir=".count))
                guard defaults != "" else { throw ConfigError("--conf-dir requires a directory") }
            } else {
                command.append(arg)
            }
        }
        return (command, defaults)
    }

    private static func confDirectory(_ override: String?, executable: URL) throws -> URL {
        if let override = nonempty(override) { return URL(fileURLWithPath: override, isDirectory: true) }
        let parent = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let bundle = parent.deletingLastPathComponent().appendingPathComponent("Resources/cli/laptop-vpn.d")
        let manager = FileManager.default
        if manager.fileExists(atPath: bundle.appendingPathComponent("connection.default.json").path) { return bundle }
        for start in [parent.path, manager.currentDirectoryPath] {
            var directory = start
            while !directory.isEmpty {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("cli/laptop-vpn.d")
                if manager.fileExists(atPath: candidate.appendingPathComponent("connection.default.json").path) { return candidate }
                if directory == "/" { break }
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        throw ConfigError("could not find laptop-vpn.d; set LAPTOP_VPN_CONF_DIR or pass --conf-dir")
    }

    private static func xrayBinary(executable: URL, environment: [String: String]) -> URL? {
        let parent = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let bundle = parent.deletingLastPathComponent().appendingPathComponent("Resources/xray/xray")
        let manager = FileManager.default
        let path = (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        if let configured = nonempty(environment["XRAY_BIN"]) {
            if configured.contains("/") {
                let url = URL(fileURLWithPath: configured)
                return manager.isExecutableFile(atPath: url.path) ? url : nil
            }
            return path.map { $0.appendingPathComponent(configured) }.first { manager.isExecutableFile(atPath: $0.path) }
        }
        return ([bundle] + path.map { $0.appendingPathComponent("xray") }).first { manager.isExecutableFile(atPath: $0.path) }
    }
}

