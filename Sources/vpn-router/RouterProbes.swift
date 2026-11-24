import Foundation
import GozarCore
import Network

final class RouterProbes {
    private struct Target {
        let name: String
        let destination: SocksWire.Destination
        var history = ProbeHistory()

        var stat: ProbeStat {
            let host = destination.host.contains(":") ? "[\(destination.host)]" : destination.host
            return history.stat(name: name, target: "\(host):\(destination.port)")
        }
    }

    private let state: RouterState
    private let upstream: SocksWire.Destination
    private var targets: [Target]

    init(state: RouterState, relay: SocksWire.Destination, upstreamPort: UInt16) {
        self.state = state
        upstream = SocksWire.Destination(host: "127.0.0.1", port: upstreamPort)
        targets = [
            Target(name: "relay", destination: relay),
            Target(name: "tunnel", destination: .init(host: "1.1.1.1", port: 443)),
            Target(name: "local", destination: .init(host: "aparat.com", port: 443)),
        ]
        state.setProbes(targets.map(\.stat))
    }

    func sample() {
        for (index, target) in targets.enumerated() {
            let tunnel = target.name == "tunnel"
            ProbeAttempt(
                endpoint: tunnel ? upstream : target.destination, socksDestination: tunnel ? target.destination : nil,
                queue: state.queue
            ).start { [weak self] sample, tcpReady in
                guard let self else { return }
                if tunnel { state.setUpstream(tcpReady) }
                targets[index].history.record(sample)
                state.setProbes(targets.map(\.stat))
            }
        }
    }
}

private final class ProbeAttempt {
    private let connection: NWConnection
    private let socksDestination: SocksWire.Destination?
    private let queue: DispatchQueue
    private let timer: DispatchSourceTimer
    private let started = DispatchTime.now()
    private var tcpReady = false
    private var completion: ((ProbeHistory.Sample, Bool) -> Void)?

    init(endpoint: SocksWire.Destination, socksDestination: SocksWire.Destination?, queue: DispatchQueue) {
        connection = makeConnection(endpoint)
        self.socksDestination = socksDestination
        self.queue = queue
        timer = DispatchSource.makeTimerSource(queue: queue)
    }

    func start(completion: @escaping (ProbeHistory.Sample, Bool) -> Void) {
        self.completion = completion
        timer.schedule(deadline: started + .seconds(5))
        timer.setEventHandler { [weak self] in self?.finish(.failure("Timed out")) }
        timer.resume()
        connection.stateUpdateHandler = { [self] status in
            switch status {
            case .ready:
                tcpReady = true
                if let socksDestination {
                    connectThroughSocks(connection, to: socksDestination) { [weak self] error in
                        guard let self else { return }
                        if let error { finish(.failure(error.localizedDescription)) }
                        else { finish(.latency(elapsedMilliseconds(since: started))) }
                    }
                } else {
                    finish(.latency(elapsedMilliseconds(since: started)))
                }
            case .failed(let error), .waiting(let error): finish(.failure(error.localizedDescription))
            case .cancelled: finish(.failure("Probe cancelled"))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func finish(_ sample: ProbeHistory.Sample) {
        guard let completion else { return }
        self.completion = nil
        timer.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion(sample, tcpReady)
    }
}
