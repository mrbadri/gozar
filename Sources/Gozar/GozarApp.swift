import AppKit
import GozarCore
import SwiftUI

@main
enum GozarMain {
    @MainActor
    static func main() {
        AppResources.registerFonts()
        let arguments = CommandLine.arguments.dropFirst()
        if let index = arguments.firstIndex(of: "--snapshot") {
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, !arguments[next].isEmpty else {
                FileHandle.standardError.write(Data("usage: Gozar --snapshot DIR\n".utf8))
                exit(2)
            }
            do {
                let directory = URL(fileURLWithPath: arguments[next], isDirectory: true)
                try Snapshots.write(to: directory)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
        } else {
            GozarApp.main()
        }
    }
}

@MainActor
struct GozarApp: App {
    @State private var app = AppModel(demo: CommandLine.arguments.contains("--demo"))

    var body: some Scene {
        Window(L.appName, id: "main") {
            Workspace(app: app)
                .frame(minWidth: 1180, minHeight: 760)
                .background {
                    WindowObserver { window, visible, closing in
                        app.updateWindowVisibility(visible)
                        if closing || !window.isVisible && !window.isMiniaturized {
                            NSApp.setActivationPolicy(.accessory)
                        } else if visible {
                            NSApp.setActivationPolicy(.regular)
                        }
                    }
                }
                .onAppear { app.start() }
                .gozarLocale()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L.addSite) { app.addSitePresented = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(app.setupPresented || app.addExitPresented)
                Button(L.addExit) { app.addExitPresented = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(app.setupPresented || app.addSitePresented)
            }
            CommandGroup(replacing: .appInfo) {
                Button(L.about) { app.about = true }
                    .accessibilityLabel(L.about)
            }
        }

        MenuBarExtra {
            MenuPanel(app: app)
                .onAppear { app.start() }
                .modifier(Feedback(app: app, menu: true))
                .gozarLocale()
        } label: {
            MenuIndicator(app: app)
        }
        .menuBarExtraStyle(.window)
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case overview, live, domains, rules, server, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: L.tabOverview
        case .live: L.tabLive
        case .domains: L.tabDomains
        case .rules: L.tabRules
        case .server: L.tabServer
        case .settings: L.tabSettings
        }
    }

    var symbol: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .live: "waveform.path"
        case .domains: "globe"
        case .rules: "point.topleft.down.to.point.bottomright.curvepath"
        case .server: "server.rack"
        case .settings: "gearshape"
        }
    }
}

struct Workspace: View {
    @Bindable var app: AppModel
    var previewScreen: Screen?

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(app: app, screen: previewScreen ?? app.destination)
            Rectangle().fill(.primary.opacity(0.07)).frame(width: 1)
            DetailScreen(app: app, screen: previewScreen ?? app.destination)
                .padding(.top, 30)
        }
        .background { WindowBackdrop() }
        .animation(Theme.motion, value: app.destination)
        .modifier(Feedback(app: app))
        .environment(\.openAddSite, { app.addSitePresented = true })
        .sheet(isPresented: $app.setupPresented) { SetupWizard(app: app).gozarLocale() }
        .sheet(isPresented: $app.addExitPresented) { AddExitSheet(app: app).gozarLocale() }
        .sheet(isPresented: $app.addSitePresented) { AddSiteSheet(app: app).gozarLocale() }
    }
}

private struct WorkspaceSidebar: View {
    let app: AppModel
    let screen: Screen
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SidebarBrand()
                .padding(.horizontal, 8)
                .padding(.bottom, 24)
            ForEach(Screen.allCases) { item in
                Button {
                    app.destination = item
                } label: {
                    SidebarItem(item: item, selected: item == screen)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(item == screen ? .isSelected : [])
            }
            Spacer(minLength: 15)
            sidebarStatus
        }
        .padding(.horizontal, 15)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(width: 198)
        .background {
            LinearGradient(colors: scheme == .dark ? [.white.opacity(0.035), .clear] : [.white.opacity(0.56), .white.opacity(0.12)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private var sidebarStatus: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    HealthDot(color: app.on ? Theme.good : app.problem ? Theme.failed : .secondary, size: 6)
                    Text(app.on ? L.connected : app.problem ? L.problem : L.disconnected)
                        .font(Theme.type(.caption, .semibold))
                }
                Text(app.exits.activeExit?.name ?? L.noActiveExit)
                    .font(Theme.type(.callout, .medium)).lineLimit(1)
                HStack(spacing: 8) {
                    Technical("↓ " + Fmt.compactRate(app.totals.rateDown), font: .caption2)
                    Technical("↑ " + Fmt.compactRate(app.totals.rateUp), font: .caption2)
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SidebarItem: View {
    let item: Screen
    let selected: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label {
            Text(item.title).font(Theme.type(.body, selected ? .bold : .medium))
        } icon: {
            Image(systemName: item.symbol).frame(width: 19)
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 43, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 13).fill(Theme.gradient)
                    .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.20)) }
                    .shadow(color: Theme.vpn.opacity(0.4), radius: 18, y: 5)
            } else if hovering {
                RoundedRectangle(cornerRadius: 13).fill(.primary.opacity(0.06))
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.motion, value: hovering)
    }
}

struct SidebarBrand: View {
    var body: some View {
        HStack(spacing: 9) {
            AppMark(size: 44)
            Text(L.appName)
                .font(Theme.type(.title2, .bold))
            Spacer(minLength: 0)
        }
    }
}

struct AppMark: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = AppResources.icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "shield.lefthalf.filled")
                    .resizable().scaledToFit().padding(10).foregroundStyle(Theme.gradient)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct DetailScreen: View {
    let app: AppModel
    let screen: Screen

    var body: some View {
        Group {
            switch screen {
            case .overview: Overview(app: app)
            case .live: LiveScreen(app: app)
            case .domains: DomainsScreen(app: app)
            case .rules: RulesScreen(app: app)
            case .server: ServersScreen(app: app)
            case .settings: SettingsScreen(app: app)
            }
        }
    }
}

struct WindowObserver: NSViewRepresentable {
    let update: (NSWindow, Bool, Bool) -> Void

    func makeNSView(context: Context) -> Probe { Probe(update: update) }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.update = update }

    @MainActor
    final class Probe: NSView {
        var update: (NSWindow, Bool, Bool) -> Void
        private var observers: [NSObjectProtocol] = []

        init(update: @escaping (NSWindow, Bool, Bool) -> Void) {
            self.update = update
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            guard let window else { return }

            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.willCloseNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] note in
                    // The close notification arrives before AppKit updates isVisible.
                    Task { @MainActor in
                        guard let self, let window else { return }
                        let closing = note.name == NSWindow.willCloseNotification
                        let visible = !closing && window.occlusionState.contains(.visible) && !window.isMiniaturized
                        self.update(window, visible, closing)
                    }
                })
            }

            Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                self.update(window, window.occlusionState.contains(.visible) && !window.isMiniaturized, false)
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

extension View {
    func gozarLocale() -> some View {
        environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "fa_IR"))
            .font(Theme.type())
            .tint(Theme.vpn)
    }
}

struct Feedback: ViewModifier {
    let app: AppModel
    var menu = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if app.working || app.toast != nil {
                    HStack(spacing: 9) {
                        if app.working {
                            ProgressView().controlSize(.small).accessibilityLabel(L.working)
                        } else {
                            Image(systemName: app.toastFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(app.toastFailed ? Theme.failed : Theme.good).accessibilityHidden(true)
                        }
                        Text(app.working ? app.outputLine.isEmpty ? L.working : app.outputLine : app.toast ?? "")
                            .font(Theme.type(.callout, .medium))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.thickMaterial, in: .rect(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)).allowsHitTesting(false) }
                    .shadow(color: .black.opacity(0.22), radius: 15, y: 5)
                    .frame(maxWidth: menu ? 290 : 510)
                    .padding(.top, menu ? 8 : 18)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : Theme.motion, value: app.working)
            .animation(reduceMotion ? nil : Theme.motion, value: app.toast)
            .sheet(isPresented: Binding(get: { app.failure != nil && app.windowVisible != menu }, set: { visible in
                if !visible { app.failure = nil }
            })) {
                ErrorSheet(message: app.failure ?? "")
            }
            .sheet(isPresented: Binding(get: { app.about && !menu }, set: { app.about = $0 })) {
                AboutSheet()
            }
    }
}

private struct ErrorSheet: View {
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L.error, systemImage: "exclamationmark.triangle").font(Theme.headline)
            Text(L.details).font(Theme.type(.caption)).foregroundStyle(.secondary)
            ScrollView {
                Text(message).font(Theme.type(.callout)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(L.cancel) { dismiss() }.keyboardShortcut(.defaultAction).accessibilityLabel(L.cancel)
            }
        }
        .padding(22)
        .frame(width: 500, height: 265)
        .gozarLocale()
    }
}

private struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 11) {
            AppMark(size: 96)
            Text(L.appName).font(Theme.headline)
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Technical(version, font: .callout).foregroundStyle(.secondary)
            }
            Button(L.cancel) { dismiss() }.keyboardShortcut(.defaultAction).accessibilityLabel(L.cancel)
        }
        .padding(24)
        .frame(width: 270)
        .gozarLocale()
    }

}
