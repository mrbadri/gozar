import GozarCore
import SwiftUI

struct RulesScreen: View {
    let app: AppModel
    @State private var site = ""
    @State private var answer: RouteDecision?
    @State private var checkError: String?
    @State private var addRule = false
    @State private var discover = false

    var body: some View {
        ScreenPage(screen: .rules) {
            Button(L.findDomains, systemImage: "globe.badge.chevron.backward") { discover = true }
                .buttonStyle(GozarButtonStyle())
                .accessibilityLabel(L.findDomains)
            Button(L.newRule, systemImage: "plus") { addRule = true }
                .buttonStyle(GozarButtonStyle(prominent: true))
                .accessibilityLabel(L.newRule)
                .disabled(app.working)
        } content: {
            PageScroll(spacing: 10) {
                Card(padding: 12) { checker }
                if let problem = app.rulesFailure {
                    Card {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(Theme.type(.callout))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if app.rules.isEmpty && app.rulesFailure == nil {
                    Card { EmptyMessage(title: L.emptyRules, symbol: "point.topleft.down.to.point.bottomright.curvepath") }
                }
                ForEach(Array(app.rules.enumerated()), id: \.element.name) { position, rule in
                    RuleCard(app: app, rule: rule, position: position, move: move)
                }
            }
        }
        .task(id: CheckInput(site: site, rules: app.rules, cisco: app.vpn.cisco)) {
            answer = nil
            checkError = nil
            let input = site.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !app.snapshot, !input.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                let result = try await app.checkSite(input)
                guard !Task.isCancelled else { return }
                answer = result
            } catch {
                if !Task.isCancelled { checkError = error.localizedDescription }
            }
        }
        .sheet(isPresented: $addRule) { NewRuleSheet(app: app) }
        .sheet(isPresented: $discover) { DiscoverySheet(app: app) }
    }

    private var checker: some View {
        HStack(spacing: 13) {
            Label(L.checkSite, systemImage: "magnifyingglass")
                .font(Theme.type(.callout, .semibold))
            TextEntry(title: L.checkSite, text: $site, placeholder: "https://example.com", snapshot: app.snapshot)
                .frame(maxWidth: 245)
            Spacer(minLength: 0)
            if let answer {
                Text(answer.rule ?? L.noRule).font(Theme.type(.caption)).foregroundStyle(.secondary)
                if let pattern = answer.pattern { Technical(pattern, font: .caption).foregroundStyle(.secondary) }
                RouteChip(route: answer.route)
            }
            if let checkError {
                Text(checkError).font(Theme.type(.caption)).foregroundStyle(Theme.failed).lineLimit(1).help(checkError)
            }
        }
    }

    private func move(_ name: String, _ to: Int) {
        guard app.rules.indices.contains(to), app.rules[to].name != name else { return }
        app.editRules(["rule-move", "--to", String(to), "--", name])
    }

    private struct CheckInput: Equatable {
        let site: String
        let rules: [Rule]
        let cisco: Bool
    }
}

private struct RuleCard: View {
    let app: AppModel
    let rule: Rule
    let position: Int
    let move: (String, Int) -> Void
    @State private var newDomain = ""
    @State private var isDropTarget = false
    @State private var edit: RuleEdit?
    @State private var askingDelete = false

    @ViewBuilder
    var body: some View {
        if app.snapshot {
            card
        } else {
            card
                .dropDestination(for: String.self) { items, _ in
                    guard !app.working, let name = items.first, name != rule.name,
                          app.rules.contains(where: { $0.name == name }) else { return false }
                    move(name, position)
                    return true
                } isTargeted: { isDropTarget = $0 }
                .confirmationDialog(L.deleteRule, isPresented: $askingDelete) {
                    Button(L.deleteRule, role: .destructive) { app.editRules(["rule-delete", "--", rule.name]) }
                        .accessibilityLabel(L.deleteRule)
                    Button(L.cancel, role: .cancel) {}.accessibilityLabel(L.cancel)
                } message: { Text(rule.name) }
                .sheet(item: $edit) { kind in
                    let title = kind == .name ? L.renameRule : L.editNote
                    SingleInputSheet(title: title, initial: kind == .name ? rule.name : rule.note ?? "",
                                     allowsEmpty: kind == .note, technical: false) { value in
                        set(kind == .name ? "rename" : "note", value)
                        return true
                    }
                }
        }
    }

    private var card: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    if app.snapshot {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
                    } else {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .draggable(rule.name)
                            .help(L.reorder)
                            .accessibilityLabel(L.reorder)
                    }
                    Text(rule.name).font(Theme.type(.headline, .semibold)).lineLimit(1)
                    routeMenu
                    if rule.route == .cisco { fallbackMenu }
                    Spacer(minLength: 0)
                    if !rule.enabled { Text(L.ruleOff).font(Theme.type(.caption)).foregroundStyle(.secondary) }
                    LabeledSwitch(title: L.enabled, isOn: Binding(get: { rule.enabled }, set: { enabled in
                        set("enabled", String(enabled))
                    }), snapshot: app.snapshot, labelVisible: false)
                    .disabled(app.working)
                    if app.snapshot {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary).padding(.horizontal, 3).accessibilityHidden(true)
                    } else {
                        Menu {
                            Button(L.renameRule) { edit = .name }.accessibilityLabel(L.renameRule)
                            Button(L.editNote) { edit = .note }.accessibilityLabel(L.editNote)
                            Divider()
                            Button(L.moveUp) { move(rule.name, position - 1) }.accessibilityLabel(L.moveUp).disabled(position == 0)
                            Button(L.moveDown) { move(rule.name, position + 1) }.accessibilityLabel(L.moveDown)
                                .disabled(position == app.rules.count - 1)
                            Divider()
                            Button(L.deleteRule, role: .destructive) { askingDelete = true }.accessibilityLabel(L.deleteRule)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel(L.details)
                        .disabled(app.working)
                    }
                }
                if let note = rule.note, !note.isEmpty {
                    Text(note).font(Theme.type(.caption)).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(alignment: .top, spacing: 12) {
                    TokenLayout(spacing: 6) {
                        ForEach(rule.domains + rule.hosts, id: \.self) { value in
                            token(value)
                        }
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 5) {
                        TextEntry(title: L.addDomain, text: $newDomain, placeholder: "example.com", snapshot: app.snapshot)
                            .frame(width: 145)
                            .onSubmit(add)
                        Button(L.addDomain, systemImage: "plus", action: add)
                            .buttonStyle(GozarButtonStyle())
                            .disabled(newDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.working)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(Theme.vpn, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var routeMenu: some View {
        if app.snapshot {
            RouteChip(route: rule.route)
        } else {
            Menu {
                ForEach(Route.ordered, id: \.self) { route in
                    Button(L.route(route), systemImage: Theme.symbol(route)) { set("route", route.rawValue) }
                        .accessibilityLabel(L.route(route))
                }
            } label: { RouteChip(route: rule.route) }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L.route + " " + L.route(rule.route))
            .disabled(app.working)
        }
    }

    @ViewBuilder
    private var fallbackMenu: some View {
        let fallback = rule.withoutCisco.map(L.route) ?? L.fallbackDefault
        if app.snapshot {
            fallbackLabel(fallback)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: Capsule())
        } else {
            Menu {
                ForEach([Route.direct, .vpn], id: \.self) { route in
                    Button(L.route(route)) { set("without-cisco", route.rawValue) }.accessibilityLabel(L.route(route))
                }
                Button(L.fallbackDefault) { set("without-cisco", "none") }.accessibilityLabel(L.fallbackDefault)
            } label: {
                fallbackLabel(fallback)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(L.withoutCisco + " " + fallback)
            .disabled(app.working)
        }
    }

    private func fallbackLabel(_ fallback: String) -> some View {
        HStack(spacing: 5) {
            Text(L.withoutCisco)
            Text(L.dash).foregroundStyle(.secondary)
            Text(fallback)
        }
        .font(Theme.type(.caption, .medium))
        .lineLimit(1)
    }

    private func token(_ value: String) -> some View {
        HStack(spacing: 6) {
            Technical(value, font: .caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
            Button {
                app.changeRoute(value, to: nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .frame(width: 25, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(TokenRemovalStyle())
            .accessibilityLabel(L.remove(value))
            .help(L.remove(value))
            .disabled(app.working)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .background(.primary.opacity(0.045), in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.085)).allowsHitTesting(false) }
    }

    private func set(_ key: String, _ value: String) {
        app.editRules(["rule-set", "--\(key)=\(value)", "--", rule.name])
    }

    private func add() {
        let entry = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty, !app.working else { return }
        app.editRules(["add-to", "--", rule.name, rule.route.rawValue, entry])
        newDomain = ""
    }

    private enum RuleEdit: String, Identifiable {
        case name, note
        var id: Self { self }
    }
}

private struct TokenLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = layout(subviews, width: bounds.width).positions
        for (offset, view) in subviews.enumerated() {
            let item = positions[offset]
            view.place(at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                       anchor: .topLeading, proposal: ProposedViewSize(item.size))
        }
    }

    private func layout(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, positions: [CGRect]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var height: CGFloat = 0
        var maxWidth: CGFloat = 0
        var items: [CGRect] = []
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width {
                x = 0
                y += height + spacing
                height = 0
            }
            items.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            maxWidth = max(maxWidth, x + size.width)
            height = max(height, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: maxWidth, height: y + height), items)
    }
}

private struct NewRuleSheet: View {
    let app: AppModel
    @State private var name = ""
    @State private var domain = ""
    @State private var route: Route = .vpn
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.newRule).font(Theme.headline)
            FieldRow(title: L.ruleName) { TextEntry(title: L.ruleName, text: $name, technical: false) }
            FieldRow(title: L.route) {
                RoutePicker(route: $route)
            }
            FieldRow(title: L.firstDomain) { TextEntry(title: L.firstDomain, text: $domain, placeholder: "example.com") }
            HStack {
                Spacer()
                Button(L.cancel, role: .cancel) { dismiss() }.accessibilityLabel(L.cancel)
                Button(L.save, action: save)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(L.save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              app.rules.contains(where: { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }))
            }
        }
        .padding(22)
        .frame(width: 410)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        app.editRules(["add-to", "--", trimmed, route.rawValue, site])
        dismiss()
    }
}

private struct DiscoverySheet: View {
    let app: AppModel
    @State private var site = ""
    @State private var target = ""
    @State private var route: Route = .vpn
    @State private var selected: Set<String> = []
    @State private var report: DomainDiscovery?
    @State private var search: Search?
    @State private var loading = false
    @State private var progressLine = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.findDomains).font(Theme.headline)
            HStack {
                TextEntry(title: L.sitePrompt, text: $site, placeholder: "https://youtube.com")
                    .onSubmit(beginSearch)
                Button(L.runSearch, systemImage: "magnifyingglass", action: beginSearch)
                    .accessibilityLabel(L.runSearch)
                    .disabled(site.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
            }
            if loading {
                VStack(spacing: 10) {
                    ProgressView(L.working).controlSize(.small)
                    if !progressLine.isEmpty {
                        Text(progressLine).font(Theme.type(.caption)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report {
                HStack {
                    Technical(report.site, font: .headline)
                    Spacer()
                    RouteChip(route: report.via)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        if let listed = report.listed, !listed.domains.isEmpty {
                            section(L.communityList, listed.domains)
                        }
                        if let live = report.live, !live.isEmpty {
                            section(L.liveHosts, live)
                        }
                        let listedHosts = Set((report.listed?.domains ?? []).map(\.host) + (report.live ?? []).map(\.host))
                        let other = report.suggested.filter { !listedHosts.contains($0) }
                        if !other.isEmpty {
                            section(L.suggested, other.map { .init(host: $0, route: route) })
                        }
                        if listedHosts.isEmpty && other.isEmpty {
                            EmptyMessage(title: L.emptyDiscovery, symbol: "magnifyingglass")
                        }
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Picker(L.rule, selection: $target) {
                        Text(L.newRule).tag("")
                        ForEach(app.rules, id: \.name) { rule in Text(rule.name).tag(rule.name) }
                    }
                    .accessibilityLabel(L.rule)
                    .onChange(of: target) { _, value in
                        if let rule = app.rules.first(where: { $0.name == value }) { route = rule.route }
                    }
                    RoutePicker(route: $route).fixedSize()
                }
            } else if let error {
                ScrollView {
                    Text(error).font(Theme.type(.callout)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
            }
            HStack {
                Spacer()
                Button(L.cancel, role: .cancel) { dismiss() }.accessibilityLabel(L.cancel)
                Button(L.addSelected, action: add)
                    .buttonStyle(GozarButtonStyle(prominent: true))
                    .accessibilityLabel(L.addSelected)
                    .disabled(selected.isEmpty || loading || app.working)
            }
        }
        .padding(22)
        .frame(width: 560, height: 478)
        .environment(\.layoutDirection, .rightToLeft)
        .task(id: search) {
            guard let search else { return }
            do {
                let result = try await app.discover(search.site) { line in
                    Task { @MainActor in
                        if self.search == search, loading { progressLine = line }
                    }
                }
                guard !Task.isCancelled else { return }
                report = result
                selected = Set(result.suggested)
                route = result.via
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    private func section(_ title: String, _ entries: [DomainDiscovery.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.type(.headline, .semibold))
            ForEach(entries, id: \.host) { entry in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { selected.contains(entry.host) }, set: { include in
                        if include { selected.insert(entry.host) } else { selected.remove(entry.host) }
                    })) {
                        Technical(entry.host).lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(entry.host)
                    Spacer()
                    RouteChip(route: entry.route)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func beginSearch() {
        let value = site.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !loading else { return }
        report = nil
        progressLine = ""
        selected.removeAll()
        target = ""
        error = nil
        loading = true
        search = Search(site: value)
    }

    private func add() {
        guard let report, !selected.isEmpty else { return }
        let name = target.isEmpty ? report.listed?.name ?? report.site : target
        let existing = app.rules.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let update = existing.flatMap { rule in
            rule.route == route ? nil : ["rule-set", "--route=\(route.rawValue)", "--", rule.name]
        }
        app.editRules(["add-to", "--", name, route.rawValue] + selected.sorted(), followedBy: update)
        dismiss()
    }

    private struct Search: Equatable {
        let id = UUID()
        let site: String
    }
}

private struct TokenRemovalStyle: ButtonStyle {
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled && hovered ? Theme.failed : .secondary)
            .background(enabled && hovered ? Theme.failed.opacity(0.12) : .clear, in: Circle())
            .opacity(configuration.isPressed ? 0.68 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : Theme.motion, value: hovered)
    }
}

struct RoutePicker: View {
    @Binding var route: Route

    var body: some View {
        Picker(L.route, selection: $route) {
            ForEach(Route.ordered, id: \.self) { route in
                Text(L.route(route)).tag(route)
            }
        }
        .accessibilityLabel(L.route)
    }
}
