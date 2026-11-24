import Foundation

struct ConfDomains {
    private static let multiSuffix: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.jp", "ne.jp", "co.kr",
        "co.in", "co.nz", "com.br", "com.tr", "com.cn", "com.hk", "com.tw", "com.sg", "com.mx",
        "co.ir", "ac.ir", "gov.ir", "org.ir", "sch.ir", "id.ir", "net.ir",
    ]
    private static let shared: Set<String> = [
        "google.com", "googleapis.com", "gstatic.com", "googleusercontent.com", "googletagmanager.com",
        "google-analytics.com", "doubleclick.net", "googlesyndication.com", "gvt1.com", "gvt2.com",
        "cloudfront.net", "amazonaws.com", "akamaihd.net", "akamaized.net", "akamai.net", "edgekey.net",
        "fastly.net", "fastly.com", "cloudflare.com", "cloudflare.net", "jsdelivr.net", "unpkg.com",
        "azureedge.net", "azurewebsites.net", "msecnd.net", "facebook.net", "fbcdn.net", "twimg.com",
    ]

    let files: ConfFiles
    let network: ConfNetwork

    func report(site: String, cisco: Bool, name: String?, all: Bool) throws -> ConfJSON {
        var host = hostOf(site)
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        guard !host.isEmpty else { throw ConfigError("invalid site") }
        let labels = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).components(separatedBy: ".")
        let suffix = labels.suffix(2).joined(separator: ".")
        let baseCount = labels.count >= 3 && Self.multiSuffix.contains(suffix) ? 3 : min(labels.count, 2)
        let base = labels.suffix(baseCount).joined(separator: ".")
        let subdomain = labels.dropLast(baseCount).last
        guard let company = labels.suffix(baseCount).first, !company.isEmpty else { throw ConfigError("invalid site") }
        let list = subdomain.map { "\(company)-\($0)" } ?? company
        let routes = try? ConfRoutes(files).load()
        let proposedTitle = name ?? list.replacingOccurrences(of: "-", with: " ").capitalized
        let title = routes.flatMap { data in
            ConfRoutes.rules(in: data, includeDisabled: true).compactMap { $0["name"]?.string }.first {
                $0.lowercased() == proposedTitle.lowercased()
            }
        } ?? proposedTitle
        let socks = network.socksPort(files)
        var seen = Set<String>()
        let listed = geosite(list, socks: socks, depth: 0, seen: &seen)
        let suggestions = subdomain != nil && Self.shared.contains(base) && !all ? [host] : listed ?? []
        let listedJSON: ConfJSON = listed.map { domains in
            .object([
                "name": .string(list),
                "domains": .array(domains.map { domain in
                    let hostname = String(domain.drop(while: { $0 == "*" || $0 == "." }))
                    return .object([
                        "domain": .string(domain),
                        "route": .string(ConfRoutes.currentRoute(routes, host: hostname, cisco: cisco)),
                    ])
                }),
            ])
        } ?? .null
        return .object([
            "site": .string(site), "title": .string(title), "via": .string(socks == nil ? "direct" : "vpn"),
            "listed": listedJSON, "live": .null, "suggested": .strings(suggestions),
        ])
    }

    private func geosite(_ name: String, socks: Int?, depth: Int, seen: inout Set<String>) -> [String]? {
        guard depth <= 2, seen.insert(name).inserted else { return [] }
        guard name.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil,
              let bytes = network.fetch("https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/\(name)",
                                        socks, nil, false),
              let text = String(data: bytes, encoding: .utf8) else { return nil }
        let country = #"^"# + NSRegularExpression.escapedPattern(for: name) + #"\.([a-z]{2}|(co|com)\.[a-z]{2})$"#
        var domains: [String] = []
        for line in text.components(separatedBy: ConfFiles.lineBreaks) {
            let value = pythonStrip(firstPart(line, before: "#"))
            if value.isEmpty { continue }
            let attributes = value.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("@") }
            if attributes.contains("@ads") || attributes.contains("@cn") { continue }
            let site = pythonStrip(value.replacingOccurrences(of: #"\s*@\S+"#, with: "", options: .regularExpression))
            let fields = site.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let kind = fields.count == 2 && !fields[1].isEmpty ? String(fields[0]) : "domain"
            let entry = fields.count == 2 && !fields[1].isEmpty ? String(fields[1]) : site
            switch kind {
            case "include":
                domains += geosite(entry, socks: socks, depth: depth + 1, seen: &seen) ?? []
            case "keyword", "regexp":
                continue
            default:
                let domain = entry.lowercased()
                if domain.range(of: country, options: .regularExpression) == nil {
                    domains.append(domain.contains(".") ? domain : "*." + domain)
                }
            }
        }
        var unique = Set<String>()
        return domains.filter { unique.insert($0).inserted }
    }
}

