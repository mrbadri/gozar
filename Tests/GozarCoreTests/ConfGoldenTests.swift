import Foundation
import Testing

private enum Seed {
    case standard, empty, old, migrated, noConnection, badConnection(String), badRoutes(String)
}

private struct GoldenCase {
    let args: [String]
    let seed: Seed

    init(_ args: [String], _ seed: Seed = .standard) {
        self.args = args
        self.seed = seed
    }
}

@Test func confCLIMatchesPython() throws {
    let package = confTestPackage
    let defaults = confTestDefaults
    let binary = try gozarctlTestBinary()
    let root = try makeConfTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    var cases: [GoldenCase] = [
        .init(["init"], .empty), .init(["init"], .old), .init(["init"]), .init(["init"], .migrated),
        .init(["init"], .badRoutes(#"{"rules": "#)), .init(["validate"]),
        .init(["validate"], .migrated), .init(["validate"], .noConnection),
        .init(["validate"], .badConnection("[]")),
        .init(["validate"], .badConnection(".")),
        .init(["validate"], .badConnection(#"{"relay":{"host":5,"port":"42"},"keepalive":[],"ciphers":[],"router":{"enabled":"true","control_port":18081,"upstream_port":18081,"unknown":1},"local_socks_port":true,"ignore":0}"#)),
        .init(["validate"], .badConnection(#"{"relay":{"host":"test","port":18443,"user":"test"},"connect_timeout_seconds":"5","reconnect_delay_seconds":1.25,"keepalive":{"max_missed":"3"},"router":null}"#)),
        .init(["validate"], .badRoutes("{\n  \"rules\": [],\n}")),
        .init(["validate"], .badRoutes(#"{"rules" []}"#)),
        .init(["validate"], .badRoutes(#"{"rules":[]} garbage"#)),
        .init(["validate"], .badRoutes(#"{"rules": ["abc]}"#)),
        .init(["validate"], .badRoutes("\u{feff}{}")),
        .init(["validate"], .badRoutes(#"{"title":"sample","rules":[null,{"name":"  ","route":"مستقیم","hosts":[12,"a&b"],"domains":["",null,"sp ace.com","hi.*.com","a_b.com"],"enabled":0,"note":null,"without_cisco":"direct","domains_extra":1},{"route":"cisco","without_cisco":"cisco","domains":{}},{"name":false,"route":"vpn","domain":[]}]}"#)),
        .init(["routes"], .badRoutes(#"{"rules":"wrong"}"#)),
        .init(["sites"]), .init(["sites"], .badRoutes("[]")),
        .init(["conn-env"]), .init(["conn-env"], .migrated), .init(["conn-env", "--defaults"], .empty),
        .init(["conn-env", "--defaults"], .migrated), .init(["conn-env"], .noConnection),
        .init(["conn-env"], .badConnection(#"{"relay":{"host":"t' hé","port":18443,"user":""},"keepalive":{"max_missed":false},"ciphers":["foo","bar + baz"],"local_socks_port":18080}"#)),
        .init(["conn-env"], .badConnection(#"{"relay":{"host":"example.test","port":true,"user":"test"},"local_socks_port":18080}"#)),
        .init(["set", "https://www.YouTube.com/watch?v=1", "machine-QA", "direct"]),
        .init(["set", "*.example.com", "مثال.ir", "vpn"]),
        .init(["set", "UPPERCASE.Example.test", "cisco"]), .init(["set", ".example.com", "direct"]),
        .init(["set", "https://", "direct"]), .init(["set", "abc", "bogus"]), .init(["set", "vpn"]),
        .init(["unset", "https://www.company.example/?a", "CORP-MGMT01", "*.example.com", "no-list.test"]),
        .init(["unset"]), .init(["unset", "claude.ai"], .badRoutes(#"{"rules": [}"#)),
        .init(["add-to", "Fresh", "cisco", "http://www.fresh.test/path", "QA-local", "foo.example.test"]),
        .init(["add-to", "company", "vpn", "company.example", "claude.ai"]),
        .init(["add-to", "Fresh", "vpn", "machine_1"]), .init(["add-to", "Fresh", "vpn", "bad_site.com"]),
        .init(["add-to", "Fresh", "direct", "*.local"]), .init(["add-to", "Fresh", "vpn", "bad machine"]),
        .init(["add-to", "Fresh", "donot"]), .init(["add-to", "Fresh"]), .init(["add-to", "Fresh", "direct"]),
        .init(["rule-set", "CLAUDE", "--enabled", "false", "--note", "یادداشت آزمایشی \u{1f5a5}"]),
        .init(["rule-set", "claude", "--rename", "گذر", "--without-cisco", "direct"]),
        .init(["rule-set", "Claude", "--route", "direct"]),
        .init(["rule-set", "Claude", "--route", "vpn", "--without-cisco", "none"]),
        .init(["rule-set", "Claude", "--without-cisco", "none"]),
        .init(["rule-set", "Iranian sites", "--without-cisco", "vpn"]),
        .init(["rule-set", "Claude", "--rename", "DIGIKALA"]),
        .init(["rule-set", "Claude", "--rename", ""]),
        .init(["rule-set", "Claude", "--enabled", "TRUE"]),
        .init(["rule-set", "Claude", "--note", "--route", "vpn"]),
        .init(["rule-set", "Claude", "--unexpected"]),
        .init(["rule-set", "missing", "--route", "direct"]),
        .init(["rule-delete", "DiGiKaLa"]), .init(["rule-delete", "missing"]), .init(["rule-delete"]),
        .init(["rule-move", "Selected subdomains", "--to", "0"]),
        .init(["rule-move", "--to=2", "YouTube"]),
        .init(["rule-move", "--to", "０", "YouTube"]),
        .init(["rule-move", "Iranian sites", "--to", "99999999999999999999999999"]),
        .init(["rule-move", "Iranian sites", "--to", "-1"]),
        .init(["rule-move", "Iranian sites", "--to", "2.0"]),
        .init(["rule-move", "Iranian sites"]),
        .init(["check"]), .init(["check", "--unknown", "example.com"]), .init(["check", "--cisco=false", "example.com"]),
        .init(["bypass", "--router"], .empty), .init(["bypass", "--json"]), .init(["routes", "extra"]),
        .init(["nonexistent"]),
    ]
    for command in ["bypass", "check", "routes", "add-to", "rule-set", "rule-delete", "rule-move"] {
        cases.append(.init([command, "-h"]))
    }
    for cisco in [false, true] {
        let flags = cisco ? ["--cisco"] : []
        for json in [false, true] {
            let options = flags + (json ? ["--json"] : [])
            cases.append(.init(["routes"] + options))
            for site in ["company.example", "api.company.example", "CORP-MGMT01", "CLAUDE.AI", "a.lab.company.example",
                         "shaparak.ir", "ir", "evil-ir.com", "example.com", "m.example.com", "disabled-host",
                         "desk.office.invalid", "localhost", "203.0.113.4", "https://User:pw@WWW.Example.NET:443/path",
                         "www.example.com:443", "https:///", "203.0.113.2", "video.youtube.com"] {
                cases.append(.init(["check", site] + options))
            }
        }
        cases.append(.init(["bypass"] + flags))
        cases.append(.init(["bypass", "--router"] + flags))
    }
    try #require(cases.count >= 60)
    let script = defaults.appendingPathComponent("vpnconf.py")
    let connection = try confTestConnection()
    let routes = try Data(contentsOf: package.appendingPathComponent("Tests/fixtures/routes.sample.json"))
    let python = URL(fileURLWithPath: "/usr/bin/python3")
    var mismatches = 0

    for (index, test) in cases.enumerated() {
        let pythonDir = root.appendingPathComponent("\(index)-python")
        let swiftDir = root.appendingPathComponent("\(index)-swift")
        let dirs = [pythonDir, swiftDir]
        for parent in dirs {
            let state = parent.appendingPathComponent("state")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            func seed(_ file: String, _ data: Data) throws { try data.write(to: state.appendingPathComponent(file)) }
            switch test.seed {
            case .standard, .migrated, .noConnection:
                try seed("routes.json", routes)
                if case .noConnection = test.seed {} else { try seed("connection.json", connection) }
            case .old:
                try seed("direct.txt", Data("# old rules\n*.example.test  # keep\nexample.test\nAPARAT.COM\nnew.example\n".utf8))
            case .badConnection(let raw):
                try seed("routes.json", routes)
                try seed("connection.json", Data(raw.utf8))
            case .badRoutes(let raw):
                try seed("routes.json", Data(raw.utf8))
                try seed("connection.json", connection)
            case .empty: break
            }
        }

        var environment = ProcessInfo.processInfo.environment
        // The same relative state path gives both programs identical user-facing paths.
        environment["LAPTOP_VPN_STATE"] = "state"
        environment["LAPTOP_VPN_CONF_DIR"] = defaults.path
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["COLUMNS"] = "80"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        if case .migrated = test.seed {
            _ = try runConfTestProcess(python, args: [script.path, "init"], in: pythonDir, environment: environment)
            _ = try runConfTestProcess(binary, args: ["init"], in: swiftDir, environment: environment)
        }

        let expected = try runConfTestProcess(python, args: [script.path] + test.args, in: pythonDir, environment: environment)
        let actual = try runConfTestProcess(binary, args: test.args, in: swiftDir, environment: environment)
        let prefix = test.args.first == "conn-env" && expected.code == 0
        let statusMatches = actual.code == expected.code
        let outputMatches = prefix ? actual.stdout.starts(with: expected.stdout) : actual.stdout == expected.stdout
        let errorsMatch = actual.stderr == expected.stderr
        var changedFiles: [String] = []
        for name in ["routes.json", "connection.json", "direct.txt", "direct.txt.old"] {
            let files = dirs.map { $0.appendingPathComponent("state/\(name)") }
            let bytes = files.map { try? Data(contentsOf: $0) }
            if bytes[0] != bytes[1] { changedFiles.append(name) }
        }
        if !statusMatches || !outputMatches || !errorsMatch || !changedFiles.isEmpty {
            mismatches += 1
            let out = !outputMatches ? "stdout expected \(String(decoding: expected.stdout, as: UTF8.self).debugDescription), got \(String(decoding: actual.stdout, as: UTF8.self).debugDescription)" : ""
            let err = !errorsMatch ? "stderr expected \(String(decoding: expected.stderr, as: UTF8.self).debugDescription), got \(String(decoding: actual.stderr, as: UTF8.self).debugDescription)" : ""
            Issue.record("\(test.args) with \(String(describing: test.seed)): Python exit \(expected.code), Swift exit \(actual.code). \(out) \(err) Files: \(changedFiles.joined(separator: ", "))")
        }
    }
    print("gozarctl Python golden: \(cases.count) invocations, \(mismatches) mismatches (exit, stdout, stderr and file bytes)")
    #expect(mismatches == 0)
}

let confTestPackage = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let confTestDefaults = confTestPackage.appendingPathComponent("cli/laptop-vpn.d")

func confTestConnection() throws -> Data {
    let original = try String(contentsOf: confTestDefaults.appendingPathComponent("connection.default.json"), encoding: .utf8)
    let adjusted = original
        .replacingOccurrences(of: "\"local_socks_port\": 1080", with: "\"local_socks_port\": 18080")
        .replacingOccurrences(of: "\"upstream_port\": 1081", with: "\"upstream_port\": 18081")
        .replacingOccurrences(of: "\"control_port\": 1090", with: "\"control_port\": 18090")
    return Data(adjusted.utf8)
}

func makeConfTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gozar-conf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private final class ConfGoldenBundleMarker: NSObject {}

func gozarctlTestBinary() throws -> URL {
    var path = Bundle(for: ConfGoldenBundleMarker.self).bundleURL.path
    while !path.isEmpty && path != "/" {
        let candidate = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("gozarctl")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        path = (path as NSString).deletingLastPathComponent
    }
    let fallback = confTestPackage.appendingPathComponent(".build/debug/gozarctl")
    if FileManager.default.isExecutableFile(atPath: fallback.path) { return fallback }
    throw CocoaError(.fileNoSuchFile)
}

func runConfTestProcess(
    _ executable: URL, args: [String], in directory: URL, environment: [String: String]
) throws -> (code: Int32, stdout: Data, stderr: Data) {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executable
    process.arguments = args
    process.environment = environment
    process.currentDirectoryURL = directory
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, bytes, diagnostics)
}

