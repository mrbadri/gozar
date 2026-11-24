import Darwin
import Foundation

public func registrableDomain(_ host: String) -> String {
    if host.contains(":") { return host }
    var ip = in_addr()
    if inet_pton(AF_INET, host, &ip) == 1 { return host }
    let labels = host.lowercased().split(separator: ".")
    guard labels.count >= 2 else { return labels.first.map(String.init) ?? host }
    let suffix = labels[labels.count - 1].utf8
    let countryCode = suffix.count == 2 && suffix.allSatisfy { (97...122).contains($0) }
    let categories: Set<Substring> = ["co", "com", "net", "org", "ac", "gov", "edu"]
    let count = countryCode && categories.contains(labels[labels.count - 2]) ? 3 : 2
    return labels.suffix(count).joined(separator: ".")
}

public struct ProbeHistory: Sendable {
    public enum Sample: Sendable {
        case latency(Double)
        case failure(String)
    }

    private var recent: [Sample] = []

    public init() {}

    public mutating func record(_ sample: Sample) {
        if recent.count == 30 { recent.removeFirst() }
        if case .latency(let ms) = sample, ms > 5000 {
            recent.append(.failure("Timed out"))
        } else {
            recent.append(sample)
        }
    }

    public func stat(name: String, target: String) -> ProbeStat {
        let latencies = recent.compactMap { sample -> Double? in
            if case .latency(let ms) = sample { return ms }
            return nil
        }.sorted()
        let median: Double? = latencies.isEmpty ? nil :
            (latencies[(latencies.count - 1) / 2] + latencies[latencies.count / 2]) / 2
        let loss = recent.isEmpty ? 0 : Double(recent.count - latencies.count) / Double(recent.count)
        switch recent.last {
        case .latency(let ms):
            return ProbeStat(name: name, target: target, lastMs: ms, medianMs: median, loss: loss, samples: recent.count)
        case .failure(let error):
            return ProbeStat(name: name, target: target, medianMs: median, loss: loss, samples: recent.count, lastError: error)
        case nil:
            return ProbeStat(name: name, target: target, loss: loss, samples: recent.count)
        }
    }
}
