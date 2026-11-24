import Foundation
import Testing
@testable import GozarCore

@Test func appFormatsTechnicalValuesWithLatinDigits() {
    #expect(Fmt.bytes(1_200_000) == "1.2 MB")
    #expect(Fmt.bytes(UInt64(803)) == "803 B")
    #expect(Fmt.bytes(999_999) == "1.0 MB")
    #expect(Fmt.rate(1_200_000) == "1.2 MB/s")
    #expect(Fmt.compactRate(1_200_000) == "1.2M")
    #expect(Fmt.milliseconds(85) == "85 ms")
    #expect(Fmt.milliseconds(1_200) == "1.2 s")
    #expect(Fmt.milliseconds(nil) == "—")
    #expect(Fmt.duration(11_520) == "3h 12m")
    #expect(Fmt.duration(90) == "1m 30s")
    #expect(Fmt.percent(0.046, places: 1) == "4.6%")
    #expect(Fmt.duration(.infinity) == "—")
}

@Test func appParsesSupportedSSEEventsAndIgnoresUnknownEvents() throws {
    let at = Date(timeIntervalSince1970: 1_795_529_104.125)
    let conn = ConnStat(id: 42, host: "api.example.test", port: 443, route: .vpn, startedAt: at, state: .open)
    let tick = Tick(at: at, totals: .init(vpn: .init(open: 1, rateDown: 120.5)),
                    openUpdates: [.init(id: 42, bytesUp: 10, bytesDown: 300, rateUp: 9, rateDown: 120.5)])
    var failed = conn
    failed.state = .failed
    failed.error = "Upstream unavailable"

    let encoder = ControlAPI.makeEncoder()
    encoder.outputFormatting = .prettyPrinted
    var parser = RouterEventParser()

    func feed(_ event: String, _ data: Data) throws -> RouterEvent? {
        if let value = try parser.consume("event: " + event) {
            Issue.record("Event delivered before its blank line: \(value)")
        }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let value = try parser.consume("data: " + line)
            #expect(value == nil)
        }
        return try parser.consume("")
    }

    #expect(try parser.consume(": ping") == nil)
    #expect(try parser.consume("") == nil)
    #expect(try feed("open", encoder.encode(conn)) == .open(conn))
    #expect(try feed("tick", encoder.encode(tick)) == .tick(tick))
    #expect(try feed("future_event", Data("not-json".utf8)) == nil)
    #expect(try feed("close", encoder.encode(failed)) == .close(failed))
    #expect(try parser.consume("") == nil)
}

@Test func appParsesRecordedGrafanaPrometheusResponse() throws {
    let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/grafana/prometheus-recording.json")
    let response = try GrafanaResponse.parse(Data(contentsOf: file))
    let series = try #require(response.series["A"]?.first)
    #expect(response.series["A"]?.count == 1)
    #expect(response.failedQueries.isEmpty)
    #expect(series.labels == ["khaleesi_health": "dead", "khaleesi_service": "backgate"])
    #expect(series.points.map(\.value) == [0, 0])
    #expect(series.points.last?.at == Date(timeIntervalSince1970: 1_641_646_110))
}

@Test func appParsesGrafanaPartialResultsAndMissingSamples() throws {
    let data = Data("""
    {
      "results": {
        "box": {"status": 200, "frames": [{
          "schema": {"fields": [
            {"type": "number", "labels": {"name": "egress-example", "target": "192.0.2.12"}},
            {"type": "time"}, {"type": "string"}
          ]},
          "data": {"values": [[null, 1, "NaN", "2.5"], [30000, 0, 90000, 60000], ["ignored"]]}
        }]},
        "loss": {"status": 400, "error": "query unavailable"},
        "pools": {"frames": []}
      }
    }
    """.utf8)
    let response = try GrafanaResponse.parse(data)
    #expect(response.failedQueries == ["loss"])
    #expect(response.series["box"]?.first?.labels["target"] == "192.0.2.12")
    #expect(response.samples("box").map(\.value) == [1, 2.5])
    #expect(response.samples("box").map { $0.at.timeIntervalSince1970 } == [0, 60])
    #expect(response.value("box") == 2.5)
    #expect(response.value("pools") == nil)
}
