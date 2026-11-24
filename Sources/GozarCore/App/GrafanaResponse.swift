import Foundation

public struct MetricPoint: Sendable, Equatable, Identifiable {
    public let at: Date
    public let value: Double
    public var id: Date { at }

    public init(at: Date, value: Double) {
        self.at = at
        self.value = value
    }
}

public struct GrafanaSeries: Sendable, Equatable {
    public let labels: [String: String]
    public let points: [MetricPoint]

    public init(labels: [String: String] = [:], points: [MetricPoint]) {
        self.labels = labels
        self.points = points
    }
}

public struct GrafanaResponse: Sendable {
    public let series: [String: [GrafanaSeries]]
    public let failedQueries: Set<String>

    public init(series: [String: [GrafanaSeries]], failedQueries: Set<String> = []) {
        self.series = series
        self.failedQueries = failedQueries
    }

    public func samples(_ key: String) -> [MetricPoint] {
        series[key]?.first?.points ?? []
    }

    public func value(_ key: String) -> Double? {
        samples(key).last?.value
    }

    public static func parse(_ data: Data) throws -> GrafanaResponse {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var series: [String: [GrafanaSeries]] = [:]
        var failures: Set<String> = []
        for (key, result) in payload.results {
            if result.error != nil || (result.status ?? 200) >= 400 { failures.insert(key) }
            series[key] = (result.frames ?? []).flatMap { $0.series() }
        }
        return GrafanaResponse(series: series, failedQueries: failures)
    }

    private struct Payload: Decodable {
        let results: [String: Result]
    }

    private struct Result: Decodable {
        let status: Int?
        let error: String?
        let frames: [Frame]?
    }

    private struct Frame: Decodable {
        let schema: Schema
        let data: Columns

        struct Schema: Decodable {
            let fields: [Field]
        }

        struct Field: Decodable {
            let type: String
            let labels: [String: String]?
        }

        struct Columns: Decodable {
            let values: [[Sample]]
        }

        // Other column types can appear alongside Time and Value fields.
        struct Sample: Decodable {
            let number: Double?

            init(from decoder: Decoder) throws {
                let item = try decoder.singleValueContainer()
                number = (try? item.decode(Double.self)) ?? (try? item.decode(String.self)).flatMap(Double.init)
            }
        }

        func series() -> [GrafanaSeries] {
            guard let timeIndex = schema.fields.firstIndex(where: { $0.type == "time" }),
                  data.values.indices.contains(timeIndex) else { return [] }
            let times = data.values[timeIndex]
            return schema.fields.enumerated().compactMap { index, field in
                guard field.type == "number", data.values.indices.contains(index) else { return nil }
                let points: [MetricPoint] = zip(times, data.values[index]).compactMap { time, sample in
                    guard let time = time.number, time.isFinite,
                          let value = sample.number, value.isFinite else { return nil }
                    return MetricPoint(at: Date(timeIntervalSince1970: time / 1000), value: value)
                }
                guard !points.isEmpty else { return nil }
                return GrafanaSeries(labels: field.labels ?? [:], points: points.sorted { $0.at < $1.at })
            }
        }
    }
}
