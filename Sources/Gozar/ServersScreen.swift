import GozarCore
import SwiftUI

struct ServersScreen: View {
    let app: AppModel
    @State private var rename: ExitListing.Exit?
    @State private var removal: Removal?
    @State private var monitoring = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Removal: Identifiable {
        case exit(ExitListing.Exit)
        case subscription(ExitListing.Subscription)

        var id: String {
            switch self { case .exit(let item): item.id; case .subscription(let item): item.id }
        }

        var name: String {
            switch self { case .exit(let item): item.name; case .subscription(let item): item.name }
        }

        var action: String {
            switch self { case .exit: L.removeExit; case .subscription: L.removeSubscription }
        }

        var message: String {
            switch self { case .exit: L.removeExitConfirm; case .subscription: L.removeSubscriptionConfirm }
        }

        var mutation: ExitMutation {
            switch self {
            case .exit(let item): .remove(item.id)
            case .subscription(let item): .removeSubscription(item.id)
            }
        }
    }

    var body: some View {
        ScreenPage(screen: .server) {
            Button(L.testAll, systemImage: "waveform.path") { test([], all: true) }
                .buttonStyle(GozarButtonStyle()).disabled(app.working || app.exits.exits.isEmpty)
            Button(L.add, systemImage: "plus") { app.addExitPresented = true }
                .buttonStyle(GozarButtonStyle(prominent: true)).disabled(app.working)
                .accessibilityLabel(L.addExit)
        } content: {
            PageScroll {
                if app.exits.exits.isEmpty {
                    Card {
                        EmptyMessage(title: L.noExits, symbol: "server.rack")
                    }
                }
                if let failure = app.exitsFailure { InlineIssue(message: failure) }
                let independent = app.exits.exits.filter { $0.subscription == nil }
                if !independent.isEmpty {
                    SectionHeading(title: L.independentExits, symbol: "server.rack") {
                        Text(L.exitCount(independent.count)).font(Theme.type(.caption)).foregroundStyle(.secondary)
                    }
                    exitGrid(independent)
                }
                ForEach(app.exits.subscriptions) { subscription in
                    subscriptionGroup(subscription)
                }
                monitoringSection
            }
        }
        .sheet(item: $rename) { item in
            SingleInputSheet(title: L.renameExit, initial: item.name, allowsEmpty: false, technical: false) { name in
                app.mutateExit(.rename(item.id, name.trimmingCharacters(in: .whitespacesAndNewlines)))
                return true
            }
            .gozarLocale()
        }
        .confirmationDialog(removal?.action ?? L.removeExit, isPresented: Binding(get: { removal != nil }, set: {
            if !$0 { removal = nil }
        }), titleVisibility: .visible, presenting: removal) { item in
            Button(item.action, role: .destructive) { app.mutateExit(item.mutation) }
            Button(L.cancel, role: .cancel) {}
        } message: { item in
            Text(item.name + " · " + item.message)
        }
    }

    private func subscriptionGroup(_ subscription: ExitListing.Subscription) -> some View {
        let children = app.exits.exits.filter { $0.subscription == subscription.id }
        let containsActive = children.contains { $0.id == app.exits.active }
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 11) {
                Image(systemName: "link")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.vpn)
                    .frame(width: 38, height: 38)
                    .background(Theme.vpn.opacity(0.11), in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(subscription.name).font(Theme.type(.headline, .semibold))
                        Text(L.exitCount(subscription.count)).font(Theme.type(.caption)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        if subscription.name != subscription.host {
                            Technical(subscription.host, font: .caption2)
                        }
                        Text(updateTime(subscription.updatedAt)).font(Theme.type(.caption2))
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button(L.updateSubscription, systemImage: "arrow.clockwise") { app.mutateExit(.updateSubscription(subscription.id)) }
                    .buttonStyle(GozarButtonStyle()).disabled(app.working)
                Button(L.removeSubscription, systemImage: "trash") { removal = .subscription(subscription) }
                    .buttonStyle(GozarButtonStyle()).disabled(app.working || containsActive)
            }
            if let message = subscription.error { InlineIssue(message: publicExitError(message)) }
            if !children.isEmpty { exitGrid(children) }
        }
        .padding(13)
        .background {
            RoundedRectangle(cornerRadius: Theme.radius)
                .fill(Theme.vpn.opacity(0.045))
                .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.vpn.opacity(0.20)) }
                .allowsHitTesting(false)
        }
    }

    private func exitGrid(_ exits: [ExitListing.Exit]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 12) {
            ForEach(exits) { item in
                ExitCard(exit: item, active: item.id == app.exits.active, reading: app.exitTests[item.id],
                         busy: app.working, testing: app.testingExits.contains(item.id), snapshot: app.snapshot,
                         activate: { app.mutateExit(.activate(item.id)) }, test: { test([item.id]) },
                         rename: { rename = item }, remove: { removal = .exit(item) })
            }
        }
    }

    private var monitoringSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card(padding: 12) {
                if app.hasToken {
                    Button {
                        monitoring.toggle()
                    } label: {
                        SectionHeading(title: L.serverMonitoring, symbol: "chart.xyaxis.line") {
                            Image(systemName: monitoring ? "chevron.up" : "chevron.down").font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(monitoring ? L.enabled : L.ruleOff)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "chart.xyaxis.line").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(L.noToken).font(Theme.type(.callout)).foregroundStyle(.secondary)
                        Spacer()
                        Button(L.tabSettings) { app.destination = .settings }.buttonStyle(GozarButtonStyle())
                    }
                }
            }
            if app.hasToken, monitoring {
                if let url = app.dashboardURL {
                    Link(destination: url) { ActionLabel(L.openInGrafana, "arrow.up.right.square") }
                        .buttonStyle(GozarButtonStyle()).accessibilityLabel(L.openInGrafana)
                }
                ServerMonitoring(app: app)
            }
        }
        .animation(reduceMotion ? nil : Theme.motion, value: monitoring)
    }

    private func test(_ ids: [String], all: Bool = false) {
        Task { _ = try? await app.testExits(ids, all: all) }
    }

    private func updateTime(_ time: String?) -> String {
        guard let time,
              let date = (try? Date.ISO8601FormatStyle().parse(time)) ??
                (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(time)) else { return L.notUpdated }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(Locale(identifier: "fa_IR")))
    }
}

private struct ExitCard: View {
    let exit: ExitListing.Exit
    let active: Bool
    let reading: ExitTestResult?
    let busy: Bool
    let testing: Bool
    let snapshot: Bool
    let activate: () -> Void
    let test: () -> Void
    let rename: () -> Void
    let remove: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Card(padding: 13) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    ExitKindBadge(transport: exit.transport)
                    Spacer(minLength: 2)
                    if exit.stale { badge(L.staleExit, color: Theme.cisco, glow: false) }
                    if active { badge(L.activeExit, color: Theme.good, glow: true) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(exit.name).font(Theme.type(.title3, .bold)).lineLimit(1)
                    Technical(exit.endpoint, font: .caption)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    if testing {
                        ProgressView().controlSize(.small).accessibilityLabel(L.testingExits)
                    } else {
                        ExitMeasurements(result: reading)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 20)
                Rectangle().fill(.primary.opacity(0.075)).frame(height: 1)
                HStack(spacing: 5) {
                    Button(L.activate, systemImage: "arrow.left", action: activate)
                        .buttonStyle(GozarButtonStyle(prominent: !active))
                        .disabled(busy || active)
                    Button(L.test, systemImage: "waveform.path", action: test)
                        .buttonStyle(GozarButtonStyle()).disabled(busy)
                    Spacer(minLength: 0)
                    exitMenu
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if active {
                RoundedRectangle(cornerRadius: Theme.radius)
                    .fill(.linearGradient(colors: [Theme.vpn.opacity(0.13), Theme.blue.opacity(0.02), .clear],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.radius)
                            .strokeBorder(.linearGradient(colors: [Theme.vpn.opacity(0.74), Theme.blue.opacity(0.20)],
                                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var exitMenu: some View {
        if snapshot {
            moreLabel
        } else {
            Menu {
                Button(L.renameExit, systemImage: "pencil", action: rename)
                Button(L.removeExit, systemImage: "trash", role: .destructive, action: remove).disabled(active)
            } label: {
                moreLabel
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy)
            .accessibilityLabel(L.details)
        }
    }

    private var moreLabel: some View {
        Image(systemName: "ellipsis")
            .frame(width: 31, height: 32)
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: 8))
    }

    private func badge(_ title: String, color: Color, glow: Bool) -> some View {
        HStack(spacing: 4) {
            HealthDot(color: color, size: 5)
            Text(title).font(Theme.type(.caption2, .bold)).lineLimit(1)
        }
        .foregroundStyle(scheme == .dark ? color : glow ? Theme.hex(0x15723C) : Theme.hex(0x925210))
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .overlay { Capsule().strokeBorder(color.opacity(0.30)) }
        .shadow(color: glow ? color.opacity(0.40) : .clear, radius: 18)
    }
}

struct ExitKindBadge: View {
    let transport: ExitListing.Transport
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color: Color = switch transport {
        case .ssh: Theme.direct
        case .vless: Theme.vpn
        case .vmess: Theme.blue
        case .trojan: Theme.cisco
        case .ss: Theme.cyan
        }
        Text(transport.label)
            .font(Theme.type(.caption2, .bold)).tracking(0.4)
            .foregroundStyle(scheme == .dark ? color : Color.primary.opacity(0.82))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.13), in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.29)) }
            .fixedSize()
    }
}

struct ExitMeasurements: View {
    let result: ExitTestResult?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let result, result.ok {
            HStack(spacing: 9) {
                Label {
                    Technical(Fmt.milliseconds(result.connectMs), font: .caption2)
                } icon: {
                    Image(systemName: "timer")
                }
                .foregroundStyle(Theme.health(result.connectMs, threshold: 150, textOn: scheme))
                Label {
                    Technical(result.mbps.map { String(format: "%.1f Mbit/s", $0) } ?? L.noValue, font: .caption2)
                } icon: {
                    Image(systemName: "arrow.down")
                }
                .foregroundStyle(result.mbps == nil ? .secondary : scheme == .dark ? Theme.good : Theme.hex(0x15723C))
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityElement(children: .combine)
        } else if let result {
            Label(L.testFailed, systemImage: "exclamationmark.circle")
                .font(Theme.type(.caption2, .semibold))
                .foregroundStyle(scheme == .dark ? Theme.failed : Theme.hex(0xAD163E))
                .help(result.error.map(publicExitError) ?? L.testFailed)
        } else {
            Label(L.noExitTest, systemImage: "timer")
                .font(Theme.type(.caption2)).foregroundStyle(.secondary)
        }
    }
}

struct ExitPicker: View {
    let app: AppModel
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            if let exit = app.exits.activeExit {
                ExitKindBadge(transport: exit.transport)
                Text(exit.name).font(Theme.type(compact ? .callout : .body, .semibold)).lineLimit(1)
            } else {
                Text(L.noActiveExit).font(Theme.type(.callout)).foregroundStyle(.secondary)
            }
            if compact { Spacer(minLength: 2) }
            if app.snapshot {
                changeLabel
            } else {
                Menu {
                    ForEach(app.exits.exits) { exit in
                        Button {
                            app.mutateExit(.activate(exit.id))
                        } label: {
                            Label(exit.name, systemImage: exit.id == app.exits.active ? "checkmark" : "server.rack")
                        }
                        .disabled(exit.id == app.exits.active)
                    }
                } label: {
                    changeLabel
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(L.changeExit)
                .disabled(app.working || app.exits.exits.count < 2)
            }
        }
    }

    private var changeLabel: some View {
        ActionLabel(L.changeExit, "chevron.down")
            .font(Theme.type(.caption2, .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.primary.opacity(0.055), in: .rect(cornerRadius: 6))
    }
}
