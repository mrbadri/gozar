import AppKit
import GozarCore
import SwiftUI

struct MenuIndicator: View {
    let app: AppModel

    var body: some View {
        let symbol = app.problem ? "exclamationmark.shield" : app.on ? "shield.lefthalf.filled" : "shield.slash"
        if app.on && app.menuRate {
            Label {
                Technical("↓ " + Fmt.compactRate(app.totals.rateDown), font: .caption.weight(.semibold))
            } icon: {
                Image(systemName: symbol).foregroundStyle(app.problem ? Color.orange : Theme.vpn)
            }
            .labelStyle(.titleAndIcon)
            .accessibilityLabel(L.iconLabel + " · " + L.download + " " + Fmt.rate(app.totals.rateDown))
        } else {
            Image(systemName: symbol)
                .foregroundStyle(app.problem ? Color.orange : .primary)
                .accessibilityLabel(L.iconLabel)
        }
    }
}

struct MenuPanel: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Card(padding: 8) { ExitPicker(app: app, compact: true) }
            HStack(spacing: 11) {
                ConnectSwitch(app: app, compact: true)
                VStack(alignment: .leading, spacing: 5) {
                    ConnectionState(app: app)
                    if let ip = app.vpn.exitIP {
                        HStack(spacing: 6) {
                            Text(L.exitIP).foregroundStyle(.secondary)
                            Technical(ip)
                        }
                        .font(Theme.type(.caption))
                    }
                }
                Spacer(minLength: 0)
            }
            Divider()
            ChainView(app: app, compact: true)
            HStack(spacing: 14) {
                menuRate(title: L.download, symbol: "arrow.down", reading: app.totals.rateDown, route: .vpn)
                Divider().frame(height: 25)
                menuRate(title: L.upload, symbol: "arrow.up", reading: app.totals.rateUp, route: .direct)
            }
            Divider()
            if !app.topDomains.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    SectionHeading(L.topNow, "chart.bar.xaxis")
                    DomainLeaders(domains: Array(app.topDomains.prefix(5)), compact: true)
                }
            } else {
                Text(app.classic ? L.routerOff : app.on ? L.emptyDomains : L.vpnOffEmpty)
                    .font(Theme.type(.callout))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 1)
            Divider()
            HStack {
                Button(L.openApp, systemImage: "macwindow", action: showWindow)
                    .buttonStyle(GozarButtonStyle(prominent: true))
                    .accessibilityLabel(L.openApp)
                Spacer()
                Button(L.quit, systemImage: "power") { NSApp.terminate(nil) }
                    .buttonStyle(GozarButtonStyle())
                    .accessibilityLabel(L.quit)
            }
        }
        .padding(14)
        .frame(width: 320)
        .frame(height: app.snapshot ? 520 : nil)
        .background { WindowBackdrop() }
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }

    private func menuRate(title: String, symbol: String, reading: Double, route: Route) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(Theme.type(.caption)).foregroundStyle(Theme.routeInk(route, in: colorScheme))
            Technical(Fmt.rate(reading), font: .system(size: 20, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : Theme.motion, value: reading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
