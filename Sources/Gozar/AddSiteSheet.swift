import GozarCore
import SwiftUI

struct AddSiteSheet: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool
    @State private var site: String
    @State private var route: Route = .direct
    @State private var rule: String?
    @State private var decision: RouteDecision?
    @State private var checking = false
    @State private var checkError: String?

    init(app: AppModel) {
        self.app = app
        let sample = "https://www.aparat.com"
        _site = State(initialValue: app.snapshot ? sample : "")
        _decision = State(initialValue: app.snapshot ? app.demoDecision("aparat.com") : nil)
    }

    private var command: AddSiteCommand? { try? .init(site: site, route: route, rule: rule) }
    private var siteText: String { site.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SheetSurface {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeading(L.addSite, symbol: "globe.badge.chevron.backward")
                VStack(alignment: .leading, spacing: 7) {
                    Text(L.siteAddress).font(Theme.type(.callout, .semibold))
                    TextEntry(title: L.siteAddress, text: $site, placeholder: "example.com", snapshot: app.snapshot)
                        .focused($focused)
                    feedback.frame(minHeight: 25, alignment: .leading)
                }
                RouteChoices(route: route) { choice in
                    route = choice
                    if !matchingRules.contains(where: { $0.name == rule }) { rule = nil }
                }
                HStack {
                    Text(L.useRule).font(Theme.type(.callout, .semibold))
                    Spacer()
                    if app.snapshot {
                        Label(L.newRule, systemImage: "chevron.down")
                            .font(Theme.type(.callout, .medium))
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(.primary.opacity(0.06), in: .rect(cornerRadius: 8))
                    } else {
                        Picker(L.useRule, selection: $rule) {
                            Text(L.newRule).tag(nil as String?)
                            ForEach(matchingRules, id: \.name) { rule in
                                Text(rule.name).tag(Optional(rule.name))
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel(L.useRule)
                    }
                }
                Divider()
                HStack {
                    Button(L.cancel) { dismiss() }.buttonStyle(GozarButtonStyle()).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L.add, systemImage: "plus", action: save)
                        .buttonStyle(GozarButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(command == nil || app.working)
                }
            }
        }
        .frame(width: 570, height: 450)
        .onAppear { if !app.snapshot { focused = true } }
        .task(id: siteText) {
            guard !app.snapshot else { return }
            decision = nil
            checkError = nil
            checking = false
            guard let address = try? AddSiteCommand.address(siteText) else { return }
            checking = true
            do {
                try await Task.sleep(for: .milliseconds(300))
                let result = try await app.checkSite(address)
                guard !Task.isCancelled else { return }
                decision = result
            } catch {
                guard !Task.isCancelled else { return }
                checkError = error.localizedDescription
            }
            checking = false
        }
    }

    private var matchingRules: [Rule] { app.rules.filter { $0.route == route } }

    @ViewBuilder private var feedback: some View {
        if let decision {
            HStack(spacing: 8) {
                Text(L.currentRoute).foregroundStyle(.secondary)
                RouteChip(route: decision.route)
                Text(decision.rule ?? L.noRule).foregroundStyle(.secondary)
            }
            .font(Theme.type(.caption))
        } else if let checkError {
            Text(checkError).font(Theme.type(.caption)).foregroundStyle(.secondary).lineLimit(2)
        } else if !siteText.isEmpty, command == nil {
            Text(L.siteInvalid).font(Theme.type(.caption)).foregroundStyle(Theme.health(2, threshold: 1, redAt: 2, textOn: scheme))
        } else if checking {
            ProgressView().controlSize(.small).accessibilityLabel(L.checkSite)
        }
    }

    private func save() {
        guard let command else { return }
        app.addSite(command)
        dismiss()
    }
}

struct RouteChoices: View {
    let route: Route
    let select: (Route) -> Void
    var compact = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: compact ? 4 : 10) {
            ForEach(Route.ordered, id: \.self) { choice in
                let selected = route == choice
                let color = Theme.color(choice)
                Button {
                    select(choice)
                } label: {
                    VStack(spacing: compact ? 3 : 5) {
                        Image(systemName: Theme.symbol(choice))
                            .font(.system(size: compact ? 13 : 22, weight: .medium))
                        Text(L.route(choice)).font(Theme.type(compact ? .caption2 : .body, .semibold))
                        if !compact {
                            Text(L.routeDescription(choice)).font(Theme.type(.caption))
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .lineLimit(1)
                    .foregroundStyle(Theme.routeInk(choice, in: scheme))
                    .frame(maxWidth: .infinity, minHeight: compact ? 46 : 94)
                    .background(.linearGradient(colors: [color.opacity(selected ? 0.21 : 0.07),
                                                         color.opacity(selected ? 0.09 : 0.02)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: .rect(cornerRadius: compact ? 8 : 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: compact ? 8 : 14)
                            .strokeBorder(color.opacity(selected ? 0.66 : 0.18))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.route(choice))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct SheetSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { GlassSurface(radius: 24) }
            .padding(10)
            .background { WindowBackdrop() }
            .clipShape(.rect(cornerRadius: 24))
    }
}

struct SheetHeading: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.gradient)
                .font(.system(size: 21, weight: .medium))
                .frame(width: 43, height: 43)
                .background(Theme.vpn.opacity(0.12), in: .rect(cornerRadius: 13))
                .accessibilityHidden(true)
            Text(title).font(Theme.type(.title2, .bold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
    }
}
