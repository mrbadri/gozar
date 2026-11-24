import GozarCore
import SwiftUI

struct LiveScreen: View {
    let app: AppModel
    @State private var search = ""
    @State private var route: Route?
    @State private var onlyOpen = false
    @State private var onlyErrors = false
    @State private var selection: Set<Int> = []
    @State private var hovered: Int?

    private var rows: [ConnStat] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return app.rowsVisible.filter { row in
            (route == nil || row.route == route) &&
                (!onlyOpen || row.state == .open) &&
                (!onlyErrors || row.state == .failed) &&
                (query.isEmpty || row.host.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        ScreenPage(screen: .live) {
            if app.router != nil {
                if app.paused {
                    Text(String(format: L.newRows, locale: Locale(identifier: "fa_IR"), app.unseen))
                        .font(Theme.type(.caption, .semibold))
                        .foregroundStyle(Theme.vpn)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.vpn.opacity(0.13), in: Capsule())
                }
                Button(app.paused ? L.resume : L.pause, systemImage: app.paused ? "play.fill" : "pause.fill", action: app.togglePause)
                    .buttonStyle(GozarButtonStyle())
                    .accessibilityLabel(app.paused ? L.resume : L.pause)
            }
        } content: {
            if app.router == nil {
                PageScroll { RouterEmpty(app: app) }
            } else {
                VStack(spacing: Theme.gap) {
                    Card { filters }
                    let filtered = rows
                    if filtered.isEmpty {
                        Card {
                            EmptyMessage(title: app.rowsVisible.isEmpty ? L.emptyConnections : L.noMatches, symbol: "bolt.horizontal.circle")
                        }
                    } else {
                        table(filtered)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 13) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextEntry(title: L.searchHost, text: $search, placeholder: "example.com", snapshot: app.snapshot)
            }
            .frame(maxWidth: 225)
            Spacer(minLength: 2)
            if app.snapshot {
                HStack(spacing: 2) {
                    segment(L.all, selected: true)
                    ForEach(Route.ordered, id: \.self) { segment(L.route($0), selected: false) }
                }
                .padding(2)
                .background(.quaternary.opacity(0.42), in: .rect(cornerRadius: 7))
                .accessibilityLabel(L.route)
            } else {
                Picker(L.route, selection: $route) {
                    Text(L.all).tag(nil as Route?)
                    ForEach(Route.ordered, id: \.self) { route in
                        Text(L.route(route)).tag(Optional(route))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(L.route)
                .frame(maxWidth: 255)
            }
            LabeledSwitch(title: L.onlyOpen, isOn: $onlyOpen, snapshot: app.snapshot)
                .onChange(of: onlyOpen) { _, on in if on { onlyErrors = false } }
                .fixedSize()
            LabeledSwitch(title: L.onlyErrors, isOn: $onlyErrors, snapshot: app.snapshot)
                .onChange(of: onlyErrors) { _, on in if on { onlyOpen = false } }
                .fixedSize()
        }
    }

    private func segment(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(Theme.type(.caption, selected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .frame(height: 21)
            .background(selected ? Theme.window : .clear, in: .rect(cornerRadius: 5))
    }

    @ViewBuilder
    private func table(_ rows: [ConnStat]) -> some View {
        if app.snapshot {
            SnapshotTable(columns: [
                .init(L.time, 65), .init(L.host), .init(L.port, 42), .init(L.route, 84), .init(L.rule, 148),
                .init(L.latency, 55), .init("↓", 64), .init("↑", 65), .init(L.rate, 85), .init(L.state, 46),
            ], rows: rows) { row in
                [
                    AnyView(Technical(Fmt.time(row.startedAt), font: .caption)),
                    AnyView(Technical(row.host, font: .body.weight(.medium)).truncationMode(.middle)),
                    AnyView(Technical(String(row.port), font: .caption)),
                    AnyView(RouteChip(route: row.route)),
                    AnyView(Text(row.rule ?? L.noValue).foregroundStyle(.secondary).lineLimit(1)),
                    AnyView(Technical(Fmt.milliseconds(row.connectMs), font: .caption)),
                    AnyView(Technical(Fmt.bytes(row.bytesDown), font: .caption)),
                    AnyView(Technical(Fmt.bytes(row.bytesUp), font: .caption)),
                    AnyView(Technical(row.state == .open ? Fmt.rate(row.rateDown) : L.noValue, font: .caption)),
                    AnyView(ConnectionStateIcon(row: row)),
                ]
            }
        } else {
            Table(rows, selection: $selection) {
                TableColumn(L.time) { row in cell(row) { Technical(Fmt.time(row.startedAt), font: .caption) } }.width(65)
                TableColumn(L.host) { row in cell(row) { Technical(row.host).truncationMode(.middle) } }.width(min: 120, ideal: 180)
                TableColumn(L.port) { row in cell(row) { Technical(String(row.port), font: .caption) } }.width(36)
                TableColumn(L.route) { row in cell(row) { RouteChip(route: row.route) } }.width(80)
                TableColumn(L.rule) { row in
                    cell(row) { Text(row.rule ?? L.noValue).lineLimit(1).help(row.rule ?? L.noRule) }
                }.width(min: 80, ideal: 148)
                TableColumn(L.latency) { row in cell(row) { Technical(Fmt.milliseconds(row.connectMs), font: .caption) } }.width(60)
                TableColumn("↓") { row in cell(row) { Technical(Fmt.bytes(row.bytesDown), font: .caption).accessibilityLabel(L.download) } }.width(62)
                TableColumn("↑") { row in cell(row) { Technical(Fmt.bytes(row.bytesUp), font: .caption).accessibilityLabel(L.upload) } }.width(62)
                TableColumn(L.rate) { row in cell(row) { Technical(row.state == .open ? Fmt.rate(row.rateDown) : L.noValue, font: .caption) } }.width(76)
                TableColumn(L.state) { row in cell(row) { ConnectionStateIcon(row: row) } }.width(46)
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .font(Theme.type().monospacedDigit())
            .contextMenu(forSelectionType: Int.self) { selected in
                if let id = selected.first, let row = rows.first(where: { $0.id == id }) {
                    RouteActions(app: app, domain: registrableDomain(row.host))
                }
            }
            .clipShape(.rect(cornerRadius: Theme.radius))
            .background { GlassSurface() }
        }
    }

    private func cell<Content: View>(_ row: ConnStat, @ViewBuilder _ content: () -> Content) -> some View {
        content().modifier(TrafficCell(id: row.id, hovered: $hovered))
    }
}

private struct ConnectionStateIcon: View {
    let row: ConnStat

    var body: some View {
        let symbol: String = switch row.state {
        case .connecting: "ellipsis.circle"
        case .open: "smallcircle.filled.circle"
        case .closed: "checkmark.circle"
        case .failed: "exclamationmark.circle.fill"
        }
        let color: Color = switch row.state {
        case .connecting: .orange
        case .open: .green
        case .closed: .secondary
        case .failed: Theme.failed
        }
        Image(systemName: symbol)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .center)
            .help(row.error ?? L.state(row.state))
            .accessibilityLabel(row.error ?? L.state(row.state))
    }
}

struct DomainsScreen: View {
    let app: AppModel
    @State private var selected: String?
    @State private var hovered: String?
    @State private var order = [KeyPathComparator(\DomainStat.bytesDown, order: .reverse)]

    init(app: AppModel) {
        self.app = app
        _selected = State(initialValue: app.snapshot ? "youtube.com" : nil)
    }

    var body: some View {
        ScreenPage(.domains) {
            if app.router == nil {
                PageScroll { RouterEmpty(app: app) }
            } else if app.domains.isEmpty {
                PageScroll { Card { EmptyMessage(title: L.emptyDomains, symbol: "globe") } }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    let rows = app.domains.sorted(using: order)
                    if app.snapshot {
                        snapshotTable(rows)
                    } else {
                        nativeTable(rows)
                    }
                    if let selected, let domain = app.domains.first(where: { $0.domain == selected }) {
                        DomainInspector(app: app, domain: domain) { self.selected = nil }
                            .frame(width: 228)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
        }
    }

    private func snapshotTable(_ rows: [DomainStat]) -> some View {
        SnapshotTable(columns: [
            .init(L.domain), .init(L.route, 81), .init(L.connections, 49), .init(L.totalDown, 63, descending: true),
            .init(L.nowDown, 72), .init(L.averageP90, 105), .init(L.errors, 32), .init(L.lastSeen, 78),
        ], rows: rows, selected: selected) { row in
            [
                AnyView(Technical(row.domain, font: .body.weight(.medium))),
                AnyView(RouteChip(route: row.route)),
                AnyView(Technical(String(row.connections), font: .caption)),
                AnyView(Technical(Fmt.bytes(row.bytesDown), font: .caption)),
                AnyView(Technical(Fmt.rate(row.rateDown), font: .caption)),
                AnyView(latency(row)),
                AnyView(Technical(String(row.failed), font: .caption).foregroundStyle(row.failed > 0 ? Theme.failed : .secondary)),
                AnyView(Technical(Fmt.time(row.lastSeen), font: .caption).foregroundStyle(.secondary)),
            ]
        }
    }

    private func nativeTable(_ rows: [DomainStat]) -> some View {
        Table(rows, selection: $selected, sortOrder: $order) {
            TableColumn(L.domain, value: \.domain) { row in cell(row) { Technical(row.domain) } }.width(min: 85, ideal: 160)
            TableColumn(L.route, value: \.route.rawValue) { row in cell(row) { RouteChip(route: row.route) } }.width(80)
            TableColumn(L.connections, value: \.connections) { row in cell(row) { Technical(String(row.connections), font: .caption) } }.width(48)
            TableColumn(L.totalDown, value: \.bytesDown) { row in cell(row) { Technical(Fmt.bytes(row.bytesDown), font: .caption) } }.width(64)
            TableColumn(L.nowDown, value: \.rateDown) { row in cell(row) { Technical(Fmt.rate(row.rateDown), font: .caption) } }.width(75)
            TableColumn(L.averageP90, value: \.sortLatency) { row in cell(row) { latency(row) } }.width(107)
            TableColumn(L.errors, value: \.failed) { row in
                cell(row) { Technical(String(row.failed), font: .caption).foregroundStyle(row.failed > 0 ? Theme.failed : .secondary) }
            }.width(34)
            TableColumn(L.lastSeen, value: \.lastSeen) { row in cell(row) { Technical(Fmt.time(row.lastSeen), font: .caption) } }.width(75)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .font(Theme.type().monospacedDigit())
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                RouteActions(app: app, domain: id)
            }
        }
        .clipShape(.rect(cornerRadius: Theme.radius))
        .background { GlassSurface() }
    }

    private func cell<Content: View>(_ row: DomainStat, @ViewBuilder _ content: () -> Content) -> some View {
        content().modifier(TrafficCell(id: row.id, hovered: $hovered))
    }

    private func latency(_ row: DomainStat) -> some View {
        Technical(Fmt.milliseconds(row.connectMsAvg) + " / " + Fmt.milliseconds(row.connectMsP90), font: .caption)
            .foregroundStyle(.secondary)
    }
}

private struct DomainInspector: View {
    let app: AppModel
    let domain: DomainStat
    let close: () -> Void
    @State private var decision: RouteDecision?
    @State private var error: String?

    init(app: AppModel, domain: DomainStat, close: @escaping () -> Void) {
        self.app = app
        self.domain = domain
        self.close = close
        _decision = State(initialValue: app.snapshot ? app.demoDecision(domain.domain) : nil)
    }

    var body: some View {
        Group {
            if app.snapshot { content }
            else { ScrollView { content }.scrollIndicators(.hidden) }
        }
        .task(id: InspectorIdentity(domain: domain.domain, rules: app.rules, cisco: app.router?.ciscoUp)) {
            guard !app.snapshot else { return }
            decision = nil
            error = nil
            do {
                let result = try await app.checkDomain(domain.domain)
                if !Task.isCancelled { decision = result }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private var content: some View {
        Card {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Technical(domain.domain, font: .headline).truncationMode(.middle).lineLimit(1)
                    Spacer(minLength: 0)
                    IconAction(title: L.hideDetails, symbol: "xmark.circle", action: close)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    RouteChip(route: decision?.route ?? domain.route)
                    Spacer(minLength: 0)
                    Technical(Fmt.rate(domain.rateDown), font: .caption.weight(.medium))
                }
                MetricChart(app.domainHistory(domain.domain), color: Theme.color(domain.route), axes: true, axisLabels: 2)
                    .frame(height: 83)
                    .accessibilityLabel(L.download + " · " + L.history2m)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.rule).font(Theme.type(.caption)).foregroundStyle(.secondary)
                    Text(decision?.rule ?? domain.rule ?? L.noRule).font(Theme.type(.callout, .medium))
                    if let pattern = decision?.pattern {
                        Technical(pattern, font: .caption).foregroundStyle(.secondary)
                    }
                    if let error { Text(error).font(Theme.type(.caption)).foregroundStyle(.secondary) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text(L.hosts).font(Theme.type(.caption)).foregroundStyle(.secondary)
                    ForEach(domain.hosts, id: \.self) { host in
                        Technical(host, font: .caption).lineLimit(1).truncationMode(.middle).help(host)
                    }
                }
                Divider()
                RouteChoices(route: decision?.route ?? domain.route, select: { route in
                    app.changeRoute(domain.domain, to: route)
                }, compact: true)
                .disabled(app.working)
                Button(L.removeFromRules, systemImage: "minus.circle") {
                    app.changeRoute(domain.domain, to: nil)
                }
                .buttonStyle(GozarButtonStyle())
                .disabled(app.working)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(3)
    }

    private struct InspectorIdentity: Equatable {
        let domain: String
        let rules: [Rule]
        let cisco: Bool?
    }
}

private struct SnapshotTable<Row: Identifiable>: View {
    struct Column: Identifiable {
        let id = UUID()
        let title: String
        let width: CGFloat?
        let descending: Bool

        init(_ title: String, _ width: CGFloat? = nil, descending: Bool = false) {
            self.title = title
            self.width = width
            self.descending = descending
        }
    }

    let columns: [Column]
    let rows: [Row]
    var selected: Row.ID?
    let cells: (Row) -> [AnyView]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(columns) { column in
                    HStack(spacing: 4) {
                        Text(column.title).lineLimit(1)
                        if column.descending { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
                    }
                    .frame(width: column.width, alignment: .leading)
                    .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: .leading)
                }
            }
            .font(Theme.type(.caption, .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(.quaternary.opacity(0.24))
            Divider()
            GeometryReader { available in
                let count = max(0, Int(available.size.height / 40))
                VStack(spacing: 0) {
                    ForEach(rows.prefix(count)) { row in
                        let items = cells(row)
                        HStack(spacing: 8) {
                            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                                items[index]
                                    .lineLimit(1)
                                    .frame(width: column.width, alignment: .leading)
                                    .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: .leading)
                            }
                        }
                        .font(Theme.type().monospacedDigit())
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(selected == row.id ? Theme.vpn.opacity(0.15) : .clear)
                        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.045)).frame(height: 1) }
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: Theme.radius))
        .background { GlassSurface() }
    }
}

private struct TrafficCell<ID: Equatable>: ViewModifier {
    let id: ID
    @Binding var hovered: ID?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(hovered == id ? Theme.vpn.opacity(0.08) : .clear)
            .contentShape(.rect)
            .onHover { inside in
                if inside { hovered = id }
                else if hovered == id { hovered = nil }
            }
    }
}

private extension DomainStat {
    var sortLatency: Double { connectMsAvg ?? .infinity }
}
