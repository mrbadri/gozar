import Foundation
import Testing
@testable import GozarCore

@Test func communityListMatchesPythonWithoutChrome() throws {
    let state = try makeConfTestDirectory()
    defer { try? FileManager.default.removeItem(at: state) }
    let script = #"""
    import json, sys
    sys.path.insert(0, sys.argv[1])
    import sitedomains
    listings = json.loads(sys.argv[2])
    sitedomains.socks_port = lambda: 18080
    sitedomains.fetch = lambda url, socks: listings.get(url.rsplit('/', 1)[-1])
    raise SystemExit(sitedomains.main(sys.argv[3:]))
    """#
    let fixture = confTestPackage.appendingPathComponent("Tests/fixtures/routes.sample.json")
    try FileManager.default.copyItem(at: fixture, to: state.appendingPathComponent("routes.json"))
    try confTestConnection().write(to: state.appendingPathComponent("connection.json"))
    let lists = [
        "youtube": """
            # name
            domain:youtube.com
            include:video
            full:YOUTUBE.com
            youtube.de
            youtube.co.uk
            youtube
            domain:ads.invalid @ads
            domain:cn.invalid @cn
            regexp:foo
            keyword:skip-me
            """,
        "video": "domain:googlevideo.com\ninclude:assets\ninclude:youtube\n",
        "assets": "ytimg.com\ninclude:too-deep\n",
        "too-deep": "excluded.test\n",
        "google-meet": "domain:meet.google.com\nshared.example.test\n",
    ]
    let data = try JSONEncoder().encode(lists)
    var environment = ProcessInfo.processInfo.environment
    environment["LAPTOP_VPN_STATE"] = state.path
    environment["LAPTOP_VPN_CONF_DIR"] = confTestDefaults.path
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    let network = ConfNetwork(listening: { $0 == 18080 }, fetch: { url, socks, userAgent, redirects in
        #expect(socks == 18080)
        #expect(userAgent == nil)
        #expect(!redirects)
        let name = URL(string: url)?.lastPathComponent ?? ""
        return lists[name].map { Data($0.utf8) }
    })
    for args in [
        ["youtube.com"], ["HTTPS://WWW.YouTube.com/video", "--cisco"], ["meet.google.com"],
        ["meet.google.com", "--all"], ["nonexistent.test", "--name", "Missing"],
    ] {
        let expected = try runConfTestProcess(URL(fileURLWithPath: "/usr/bin/python3"),
                                              args: ["-c", script, confTestDefaults.path, String(decoding: data, as: UTF8.self)]
                                                + args + ["--json", "--quick"], in: state, environment: environment)
        let actual = ConfCLI.run(["domains"] + args + ["--json"], executable: state.appendingPathComponent("gozarctl"),
                                 environment: environment, network: network)
        #expect(expected.code == 0)
        #expect(actual.code == expected.code)
        #expect(Data(actual.stdout.utf8) == expected.stdout)
        #expect(Data(actual.stderr.utf8) == expected.stderr)
    }
}

