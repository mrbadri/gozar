import Foundation
import Testing
import GozarCore

@Test func routingMatchesPython() throws {
    let hosts = [
        "company.example", "www.company.example", "x.y.corp.example.net", "DIGIKALA.SERVICES",
        "shop.example", "m.shop.example", "fakecompany.example", "company.example.example.org",
        "lab.company.example", "x.lab.company.example", "company.example.",
        "claude.ai", "api.claude.ai", "CLAUDE.AI", "claude.com", "api.anthropic.com",
        "cdn.claudeusercontent.com", "evilclaude.ai", "a.b.shaparak.ir", "shaparak.ir", "ir",
        "evil-ir.com", "ir.example.org", "ir.", "aparat.com", "www.aparat.com", "notaparat.com",
        "test.aparat.com", "video.test.aparat.com", "filimo.com", "x.torob.com", "api.zarinpal.com",
        "eitaa.com", "bale.ai", "news.varzesh3.com", "www.youtube.com", "video.youtube.com",
        "R5.googlevideo.com", "i.ytimg.com", "static.ggpht.com", "youtube.com.example.org",
        "CORP-MGMT01", "corp-mgmt01.corp", "corp-agent-ser", "HQ-SAFETICA-SERVER", "unknown-host",
        "example.com", "sub.example.com", "a.b.example.com", "ample.com", "example.net", "www.example.net",
        "disabled.example.org", "disabled-host", "OFFICE.invalid", "Workstation.Office.Invalid",
        "a.b.office.invalid", "1.1.1.1", "203.0.113.4", "203.0.113.5", "2001:db8::1",
    ]
    let domains = [
        "YouTube.com", "*.x.com", ".x.com", "ir", "*.IR", "  example.org...  ",
        "HTTPS://user:pass@www.YouTube.com:443/watch?v=x", "www.youtube.com",
        "www.youtube.com?video=1", "www.youtube.com/watch", "https://www.example.org../",
        "\u{1c}EXAMPLE.com\u{85}", "https://example.com\n/path", "https://example.com\r/path",
        "", " ", "https:///", "foo_bar", "foo.*.com", "foo..com", "-foo.com",
        "https://www.[2001:db8::1]", "https://example.com#fragment", "مثال.ir",
    ]

    let testFile = URL(fileURLWithPath: #filePath)
    let package = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let repo = package
    let fixture = package.appendingPathComponent("Tests/fixtures/routes.sample.json")
    let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: state) }
    let paths = StatePaths(stateDir: state)
    try FileManager.default.copyItem(at: fixture, to: paths.routes)
    let routes = try ConfigStore(paths: paths).loadRoutes()
    let engine = try RuleEngine(rules: routes.rules)

    let python = #"""
    import json, sys
    sys.path.insert(0, sys.argv[1])
    import vpnconf
    with open(sys.argv[2], encoding='utf-8') as file:
        routes = json.load(file)
    hosts, domains = json.loads(sys.argv[3])
    decisions = []
    for host in hosts:
        for cisco in (False, True):
            rule, pattern = vpnconf.match(routes, host)
            decisions.append(dict(route=vpnconf.effective(rule, cisco) if rule else 'vpn',
                                  rule=rule['name'] if rule else None, pattern=pattern or None))
    def parse(domain):
        try:
            kind, name = vpnconf.parse_domain(domain)
            return dict(kind=kind, name=name)
        except vpnconf.ConfigError:
            return None
    print(json.dumps(dict(decisions=decisions, domains=list(map(parse, domains)))))
    """#
    struct Domain: Codable, Equatable {
        let kind: String
        let name: String
    }
    struct Golden: Decodable {
        let decisions: [RouteDecision]
        let domains: [Domain?]
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let input = try JSONEncoder().encode([hosts, domains])
    process.arguments = ["-c", python, repo.appendingPathComponent("cli/laptop-vpn.d").path,
                         paths.routes.path, String(decoding: input, as: UTF8.self)]
    var environment = ProcessInfo.processInfo.environment
    environment["LAPTOP_VPN_STATE"] = state.path
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    let golden = try JSONDecoder().decode(Golden.self, from: data)
    let comparisons = hosts.flatMap { host in [false, true].map { (host, $0) } }
    try #require(comparisons.count >= 80)
    try #require(golden.decisions.count == comparisons.count)
    try #require(golden.domains.count == domains.count)

    var routeMismatches = 0
    for ((host, cisco), expected) in zip(comparisons, golden.decisions) {
        let actual = engine.decide(host, ciscoUp: cisco)
        if actual != expected { routeMismatches += 1 }
        #expect(actual == expected, "\(host), Cisco \(cisco)")
    }

    var domainMismatches = 0
    for (input, expected) in zip(domains, golden.domains) {
        let actual = (try? RuleEngine.parseDomain(input)).map { Domain(kind: $0.kind.rawValue, name: $0.name) }
        if actual != expected { domainMismatches += 1 }
        #expect(actual == expected, "\(String(reflecting: input))")
    }
    print("Python golden: \(comparisons.count) route comparisons, \(routeMismatches) mismatches. \(domains.count) domain parses, \(domainMismatches) mismatches.")
}

@Test func ipv4CIDRAndLocalNetworks() throws {
    let engine = try RuleEngine(rules: [
        Rule(name: "First network", route: .direct, hosts: ["198.51.100.0/24"]),
        Rule(name: "Later exact host", route: .vpn, hosts: ["198.51.100.10"]),
        Rule(name: "First exact host", route: .cisco, hosts: ["203.0.113.10"]),
        Rule(name: "Later network", route: .vpn, hosts: ["203.0.113.0/24", "10.0.0.0/8"]),
        Rule(name: "Local override attempt", route: .vpn, hosts: ["localhost", "*.local", "::1"]),
    ])

    #expect(engine.decide("198.51.100.10", ciscoUp: false) ==
            RouteDecision(route: .direct, rule: "First network", pattern: "198.51.100.0/24"))
    #expect(engine.decide("198.51.100.255", ciscoUp: false).rule == "First network")
    #expect(engine.decide("198.51.101.0", ciscoUp: false) == RouteDecision(route: .vpn))
    #expect(engine.decide("198.51.100.256", ciscoUp: false) == RouteDecision(route: .vpn))
    #expect(engine.decide("203.0.113.10", ciscoUp: true).rule == "First exact host")
    #expect(engine.decide("203.0.113.9", ciscoUp: true).rule == "Later network")

    let localHosts = ["LOCALHOST", "127.9.8.7", "::1", "printer.LOCAL", "169.254.1.2",
                      "10.1.2.3", "172.16.0.0", "172.31.255.255", "192.168.1.2"]
    for host in localHosts {
        for cisco in [false, true] {
            let decision = engine.decide(host, ciscoUp: cisco)
            #expect(decision.rule == "Local network", "\(host)")
            #expect(decision.route == .direct, "\(host)")
        }
    }
    #expect(engine.decide("172.32.0.0", ciscoUp: true) == RouteDecision(route: .vpn))
    #expect(engine.decide("local", ciscoUp: true) == RouteDecision(route: .vpn))
}
