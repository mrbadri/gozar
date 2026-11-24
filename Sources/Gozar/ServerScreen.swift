import GozarCore
import SwiftUI

struct ServerMonitoring: View {
    let app: AppModel

    var body: some View {
        if let response = app.grafana, !response.series.values.allSatisfy(\.isEmpty) {
            Card { box(response) }
            poolCards(response)
            HStack(alignment: .top, spacing: Theme.gap) {
                VStack(spacing: Theme.gap) {
                    latencyCharts(response)
                    stealChart(response)
                }
                .frame(maxWidth: .infinity)
                members(response)
                    .frame(width: 310)
            }
        } else {
            Card { EmptyMessage(title: L.emptyServer, symbol: "server.rack") }
        }
        if let failure = app.grafanaFailure {
            Card {
                InlineIssue(message: failure)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func box(_ response: GrafanaResponse) -> some View {
        let steal = response.value("steal")
        let memory = response.value("mem_free")
        return HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.vpn)
                        .frame(width: 43, height: 43)
                        .background(Theme.vpn.opacity(0.13), in: .rect(cornerRadius: 12))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Technical(app.box["name"] ?? L.noValue, font: Theme.headline)
                        Technical(app.box["target"] ?? L.noValue, font: .caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L.serverAddress + " " + (app.box["target"] ?? L.noValue))
                    }
                }
                HStack(spacing: 12) {
                    timing(L.onThisBoxSince, response.value("since"))
                    timing(L.uptime, response.value("uptime"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().frame(height: 62)
            GaugeMetric(title: L.steal, value: steal, color: Theme.health(steal, threshold: 0.10))
            GaugeMetric(title: L.freeMemory, value: memory, color: Theme.direct)
            Divider().frame(height: 62)
            VStack(alignment: .leading, spacing: 4) {
                Label(L.nicTraffic, systemImage: "arrow.up.right").font(Theme.type(.caption)).foregroundStyle(.secondary)
                Technical(response.value("nic_tx").map(Fmt.rate) ?? L.noValue,
                          font: .system(size: 23, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(spacing: 5) {
                    Text(L.cpuOurs)
                    Technical(Fmt.percent(response.value("cpu_ours")))
                }
                .font(Theme.type(.caption2))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 125, alignment: .leading)
        }
        .frame(minHeight: 77)
    }

    private func timing(_ label: String, _ seconds: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.type(.caption2)).foregroundStyle(.secondary)
            Technical(Fmt.duration(seconds), font: .callout.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    private func poolCards(_ response: GrafanaResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(L.pools, "point.3.connected.trianglepath.dotted").padding(.horizontal, 2)
            HStack(spacing: Theme.gap) {
                ForEach(["app", "ci", "phone", "vpn"], id: \.self) { name in
                    let count = response.series["pools"]?.first { $0.labels["pool"] == name }?.points.last?.value
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Technical(name, font: .callout.weight(.semibold))
                                Spacer(minLength: 0)
                                ForEach(0..<2) { index in
                                    HealthDot(color: count.map { $0 > Double(index) ? .green : .orange } ?? .gray)
                                }
                            }
                            Technical(count.map { "\(Int($0)) / 2" } ?? L.noValue, font: .caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(count.map { "\(Int($0))/2 " + L.healthy } ?? L.noValue)
                    }
                }
            }
        }
    }

    private func members(_ response: GrafanaResponse) -> some View {
        let data = (response.series["members"] ?? []).compactMap(Member.init).sorted { ($0.pool, $0.id) < ($1.pool, $1.id) }
        return Card {
            VStack(alignment: .leading, spacing: 9) {
                SectionHeading(L.members, "server.rack")
                HStack {
                    Text(L.member).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L.route).frame(width: 55, alignment: .leading)
                    Text(L.state).frame(width: 88, alignment: .leading)
                }
                .font(Theme.type(.caption, .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                if data.isEmpty {
                    Text(L.emptyServer).font(Theme.type(.callout)).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(data.enumerated()), id: \.element.id) { index, member in
                            HStack(spacing: 6) {
                                Technical(member.id, font: .callout.weight(.medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Technical(member.pool, font: .caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 55, alignment: .leading)
                                HStack(spacing: 5) {
                                    HealthDot(color: member.color)
                                    Text(member.label).font(Theme.type(.caption)).lineLimit(1)
                                }
                                .frame(width: 88, alignment: .leading)
                            }
                            .padding(.horizontal, 7)
                            .frame(height: 33)
                            .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.037) : .clear,
                                        in: .rect(cornerRadius: 5))
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    private func latencyCharts(_ response: GrafanaResponse) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(title: L.latency, symbol: "waveform.path.ecg") {
                    Text(L.history30m).font(Theme.type(.caption)).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        chartNumber(L.ping, response.value("ping").map { Fmt.milliseconds($0 * 1_000) }, Theme.vpn)
                        MetricChart(response.samples("ping_range"), color: Theme.vpn, axes: true) { Fmt.milliseconds($0 * 1_000) }
                            .frame(height: 79)
                            .accessibilityLabel(L.ping + " · " + L.history30m)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        chartNumber(L.loss, Fmt.percent(response.value("loss"), places: 1), Theme.cisco)
                        MetricChart(response.samples("loss_range"), color: Theme.cisco, axes: true) { Fmt.percent($0, places: 1) }
                            .frame(height: 79)
                            .accessibilityLabel(L.loss + " · " + L.history30m)
                    }
                }
            }
        }
    }

    private func stealChart(_ response: GrafanaResponse) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(title: L.steal, symbol: "cpu") {
                    Technical(Fmt.percent(response.value("steal"), places: 1), font: .callout.weight(.semibold))
                    Text(L.history30m).font(Theme.type(.caption)).foregroundStyle(.secondary)
                }
                MetricChart(response.samples("steal_range"), color: Theme.direct, axes: true) { Fmt.percent($0) }
                    .frame(height: 113)
                    .accessibilityLabel(L.steal + " · " + L.history30m)
            }
        }
    }

    private func chartNumber(_ name: String, _ number: String?, _ color: Color) -> some View {
        HStack(spacing: 6) {
            HealthDot(color: color)
            Text(name).font(Theme.type(.caption)).foregroundStyle(.secondary)
            Technical(number ?? L.noValue, font: .caption.weight(.semibold))
        }
    }

    private struct Member {
        let id: String
        let pool: String
        let label: String
        let color: Color

        init?(_ series: GrafanaSeries) {
            guard let id = series.labels["member"], let pool = series.labels["pool"],
                  let state = series.points.last?.value else { return nil }
            self.id = id
            self.pool = pool
            (label, color) = switch state {
            case 1: (L.healthy, .green)
            case 0: (L.unhealthy, .red)
            case 2: (L.draining, .orange)
            case -1: (L.maintenance, .gray)
            default: (L.noValue, .gray)
            }
        }
    }
}

private struct GaugeMetric: View {
    let title: String
    let value: Double?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(Theme.type(.caption)).foregroundStyle(.secondary).lineLimit(1)
            Technical(Fmt.percent(value, places: title == L.steal ? 1 : 0),
                      font: .system(size: 25, weight: .semibold, design: .rounded))
            GeometryReader { proxy in
                Capsule().fill(color.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color)
                            .frame(width: proxy.size.width * min(1, max(0, value ?? 0)))
                    }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .frame(width: 107, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

enum Guide {
    static let url = URL(string: "https://github.com/mrbadri/gozar#grafana")!
}
