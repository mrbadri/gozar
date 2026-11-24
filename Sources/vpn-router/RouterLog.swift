import Darwin
import Foundation
import GozarCore
import OSLog

final class RouterLog {
    static let logger = Logger(subsystem: "ir.mrbadri.gozar", category: "router")
    private let path: URL
    private let clock = DateFormatter()
    private var descriptor: Int32 = -1

    init(path: URL) {
        self.path = path
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss"
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func started(at date: Date) {
        write("--- \(date.formatted(.iso8601)) router started")
    }

    func connection(_ stat: ConnStat) {
        let time = clock.string(from: stat.endedAt ?? stat.startedAt)
        let host = "\(stat.host):\(stat.port)"
        if let error = stat.error {
            let singleLine = error.components(separatedBy: .newlines).joined(separator: " ")
            write("\(time) ✗ \(host) [\(stat.route.rawValue)] \(singleLine)", failed: true)
        } else {
            write("\(time) → \(host) [\(stat.route.rawValue)]")
        }
    }

    private func write(_ line: String, failed: Bool = false) {
        if failed { Self.logger.error("\(line, privacy: .private)") }
        else { Self.logger.info("\(line, privacy: .private)") }
        if descriptor < 0 {
            descriptor = open(path.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            Self.logger.error("Could not open router.log")
            return
        }
        var metadata = stat()
        if fstat(descriptor, &metadata) == 0, metadata.st_size >= 20 * 1024 * 1024 {
            if ftruncate(descriptor, 0) != 0 { Self.logger.error("Could not rotate router.log") }
        }
        let bytes = Array((line + "\n").utf8)
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    Self.logger.error("Could not write router.log")
                    return
                }
                offset += written
            }
        }
    }
}
