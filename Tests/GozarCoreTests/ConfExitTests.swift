import Foundation
import Testing
@testable import GozarCore

private let fixtures = confTestPackage.appendingPathComponent("Tests/fixtures/links")
private let fakeID = "12345678-1234-4234-8234-123456789abc"

private func fixtureLink(_ name: String) throws -> String {
    try String(contentsOf: fixtures.appendingPathComponent(name + ".link"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

@Test(arguments: ["vless-panel", "vless-reality", "vless-ws", "vless-xhttp", "vless-httpupgrade", "vless-tcp-http",
                  "vmess-ws", "trojan-grpc", "ss-sip002", "ss-legacy"])
func outboundMatchesFixture(_ name: String) throws {
    let link = try ParsedLink(fixtureLink(name))
    let expectedData = try Data(contentsOf: fixtures.appendingPathComponent(name + ".json"))
    let expected = try #require(JSONSerialization.jsonObject(with: expectedData) as? NSDictionary)
    let actual = try #require(JSONSerialization.jsonObject(with: Data(link.outbound.rendered().utf8)) as? NSDictionary)
    #expect(actual == expected)
    let config = try ConfJSON(parsing: String(decoding: link.configuration(port: 18301), as: UTF8.self)).object
    let inbounds = try #require(config?["inbounds"]?.array)
    let inbound = try #require(inbounds.first?.object)
    #expect(inbounds.count == 1)
    #expect(inbound["listen"]?.string == "127.0.0.1")
    #expect(inbound["port"]?.int == 18301)
    #expect(inbound["settings"]?.object?["udp"]?.bool == false)
    #expect(inbound["settings"]?.object?["auth"]?.string == "noauth")
    #expect(config?["outbounds"]?.array == [link.outbound])
    #expect(config?["log"]?.object?["loglevel"]?.string == "warning")
    #expect(config?["routing"]?.object?["rules"]?.array?.first?.object?["outboundTag"]?.string == "exit")
}

@Test(arguments: [
    ("vmess://I", "base64 JSON"),
    ("ss://", "credentials"),
    ("ss://bad@", "host"),
    ("vless://", "uuid"),
    ("vless://invalid@host.test:18443", "uuid"),
    ("vless://\(fakeID)@host.test:70000", "port"),
    ("vless://\(fakeID)@[2001:xyz::1]:18443", "host"),
    ("vless://\(fakeID)@host.test:18443?type=kcp", "type"),
    ("vless://\(fakeID)@host.test:18443?security=reality", "pbk"),
    ("trojan://example@host.test:18443?path=%no", "path"),
    ("trojan://@host.test:18443", "password"),
])
func linkErrorsNameTheField(raw: String, field: String) {
    do {
        _ = try ParsedLink(raw)
        Issue.record("Malformed link parsed")
    } catch {
        #expect(error.localizedDescription.contains(field))
        #expect(!error.localizedDescription.contains(raw))
    }
}

private struct ConfHarness {
    let state: URL
    let executable: URL
    var network = ConfNetwork(listening: { _ in false }, fetch: { _, _, _, _ in nil })
    var environment: [String: String]

    init(state: URL) {
        self.state = state
        executable = state.appendingPathComponent("gozarctl")
        environment = ["LAPTOP_VPN_STATE": state.path, "LAPTOP_VPN_CONF_DIR": confTestDefaults.path,
                       "XRAY_BIN": state.appendingPathComponent("no-xray").path]
    }

    func run(_ args: String...) -> ConfCLI.Result {
        ConfCLI.run(args, executable: executable, environment: environment, network: network)
    }

    func call(_ args: String...) throws -> ConfObject {
        let result = ConfCLI.run(args + ["--json"], executable: executable, environment: environment, network: network)
        try #require(result.code == 0, "\(args.first ?? ""): \(result.stderr)")
        return try #require(try ConfJSON(parsing: result.stdout).object)
    }
}

@Test func exitCommandsMigrateAndSwitchWithoutChangingLegacyRelay() throws {
    let state = try makeConfTestDirectory()
    defer { try? FileManager.default.removeItem(at: state) }
    let cli = ConfHarness(state: state)
    let connectionURL = state.appendingPathComponent("connection.json")
    let exitURL = state.appendingPathComponent("exits.json")
    try confTestConnection().write(to: connectionURL)
    #expect(cli.run("init").code == 0)
    #expect(try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: exitURL.path)[.posixPermissions] as? Int == 0o600)
    let original = try Data(contentsOf: connectionURL)
    let migrated = try cli.call("exits")
    #expect(migrated["active"]?.string == "relay")
    #expect(migrated["exits"]?.array?.first?.object?["name"]?.string == "سرور اصلی")
    #expect(cli.run("conn-env").stdout.contains("EXIT_ID=relay\nEXIT_KIND=ssh\nKEYCHAIN_SERVICE=vpnuser-relay\nKEYCHAIN_ACCOUNT=vpnuser\n"))

    let addedSSH = try cli.call("exit-add-ssh", "[2001:db8::1]", "18443", "test-user", "--name", "SSH fixture")
    let hid = try #require(addedSSH["ids"]?.strings.first)
    #expect(hid.hasPrefix("h") && hid.count == 7)
    #expect(try cli.call("exit-rename", hid, "Renamed")["active"]?.string == "relay")
    #expect(try cli.call("exit-use", hid)["active"]?.string == hid)
    let env = cli.run("conn-env")
    #expect(env.code == 0)
    #expect(env.stdout.hasPrefix("HOST=2001:db8::1\nPORT=18443\nUSER_NAME=test-user\n"))
    #expect(env.stdout.contains("KEYCHAIN_SERVICE=gozar-ssh\nKEYCHAIN_ACCOUNT=\(hid)\n"))
    let remove = cli.run("exit-rm", hid, "--json")
    #expect(remove.code == 1)
    #expect(remove.stdout.contains("cannot remove the active exit"))
    #expect(!remove.stderr.isEmpty)

    let raw = try fixtureLink("vless-ws")
    let xids = try cli.call("exit-add", raw, fixtureLink("ss-legacy"))["ids"]?.strings
    let xid = try #require(xids?.first)
    #expect(xids?.count == 2)
    #expect(xid.hasPrefix("x") && xid.count == 7)
    let listed = cli.run("exits", "--json")
    #expect(!listed.stdout.contains(raw))
    #expect(!listed.stdout.contains(fakeID))
    #expect(!listed.stdout.contains("test:pass"))
    #expect(try cli.call("exit-use", xid)["active"]?.string == xid)
    #expect(try cli.call("exit-rm", hid)["active"]?.string == xid)
    let xrayEnvironment = cli.run("conn-env")
    #expect(xrayEnvironment.code == 0)
    #expect(xrayEnvironment.stdout.contains("EXIT_ID=\(xid)\nEXIT_KIND=xray\nXRAY_CONFIG="))
    let xray = state.appendingPathComponent("xray.json")
    #expect(try FileManager.default.attributesOfItem(atPath: xray.path)[.posixPermissions] as? Int == 0o600)
    let config = try ConfJSON(parsing: String(contentsOf: xray, encoding: .utf8))
    #expect(config.object?["inbounds"]?.array?.first?.object?["port"]?.int == 18080)
    let explicitConfig = try cli.call("xray-config", xid, "--port", "18341")
    #expect(explicitConfig["inbounds"]?.array?.first?.object?["port"]?.int == 18341)
    #expect(try Data(contentsOf: connectionURL) == original)

    try Data(#"{"relay":"obsolete","local_socks_port":18080,"router":{"enabled":true,"upstream_port":18081,"control_port":18090}}"#.utf8)
        .write(to: connectionURL)
    #expect(cli.run("validate").code == 0)
    #expect(cli.run("conn-env").code == 0)
    let routedConfig = try ConfJSON(parsing: String(contentsOf: xray, encoding: .utf8))
    #expect(routedConfig.object?["inbounds"]?.array?.first?.object?["port"]?.int == 18081)
}

@Test func subscriptionReusesIdentityPreservesNamesAndRetainsTheActiveVanishedExit() throws {
    let state = try makeConfTestDirectory()
    defer { try? FileManager.default.removeItem(at: state) }
    try confTestConnection().write(to: state.appendingPathComponent("connection.json"))
    var cli = ConfHarness(state: state)
    let startingA = try fixtureLink("vless-ws")
    let startingB = try fixtureLink("ss-sip002")
    let startingC = try fixtureLink("trojan-grpc")
    let tokenURL = "https://subscribe.example.test/private/sensitive-fixture-token"
    var body: Data? = Data((startingA + "\n" + startingB + "\n" + startingC + "\nunsupported://test\n").utf8)
        .base64EncodedData()
    var calls = 0
    cli.network = ConfNetwork(listening: { $0 == 18080 }, fetch: { url, port, ua, redirects in
        #expect(url == tokenURL)
        #expect(port == 18080)
        #expect(ua == "v2rayNG/1.9.27")
        #expect(redirects)
        calls += 1
        return body
    })
    let add = try cli.call("sub-add", tokenURL)
    let subid = try #require(add["id"]?.string)
    #expect(subid.hasPrefix("s") && subid.count == 7)
    #expect(add["added"]?.int == 3)
    #expect(add["ignored"]?.int == 1)
    let first = try cli.call("exits")
    let exits = (first["exits"]?.array ?? []).compactMap(\.object)
    let aid = try #require(exits.first { $0["protocol"]?.string == "vless" }?["id"]?.string)
    let bid = try #require(exits.first { $0["protocol"]?.string == "ss" }?["id"]?.string)
    let cname = try #require(exits.first { $0["protocol"]?.string == "trojan" }?["id"]?.string)
    #expect(try cli.call("exit-use", aid)["active"]?.string == aid)
    _ = try cli.call("exit-rename", bid, "My subscription name")
    body = try Data((startingB.replacingOccurrences(of: "#SS%20SIP002", with: "#New") + "\n" + fixtureLink("vmess-ws")).utf8)
    let update = try cli.call("sub-update", subid)
    #expect(update["added"]?.int == 1)
    #expect(update["updated"]?.int == 1)
    #expect(update["removed"]?.int == 1)
    #expect(update["ignored"]?.int == 0)
    let listing = cli.run("exits", "--json")
    #expect(!listing.stdout.contains("sensitive-fixture-token"))
    #expect(!listing.stdout.contains("ss://"))
    let status = try #require(try ConfJSON(parsing: listing.stdout).object)
    #expect(status["active"]?.string == aid)
    let items = (status["exits"]?.array ?? []).compactMap(\.object)
    #expect(items.first { $0["id"]?.string == aid }?["stale"]?.bool == true)
    #expect(items.first { $0["id"]?.string == bid }?["name"]?.string == "My subscription name")
    #expect(!items.contains { $0["id"]?.string == cname })
    let sub = status["subscriptions"]?.array?.first?.object
    #expect(sub?["host"]?.string == "subscribe.example.test")
    #expect(sub?["count"]?.int == 3)
    #expect(sub?["updated_at"]?.string != nil)
    #expect(sub?["error"] == .null)
    #expect(cli.run("sub-rm", subid, "--json").code == 1)
    body = nil
    let failure = cli.run("sub-update", "--json")
    #expect(failure.code == 1)
    #expect(!failure.stdout.contains("sensitive-fixture-token"))
    #expect(calls == 3)
    let failedList = try cli.call("exits")
    #expect(failedList["subscriptions"]?.array?.first?.object?["error"]?.string == "could not download subscription")
    #expect(try cli.call("exit-use", "relay")["active"]?.string == "relay")
    #expect(try cli.call("sub-rm", subid)["removed"]?.int == 3)
    #expect(try cli.call("exits")["exits"]?.array?.count == 1)
}

@Test func exitTestUsesPrivateAskpassAndEncodesResultWithoutCredentials() throws {
    let state = try makeConfTestDirectory()
    defer { try? FileManager.default.removeItem(at: state) }
    let cli = ConfHarness(state: state)
    let legacy = ConfExit(id: "relay", name: "Relay", kind: .ssh, host: "localhost", port: 18443, user: "test-user")
    let new = ConfExit(id: "h123456", name: "Test", kind: .ssh, host: "localhost", port: 18443, user: "test-user")
    #expect(String(decoding: ConfExitTest.askpassScript(legacy), as: UTF8.self) ==
            "#!/bin/sh\nexec /usr/bin/security find-generic-password -s vpnuser-relay -a test-user -w\n")
    #expect(String(decoding: ConfExitTest.askpassScript(new), as: UTF8.self) ==
            "#!/bin/sh\nexec /usr/bin/security find-generic-password -s gozar-ssh -a h123456 -w\n")
    let helper = state.appendingPathComponent("askpass")
    let ssh = try ConfExitTest.sshProcess(new, port: 18333, askpass: helper,
                                          knownHosts: state.appendingPathComponent("known_hosts"), seconds: 2)
    #expect(ssh.environment?["SSH_ASKPASS"] == helper.path)
    #expect(ssh.environment?["SSH_ASKPASS_REQUIRE"] == "force")
    #expect(ssh.arguments?.contains("127.0.0.1:18333") == true)
    #expect(ssh.arguments?.contains("PreferredAuthentications=password") == true)
    let xid = try #require(try cli.call("exit-add", fixtureLink("vless-ws"))["ids"]?.strings.first)
    let response = cli.run("exit-test", xid, "--seconds", "1", "--json")
    #expect(response.code == 0)
    let result = try #require(try ConfJSON(parsing: response.stdout).array?.first?.object)
    #expect(result["id"]?.string == xid)
    #expect(result["ok"]?.bool == false)
    #expect(result["connect_ms"] == .null)
    #expect(result["mbps"] == .null)
    #expect(result["error"]?.string?.contains("XRAY_BIN") == true)
    #expect(!response.stdout.contains(fakeID))
    let success = ConfExitTest.Result(id: xid, connectMS: 19.25, mbps: 10.1, error: nil)
    #expect(success.json.rendered() == "{\"id\": \"\(xid)\", \"ok\": true, \"connect_ms\": 19.25, \"mbps\": 10.1, \"error\": null}")
}

