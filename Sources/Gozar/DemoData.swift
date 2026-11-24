import Foundation
import GozarCore

enum DemoData {
    static let exits = ExitListing(active: "xf31b7a", exits: [
        .init(id: "relay", name: "سرور اصلی", kind: .ssh, transport: .ssh, address: "relay.example.net", port: 47853),
        .init(id: "xb82af0", name: "Helsinki", kind: .xray, transport: .trojan, address: "hel.example.net", port: 443),
        .init(id: "x9f2a37", name: "Zurich", kind: .xray, transport: .ss, address: "zrh.example.net", port: 8388),
        .init(id: "xf31b7a", name: "Frankfurt", kind: .xray, transport: .vless, address: "fra.example.net", port: 443,
              subscription: "s1a2b3c", stale: true),
        .init(id: "x4f8b2c", name: "Amsterdam", kind: .xray, transport: .vmess, address: "ams.example.net", port: 443,
              subscription: "s1a2b3c"),
        .init(id: "x3a34df", name: "Stockholm", kind: .xray, transport: .vless, address: "arn.example.net", port: 443,
              subscription: "s1a2b3c")
    ], subscriptions: [
        .init(id: "s1a2b3c", name: "شبکهٔ اروپا", host: "feed.example.net", count: 3, updatedAt: "2026-11-24T06:00:00Z", error: nil)
    ])

    static let exitTests: [String: ExitTestResult] = [
        "relay": .init(id: "relay", ok: true, connectMs: 113, mbps: 28.4),
        "xb82af0": .init(id: "xb82af0", ok: false, connectMs: nil, mbps: nil, error: "Connection timed out"),
        "xf31b7a": .init(id: "xf31b7a", ok: true, connectMs: 74, mbps: 58.2),
        "x4f8b2c": .init(id: "x4f8b2c", ok: true, connectMs: 161, mbps: 22.7),
        "x3a34df": .init(id: "x3a34df", ok: true, connectMs: 148, mbps: 31.3)
    ]
    static let reference = Date(timeIntervalSince1970: 1_795_529_104)
    static let hostnames = [
        "youtube.com", "googlevideo.com", "github.com", "aparat.com", "company.example", "claude.ai",
        "google.com", "gstatic.com", "githubusercontent.com", "openrouter.ai", "shaparak.ir",
        "cloudflare.com", "npmjs.org", "discord.com", "corp.example.net", "apple.com",
        "developer.apple.com", "cdn.jsdelivr.net", "snapp.ir", "divar.ir", "torob.com",
        "stackoverflow.com", "anthropic.com", "chatgpt.com", "api.openai.com", "netlify.com",
        "vimeo.com", "wikipedia.org", "wikimedia.org", "fastly.net", "googleapis.com", "pypi.org",
        "docker.com", "docker.io", "telegram.org", "speedtest.net", "example.org", "twitch.tv", "notion.so", "figma.com",
    ]

    static let rules: [Rule] = [
        Rule(name: L.demoRuleIran, route: .direct, note: L.demoNoteIran,
             domains: ["ir", "aparat.com", "company.example", "torob.com", "rubika.com"]),
        Rule(name: L.demoRuleWork, route: .cisco, withoutCisco: .vpn, note: L.demoNoteWork,
             domains: ["corp.example.net", "*.corp.example"], hosts: ["CORP-MGMT01", "*.office"]),
        Rule(name: L.demoRuleStreaming, route: .vpn, note: L.demoNoteStreaming,
             domains: ["youtube.com", "googlevideo.com", "vimeo.com", "twitch.tv"]),
        Rule(name: L.demoRuleAI, route: .vpn, note: L.demoNoteAI,
             domains: ["claude.ai", "anthropic.com", "openrouter.ai", "chatgpt.com"]),
        Rule(name: L.demoRulePaused, route: .direct, enabled: false, note: L.demoNotePaused, domains: ["example.org"]),
    ]

    private static let connectionDefaults = ConnectionFile(
        relayHost: "203.0.113.10", relayPort: 47853, relayUser: "vpnuser", router: .init(enabled: true)
    )

    static var connection: ConnectionDraft {
        var draft = ConnectionDraft()
        draft.relayHost = connectionDefaults.relayHost
        draft.relayPort = String(connectionDefaults.relayPort)
        draft.relayUser = connectionDefaults.relayUser
        draft.routerEnabled = connectionDefaults.router.enabled
        draft.localPort = String(connectionDefaults.localSocksPort)
        draft.upstreamPort = String(connectionDefaults.router.upstreamPort)
        draft.controlPort = String(connectionDefaults.router.controlPort)
        return draft
    }

    static var status: VPNStatus {
        VPNStatus(loop: true, socks: true, exitIP: "198.51.100.20", proxy: true, cisco: true, ciscoCopy: true,
                  router: .init(enabled: true, running: true, controlPort: connectionDefaults.router.controlPort))
    }

    static func rate(_ route: Route, tick: Int) -> Double {
        let base: Double
        let phase: Double
        switch route {
        case .vpn: (base, phase) = (4_850_000, 0)
        case .direct: (base, phase) = (1_205_000, 1.9)
        case .cisco: (base, phase) = (398_000, 3.5)
        }
        return base * (0.91 + wave(tick, phase: phase))
    }

    private static func wave(_ tick: Int, phase: Double) -> Double {
        let t = Double(tick)
        return 0.29 * sin(t / 13 + phase) + 0.14 * cos(t / 6 + phase) + 0.09 * sin(t / 2.9)
    }

    static func totals(_ tick: Int) -> RouterTotals {
        func route(_ route: Route, open: Int, connections: Int) -> RouteTotals {
            let down = rate(route, tick: tick)
            return RouteTotals(connections: connections, open: open, failed: route == .vpn ? 1 : 0,
                               bytesUp: 74_400_000, bytesDown: 1_928_000_000, rateUp: down * 0.081, rateDown: down)
        }
        return RouterTotals(vpn: route(.vpn, open: 24, connections: 318), direct: route(.direct, open: 8, connections: 132),
                            cisco: route(.cisco, open: 4, connections: 49))
    }

    static func router(_ tick: Int, at: Date) -> RouterStatus {
        RouterStatus(version: "1.0", startedAt: at.addingTimeInterval(-11_520),
                     listenPort: connectionDefaults.localSocksPort, upstreamPort: connectionDefaults.router.upstreamPort,
                     upstreamUp: true, ciscoUp: true, rulesLoadedAt: at.addingTimeInterval(-420), open: 36, total: 499,
                     totals: totals(tick), probes: [
                        .init(name: "relay", target: "203.0.113.10:47853", lastMs: 34 + wave(tick, phase: 0) * 12,
                              medianMs: 34, loss: 0, samples: 30),
                        .init(name: "tunnel", target: "1.1.1.1:443", lastMs: 186 + wave(tick, phase: 1) * 45,
                              medianMs: 181, loss: 0, samples: 30),
                        .init(name: "local", target: "aparat.com:443", lastMs: 21, medianMs: 19, loss: 0, samples: 30),
                     ])
    }

    static func decision(_ host: String, rules: [Rule]) -> RouteDecision {
        (try? RuleEngine(rules: rules).decide(host, ciscoUp: false)) ?? RouteDecision(route: .vpn)
    }

    static func domains(_ tick: Int, at: Date, rules: [Rule]) -> [DomainStat] {
        var seen: Set<String> = []
        return hostnames.enumerated().compactMap { index, host in
            let domain = registrableDomain(host)
            guard seen.insert(domain).inserted else { return nil }
            let route: Route
            let working = (try? RuleEngine(rules: rules).match(domain))?.rule
            switch working?.route {
            case .cisco: route = .cisco
            case .direct: route = .direct
            default: route = .vpn
            }
            let rank = Double(index + 1)
            let down = 3_350_000 / pow(rank, 1.48) * (0.99 + wave(tick, phase: rank / 2))
            let name = domain == "googlevideo.com" ? "rr3---sn-4g5edn7l" : "www"
            let hosts = ["\(name).\(domain)", "api.\(domain)", "cdn.\(domain)"]
            let ms = (route == .direct ? 34.0 : 109.0) + Double(index % 8) * 11
            return DomainStat(domain: domain, hosts: hosts, route: route, rule: working?.name,
                              connections: max(1, 74 - index * 2), open: max(0, 9 - index), failed: domain == "discord.com" ? 1 : 0,
                              bytesUp: UInt64(down * 17), bytesDown: UInt64(down * 182),
                              rateUp: down * 0.067, rateDown: down, connectMsAvg: ms, connectMsP90: ms + 41,
                              lastSeen: at.addingTimeInterval(Double(-index)))
        }
    }

    static func connectionRow(id: Int, at: Date, domain: DomainStat, rank: Int) -> ConnStat {
        let failed = domain.domain == "discord.com"
        let state: ConnStat.State = failed ? .failed : rank.isMultiple(of: 3) ? .closed : .open
        return ConnStat(id: id, host: domain.hosts[rank % domain.hosts.count], port: 443, route: domain.route,
                        rule: domain.rule, startedAt: at, connectMs: failed ? nil : domain.connectMsAvg,
                        endedAt: state == .open ? nil : at.addingTimeInterval(0.6), state: state,
                        error: failed ? L.demoFailure : nil, bytesUp: failed ? 0 : UInt64(10_420 + rank * 361),
                        bytesDown: failed ? 0 : domain.bytesDown / 68,
                        rateUp: state == .open ? domain.rateUp / 4 : 0,
                        rateDown: state == .open ? domain.rateDown / 3 : 0)
    }

    static func grafana(_ tick: Int, at: Date) -> GrafanaResponse {
        func point(_ value: Double, labels: [String: String] = [:]) -> GrafanaSeries {
            GrafanaSeries(labels: labels, points: [MetricPoint(at: at, value: value)])
        }
        func range(_ base: Double, amplitude: Double, phase: Double) -> GrafanaSeries {
            GrafanaSeries(points: (0...60).map { index in
                let value = base + amplitude * wave(index * 4 + tick, phase: phase)
                    + (index > 31 && index < 41 ? amplitude * 0.4 : 0)
                return MetricPoint(at: at.addingTimeInterval(Double(index - 60) * 30), value: max(0, value))
            })
        }
        return GrafanaResponse(series: [
            "box": [point(1, labels: ["name": "egress-box", "target": "198.51.100.20"])],
            "uptime": [point(215_340)], "since": [point(112_320)], "nic_tx": [point(3_420_000)],
            "mem_free": [point(0.71)], "cpu_ours": [point(0.14)], "steal": [point(0.046)],
            "ping": [point(0.112)], "loss": [point(0.002)], "openrouter": [point(0.71)],
            "phone_banner": [point(0.183)],
            "pools": ["app", "ci", "phone", "vpn"].map { point($0 == "ci" ? 1 : 2, labels: ["pool": $0]) },
            "members": ["app", "ci", "phone", "vpn"].flatMap { pool in
                (1...2).map { point(pool == "ci" && $0 == 2 ? 2 : 1, labels: ["pool": pool, "member": "\(pool)-\($0)"]) }
            },
            "ping_range": [range(0.112, amplitude: 0.038, phase: 1)],
            "loss_range": [range(0.003, amplitude: 0.007, phase: 0)],
            "steal_range": [range(0.052, amplitude: 0.052, phase: 2)],
            "openrouter_range": [range(0.71, amplitude: 0.27, phase: 6)],
        ])
    }

    static func discovery(_ site: String, rules: [Rule]) -> DomainDiscovery {
        let host = (try? RuleEngine.parseDomain(site).name) ?? site
        let name = registrableDomain(host)
        let community = name == "youtube.com" ? ["youtube.com", "googlevideo.com", "ytimg.com"] : [name, "cdn.\(name)"]
        let live = name == "youtube.com" ? ["www.youtube.com", "rr3---sn-4g5edn7l.googlevideo.com"] : ["www.\(name)", "api.\(name)"]
        func entries(_ hosts: [String]) -> [DomainDiscovery.Entry] {
            hosts.map { .init(host: $0, route: decision($0, rules: rules).route) }
        }
        return DomainDiscovery(site: host, title: name, via: decision(name, rules: rules).route,
                               listed: .init(name: name, domains: entries(community)), live: entries(live), suggested: community)
    }
}
