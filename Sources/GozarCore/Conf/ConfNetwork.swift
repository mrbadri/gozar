import Darwin
import Foundation

struct ConfNetwork {
    var listening: (Int) -> Bool = { port in
        guard let socket = try? LoopbackSocket(port: port, deadline: .now() + .milliseconds(500)) else { return false }
        return socket.fd >= 0
    }
    var fetch: (String, Int?, String?, Bool) -> Data? = { url, socks, userAgent, redirects in
        guard let config = curlURL(url) else { return nil }
        var args = curlArguments(socks: socks) + [
            "--fail", "--max-time", "20", "--max-filesize", "10000000", "--config", "-",
        ]
        if redirects { args += ["--location", "--max-redirs", "5", "--proto-redir", "=http,https"] }
        if let userAgent { args += ["--user-agent", userAgent] }
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = args
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input
        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: config)
            try input.fileHandleForWriting.close()
        } catch {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            return nil
        }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? bytes : nil
    }

    func socksPort(_ files: ConfFiles) -> Int? {
        guard let port = try? ConfConnection(files).socksPort, listening(port) else { return nil }
        return port
    }
}

func curlArguments(socks: Int?) -> [String] {
    let proxy = socks.map { "socks5h://127.0.0.1:\($0)" } ?? ""
    return ["--disable", "--silent", "--globoff", "--proto", "=http,https", "--proxy", proxy, "--noproxy", ""]
}

private func curlURL(_ url: String) -> Data? {
    // Send subscription URLs on stdin so their tokens stay out of curl's command line.
    guard url.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { return nil }
    let quoted = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return Data("url = \"\(quoted)\"\n".utf8)
}

final class LoopbackSocket {
    let fd: Int32

    init(port: Int, deadline: DispatchTime) throws {
        guard let port = UInt16(exactly: port) else { throw ConfigError("invalid SOCKS port") }
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw ConfigError("could not open a loopback socket") }
        var succeeded = false
        defer { if !succeeded { close(socket) } }
        guard fcntl(socket, F_SETFL, O_NONBLOCK) == 0, fcntl(socket, F_SETFD, FD_CLOEXEC) == 0 else {
            throw ConfigError("could not set loopback socket flags")
        }
        var enabled: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ConfigError("could not set loopback socket options")
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let result = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EINTR else { throw ConfigError("upstream is unavailable") }
            try Self.wait(socket, event: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw ConfigError("upstream is unavailable")
            }
        }
        fd = socket
        succeeded = true
    }

    deinit { close(fd) }

    private static func wait(_ fd: Int32, event: Int16, deadline: DispatchTime) throws {
        var item = pollfd(fd: fd, events: event, revents: 0)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { throw ConfigError("SOCKS request timed out") }
            let ms = min(UInt64(Int32.max), (deadline.uptimeNanoseconds - now + 999_999) / 1_000_000)
            let count = poll(&item, 1, Int32(ms))
            if count > 0, item.revents & event != 0 { return }
            if count == 0 { throw ConfigError("SOCKS request timed out") }
            if count > 0 || errno != EINTR { throw ConfigError("SOCKS socket closed") }
        }
    }

    func send(_ bytes: [UInt8], deadline: DispatchTime) throws {
        try bytes.withUnsafeBytes { buffer in
            var position = 0
            while position < buffer.count {
                try Self.wait(fd, event: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(fd, buffer.baseAddress?.advanced(by: position), buffer.count - position)
                if count > 0 { position += count }
                else if count == 0 || (errno != EAGAIN && errno != EINTR) { throw ConfigError("SOCKS write failed") }
            }
        }
    }

    func receive(_ length: Int, deadline: DispatchTime) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        try bytes.withUnsafeMutableBytes { buffer in
            var position = 0
            while position < buffer.count {
                try Self.wait(fd, event: Int16(POLLIN), deadline: deadline)
                let count = Darwin.read(fd, buffer.baseAddress?.advanced(by: position), buffer.count - position)
                if count > 0 { position += count }
                else if count == 0 || (errno != EAGAIN && errno != EINTR) { throw ConfigError("SOCKS reply ended early") }
            }
        }
        return bytes
    }
}

