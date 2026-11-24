import Darwin
import Foundation

public enum SocksWire {
    public enum Version: UInt8, Sendable { case four = 4, five = 5 }

    public struct Destination: Equatable, Sendable {
        public let host: String
        public let port: UInt16

        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    public enum Parse<Value: Equatable>: Equatable {
        case need(Int)
        case value(Value)
        case reject(UInt8)
    }

    public static func greeting(_ bytes: [UInt8]) -> Parse<UInt8> {
        guard bytes.count >= 2 else { return .need(2) }
        guard bytes[0] == 5 else { return .reject(0xff) }
        let end = 2 + Int(bytes[1])
        guard bytes.count >= end else { return .need(end) }
        return bytes[2..<end].contains(0) ? .value(0) : .reject(0xff)
    }

    public static func request(_ bytes: [UInt8]) -> Parse<Destination> {
        guard bytes.count >= 4 else { return .need(4) }
        guard bytes[0] == 5, bytes[2] == 0 else { return .reject(1) }
        guard bytes[1] == 1 else { return .reject(7) }
        guard let end = addressEnd(bytes) else { return .reject(8) }
        guard bytes.count >= end else { return .need(end) }
        let port = UInt16(bytes[end - 2]) << 8 | UInt16(bytes[end - 1])
        guard port != 0 else { return .reject(1) }
        let host: String?
        switch bytes[3] {
        case 1: host = bytes[4..<8].map(String.init).joined(separator: ".")
        case 4:
            var address = Array(bytes[4..<20])
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let success = address.withUnsafeMutableBytes {
                inet_ntop(AF_INET6, $0.baseAddress, &output, socklen_t(output.count)) != nil
            }
            host = success ? String(cString: output) : nil
        default: host = hostname(bytes[5..<end - 2])
        }
        guard let host else { return .reject(8) }
        return .value(Destination(host: host, port: port))
    }

    public static func request4(_ bytes: [UInt8]) -> Parse<Destination> {
        guard bytes.count >= 2 else { return .need(2) }
        guard bytes[0] == 4, bytes[1] == 1 else { return .reject(0x5b) }
        guard bytes.count >= 8 else { return .need(8) }
        let port = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        guard port != 0 else { return .reject(0x5b) }
        // Read NUL-terminated fields without consuming pipelined application data.
        let userEnd = 8 + 255
        guard let user = bytes[8..<min(bytes.count, userEnd + 1)].firstIndex(of: 0) else {
            return bytes.count <= userEnd ? .need(bytes.count + 1) : .reject(0x5b)
        }
        let ip = bytes[4..<8]
        if ip.prefix(3).allSatisfy({ $0 == 0 }), ip.last != 0 {
            let start = user + 1
            let hostEnd = start + 255
            guard let end = bytes[start..<min(bytes.count, hostEnd + 1)].firstIndex(of: 0) else {
                return bytes.count <= hostEnd ? .need(bytes.count + 1) : .reject(0x5b)
            }
            guard let host = hostname(bytes[start..<end]) else { return .reject(0x5b) }
            return .value(Destination(host: host, port: port))
        }
        return .value(Destination(host: ip.map(String.init).joined(separator: "."), port: port))
    }

    public static func upstreamRequest(_ destination: Destination) -> Data? {
        let name = destination.host.utf8
        guard let count = UInt8(exactly: name.count), count > 0 else { return nil }
        var bytes: [UInt8] = [5, 1, 0, 3, count]
        bytes.append(contentsOf: name)
        bytes.append(UInt8(destination.port >> 8))
        bytes.append(UInt8(truncatingIfNeeded: destination.port))
        return Data(bytes)
    }

    public static func upstreamReply(_ bytes: [UInt8]) -> Parse<UInt8> {
        guard bytes.count >= 4 else { return .need(4) }
        guard bytes[0] == 5, bytes[2] == 0 else { return .reject(1) }
        guard bytes[1] == 0 else { return .reject(bytes[1] == 5 ? 5 : 1) }
        guard let end = addressEnd(bytes) else { return .reject(1) }
        return bytes.count < end ? .need(end) : .value(0)
    }

    public static func reply(_ version: Version, code: UInt8) -> Data {
        switch version {
        case .four: return Data([0, code == 0 ? 0x5a : 0x5b, 0, 0, 0, 0, 0, 0])
        case .five: return Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0])
        }
    }

    private static func addressEnd(_ bytes: [UInt8]) -> Int? {
        switch bytes[3] {
        case 1: return 10
        case 3: return bytes.count < 5 ? 5 : 7 + Int(bytes[4])
        case 4: return 22
        default: return nil
        }
    }

    private static func hostname(_ bytes: ArraySlice<UInt8>) -> String? {
        // A SOCKS hostname may be UTF-8 but cannot contain whitespace or controls.
        guard !bytes.isEmpty, let host = String(bytes: bytes, encoding: .utf8),
              host.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return host
    }
}
