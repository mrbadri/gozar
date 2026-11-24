import Foundation

public struct RouterHTTPRequest: Equatable, Sendable {
    public static let maxHeadBytes = 16 * 1024
    public static let terminator = Data([13, 10, 13, 10])

    public let method: String
    public let path: String
    public let hasBody: Bool
    private let query: [URLQueryItem]
    private let authorization: String?

    public init?(_ head: Data) {
        guard head.count <= Self.maxHeadBytes, head.suffix(4) == Self.terminator,
              let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, !request[0].isEmpty, request[0].utf8.allSatisfy(Self.isToken),
              request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0",
              request[1].hasPrefix("/"), !request[1].hasPrefix("//"),
              request[1].utf8.allSatisfy({ (33...126).contains($0) }),
              let url = URLComponents(string: String(request[1])), url.fragment == nil else { return nil }
        var auth: String?
        var contentLength: Int?
        var transferEncoded = false
        for line in lines.dropFirst().dropLast(2) {
            guard let colon = line.firstIndex(of: ":"), colon > line.startIndex,
                  line[..<colon].utf8.allSatisfy(Self.isToken) else { return nil }
            let value = line[line.index(after: colon)...]
            guard value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else { return nil }
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            switch line[..<colon].lowercased() {
            case "authorization":
                guard auth == nil else { return nil }
                auth = trimmed
            case "content-length":
                guard contentLength == nil, !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
                      let length = Int(trimmed) else { return nil }
                contentLength = length
            case "transfer-encoding":
                transferEncoded = true
            default: break
            }
        }
        method = String(request[0])
        path = url.percentEncodedPath
        hasBody = transferEncoded || (contentLength ?? 0) > 0
        query = url.queryItems ?? []
        authorization = auth
    }

    public func parameter(_ name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    public func isAuthorized(token: String) -> Bool {
        guard let header = authorization, let separator = header.firstIndex(of: " "),
              header[..<separator].lowercased() == "bearer" else { return false }
        let given = header[separator...].drop(while: { $0 == " " }).utf8
        let expected = token.utf8
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func isToken(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122, 33, 35...39, 42, 43, 45, 46, 94...96, 124, 126:
            return true
        default: return false
        }
    }
}
