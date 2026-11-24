import Foundation
import GozarCore
import os

private struct ByteCounts {
    var up: UInt64 = 0
    var down: UInt64 = 0
}

final class TrafficCounter: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: ByteCounts())

    func add(_ count: Int, upload: Bool) {
        counts.withLock {
            if upload { $0.up += UInt64(count) }
            else { $0.down += UInt64(count) }
        }
    }

    fileprivate func snapshot() -> ByteCounts { counts.withLock { $0 } }
}

// All mutable state is confined to queue.
final class RouterState: @unchecked Sendable {
    private struct Active {
        var stat: ConnStat
        let traffic: TrafficCounter
        var lastSeen: Date

        func snapshot() -> ConnStat {
            let bytes = traffic.snapshot()
            var current = stat
            current.bytesUp = bytes.up
            current.bytesDown = bytes.down
            return current
        }
    }

    private struct Domain {
        var latest: ConnStat
        var lastSeen: Date
        var hosts: [String] = []
        var counts = RouteTotals()
        var latencies: [Double] = []

        mutating func add(_ stat: ConnStat, seen: Date) {
            if seen > lastSeen || (seen == lastSeen && stat.id > latest.id) {
                latest = stat
                lastSeen = seen
            }
            if hosts.count < 20, !hosts.contains(stat.host) { hosts.append(stat.host) }
            counts.connections += 1
            if stat.state == .open { counts.open += 1 }
            if stat.state == .failed { counts.failed += 1 }
            counts.bytesUp += stat.bytesUp
            counts.bytesDown += stat.bytesDown
            counts.rateUp += stat.rateUp
            counts.rateDown += stat.rateDown
            if let ms = stat.connectMs { latencies.append(ms) }
        }

        func snapshot(_ domain: String) -> DomainStat {
            let average = latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count)
            let p90 = latencies.isEmpty ? nil : latencies.sorted()[Int(ceil(0.9 * Double(latencies.count))) - 1]
            return DomainStat(
                domain: domain, hosts: hosts.sorted(), route: latest.route, rule: latest.rule,
                connections: counts.connections, open: counts.open, failed: counts.failed,
                bytesUp: counts.bytesUp, bytesDown: counts.bytesDown, rateUp: counts.rateUp, rateDown: counts.rateDown,
                connectMsAvg: average, connectMsP90: p90, lastSeen: lastSeen
            )
        }
    }

    let queue = DispatchQueue(label: "ir.mrbadri.gozar.router.state")
    let startedAt = Date()
    private let store: ConfigStore
    private let log: RouterLog
    private let listenPort: UInt16
    private let upstreamPort: UInt16
    private var rules: RuleEngine
    private var rulesLoadedAt: Date?
    private var rulesError: String?
    private var active: [Int: Active] = [:]
    private var closed = [ConnStat?](repeating: nil, count: 2000)
    private var closedIndex = 0
    private var nextID = 1
    private var totals = RouterTotals()
    // Four cumulative samples span the last three one-second intervals.
    private var samples: [(time: DispatchTime, totals: RouterTotals)] = [(.now(), .init())]
    private var probes: [ProbeStat] = []
    private var upstreamUp = false
    private var ciscoUp = false

    var onEvent: ((RouterEvent) -> Void)?

    init(store: ConfigStore, log: RouterLog, listenPort: UInt16, upstreamPort: UInt16) throws {
        self.store = store
        self.log = log
        self.listenPort = listenPort
        self.upstreamPort = upstreamPort
        rules = try RuleEngine(rules: [])
    }

    func reload() {
        do {
            rules = try RuleEngine(rules: store.loadRoutes().rules)
            rulesLoadedAt = Date()
            rulesError = nil
        } catch {
            rulesError = error.localizedDescription
            RouterLog.logger.error("Could not reload routes")
        }
    }

    func check(_ host: String) -> RouteCheck {
        RouteCheck(decision: rules.decide(host, ciscoUp: ciscoUp), ciscoUp: ciscoUp)
    }

    func setCisco(_ up: Bool) { ciscoUp = up }
    func setUpstream(_ up: Bool) { upstreamUp = up }
    func setProbes(_ current: [ProbeStat]) { probes = current }

    func register(
        _ destination: SocksWire.Destination, at acceptedAt: Date, traffic: TrafficCounter
    ) -> ConnStat {
        let decision = check(destination.host)
        let stat = ConnStat(id: nextID, host: destination.host, port: Int(destination.port),
                            route: decision.route, rule: decision.rule, startedAt: acceptedAt)
        nextID += 1
        active[stat.id] = Active(stat: stat, traffic: traffic, lastSeen: acceptedAt)
        totals[keyPath: key(for: stat.route)].connections += 1
        log.connection(stat)
        return stat
    }

    func opened(id: Int, connectMs: Double) {
        guard var entry = active[id] else { return }
        entry.stat.connectMs = connectMs
        entry.stat.state = .open
        entry.lastSeen = Date()
        active[id] = entry
        totals[keyPath: key(for: entry.stat.route)].open += 1
        onEvent?(.open(entry.stat))
    }

    func finished(id: Int, error: String?) {
        guard let entry = active.removeValue(forKey: id) else { return }
        var stat = entry.snapshot()
        let route = key(for: stat.route)
        if stat.state == .open { totals[keyPath: route].open -= 1 }
        stat.state = error == nil ? .closed : .failed
        stat.error = error
        stat.endedAt = Date()
        stat.rateUp = 0
        stat.rateDown = 0
        totals[keyPath: route].bytesUp += stat.bytesUp
        totals[keyPath: route].bytesDown += stat.bytesDown
        if error != nil {
            totals[keyPath: route].failed += 1
            log.connection(stat)
        }
        closed[closedIndex] = stat
        closedIndex = (closedIndex + 1) % closed.count
        onEvent?(.close(stat))
    }

    func tick() {
        let at = Date()
        let now = DispatchTime.now()
        let seconds = elapsedMilliseconds(since: samples.last!.time) / 1000
        var updates: [OpenUpdate] = []
        var liveTotals = totals
        for (id, entry) in active {
            var current = entry.snapshot()
            let sent = current.bytesUp - entry.stat.bytesUp
            let received = current.bytesDown - entry.stat.bytesDown
            current.rateUp = Double(sent) / seconds
            current.rateDown = Double(received) / seconds
            let changed = sent != 0 || received != 0
            active[id] = Active(stat: current, traffic: entry.traffic, lastSeen: changed ? at : entry.lastSeen)
            if current.state == .open, changed {
                updates.append(OpenUpdate(id: id, bytesUp: current.bytesUp, bytesDown: current.bytesDown,
                                          rateUp: current.rateUp, rateDown: current.rateDown))
            }
            let route = key(for: current.route)
            liveTotals[keyPath: route].bytesUp += current.bytesUp
            liveTotals[keyPath: route].bytesDown += current.bytesDown
        }
        if samples.count == 4 { samples.removeFirst() }
        let oldest = samples[0]
        let span = elapsedMilliseconds(since: oldest.time) / 1000
        for route in [\RouterTotals.vpn, \.direct, \.cisco] {
            totals[keyPath: route].rateUp = Double(liveTotals[keyPath: route].bytesUp - oldest.totals[keyPath: route].bytesUp) / span
            totals[keyPath: route].rateDown = Double(liveTotals[keyPath: route].bytesDown - oldest.totals[keyPath: route].bytesDown) / span
            liveTotals[keyPath: route].rateUp = totals[keyPath: route].rateUp
            liveTotals[keyPath: route].rateDown = totals[keyPath: route].rateDown
        }
        samples.append((now, liveTotals))
        onEvent?(.tick(Tick(at: at, totals: liveTotals, openUpdates: updates)))
    }

    func status() -> RouterStatus {
        var current = totals
        for entry in active.values {
            let bytes = entry.traffic.snapshot()
            let route = key(for: entry.stat.route)
            current[keyPath: route].bytesUp += bytes.up
            current[keyPath: route].bytesDown += bytes.down
        }
        return RouterStatus(
            version: "1", startedAt: startedAt, listenPort: Int(listenPort), upstreamPort: Int(upstreamPort),
            upstreamUp: upstreamUp, ciscoUp: ciscoUp, rulesLoadedAt: rulesLoadedAt, rulesError: rulesError,
            open: current.vpn.open + current.direct.open + current.cisco.open, total: nextID - 1,
            totals: current, probes: probes
        )
    }

    func connections(limit: Int) -> [ConnStat] {
        let live = active.values.map { $0.snapshot() }.sorted {
            if $0.state != $1.state { return $0.state == .open }
            return $0.id > $1.id
        }
        if live.count >= limit { return Array(live.prefix(limit)) }
        return live + recentClosed(limit: limit - live.count)
    }

    func domains(window: Int) -> [DomainStat] {
        let cutoff = Date().addingTimeInterval(-Double(window))
        var byDomain: [String: Domain] = [:]
        func add(_ stat: ConnStat, seen: Date) {
            let domain = registrableDomain(stat.host)
            byDomain[domain, default: Domain(latest: stat, lastSeen: seen)].add(stat, seen: seen)
        }
        for entry in active.values { add(entry.snapshot(), seen: entry.lastSeen) }
        for stat in recentClosed(limit: closed.count) {
            if let endedAt = stat.endedAt, endedAt >= cutoff { add(stat, seen: endedAt) }
        }
        return byDomain.map { $0.value.snapshot($0.key) }.sorted {
            let left = $0.bytesUp + $0.bytesDown
            let right = $1.bytesUp + $1.bytesDown
            return left == right ? $0.domain < $1.domain : left > right
        }
    }

    private func recentClosed(limit: Int) -> [ConnStat] {
        (0..<limit).compactMap { offset in
            closed[(closedIndex - 1 - offset + closed.count) % closed.count]
        }
    }

    private func key(for route: Route) -> WritableKeyPath<RouterTotals, RouteTotals> {
        switch route {
        case .vpn: return \.vpn
        case .direct: return \.direct
        case .cisco: return \.cisco
        }
    }
}
