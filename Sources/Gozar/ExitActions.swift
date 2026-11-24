import Foundation
import GozarCore

enum ExitInput {
    case links([String])
    case subscription(String)
    case ssh(host: String, port: Int, user: String, password: String)

    init(paste: String) throws {
        let values = paste.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = values.first else { throw AppError(L.pasteLink) }
        if values.count == 1, let url = URLComponents(string: first),
           let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
           let host = url.host, !host.isEmpty {
            self = .subscription(first)
        } else if values.allSatisfy({ value in
            guard let delimiter = value.range(of: "://"),
                  delimiter.upperBound < value.endIndex else { return false }
            return ["vless", "vmess", "trojan", "ss"].contains(String(value[..<delimiter.lowerBound]))
        }) {
            self = .links(values)
        } else {
            throw AppError(L.invalidExitLinks)
        }
    }

    init(host: String, port: String, user: String, password: String) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.hasPrefix("-"), !user.isEmpty, !user.hasPrefix("-"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              user.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let port = Int(port), (1...65535).contains(port), !password.isEmpty else {
            throw AppError(L.invalidSSH)
        }
        self = .ssh(host: host, port: port, user: user, password: password)
    }
}

enum ExitMutation {
    case activate(String)
    case rename(String, String)
    case remove(String)
    case updateSubscription(String)
    case removeSubscription(String)

    var command: [String] {
        switch self {
        case .activate(let id): ["exit-use", "--json", "--", id]
        case .rename(let id, let name): ["exit-rename", "--json", "--", id, name]
        case .remove(let id): ["exit-rm", "--json", "--", id]
        case .updateSubscription(let id): ["sub-update", "--json", "--", id]
        case .removeSubscription(let id): ["sub-rm", "--json", "--", id]
        }
    }
}

struct AddedExits: Decodable { let ids: [String] }
struct AddedSubscription: Decodable { let id: String }

func publicExitError(_ message: String) -> String {
    // Links and subscription URLs may appear verbatim in output from a child process.
    let pattern = #"(?i)\b(?:https?|vless|vmess|trojan|ss)://[^\s"'<>]+"#
    return message.replacingOccurrences(of: pattern, with: "…", options: .regularExpression)
}
