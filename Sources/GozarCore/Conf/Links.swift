import Darwin
import Foundation

enum LinkProtocol: String, Sendable {
    case vless, vmess, trojan, ss
}

struct ParsedLink {
    struct Identity: Hashable {
        let kind: LinkProtocol
        let address: String
        let port: Int
        let credential: String
    }

    let identity: Identity
    let name: String
    let outbound: ConfJSON

    var kind: LinkProtocol { identity.kind }
    var address: String { identity.address }
    var port: Int { identity.port }

    init(_ link: String) throws {
        guard let scheme = link.range(of: "://"),
              let kind = LinkProtocol(rawValue: link[..<scheme.lowerBound].lowercased()) else {
            throw ConfigError("link protocol must be vless, vmess, trojan or ss")
        }
        let payload = String(link[scheme.upperBound...])
        let server: LinkServer
        var fields: [String: String]
        var credential: String
        var protocolSettings: ConfObject

        switch kind {
        case .vmess:
            guard let bytes = Self.decodeBase64(payload), let text = String(data: bytes, encoding: .utf8),
                  let object = try? ConfJSON(parsing: text).object else { throw Self.invalid(kind, "base64 JSON") }
            server = try LinkServer(kind, host: object["add"]?.string, port: object["port"]?.string ?? object["port"]?.int.map(String.init),
                                    name: object["ps"]?.string)
            credential = try Self.uuid(object["id"]?.string, kind: kind, field: "id")
            let alterID = object["aid"]?.int ?? object["aid"]?.string.flatMap(Int.init)
            if let aid = object["aid"], aid.string != "", alterID.map({ (0...65535).contains($0) }) != true {
                throw Self.invalid(kind, "aid")
            }
            let security = object["tls"]?.string ?? ""
            fields = [
                "security": security.isEmpty ? "none" : security,
                "type": object["net"]?.string ?? "tcp",
                "headerType": object["type"]?.string ?? "none",
            ]
            for key in ["host", "path", "sni", "alpn", "fp"] { fields[key] = object[key]?.string }
            if fields["type"] == "grpc" { fields["serviceName"] = fields["path"] }
            protocolSettings = ["id": .string(credential), "alterId": .int(alterID ?? 0),
                                "security": .string(nonempty(object["scy"]?.string) ?? "auto")]
        case .ss:
            let parts = payload.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let main = String(parts[0])
            let name = try parts.dropFirst().first.map { try Self.percentDecode(String($0), kind: kind, field: "name") }
            let source: String
            let hasAuthority = firstPart(main, before: "?").contains("@")
            if hasAuthority {
                source = main
            } else {
                let encoded = try Self.percentDecode(firstPart(main, before: "?"), kind: kind, field: "credentials")
                guard let bytes = Self.decodeBase64(encoded), let decoded = String(data: bytes, encoding: .utf8) else {
                    throw Self.invalid(kind, "credentials")
                }
                source = decoded
            }
            let authority = hasAuthority ? firstPart(source, before: "?") : source
            guard let at = authority.lastIndex(of: "@") else { throw Self.invalid(kind, "address") }
            let endpoint = String(source[source.index(after: at)...])
            server = try LinkServer(kind, endpoint: endpoint, name: name)
            if server.query["plugin"].flatMap(nonempty) != nil { throw Self.invalid(kind, "plugin (unsupported)") }
            let raw = String(source[..<at])
            let decoded: String
            if hasAuthority {
                let value = try Self.percentDecode(raw, kind: kind, field: "credentials")
                if value.contains(":") { decoded = value }
                else if let bytes = Self.decodeBase64(value), let text = String(data: bytes, encoding: .utf8) { decoded = text }
                else { throw Self.invalid(kind, "credentials") }
            } else {
                decoded = raw
            }
            let credentials = decoded.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let method = credentials.first, Self.ssMethods.contains(method.lowercased()) else {
                throw Self.invalid(kind, "method")
            }
            guard credentials.count == 2, !credentials[1].isEmpty else { throw Self.invalid(kind, "password") }
            credential = String(credentials[1])
            fields = [:]
            protocolSettings = ["method": .string(method.lowercased()), "password": .string(credential)]
        case .vless, .trojan:
            let boundary = payload.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? payload.endIndex
            let authority = payload[..<boundary]
            guard let at = authority.lastIndex(of: "@") else { throw Self.invalid(kind, kind == .vless ? "uuid" : "password") }
            let field = kind == .vless ? "uuid" : "password"
            credential = try Self.percentDecode(String(authority[..<at]), kind: kind, field: field)
            guard !credential.isEmpty else { throw Self.invalid(kind, field) }
            server = try LinkServer(kind, endpoint: String(payload[payload.index(after: at)...]))
            fields = server.query
            if kind == .vless {
                credential = try Self.uuid(credential, kind: kind, field: field)
                protocolSettings = ["id": .string(credential), "encryption": .string(nonempty(fields["encryption"]) ?? "none")]
                if let flow = nonempty(fields["flow"]) {
                    guard ["xtls-rprx-vision", "xtls-rprx-vision-udp443"].contains(flow) else { throw Self.invalid(kind, "flow") }
                    protocolSettings["flow"] = .string(flow)
                }
            } else {
                protocolSettings = ["password": .string(credential)]
                fields["security"] = fields["security"] ?? "tls"
            }
        }

        protocolSettings["address"] = .string(server.address)
        protocolSettings["port"] = .int(server.port)
        let transport = try Self.stream(kind, fields: fields)
        identity = Identity(kind: kind, address: server.address, port: server.port, credential: credential)
        let host = server.address.contains(":") ? "[\(server.address)]" : server.address
        name = nonempty(server.name) ?? "\(host):\(server.port)"
        outbound = .object([
            "tag": .string("exit"),
            "protocol": .string(kind == .ss ? "shadowsocks" : kind.rawValue),
            "settings": .object(protocolSettings),
            "streamSettings": .object(transport),
        ])
    }

    func configuration(port: Int) throws -> Data {
        guard (1...65535).contains(port) else { throw ConfigError("port must be between 1 and 65535") }
        let configuration: ConfJSON = .object([
            "log": .object(["loglevel": .string("warning")]),
            "inbounds": .array([.object([
                "tag": .string("socks-in"), "listen": .string("127.0.0.1"), "port": .int(port),
                "protocol": .string("socks"), "settings": .object(["auth": .string("noauth"), "udp": .bool(false)]),
            ])]),
            "outbounds": .array([outbound]),
            "routing": .object(["rules": .array([.object([
                "type": .string("field"), "inboundTag": .strings(["socks-in"]), "outboundTag": .string("exit"),
            ])])]),
        ])
        return Data((configuration.dumped() + "\n").utf8)
    }

    private static func stream(_ kind: LinkProtocol, fields: [String: String]) throws -> ConfObject {
        let network = nonempty(fields["type"])?.lowercased() ?? "tcp"
        let security = nonempty(fields["security"])?.lowercased() ?? "none"
        let host = nonempty(fields["host"])
        let path = nonempty(fields["path"])
        let mode = nonempty(fields["mode"])
        let csv: (String) -> [String] = { $0.split(separator: ",").map { pythonStrip(String($0)) }.filter { !$0.isEmpty } }
        var stream: ConfObject = ["network": .string(network), "security": .string(security)]

        switch network {
        case "tcp":
            let header = nonempty(fields["headerType"]) ?? "none"
            if header == "http" {
                var request: ConfObject = [:]
                if let path { request["path"] = .strings(csv(path)) }
                if let host { request["headers"] = .object(["Host": .strings(csv(host))]) }
                stream["tcpSettings"] = .object(["header": .object(["type": .string("http"), "request": .object(request)])])
            } else if header != "none" {
                throw invalid(kind, "headerType")
            }
        case "ws", "httpupgrade", "xhttp":
            var transport: ConfObject = ["path": .string(path ?? "/")]
            if let host { transport["host"] = .string(host) }
            if network == "xhttp", let mode {
                guard ["auto", "packet-up", "stream-up", "stream-one"].contains(mode) else { throw invalid(kind, "mode") }
                transport["mode"] = .string(mode)
            }
            stream[network + "Settings"] = .object(transport)
        case "grpc":
            var transport: ConfObject = ["serviceName": .string(fields["serviceName"] ?? "")]
            if let host { transport["authority"] = .string(host) }
            if let mode {
                guard ["gun", "multi"].contains(mode) else { throw invalid(kind, "mode") }
                transport["multiMode"] = .bool(mode == "multi")
            }
            stream["grpcSettings"] = .object(transport)
        default:
            throw invalid(kind, "type")
        }

        switch security {
        case "none": break
        case "tls":
            var tls: ConfObject = [:]
            if let sni = nonempty(fields["sni"]) { tls["serverName"] = .string(sni) }
            if let fp = nonempty(fields["fp"]) { tls["fingerprint"] = .string(fp) }
            if let alpn = nonempty(fields["alpn"]) { tls["alpn"] = .strings(csv(alpn)) }
            stream["tlsSettings"] = .object(tls)
        case "reality":
            guard ["tcp", "grpc", "xhttp"].contains(network) else { throw invalid(kind, "type for REALITY") }
            guard let publicKey = fields["pbk"].flatMap(decodeBase64), publicKey.count == 32 else {
                throw invalid(kind, "pbk")
            }
            let rawKey = publicKey.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            var reality: ConfObject = [
                "password": .string(rawKey), "fingerprint": .string(nonempty(fields["fp"]) ?? "chrome"),
            ]
            if let sni = nonempty(fields["sni"]) { reality["serverName"] = .string(sni) }
            if let sid = fields["sid"] {
                guard sid.count <= 16, sid.count.isMultiple(of: 2),
                      sid.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
                else { throw invalid(kind, "sid") }
                reality["shortId"] = .string(sid)
            }
            if let spx = fields["spx"] { reality["spiderX"] = .string(spx) }
            stream["realitySettings"] = .object(reality)
        default:
            throw invalid(kind, "security")
        }
        return stream
    }

    private static let ssMethods: Set<String> = [
        "aes-128-gcm", "aead_aes_128_gcm", "aes-256-gcm", "aead_aes_256_gcm",
        "chacha20-poly1305", "aead_chacha20_poly1305", "chacha20-ietf-poly1305",
        "xchacha20-poly1305", "aead_xchacha20_poly1305", "xchacha20-ietf-poly1305",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
    ]

    static func invalid(_ kind: LinkProtocol, _ field: String) -> ConfigError {
        ConfigError("\(kind.rawValue) link: invalid or missing \(field)")
    }

    static func percentDecode(_ text: String, kind: LinkProtocol, field: String) throws -> String {
        guard let value = text.removingPercentEncoding else { throw invalid(kind, field) }
        return value
    }

    static func decodeBase64(_ input: String) -> Data? {
        var text = input.unicodeScalars.filter { !$0.properties.isWhitespace }.map(String.init).joined()
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = text.utf8.count % 4
        if remainder == 1 { return nil }
        if remainder != 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text)
    }

    private static func uuid(_ raw: String?, kind: LinkProtocol, field: String) throws -> String {
        guard let raw, let uuid = UUID(uuidString: raw) else { throw invalid(kind, field) }
        return uuid.uuidString.lowercased()
    }
}

private struct LinkServer {
    let address: String
    let port: Int
    let name: String?
    var query: [String: String] = [:]

    init(_ kind: LinkProtocol, host: String?, port: String?, name: String?) throws {
        guard let host = host.flatMap(normalizedExitHost) else { throw ParsedLink.invalid(kind, "host") }
        guard let port = port.flatMap(exitPort) else { throw ParsedLink.invalid(kind, "port") }
        self.address = host
        self.port = port
        self.name = name
    }

    init(_ kind: LinkProtocol, endpoint: String, name override: String? = nil) throws {
        let hash = endpoint.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let pieces = hash[0].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let authority = String(pieces[0].hasSuffix("/") ? pieces[0].dropLast() : pieces[0])
        let hostPort: (host: String, port: String?)
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { throw ParsedLink.invalid(kind, "host") }
            let suffix = authority[authority.index(after: close)...]
            hostPort = (String(authority[...close]), suffix.hasPrefix(":") ? String(suffix.dropFirst()) : nil)
        } else {
            let components = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            hostPort = (String(components[0]), components.count == 2 ? String(components[1]) : nil)
        }
        let name = try override ?? hash.dropFirst().first.map { try ParsedLink.percentDecode(String($0), kind: kind, field: "name") }
        try self.init(kind, host: hostPort.host, port: hostPort.port, name: name)
        for pair in pieces.dropFirst().first?.split(separator: "&") ?? [] {
            let item = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = try ParsedLink.percentDecode(String(item[0]), kind: kind, field: "query name")
            let field = ["encryption", "flow", "security", "sni", "fp", "alpn", "pbk", "sid", "spx", "type",
                         "headerType", "host", "path", "serviceName", "mode", "plugin"].contains(key) ? key : "query value"
            let value = try ParsedLink.percentDecode(String(item.dropFirst().first ?? ""), kind: kind, field: field)
            query[key] = query[key] ?? value
        }
    }
}

func nonempty(_ text: String?) -> String? {
    text.flatMap { $0.isEmpty ? nil : $0 }
}

func normalizedExitHost(_ host: String) -> String? {
    var text = host
    if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
    if text.contains(":") {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        var canonical = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &canonical, socklen_t(canonical.count)) != nil else { return nil }
        return String(cString: canonical)
    }
    guard text.utf8.count <= 253,
          text.range(of: #"\A[A-Za-z0-9_](?:[A-Za-z0-9_.-]*[A-Za-z0-9_.])?\z"#, options: .regularExpression) != nil,
          !text.contains("..") else { return nil }
    return text.lowercased()
}

func exitPort(_ raw: String) -> Int? {
    guard raw.utf8.allSatisfy({ (48...57).contains($0) }), let port = Int(raw), (1...65535).contains(port) else { return nil }
    return port
}

