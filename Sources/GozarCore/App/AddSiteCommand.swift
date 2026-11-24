import Foundation

public enum AddSiteCommand: Equatable, Sendable {
    case vpn([String])
    case configuration([String])

    public init(site raw: String, route: Route, rule: String? = nil) throws {
        let site = try Self.address(raw)
        if let rule {
            self = .configuration(["add-to", "--", rule, route.rawValue, site])
        } else {
            self = .vpn(["set", site, route.rawValue])
        }
    }

    public static func address(_ raw: String) throws -> String {
        var site = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !site.hasPrefix("-"), site.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ConfigError("invalid site")
        }
        if site.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#")) != nil {
            let url = site.contains("://") ? site : "https://" + site
            guard let host = URL(string: url)?.host?.lowercased() else { throw ConfigError("invalid site URL") }
            site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        _ = try RuleEngine.parseDomain(site)
        return site
    }
}
