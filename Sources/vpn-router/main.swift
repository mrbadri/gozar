import Darwin
import Foundation
import GozarCore
import Network
import Security

private struct Options {
    let store: ConfigStore
    let listen: UInt16
    let upstream: UInt16
    let control: UInt16
    let relay: SocksWire.Destination
    let runProbes: Bool

    init(_ args: [String]) throws {
        var values: [String: String] = [:]
        var probes = true
        var arguments = args.makeIterator()
        while let argument = arguments.next() {
            if argument == "--no-probes" {
                probes = false
                continue
            }
            guard ["--state", "--listen-port", "--upstream-port", "--control-port"].contains(argument),
                  values[argument] == nil, let value = arguments.next(),
                  !value.isEmpty, !value.hasPrefix("--") else {
                throw ConfigError("Usage: vpn-router [--state DIR] [--listen-port N] [--upstream-port N] [--control-port N] [--no-probes]")
            }
            values[argument] = value
        }
        let paths = values["--state"].map { StatePaths(stateDir: URL(fileURLWithPath: $0, isDirectory: true)) }
            ?? StatePaths.resolve()
        store = ConfigStore(paths: paths)
        let file = try store.loadConnection()
        func port(_ name: String, _ fallback: Int) throws -> UInt16 {
            guard let value = values[name] else { return UInt16(fallback) }
            guard let number = UInt16(value), number >= 1024 else {
                throw ConfigError("\(name) must be between 1024 and 65535")
            }
            return number
        }
        listen = try port("--listen-port", file.localSocksPort)
        upstream = try port("--upstream-port", file.router.upstreamPort)
        control = try port("--control-port", file.router.controlPort)
        guard Set([listen, upstream, control]).count == 3 else {
            throw ConfigError("Listen, upstream, and control ports must be distinct")
        }
        relay = SocksWire.Destination(host: file.relayHost, port: UInt16(file.relayPort))
        runProbes = probes
    }
}

private final class Router {
    private let queue = DispatchQueue(label: "ir.mrbadri.gozar.router.listeners")
    private let ciscoQueue = DispatchQueue(label: "ir.mrbadri.gozar.router.cisco")
    private let options: Options
    private let log: RouterLog
    private let token: String
    private let state: RouterState
    private let control: ControlServer
    private let sockets: NWListener
    private let http: NWListener
    private var ready = Set<UInt16>()
    private var published = false
    private var timers: [DispatchSourceTimer] = []
    private var signals: [DispatchSourceSignal] = []

    init(options: Options) throws {
        self.options = options
        log = RouterLog(path: options.store.paths.routerLog)
        token = try Self.makeToken()
        state = try RouterState(store: options.store, log: log, listenPort: options.listen, upstreamPort: options.upstream)
        control = ControlServer(state: state, token: token)
        sockets = try loopbackListener(port: options.listen)
        http = try loopbackListener(port: options.control)
    }

    func run() -> Never {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [self] in stop(0) }
            signals.append(source)
            source.resume()
        }
        sockets.newConnectionHandler = { [self] connection in
            guard published else { connection.cancel(); return }
            SocksSession(client: connection, state: state, upstreamPort: options.upstream).start()
        }
        http.newConnectionHandler = { [self] connection in
            guard published else { connection.cancel(); return }
            control.accept(connection)
        }
        start(sockets, port: options.listen)
        start(http, port: options.control)
        dispatchMain()
    }

    private func start(_ listener: NWListener, port: UInt16) {
        listener.stateUpdateHandler = { [self] status in
            switch status {
            case .ready:
                ready.insert(port)
                if ready.count == 2, !published {
                    do { try publish() }
                    catch { stop(1, error.localizedDescription) }
                }
            case .waiting(let error), .failed(let error):
                stop(1, "Cannot listen on 127.0.0.1:\(port): \(error)")
            default: break
            }
        }
        listener.start(queue: queue)
    }

    private func publish() throws {
        timers.append(options.store.watch { [state] in state.queue.async { state.reload() } })
        state.queue.sync {
            state.reload()
            state.onEvent = { [weak control] in control?.emit($0) }
        }
        try Self.writeToken(token, to: options.store.paths.routerToken)
        let info = RouterInfo(controlPort: Int(options.control), pid: Int(getpid()), startedAt: state.startedAt)
        try ControlAPI.makeEncoder().encode(info).write(to: options.store.paths.routerInfo, options: .atomic)
        published = true
        state.queue.sync { log.started(at: state.startedAt) }
        schedule(on: state.queue, in: 1, every: 1) { [state] in state.tick() }
        schedule(on: state.queue, in: 15, every: 15) { [control] in control.ping() }
        schedule(on: ciscoQueue, in: 0, every: 3) { [state] in
            let up = Self.ciscoIsUp()
            state.queue.async { state.setCisco(up) }
        }
        if options.runProbes {
            let probes = state.queue.sync {
                RouterProbes(state: state, relay: options.relay, upstreamPort: options.upstream)
            }
            schedule(on: state.queue, in: 0, every: 10) { probes.sample() }
        }
    }

    private func schedule(on queue: DispatchQueue, in delay: Int, every interval: Int, action: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(delay), repeating: .seconds(interval))
        timer.setEventHandler(handler: action)
        timers.append(timer)
        timer.resume()
    }

    private func stop(_ code: Int32, _ error: String? = nil) -> Never {
        if published { try? FileManager.default.removeItem(at: options.store.paths.routerInfo) }
        if let error { writeError(error) }
        exit(code)
    }

    private static func ciscoIsUp() -> Bool {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let commands = Data("show State:/Network/Service/com.cisco.anyconnect/Proxies\n".utf8)
            try input.fileHandleForWriting.write(contentsOf: commands)
            try input.fileHandleForWriting.close()
            let reply = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            return String(decoding: reply, as: UTF8.self).contains("<dictionary>")
        } catch {
            return false
        }
    }

    private static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ConfigError("Could not generate router token") }
        return bytes.map { String(format: "%02x", Int($0)) }.joined()
    }

    private static func writeToken(_ token: String, to path: URL) throws {
        // Rename a private file so the token is never published with default permissions.
        var template = (path.path + ".XXXXXX").utf8CString
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { throw ConfigError("Could not create router.token") }
        let temporaryPath = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { unlink(temporaryPath) }
        guard fchmod(descriptor, 0o600) == 0 else { throw ConfigError("Could not secure router.token") }
        try file.write(contentsOf: Data((token + "\n").utf8))
        try file.close()
        guard rename(temporaryPath, path.path) == 0 else { throw ConfigError("Could not publish router.token") }
    }
}

private func writeError(_ error: String) {
    let line = "vpn-router: \(error)"
    RouterLog.logger.error("\(line, privacy: .private)")
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

do {
    try Router(options: Options(Array(CommandLine.arguments.dropFirst()))).run()
} catch {
    writeError(error.localizedDescription)
    exit(1)
}
