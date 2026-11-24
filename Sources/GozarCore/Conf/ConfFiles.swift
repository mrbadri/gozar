import Darwin
import Foundation

struct ConfFiles {
    let state: URL
    let defaults: URL
    let displayState: String

    var routes: URL { state.appendingPathComponent("routes.json") }
    var connection: URL { state.appendingPathComponent("connection.json") }
    var exits: URL { state.appendingPathComponent("exits.json") }
    var xray: URL { state.appendingPathComponent("xray.json") }
    var oldDirect: URL { state.appendingPathComponent("direct.txt") }
    var hasExits: Bool { exists(exits) }

    init(state: String?, defaults: URL) {
        let path = state.flatMap { $0.isEmpty ? nil : $0 } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/laptop-vpn").path
        let parts = path.split(separator: "/").filter { $0 != "." }
        displayState = (path.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
        self.state = URL(fileURLWithPath: path, isDirectory: true)
        self.defaults = defaults.resolvingSymlinksInPath().standardizedFileURL
    }

    func display(_ url: URL) -> String {
        guard url.deletingLastPathComponent().path == state.path else { return url.path }
        if displayState == "/" { return "/" + url.lastPathComponent }
        return displayState.isEmpty ? url.lastPathComponent : displayState + "/" + url.lastPathComponent
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func createState() throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func locked<T>(_ operation: () throws -> T) throws -> T {
        let directory = open(state.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw ConfigError("\(displayState): state directory is unavailable") }
        defer { close(directory) }
        while flock(directory, LOCK_EX) != 0 {
            if errno != EINTR { throw ConfigError("\(displayState): could not lock state directory") }
        }
        return try operation()
    }

    func readText(_ url: URL) throws -> String {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        } catch {
            throw ConfigError("\(display(url)): \(exists(url) ? error.localizedDescription : "file not found")")
        }
    }

    func load(_ url: URL) throws -> ConfJSON {
        let text = try readText(url)
        do {
            return try ConfJSON(parsing: text)
        } catch let error as ConfJSONError {
            throw ConfigError("""
                \(display(url)): line \(error.line), column \(error.column): \(error.message)
                  (JSON: double quotes only, no comma after the last item, no // comments — use "note")
                """)
        }
    }

    func write(_ value: ConfJSON, to url: URL) throws {
        try Data((value.dumped() + "\n").utf8).write(to: url, options: .atomic)
    }

    func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
        let temp = state.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigError("could not write \(display(url))")
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        guard rename(temp.path, url.path) == 0 else { throw ConfigError("could not replace \(display(url))") }
    }

    func schemaURI(_ filename: String) -> String {
        // pathlib's as_uri percent-encodes everything except RFC 3986 unreserved characters and '/'.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        let path = defaults.appendingPathComponent(filename).path
        return "file://" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
    }

    func withGuide(_ data: ConfObject, schema: String, guide: [String]) -> ConfJSON {
        var result: ConfObject = ["$schema": .string(schemaURI(schema)), "_guide": .strings(guide)]
        for key in data.keys where key != "$schema" && key != "_guide" { result[key] = data[key] }
        return .object(result)
    }

    func initialize() throws -> [String] {
        var notes: [String] = []
        if !exists(connection) {
            let data = try defaultObject("connection")
            try write(withGuide(data, schema: "connection.schema.json", guide: Self.connectionGuide), to: connection)
            notes.append("created \(display(connection))")
        }
        if !exists(routes) {
            var data = try defaultObject("routes")
            if exists(oldDirect) {
                var rules = data["rules"]?.array ?? []
                let known = Set(rules.flatMap { $0.object?["domains"]?.strings ?? [] })
                var seen = known
                let extra = try readText(oldDirect).components(separatedBy: Self.lineBreaks).compactMap { line -> String? in
                    let site = pythonStrip(firstPart(line, before: "#")).lowercased()
                    let domain = site.hasPrefix("*.") ? String(site.dropFirst(2)) : site
                    return !domain.isEmpty && seen.insert(domain).inserted ? domain : nil
                }
                if !extra.isEmpty {
                    rules.append(.object(["name": .string("From direct.txt"), "route": .string("direct"), "domains": .strings(extra)]))
                    data["rules"] = .array(rules)
                    notes.append("moved \(extra.count) extra site(s) from direct.txt into routes.json")
                }
                let backup = state.appendingPathComponent("direct.txt.old")
                guard rename(oldDirect.path, backup.path) == 0 else { throw ConfigError("could not move direct.txt") }
            }
            try write(withGuide(data, schema: "routes.schema.json", guide: Self.routesGuide), to: routes)
            notes.append("created \(display(routes))")
        }
        for (url, schema, guide) in [(routes, "routes.schema.json", Self.routesGuide),
                                     (connection, "connection.schema.json", Self.connectionGuide)] {
            // An incomplete edit belongs to the user. Validation can report the parse error.
            guard let data = try? load(url).object else { continue }
            if data["_guide"] != .strings(guide) || data["$schema"] != .string(schemaURI(schema)) {
                try write(withGuide(data, schema: schema, guide: guide), to: url)
            }
        }
        return notes
    }

    private func defaultObject(_ name: String) throws -> ConfObject {
        let file = defaults.appendingPathComponent(name + ".default.json")
        guard let data = try load(file).object else { throw ConfigError("\(file.path): must be an object") }
        return data
    }

    static let lineBreaks = CharacterSet(charactersIn: "\n\r\u{b}\u{c}\u{1c}\u{1d}\u{1e}\u{85}\u{2028}\u{2029}")

    static let fixedDirect = [
        "127.0.0.1",
        "localhost",
        "*.local",
        "169.254.0.0/16",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "<local>",
    ]

    static let routesGuide = [
        "راهنما — این بخش رو vpn خودش به‌روز نگه می‌داره؛ دست نزن. قانون‌های خودت توی rules.",
        "هر سایتی که اینجا نیست از VPN می‌ره. پس معمولاً فقط چیزهایی رو می‌نویسی که نباید از VPN برن.",
        "",
        "هر قانون: { \"name\": اسم دلخواه, \"route\": راه, \"domains\": [...] و/یا \"hosts\": [...] }",
        "route:  vpn = از VPN ِ ما  ·  cisco = از Cisco وقتی وصله  ·  direct = هیچ‌وقت از VPN ِ ما نه",
        "without_cisco: فقط برای cisco — وقتی Cisco وصل نیست: \"direct\" (پیش‌فرض) یا \"vpn\"",
        "enabled: false → قانون موقتاً خاموش، بدون پاک کردن",
        "note: هر توضیحی برای خودت (JSON کامنت // نداره)",
        "",
        "domains — شکل نوشتن:",
        "  \"youtube.com\"      خود youtube.com و همهٔ زیردامنه‌هاش (www.youtube.com، m.youtube.com، …)",
        "  \"*.company.example\"   فقط زیردامنه‌ها (api.company.example، …)، نه خود company.example",
        "  \"*.ir\"  یا  \"ir\"     همهٔ دامنه‌های .ir",
        "  آدرس کامل هم قبوله و خودش تمیزش می‌کنه: \"https://www.youtube.com/watch?v=x\" ← youtube.com",
        "hosts — اسم دقیق، بدون زیردامنه: \"corp-mgmt01\" · \"192.168.1.5\" · \"10.0.0.0/8\"",
        "",
        "اگه یه سایت با چند قانون جور شد: hosts به domains می‌چربه، و بین domains دقیق‌ترین (طولانی‌ترین).",
        "دامنه‌های یه سایت رو پیدا کن:  vpn domains youtube   (و با --add vpn اضافه‌شون کن)",
        "بعد از ذخیره:  vpn apply   ·   یا ویرایش با  vpn config  که خودش چک و اعمال می‌کنه",
    ]

    static let connectionGuide = [
        "راهنما — این بخش رو vpn خودش به‌روز نگه می‌داره؛ دست نزن.",
        "relay: سرور ایران (relay) که تونل بهش وصل می‌شه — host، port (phone_vpn_relay_port)، user (phone_vpn_user)",
        "رمز اینجا نیست: توی Keychain ِ مکه (سرویس vpnuser-relay). پاک کردنش: vpn forget",
        "local_socks_port: proxy ِ محلی کجا گوش بده (پیش‌فرض 1080)",
        "keepalive: هر interval_seconds چک می‌کنه؛ max_missed بار بی‌جواب = قطع و وصل دوباره",
        "بعد از ذخیره:  vpn apply  — اگه وصلی، یه بار قطع و وصل می‌شه",
    ]

}

func pythonStrip(_ text: String) -> String {
    var scalars = text.unicodeScalars[...]
    func whitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1c...0x1f).contains(scalar.value)
    }
    while let first = scalars.first, whitespace(first) { scalars.removeFirst() }
    while let last = scalars.last, whitespace(last) { scalars.removeLast() }
    return String(scalars)
}

func firstPart(_ value: String, before separator: Unicode.Scalar) -> String {
    String(value.unicodeScalars.prefix { $0 != separator })
}

func hostOf(_ site: String) -> String {
    var host = pythonStrip(site).lowercased()
    if let scheme = host.range(of: "://", options: .literal) { host = String(host[scheme.upperBound...]) }
    host = firstPart(firstPart(host, before: "/"), before: "?")
    if let user = host.unicodeScalars.lastIndex(of: "@") {
        host = String(host.unicodeScalars[host.unicodeScalars.index(after: user)...])
    }
    return firstPart(host, before: ":")
}

func shellQuote(_ value: String) -> String {
    if !value.isEmpty, value.range(of: #"\A[A-Za-z0-9_@%+=:,./-]+\z"#, options: .regularExpression) != nil {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

