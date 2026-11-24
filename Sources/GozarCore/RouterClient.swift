import Foundation

public struct RouterClient: Sendable {
    private let paths: StatePaths
    private let session: URLSession
    private static let noRedirect = NoRedirect()

    public init(paths: StatePaths = .resolve(), session: URLSession? = nil) {
        self.paths = paths
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            self.session = URLSession(configuration: configuration)
        }
    }

    public func status() async throws -> RouterStatus {
        try await get("/v1/status")
    }

    public func connections(limit: Int = 300) async throws -> [ConnStat] {
        try await get("/v1/connections", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    public func domains(window: Int = 600) async throws -> [DomainStat] {
        try await get("/v1/domains", query: [URLQueryItem(name: "window", value: String(window))])
    }

    public func check(host: String) async throws -> RouteCheck {
        try await get("/v1/check", query: [URLQueryItem(name: "host", value: host)])
    }

    public func reload() async throws {
        var request = try request("/v1/reload")
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request, delegate: Self.noRedirect)
        try Self.validate(response, expected: 204)
    }

    public func events() -> AsyncThrowingStream<RouterEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(512)) { continuation in
            let task = Task {
                do {
                    var request = try request("/v1/events")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: request, delegate: Self.noRedirect)
                    defer { bytes.task.cancel() }
                    try Self.validate(response)

                    var parser = RouterEventParser()
                    var line: [UInt8] = []
                    var followsCR = false
                    // Empty lines delimit events, so preserve them when splitting the stream.
                    for try await byte in bytes {
                        if byte == 10, followsCR {
                            followsCR = false
                            continue
                        }
                        followsCR = byte == 13
                        guard byte == 10 || byte == 13 else {
                            line.append(byte)
                            continue
                        }
                        let event = try parser.consume(String(decoding: line, as: UTF8.self))
                        line.removeAll(keepingCapacity: true)
                        guard let event else { continue }
                        switch continuation.yield(event) {
                        case .enqueued: break
                        case .dropped: throw ClientError.slowConsumer
                        case .terminated: return
                        @unknown default: return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func get<Value: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Value {
        let request = try request(path, query: query)
        let (data, response) = try await session.data(for: request, delegate: Self.noRedirect)
        try Self.validate(response)
        return try ControlAPI.makeDecoder().decode(Value.self, from: data)
    }

    private func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        let info = try ControlAPI.makeDecoder().decode(RouterInfo.self, from: Data(contentsOf: paths.routerInfo))
        guard (1024...65_535).contains(info.controlPort) else { throw ClientError.badPort }

        let token = try String(contentsOf: paths.routerToken, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count == 64, token.utf8.allSatisfy(Self.isHexDigit) else { throw ClientError.badToken }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = info.controlPort
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ClientError.badPort }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func validate(_ response: URLResponse, expected: Int = 200) throws {
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard response.statusCode == expected else { throw ClientError.httpStatus(response.statusCode) }
    }

    private enum ClientError: LocalizedError {
        case badPort, badToken, invalidResponse, httpStatus(Int), slowConsumer

        var errorDescription: String? {
            switch self {
            case .badPort: return "Invalid control port in router.json"
            case .badToken: return "Invalid format in router.token"
            case .invalidResponse: return "Expected an HTTP response from the router"
            case .httpStatus(let code): return "Router returned HTTP \(code)"
            case .slowConsumer: return "Router event consumer fell behind"
            }
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

struct RouterEventParser {
    private var name = ""
    private var data: [String] = []
    private let decoder = ControlAPI.makeDecoder()

    mutating func consume(_ line: String) throws -> RouterEvent? {
        if line.isEmpty {
            defer {
                name = ""
                data.removeAll(keepingCapacity: true)
            }
            guard !data.isEmpty else { return nil }
            let payload = Data(data.joined(separator: "\n").utf8)
            switch name {
            case "open": return .open(try decoder.decode(ConnStat.self, from: payload))
            case "close": return .close(try decoder.decode(ConnStat.self, from: payload))
            case "tick": return .tick(try decoder.decode(Tick.self, from: payload))
            default: return nil
            }
        }

        let field = line.prefix { $0 != ":" }
        var value = line.dropFirst(field.count)
        if value.first == ":" { value.removeFirst() }
        if value.first == " " { value.removeFirst() }
        switch field {
        case "event": name = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }
}
