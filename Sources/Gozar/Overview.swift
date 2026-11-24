import GozarCore
import SwiftUI

struct Overview: View {
    let app: AppModel

    var body: some View {
        ScreenPage(screen: .overview) {
            if let router = app.router {
                Label { Technical("v\(router.version)") } icon: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                    .font(Theme.type(.caption))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L.routerMode)
            }
        } content: {
            PageScroll(spacing: 11) {
                Card(padding: 12) { hero }
                if app.router != nil {
                    Card(padding: 12) { ChainView(app: app) }
                    traffic
                    Card(padding: 12) { top }
                    if let error = app.router?.rulesError { errorNotice(error) }
                } else {
                    RouterEmpty(app: app)
                    if app.classic { Card { classicStatus } }
                }
                if let stopped = app.vpn.stopped, !app.on { errorNotice(stopped) }
                if let error = app.statusFailure { errorNotice(error) }
                ForEach(app.vpn.notes, id: \.self) { note in errorNotice(note, symbol: "info.circle") }
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 20) {
            ConnectSwitch(app: app)
            VStack(alignment: .leading, spacing: 6) {
                ConnectionState(app: app)
                if let ip = app.vpn.exitIP {
                    HStack(spacing: 8) {
                        Text(L.exitIP).font(Theme.type(.callout)).foregroundStyle(.secondary)
                        Technical(ip, font: .callout.weight(.medium))
                    }
                }
                if let via = app.vpn.via {
                    Label { Technical(via) } icon: { Image(systemName: "arrow.triangle.branch") }
                        .font(Theme.type(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 115, maxWidth: 180, alignment: .leading)
            Spacer(minLength: 0)
            if app.router != nil {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 20) {
                        RateReadout(title: L.download, symbol: "arrow.down", value: app.totals.rateDown, route: .vpn)
                        Divider().frame(height: 51)
                        RateReadout(title: L.upload, symbol: "arrow.up", value: app.totals.rateUp, route: .direct)
                    }
                    ExitPicker(app: app)
                        .padding(.top, 2)
                }
                .frame(minWidth: 390, maxWidth: 515, alignment: .leading)
            } else {
                ExitPicker(app: app).frame(maxWidth: 290)
            }
        }
        .frame(minHeight: 120)
        .padding(.horizontal, 7)
    }

    private var traffic: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeading(title: L.traffic, symbol: "waveform.path") {
                Text(L.history2m).font(Theme.type(.caption)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
            HStack(spacing: Theme.gap) {
                ForEach(Route.ordered, id: \.self) { route in
                    RouteTraffic(app: app, route: route)
                }
            }
        }
    }

    private var top: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeading(L.topNow, "chart.bar.xaxis")
            if app.topDomains.isEmpty {
                EmptyMessage(title: L.emptyDomains, symbol: "globe")
            } else {
                DomainLeaders(domains: Array(app.topDomains.prefix(6)), columns: 2)
            }
        }
    }

    private var classicStatus: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeading(L.classicMode, "switch.2")
            HStack(spacing: 22) {
                ToggleReadout(name: L.proxy, enabled: app.vpn.proxy)
                ToggleReadout(name: L.routeCisco, enabled: app.vpn.cisco)
                if let copy = app.vpn.ciscoCopy { ToggleReadout(name: L.ciscoCopy, enabled: copy) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorNotice(_ text: String, symbol: String = "exclamationmark.triangle") -> some View {
        Card(padding: 12) {
            Label(text, systemImage: symbol)
                .font(Theme.type(.callout))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ConnectSwitch: View {
    let app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compact = false

    private var title: String {
        if app.connecting { return L.connecting }
        return app.on || app.vpn.loop ? L.disconnect : L.connect
    }

    var body: some View {
        let size: CGFloat = compact ? 53 : 120
        let animate = !reduceMotion && !app.snapshot
        Button(action: app.toggleConnection) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(app.on || app.connecting) || !animate)) { timeline in
                let seconds = animate ? timeline.date.timeIntervalSinceReferenceDate : 0
                let angle = app.connecting ? seconds.truncatingRemainder(dividingBy: 2) * 180 : 0
                let breathing = app.on && animate ? 0.34 + 0.10 * sin(seconds * 1.7) : 0.40
                ZStack {
                    Circle()
                        .fill(.radialGradient(colors: [Theme.vpn.opacity(breathing * 0.51), .clear],
                                              center: .center, startRadius: size / 3, endRadius: size * 0.67))
                        .scaleEffect(1.36)
                        .opacity(app.on || app.connecting ? 1 : 0)
                    Circle().strokeBorder(Theme.accent(app).opacity(0.22))
                    Circle().strokeBorder(Theme.accent(app).opacity(0.32))
                        .padding(compact ? 3 : 6)
                    Circle()
                        .fill(app.on || app.connecting ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.thinMaterial))
                        .shadow(color: app.on || app.connecting ? Theme.vpn.opacity(breathing) : .clear, radius: 18)
                        .padding(compact ? 7 : 13)
                    Circle()
                        .strokeBorder(.linearGradient(colors: [.white.opacity(0.45), .white.opacity(0.04)],
                                                      startPoint: .topTrailing, endPoint: .bottomLeading))
                        .padding(compact ? 7 : 13)
                    if app.connecting {
                        Circle()
                            .strokeBorder(AngularGradient(colors: [.clear, Theme.vpn, Theme.blue, .clear],
                                                          center: .center, angle: .degrees(angle)), lineWidth: 2)
                    }
                    Image(systemName: "power")
                        .font(.system(size: compact ? 19 : 37, weight: .medium))
                        .foregroundStyle(app.on || app.connecting ? .white : .secondary)
                        .symbolEffect(.pulse, isActive: app.connecting && animate)
                }
                .frame(width: size, height: size)
            }
        }
        .buttonStyle(.plain)
        .disabled(app.working)
        .accessibilityLabel(title)
        .accessibilityValue(app.on ? L.connected : L.disconnected)
        .help(title)
        .animation(reduceMotion ? nil : Theme.motion, value: app.on)
        .animation(reduceMotion ? nil : Theme.motion, value: app.connecting)
    }
}

struct ConnectionState: View {
    let app: AppModel

    var body: some View {
        let label = app.connecting ? L.connecting : app.problem ? L.problem : app.on ? L.connected : L.disconnected
        HStack(spacing: 8) {
            HealthDot(color: app.connecting ? Theme.vpn : app.problem ? Theme.cisco : app.on ? Theme.good : .gray, size: 8)
            Text(label).font(Theme.headline).lineLimit(1)
        }
    }
}

private struct RateReadout: View {
    let title: String
    let symbol: String
    let value: Double
    let route: Route
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let display = Fmt.rate(value)
        let parts = display.split(separator: " ", maxSplits: 1)
        return VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: symbol)
                .font(Theme.type(.callout, .medium))
                .foregroundStyle(Theme.routeInk(route, in: colorScheme))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(parts.first.map(String.init) ?? display)
                    .font(Theme.number)
                    .foregroundStyle(.linearGradient(colors: [Theme.routeInk(route, in: colorScheme), Theme.color(route)],
                                                      startPoint: .top, endPoint: .bottom))
                    .contentTransition(.numericText())
                if parts.count > 1 {
                    Technical(String(parts[1]), font: .caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.76)
            .environment(\.layoutDirection, .leftToRight)
            .animation(reduceMotion ? nil : Theme.motion, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct RouteTraffic: View {
    let app: AppModel
    let route: Route
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let sample = app.totals[route]
        let color = Theme.color(route)
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    RouteChip(route: route)
                    Spacer(minLength: 0)
                    Technical(String(sample.open), font: .caption.weight(.semibold))
                    Text(L.openConnections).font(Theme.type(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 12) {
                    Label { Technical(Fmt.rate(sample.rateDown), font: .subheadline.weight(.semibold)) } icon: {
                        Image(systemName: "arrow.down").foregroundStyle(color)
                    }
                    .accessibilityLabel(L.download + " " + Fmt.rate(sample.rateDown))
                    Spacer(minLength: 0)
                    Label { Technical(Fmt.rate(sample.rateUp), font: .caption) } icon: {
                        Image(systemName: "arrow.up")
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L.upload + " " + Fmt.rate(sample.rateUp))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : Theme.motion, value: sample)
                MetricChart(app.routeHistory(route), color: color)
                    .frame(height: 30)
                    .accessibilityLabel(L.download + " · " + L.history2m)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ChainView: View {
    let app: AppModel
    var compact = false
    @Environment(\.colorScheme) private var colorScheme

    private var links: [LinkReading] {
        let relay = app.probe("relay")
        let ping = app.grafana?.value("ping").map { $0 * 1_000 }
        let openrouter = app.grafana?.value("openrouter").map { $0 * 1_000 }
        return [
            LinkReading(time: relay?.lastMs, color: Theme.health(relay?.lastMs, threshold: 60, loss: relay?.loss),
                        weight: app.totals.rateDown),
            LinkReading(time: ping, color: Theme.health(ping, threshold: 150, loss: app.grafana?.value("loss")),
                        weight: app.totals[.vpn].rateDown, loss: app.grafana?.value("loss")),
            LinkReading(time: openrouter, color: Theme.health(openrouter, threshold: 1_000),
                        weight: app.totals[.vpn].rateDown),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 8) {
            if !compact { SectionHeading(L.path, "point.3.connected.trianglepath.dotted") }
            HStack(alignment: .top, spacing: compact ? 1 : 10) {
                node(0, L.nodeMac, "laptopcomputer", app.history("local"), compact ? links[0].color : Theme.direct)
                link(links[0])
                node(1, L.nodeIran, "server.rack", app.history("relay"), links[0].color)
                link(links[1])
                node(2, L.nodeEgress, "externaldrive.connected.to.line.below",
                     app.grafana?.samples("ping_range") ?? [], links[1].color)
                link(links[2])
                node(3, L.nodeInternet, "globe.americas",
                     app.grafana?.samples("openrouter_range") ?? [], links[2].color)
            }
            .frame(maxWidth: .infinity)
            if !compact {
                HStack(spacing: 12) {
                    tunnelReading
                    Capsule()
                        .fill(Theme.health(app.probe("tunnel")?.lastMs, threshold: 400, redAt: 800).opacity(0.27))
                        .frame(height: 1)
                        .accessibilityHidden(true)
                    egressReadings
                }
            }
        }
    }

    private var tunnelReading: some View {
        let latency = app.probe("tunnel")?.lastMs
        let points = Array(app.history("tunnel").suffix(22))
        let color = Theme.health(latency, threshold: 400, redAt: 800)
        return HStack(spacing: 8) {
            Text(L.endToEnd).foregroundStyle(.secondary)
            Technical(Fmt.milliseconds(latency), font: .caption.weight(.semibold))
                .foregroundStyle(Theme.health(latency, threshold: 400, redAt: 800, textOn: colorScheme))
            if !points.isEmpty {
                MetricChart(points, color: color)
                    .frame(width: 82, height: 17)
                    .accessibilityHidden(true)
            }
        }
        .font(Theme.type(.caption))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.32), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func node(_ index: Int, _ name: String, _ symbol: String, _ points: [MetricPoint], _ color: Color) -> some View {
        VStack(spacing: compact ? 3 : 4) {
            if compact {
                HealthDot(color: color, size: 10)
                    .frame(height: 18)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(index == 2 ? Theme.vpn : color)
                    .frame(width: 56, height: 56)
                    .background {
                        Circle().fill(.linearGradient(colors: [color.opacity(0.20), color.opacity(0.035)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay { Circle().strokeBorder(color.opacity(0.31)) }
                    }
                    .accessibilityHidden(true)
            }
            HStack(spacing: 6) {
                Text(name)
                    .font(compact ? Theme.type(.caption2) : Theme.type(.subheadline, .semibold))
                if index == 2, !compact, let server = app.box["name"] {
                    Technical(server, font: .caption2).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            if !compact {
                MetricChart(Array(points.suffix(22)), color: color)
                    .frame(width: 68, height: 16)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: compact ? 48 : index == 2 ? 144 : 115)
        .accessibilityElement(children: .combine)
    }

    private var egressReadings: some View {
        let steal = app.grafana?.value("steal")
        let memory = app.grafana?.value("mem_free")
        return HStack(spacing: 12) {
            nodeMetric(L.steal, value: Fmt.percent(steal, places: 1),
                       color: Theme.health(steal, threshold: 0.10, textOn: colorScheme))
            nodeMetric(L.freeMemory, value: Fmt.percent(memory))
        }
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }

    private func nodeMetric(_ title: String, value: String, color: Color = .secondary) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Technical(value, font: .caption.weight(.semibold)).foregroundStyle(color)
        }
        .font(Theme.type(.caption))
        .help(title)
        .accessibilityLabel(title + " " + value)
    }

    private func link(_ reading: LinkReading) -> some View {
        VStack(spacing: 3) {
            ZStack {
                ChainLink(color: reading.color, rate: reading.weight, snapshot: app.snapshot, compact: compact)
                if !compact {
                    HStack(spacing: 4) {
                        Technical(Fmt.milliseconds(reading.time), font: .caption2.weight(.semibold))
                        if let loss = reading.loss {
                            Technical(Fmt.percent(loss, places: 1), font: .caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(L.loss + " " + Fmt.percent(loss, places: 1))
                        }
                    }
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(colorScheme == .dark ? Theme.hex(0x20233C) : Theme.hex(0xF1F2FB), in: Capsule())
                    .overlay { Capsule().strokeBorder(reading.color.opacity(0.29)) }
                    .fixedSize()
                }
            }
            .frame(height: compact ? 13 : 30)
            if compact {
                Technical(Fmt.milliseconds(reading.time), font: .system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary).fixedSize()
            }
        }
        .padding(.top, compact ? 2 : 13)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private struct LinkReading {
        let time: Double?
        let color: Color
        let weight: Double
        var loss: Double?
    }
}

private struct ChainLink: View {
    let color: Color
    let rate: Double
    let snapshot: Bool
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || rate < 1 || snapshot)) { timeline in
            Canvas { context, size in
                let speed = 0.27 + min(0.65, log10(max(1, rate)) * 0.10)
                let phase = snapshot ? 0.18 : (timeline.date.timeIntervalSinceReferenceDate * speed)
                    .truncatingRemainder(dividingBy: 1)
                let height: CGFloat = compact ? 2 : 6
                let y = size.height / 2
                let capsule = Path(roundedRect: CGRect(x: 0, y: y - height / 2, width: size.width, height: height),
                                   cornerRadius: height / 2)
                context.fill(capsule, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.20), color.opacity(0.65), color.opacity(0.30)]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)
                ))
                if rate >= 1, !reduceMotion {
                    let diameter: CGFloat = compact ? 3 : 4
                    for index in 0..<(compact ? 1 : 4) {
                        let position = (phase + Double(index) / 4).truncatingRemainder(dividingBy: 1)
                        let x = (1 - position) * max(0, size.width - diameter)
                        let dot = Path(ellipseIn: CGRect(x: x, y: y - diameter / 2, width: diameter, height: diameter))
                        context.fill(dot, with: .color(color))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct DomainLeaders: View {
    let domains: [DomainStat]
    var columns = 1
    var compact = false

    var body: some View {
        let maxRate = max(1, domains.first?.rateDown ?? 0)
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: compact ? 7 : 6) {
            ForEach(0..<((domains.count + columns - 1) / columns), id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if domains.indices.contains(index) { leader(domains[index], maxRate: maxRate) }
                        else { Color.clear.gridCellUnsizedAxes([.vertical]) }
                    }
                }
            }
        }
    }

    private func leader(_ domain: DomainStat, maxRate: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Technical(domain.domain, font: compact ? .caption.weight(.medium) : .callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                RouteChip(route: domain.route)
                Technical(Fmt.rate(domain.rateDown), font: .caption.weight(.medium))
                    .frame(width: compact ? 65 : 76, alignment: .trailing)
            }
            if !compact {
                GeometryReader { geometry in
                    Capsule().fill(Theme.color(domain.route).opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.color(domain.route).opacity(0.68))
                                .frame(width: geometry.size.width * (domain.rateDown / maxRate))
                        }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct RouterEmpty: View {
    let app: AppModel

    var body: some View {
        Card {
            VStack(spacing: 4) {
                EmptyMessage(title: app.classic ? L.routerOff : app.on || app.vpn.loop ? L.routerUnavailable : L.vpnOffEmpty,
                             symbol: app.classic ? "point.3.connected.trianglepath.dotted" : "shield.slash")
                if app.classic {
                    Button(L.enableRouter, action: app.enableRouterMode)
                        .buttonStyle(GozarButtonStyle(prominent: true))
                        .accessibilityLabel(L.enableRouter)
                        .disabled(app.working)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ToggleReadout: View {
    let name: String
    let enabled: Bool

    var body: some View {
        HStack(spacing: 7) {
            HealthDot(color: enabled ? .green : .gray)
            Text(name)
            Text(enabled ? L.on : L.ruleOff).foregroundStyle(.secondary)
        }
        .font(Theme.type(.callout))
        .accessibilityElement(children: .combine)
    }
}
