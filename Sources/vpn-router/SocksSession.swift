import Foundation
import GozarCore
import Network

final class SocksSession {
    private enum Phase { case greeting, dialing, replying, rejecting, splicing, done }

    private let client: NWConnection
    private let queue = DispatchQueue(label: "ir.mrbadri.gozar.router.connection")
    private let state: RouterState
    private let upstreamPort: UInt16
    private let acceptedAt = Date()
    private let acceptedTime = DispatchTime.now()
    private let traffic = TrafficCounter()
    private var outbound: NWConnection?
    private var deadline: DispatchSourceTimer?
    private var phase = Phase.greeting
    private var version = SocksWire.Version.five
    private var stat: ConnStat?
    private var upstreamReady = false
    private var completedDirections = 0

    init(client: NWConnection, state: RouterState, upstreamPort: UInt16) {
        self.client = client
        self.state = state
        self.upstreamPort = upstreamPort
    }

    func start() {
        // The client handler owns the session until finish() breaks the cycle.
        client.stateUpdateHandler = { [self] status in
            switch status {
            case .ready: readVersion()
            case .failed(let error): connectionFailed(error, side: "Client")
            case .cancelled: finish("Client connection cancelled")
            default: break
            }
        }
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: acceptedTime + .seconds(30))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if phase == .dialing {
                    // Give the timeout reply a short, bounded write deadline as well.
                    deadline?.schedule(deadline: .now() + .seconds(1))
                    failDial(TransportFailure(message: "Connection timed out"))
                } else {
                    finish("Handshake timed out")
                }
            }
            deadline = timer
            timer.resume()
            client.start(queue: queue)
        }
    }

    private func readVersion() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] bytes, _, _, error in
            guard let self, phase == .greeting else { return }
            if let error { finish(error.localizedDescription); return }
            switch bytes?.first {
            case 5: readGreeting()
            case 4:
                version = .four
                readRequest(prefix: [4])
            case .some: rejectGreeting()
            case nil: finish(nil)
            }
        }
    }

    private func readGreeting() {
        readFrame(client, prefix: [5], parse: SocksWire.greeting) { [weak self] result in
            guard let self, phase == .greeting else { return }
            switch result {
            case .success(.value):
                client.send(content: Data([5, 0]), completion: .contentProcessed { [weak self] error in
                    guard let self, phase == .greeting else { return }
                    if let error { finish(error.localizedDescription); return }
                    readRequest()
                })
            case .success(.reject): rejectGreeting()
            case .failure(let error): finish(error.localizedDescription)
            case .success(.need): preconditionFailure("Incomplete SOCKS greeting")
            }
        }
    }

    private func rejectGreeting() {
        phase = .rejecting
        client.send(content: Data([5, 0xff]), completion: .contentProcessed { [weak self] _ in self?.finish(nil) })
    }

    private func readRequest(prefix: [UInt8] = []) {
        let parser = version == .four ? SocksWire.request4 : SocksWire.request
        readFrame(client, prefix: prefix, parse: parser) { [weak self] result in
            guard let self, phase == .greeting else { return }
            switch result {
            case .success(.value(let destination)): dial(destination)
            case .success(.reject(let code)): sendFailure(code: code, error: "SOCKS request rejected")
            case .failure(let error): finish(error.localizedDescription)
            case .success(.need): preconditionFailure("Incomplete SOCKS request")
            }
        }
    }

    private func dial(_ destination: SocksWire.Destination) {
        phase = .dialing
        let entry = state.queue.sync { state.register(destination, at: acceptedAt, traffic: traffic) }
        stat = entry
        let vpn = entry.route == .vpn
        let endpoint = vpn ? SocksWire.Destination(host: "127.0.0.1", port: upstreamPort) : destination
        let remote = makeConnection(endpoint)
        outbound = remote
        remote.stateUpdateHandler = { [weak self, weak remote] status in
            guard let self, let remote else { return }
            switch status {
            case .ready:
                guard phase == .dialing else { return }
                if vpn {
                    upstreamReady = true
                    state.queue.async { [state] in state.setUpstream(true) }
                    connectThroughSocks(remote, to: destination) { [weak self] error in
                        guard let self, phase == .dialing else { return }
                        if let error { failDial(error) }
                        else { connected(id: entry.id) }
                    }
                } else {
                    connected(id: entry.id)
                }
            case .failed(let error):
                if phase == .dialing { failDial(error) }
                else if phase == .replying || phase == .splicing { connectionFailed(error, side: "Outbound") }
            case .waiting(let error):
                // Once connected, let the active TCP I/O report whether a path change breaks the stream.
                if phase == .dialing { failDial(error) }
            case .cancelled:
                if phase == .dialing { failDial(TransportFailure(message: "Outbound connection cancelled")) }
                else if phase == .replying || phase == .splicing { finish("Outbound connection cancelled") }
            default: break
            }
        }
        remote.start(queue: queue)
    }

    private func connectionFailed(_ error: NWError, side: String) {
        let detail = "\(side) connection: \(error)"
        if phase == .splicing, error == .posix(.ENETDOWN) {
            // Network.framework can report ENETDOWN before delivering the final TCP EOF callbacks.
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in self?.finish(detail) }
        } else {
            finish(detail)
        }
    }

    private func failDial(_ error: Error) {
        guard phase == .dialing, let stat else { return }
        if stat.route == .vpn, !upstreamReady {
            state.queue.async { [state] in state.setUpstream(false) }
        }
        let reply = connectionReply(for: error)
        sendFailure(code: stat.route == .vpn && reply != 5 ? 1 : reply, error: error.localizedDescription)
    }

    private func sendFailure(code: UInt8, error: String) {
        phase = .rejecting
        outbound?.stateUpdateHandler = nil
        outbound?.cancel()
        client.send(content: SocksWire.reply(version, code: code), completion: .contentProcessed { [weak self] _ in
            self?.finish(error)
        })
    }

    private func connected(id: Int) {
        phase = .replying
        let ms = elapsedMilliseconds(since: acceptedTime)
        state.queue.async { [state] in state.opened(id: id, connectMs: ms) }
        client.send(content: SocksWire.reply(version, code: 0), completion: .contentProcessed { [weak self] error in
            guard let self, phase == .replying, let outbound else { return }
            if let error { finish(error.localizedDescription); return }
            phase = .splicing
            deadline?.cancel()
            deadline = nil
            splice(from: client, to: outbound, upload: true)
            splice(from: outbound, to: client, upload: false)
        })
    }

    private func splice(from source: NWConnection, to destination: NWConnection, upload: Bool) {
        let direction = upload ? "upload" : "download"
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, eof, error in
            guard let self, phase == .splicing else { return }
            if let error { finish("Could not read \(direction): \(error)"); return }
            let bytes = data?.count ?? 0
            if bytes == 0, !eof { splice(from: source, to: destination, upload: upload); return }
            destination.send(
                content: data, contentContext: eof ? .finalMessage : .defaultMessage, isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    guard let self, phase == .splicing else { return }
                    if let error { finish("Could not write \(direction): \(error)"); return }
                    traffic.add(bytes, upload: upload)
                    if eof {
                        completedDirections += 1
                        if completedDirections == 2 { finish(nil) }
                    } else {
                        splice(from: source, to: destination, upload: upload)
                    }
                }
            )
        }
    }

    private func finish(_ error: String?) {
        guard phase != .done else { return }
        phase = .done
        deadline?.cancel()
        deadline = nil
        client.stateUpdateHandler = nil
        outbound?.stateUpdateHandler = nil
        client.cancel()
        outbound?.cancel()
        if let id = stat?.id { state.queue.async { [state] in state.finished(id: id, error: error) } }
    }
}
