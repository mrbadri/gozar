import Foundation
import GozarCore

actor GrafanaClient {
    private struct Datasource: Decodable {
        let uid: String
        let type: String
        let isDefault: Bool?
    }

    private struct Query: Encodable {
        struct Source: Encodable {
            let uid: String
            let type = "prometheus"
        }

        let refId: String
        let expr: String
        let datasource: Source
        let instant: Bool
        let range: Bool
        let format = "time_series"
        let intervalMs = 30_000
        let interval = "30s"
        let maxDataPoints = 61
    }

    private struct Payload: Encodable {
        let from = "now-30m"
        let to = "now"
        let queries: [Query]
    }

    private let session: URLSession
    private var discovered: (base: URL, uid: String)?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    static func baseURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    func fetch(base: URL, token: String) async throws -> GrafanaResponse {
        let uid: String
        if let discovered, discovered.base == base {
            uid = discovered.uid
        } else {
            let data = try await request(base.appendingPathComponent("api/datasources"), token: token)
            let sources = try JSONDecoder().decode([Datasource].self, from: data).filter { $0.type == "prometheus" }
            guard let source = sources.first(where: { $0.isDefault == true }) ?? sources.first else {
                throw AppError("Grafana: Prometheus datasource unavailable")
            }
            uid = source.uid
            discovered = (base, uid)
        }

        let source = Query.Source(uid: uid)
        let queries = Self.expressions.sorted(by: { $0.key < $1.key }).flatMap { key, expression in
            let instant = Query(refId: key, expr: expression, datasource: source, instant: true, range: false)
            guard Self.range.contains(key) else { return [instant] }
            return [instant, Query(refId: key + "_range", expr: expression, datasource: source, instant: false, range: true)]
        }
        let body = try JSONEncoder().encode(Payload(queries: queries))
        let data = try await request(base.appendingPathComponent("api/ds/query"), token: token, body: body)
        return try GrafanaResponse.parse(data)
    }

    private func request(_ url: URL, token: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError("Grafana: invalid response") }
        // Grafana can return partial results with HTTP 400.
        guard http.statusCode == 200 || (body != nil && http.statusCode == 400) else {
            throw AppError("Grafana: HTTP \(http.statusCode)")
        }
        return data
    }

    private static let range: Set<String> = ["ping", "loss", "steal", "openrouter"]
    private static let expressions = [
        "box": "egress_host_info",
        "since": "time() - max(egress_host_since_timestamp_seconds)",
        "uptime": "time() - max(egress_host_boot_time_seconds)",
        "steal": #"sum(rate(egress_host_cpu_seconds_total{mode="steal"}[2m])) / clamp_min(sum(rate(egress_host_cpu_seconds_total[2m])), 0.001)"#,
        "cpu_ours": #"sum(rate(egress_host_cpu_seconds_total{mode=~"user|nice|system|irq|softirq"}[2m])) / clamp_min(sum(rate(egress_host_cpu_seconds_total[2m])), 0.001)"#,
        "mem_free": "max(egress_host_memory_available_bytes) / max(egress_host_memory_total_bytes)",
        "nic_tx": "sum(rate(egress_host_network_transmit_bytes_total[2m]))",
        "ping": "max(egress_tunnel_icmp_rtt_seconds)",
        "loss": "max(egress_tunnel_icmp_loss_ratio)",
        "pools": "max by (pool) (egress_tunnel_pool_healthy_members)",
        "phone_banner": #"min(egress_tunnel_probe_median_seconds{pool="phone",probe="banner"})"#,
        "openrouter": #"min(egress_tunnel_probe_median_seconds{pool="app",probe="openrouter"})"#,
        "members": "max by (pool, member) (egress_tunnel_haproxy_state)",
    ]

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
