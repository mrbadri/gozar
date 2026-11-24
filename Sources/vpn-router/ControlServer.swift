import Foundation
import GozarCore
import Network

final class ControlServer {
    let state: RouterState
    private let token: String
    private let encoder = ControlAPI.makeEncoder()
    private var streams: [ObjectIdentifier: ControlSession] = [:]

    init(state: RouterState, token: String) {
        self.state = state
        self.token = token
    }

    func accept(_ connection: NWConnection) {
        state.queue.async { [self] in
            ControlSession(connection: connection, server: self).start()
        }
    }

    func handle(_ request: RouterHTTPRequest, session: ControlSession) {
        guard request.isAuthorized(token: token) else {
            session.respond("401 Unauthorized", headers: "WWW-Authenticate: Bearer\r\n")
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/status"):
            json(state.status(), session: session)
        case ("GET", "/v1/connections"):
            let limit = min(2000, max(0, request.parameter("limit").flatMap(Int.init) ?? 300))
            json(state.connections(limit: limit), session: session)
        case ("GET", "/v1/domains"):
            let window = max(0, request.parameter("window").flatMap(Int.init) ?? 600)
            json(state.domains(window: window), session: session)
        case ("GET", "/v1/check"):
            guard let host = request.parameter("host"), !host.isEmpty, host.utf8.count <= 255,
                  host.unicodeScalars.allSatisfy({
                      !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
                  }) else {
                session.respond("400 Bad Request")
                return
            }
            json(state.check(host), session: session)
        case ("POST", "/v1/reload"):
            guard !request.hasBody else {
                session.respond("400 Bad Request")
                return
            }
            state.reload()
            session.respond("204 No Content")
        case ("GET", "/v1/events"):
            guard streams.count < 8 else {
                session.respond("503 Service Unavailable")
                return
            }
            streams[ObjectIdentifier(session)] = session
            session.stream()
        default:
            session.respond("404 Not Found")
        }
    }

    func remove(_ session: ControlSession) {
        streams.removeValue(forKey: ObjectIdentifier(session))
    }

    func emit(_ event: RouterEvent) {
        guard !streams.isEmpty else { return }
        switch event {
        case .open(let stat): emit("open", stat)
        case .close(let stat): emit("close", stat)
        case .tick(let tick): emit("tick", tick)
        }
    }

    func ping() { broadcast(Data(": ping\n\n".utf8)) }

    private func broadcast(_ bytes: Data) {
        for session in streams.values { session.enqueue(bytes) }
    }

    private func emit(_ name: String, _ value: some Encodable) {
        guard let data = try? encoder.encode(value) else {
            RouterLog.logger.error("Could not encode router event")
            return
        }
        var frame = Data("event: \(name)\ndata: ".utf8)
        frame.append(data)
        frame.append(contentsOf: [10, 10])
        broadcast(frame)
    }

    private func json(_ value: some Encodable, session: ControlSession) {
        do {
            session.respond("200 OK", headers: "Content-Type: application/json\r\n", body: try encoder.encode(value))
        } catch {
            RouterLog.logger.error("Could not encode router response")
            session.respond("500 Internal Server Error")
        }
    }
}

final class ControlSession {
    private let connection: NWConnection
    private let server: ControlServer
    private let timer: DispatchSourceTimer
    private var head = Data()
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var writing = false
    private var stopped = false

    init(connection: NWConnection, server: ControlServer) {
        self.connection = connection
        self.server = server
        timer = DispatchSource.makeTimerSource(queue: server.state.queue)
    }

    func start() {
        timer.setEventHandler { [weak self] in self?.stop() }
        timer.schedule(deadline: .now() + .seconds(10))
        timer.resume()
        connection.stateUpdateHandler = { [self] status in
            switch status {
            case .ready: readHead()
            case .failed, .cancelled: stop()
            default: break
            }
        }
        connection.start(queue: server.state.queue)
    }

    private func readHead() {
        let remaining = RouterHTTPRequest.maxHeadBytes - head.count
        guard remaining > 0 else { respond("431 Request Header Fields Too Large"); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(4096, remaining)) { [weak self] data, _, eof, error in
            guard let self, !stopped else { return }
            if error != nil { stop(); return }
            let searchStart = max(0, head.count - RouterHTTPRequest.terminator.count + 1)
            if let data { head.append(data) }
            if let end = head.range(of: RouterHTTPRequest.terminator, in: searchStart..<head.count) {
                let request = RouterHTTPRequest(Data(head.prefix(end.upperBound)))
                head = Data()
                if let request { server.handle(request, session: self) }
                else { respond("400 Bad Request") }
            } else if eof {
                stop()
            } else {
                readHead()
            }
        }
    }

    func respond(_ status: String, headers: String = "", body: Data = Data()) {
        timer.schedule(deadline: .now() + .seconds(10))
        let length = status == "204 No Content" ? "" : "Content-Length: \(body.count)\r\n"
        var bytes = Data("HTTP/1.1 \(status)\r\nConnection: close\r\n\(headers)\(length)\r\n".utf8)
        bytes.append(body)
        connection.send(content: bytes, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.stop() })
    }

    func stream() {
        enqueue(Data(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n").utf8))
        // An SSE client sends nothing after the request. A read detects disconnects while idle.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in self?.stop() }
    }

    func enqueue(_ bytes: Data) {
        guard !stopped else { return }
        guard pending.count < 512, pendingBytes + bytes.count <= 1024 * 1024 else { stop(); return }
        pending.append(bytes)
        pendingBytes += bytes.count
        flush()
    }

    private func flush() {
        guard !writing, !pending.isEmpty else { return }
        writing = true
        let bytes = pending.removeFirst()
        timer.schedule(deadline: .now() + .seconds(5))
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self, !stopped else { return }
            if error != nil { stop(); return }
            timer.schedule(deadline: .distantFuture)
            writing = false
            pendingBytes -= bytes.count
            flush()
        })
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        timer.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.removeAll()
        server.remove(self)
    }
}
