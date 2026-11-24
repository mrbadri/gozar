import Darwin
import Foundation

struct ConfExitTest {
    struct Result: Sendable {
        let id: String
        let connectMS: Double?
        let mbps: Double?
        let error: String?

        var json: ConfJSON {
            .object([
                "id": .string(id), "ok": .bool(error == nil),
                "connect_ms": connectMS.map { .number(String($0)) } ?? .null,
                "mbps": mbps.map { .number(String($0)) } ?? .null,
                "error": error.map(ConfJSON.string) ?? .null,
            ])
        }
    }

    let xrayBinary: URL?
    let knownHosts: URL

    func run(exits: [ConfExit], seconds: Int) -> [Result] {
        let results = Results()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        for (index, exit) in exits.enumerated() {
            queue.addOperation { results.set(test(exit, seconds: seconds), at: index) }
        }
        queue.waitUntilAllOperationsAreFinished()
        return results.ordered
    }

    private func test(_ exit: ConfExit, seconds: Int) -> Result {
        var connectMS: Double?
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gozar-exit-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }

            let reservation = try ReservedPort()
            let process = try upstream(exit, port: reservation.port, directory: directory, seconds: seconds)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            reservation.releaseSocket()
            do {
                try process.run()
            } catch {
                throw ConfigError("could not launch \(exit.kind.rawValue)")
            }
            defer { Self.stop(process) }

            let readyDeadline = DispatchTime.now() + .seconds(seconds)
            while process.isRunning, DispatchTime.now() < readyDeadline {
                if ConfNetwork().listening(reservation.port) { break }
                Thread.sleep(forTimeInterval: 0.025)
            }
            guard process.isRunning else { throw ConfigError("\(exit.kind.rawValue) exited during startup") }
            guard DispatchTime.now() < readyDeadline else { throw ConfigError("upstream startup timed out") }

            var samples: [Double] = []
            for _ in 0..<3 { samples.append(try measureConnect(port: reservation.port, seconds: min(seconds, 3))) }
            connectMS = samples.sorted()[1]
            let mbps = try download(port: reservation.port, seconds: seconds)
            return Result(id: exit.id, connectMS: connectMS, mbps: mbps, error: nil)
        } catch {
            return Result(id: exit.id, connectMS: connectMS, mbps: nil, error: error.localizedDescription)
        }
    }

    private func upstream(_ exit: ConfExit, port: Int, directory: URL, seconds: Int) throws -> Process {
        switch exit.kind {
        case .xray:
            guard let xrayBinary else { throw ConfigError("Xray binary unavailable; set XRAY_BIN") }
            let file = directory.appendingPathComponent("xray.json")
            let data = try exit.parsedLink().configuration(port: port)
            guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
            else { throw ConfigError("could not write test Xray configuration") }
            let process = Process()
            process.executableURL = xrayBinary
            process.arguments = ["run", "-c", file.path]
            return process
        case .ssh:
            let hosts = directory.appendingPathComponent("known_hosts")
            if FileManager.default.fileExists(atPath: knownHosts.path) {
                try FileManager.default.copyItem(at: knownHosts, to: hosts)
            }
            let askpass = directory.appendingPathComponent("askpass")
            guard FileManager.default.createFile(atPath: askpass.path, contents: Self.askpassScript(exit),
                                                 attributes: [.posixPermissions: 0o700])
            else { throw ConfigError("could not write SSH password helper") }
            return try Self.sshProcess(exit, port: port, askpass: askpass, knownHosts: hosts, seconds: seconds)
        }
    }

    static func askpassScript(_ exit: ConfExit) -> Data {
        let service = shellQuote(exit.keychainService)
        let account = shellQuote(exit.keychainAccount)
        return Data("#!/bin/sh\nexec /usr/bin/security find-generic-password -s \(service) -a \(account) -w\n".utf8)
    }

    static func sshProcess(_ exit: ConfExit, port: Int, askpass: URL, knownHosts: URL, seconds: Int) throws -> Process {
        guard let host = exit.host.flatMap(normalizedExitHost), let serverPort = exit.port,
              (1...65535).contains(serverPort), let user = exit.user, validSSHUser(user) else {
            throw ConfigError("invalid SSH host, port or user")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-F", "/dev/null", "-N", "-D", "127.0.0.1:\(port)", "-p", String(serverPort), "-l", user,
            "-o", "ExitOnForwardFailure=yes", "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
            "-o", "NumberOfPasswordPrompts=1", "-o", "ConnectTimeout=\(seconds)",
            "-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=accept-new", "--", host,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askpass.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        process.environment = environment
        return process
    }

    private func measureConnect(port: Int, seconds: Int) throws -> Double {
        let deadline = DispatchTime.now() + .seconds(seconds)
        let socket = try LoopbackSocket(port: port, deadline: deadline)
        try socket.send([5, 1, 0], deadline: deadline)
        guard try socket.receive(2, deadline: deadline) == [5, 0] else { throw ConfigError("upstream did not offer SOCKS5") }
        let start = DispatchTime.now()
        try socket.send([5, 1, 0, 1, 1, 1, 1, 1, 1, 187], deadline: deadline)
        let header = try socket.receive(4, deadline: deadline)
        guard header[0] == 5, header[1] == 0 else { throw ConfigError("SOCKS CONNECT to 1.1.1.1:443 failed") }
        let addressLength: Int
        switch header[3] {
        case 1: addressLength = 4
        case 3: addressLength = Int(try socket.receive(1, deadline: deadline)[0])
        case 4: addressLength = 16
        default: throw ConfigError("invalid SOCKS CONNECT reply")
        }
        _ = try socket.receive(addressLength + 2, deadline: deadline)
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private func download(port: Int, seconds: Int) throws -> Double {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = curlArguments(socks: port) + [
            "--fail", "--max-time", String(seconds), "--max-filesize", "2000000", "--output", "/dev/null",
            "--write-out", "%{size_download} %{time_total}", "https://speed.cloudflare.com/__down?bytes=2000000",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let values = String(decoding: data, as: UTF8.self).split(separator: " ").compactMap { Double($0) }
        guard [0, 28].contains(process.terminationStatus), values.count == 2, values[0] > 0, values[1] > 0 else {
            throw ConfigError("speed download failed")
        }
        return values[0] * 8 / values[1] / 1_000_000
    }

    private static func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let until = DispatchTime.now() + .milliseconds(500)
            while process.isRunning && DispatchTime.now() < until { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var byIndex: [Int: Result] = [:]

        func set(_ result: Result, at index: Int) {
            lock.lock()
            defer { lock.unlock() }
            byIndex[index] = result
        }

        var ordered: [Result] {
            lock.lock()
            defer { lock.unlock() }
            return byIndex.sorted { $0.key < $1.key }.map(\.value)
        }
    }
}

private final class ReservedPort {
    private static let poolLock = NSLock()
    private static var used = Set<Int>()
    private var socket: Int32
    let port: Int

    init() throws {
        Self.poolLock.lock()
        defer { Self.poolLock.unlock() }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConfigError("could not allocate test port") }
        var succeeded = false
        defer { if !succeeded { close(fd) } }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw ConfigError("could not allocate test port") }
        // Let the kernel select a free port and retain it until just before the child binds.
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let selected = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress -> Bool in
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                return bind(fd, socketAddress, length) == 0 && getsockname(fd, socketAddress, &length) == 0
            }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        guard selected, port >= 18300, Self.used.insert(port).inserted else {
            throw ConfigError("could not allocate a free test port at or above 18300")
        }
        self.socket = fd
        self.port = port
        succeeded = true
    }

    func releaseSocket() {
        if socket >= 0 { close(socket); socket = -1 }
    }

    deinit {
        releaseSocket()
        Self.poolLock.lock()
        Self.used.remove(port)
        Self.poolLock.unlock()
    }
}

