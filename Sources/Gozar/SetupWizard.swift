import GozarCore
import SwiftUI

struct SetupWizard: View {
    enum Step: Int, CaseIterable {
        case welcome, server, test, settings, ready

        var title: String {
            switch self {
            case .welcome: L.welcome
            case .server: L.setupServer
            case .test: L.test
            case .settings: L.tabSettings
            case .ready: L.setupReady
            }
        }

        var symbol: String {
            switch self {
            case .welcome: "sparkles"
            case .server: "server.rack"
            case .test: "waveform.path"
            case .settings: "switch.2"
            case .ready: "power"
            }
        }
    }

    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step
    @State private var candidates: [String]
    @State private var selection: String?
    @State private var routerMode = true
    @State private var launch: Bool
    @State private var terminal = false
    @State private var error: String?
    @State private var success = false

    init(app: AppModel, step: Step = .welcome) {
        self.app = app
        _step = State(initialValue: step)
        _launch = State(initialValue: app.loginEnabled)
        let sample = ["xf31b7a", "relay", "xb82af0"]
        _candidates = State(initialValue: app.snapshot ? sample : [])
        _selection = State(initialValue: app.snapshot ? sample.first : nil)
    }

    var body: some View {
        SheetSurface {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Text(L.setup).font(Theme.type(.callout, .bold)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .frame(width: 27, height: 27)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L.cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(app.working)
                }
                progress
                bodyForStep
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 720, height: 520)
        .animation(reduceMotion ? nil : Theme.motion, value: step)
        .interactiveDismissDisabled(app.working)
    }

    private var progress: some View {
        HStack(spacing: 10) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                let current = item == step
                let completed = item.rawValue < step.rawValue
                VStack(alignment: .leading, spacing: 5) {
                    Capsule()
                        .fill(current ? AnyShapeStyle(Theme.gradient) :
                                AnyShapeStyle(completed ? Theme.vpn.opacity(0.48) : Color.primary.opacity(0.10)))
                        .frame(height: 4)
                        .shadow(color: current ? Theme.vpn.opacity(0.36) : .clear, radius: 7)
                    Text(item.title)
                        .font(Theme.type(.caption, current ? .bold : .medium))
                        .foregroundStyle(current ? Theme.routeInk(.vpn, in: scheme) : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var bodyForStep: some View {
        switch step {
        case .welcome:
            VStack(spacing: 8) {
                SetupEmblem(symbol: nil, colors: [Theme.vpn, Theme.blue], size: 155)
                Text(L.welcome).font(Theme.type(.largeTitle, .bold, size: 35))
                Text(L.welcomeMessage).font(Theme.type(.body)).foregroundStyle(.secondary)
                Button(L.startSetup, systemImage: "arrow.left", action: { step = .server })
                    .buttonStyle(GozarButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 15)
            }
        case .server:
            ExitForm(app: app, title: L.setupServer, onCancel: { step = .welcome }, onAdded: beginTests,
                     existing: app.exits.exits.isEmpty ? nil : { beginTests(app.exits.exits.map(\.id)) })
                .frame(maxWidth: 580)
        case .test:
            testStep
        case .settings:
            settingsStep
        case .ready:
            readyStep
        }
    }

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeading(L.test, symbol: "waveform.path")
            if app.working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.testingExits).font(Theme.type(.callout))
                }
                .foregroundStyle(.secondary)
            } else if let error {
                InlineIssue(message: error)
            } else {
                Text(L.setupConnectionHint).font(Theme.type(.callout)).foregroundStyle(.secondary)
            }
            let best = ExitTestResult.best(in: candidates.compactMap { app.exitTests[$0] })
            if app.snapshot {
                candidateRows(best: best)
            } else {
                ScrollView {
                    candidateRows(best: best)
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: 180)
            }
            Spacer(minLength: 0)
            wizardFooter(
                back: { step = .server },
                next: { error = nil; step = .settings },
                enabled: selection != nil
            ) {
                Button(L.testAgain, systemImage: "arrow.clockwise", action: runTests)
                    .buttonStyle(GozarButtonStyle())
                    .disabled(app.working)
            }
        }
    }

    private func candidateRows(best: String?) -> some View {
        VStack(spacing: 7) {
            ForEach(candidates, id: \.self) { id in
                if let exit = app.exits.exits.first(where: { $0.id == id }) {
                    candidate(exit, best: best == id)
                }
            }
        }
    }

    private func candidate(_ exit: ExitListing.Exit, best: Bool) -> some View {
        let selected = selection == exit.id
        return Button {
            selection = exit.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.routeInk(.vpn, in: scheme) : .secondary)
                Text(exit.name).font(Theme.type(.body, .semibold)).lineLimit(1)
                ExitKindBadge(transport: exit.transport)
                if best {
                    Text(L.bestExit)
                        .font(Theme.type(.caption2, .bold)).foregroundStyle(Theme.routeInk(.vpn, in: scheme))
                }
                Spacer(minLength: 8)
                ExitMeasurements(result: app.exitTests[exit.id])
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(selected ? Theme.vpn.opacity(0.12) : .primary.opacity(0.035), in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.vpn.opacity(selected ? 0.45 : 0.08)) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(app.working)
    }

    private var settingsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeading(L.tabSettings, symbol: "switch.2")
            Text(L.setupSettingsHint).font(Theme.type(.callout)).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                setupToggle(L.routerRecommended, detail: L.setupRouterHint, symbol: "point.3.connected.trianglepath.dotted", value: $routerMode)
                setupToggle(L.launchAtLogin, detail: L.setupLaunchHint, symbol: "macwindow", value: $launch)
                setupToggle(L.installTerminal, detail: L.setupTerminalHint, symbol: "terminal", value: $terminal)
            }
            if let error { InlineIssue(message: error) }
            Spacer(minLength: 0)
            wizardFooter(back: { error = nil; step = .test }, next: save, enabled: true) {
                if app.working { ProgressView().controlSize(.small).accessibilityLabel(L.working) }
            }
        }
    }

    private func setupToggle(_ name: String, detail: String, symbol: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).foregroundStyle(Theme.routeInk(.vpn, in: scheme))
                .frame(width: 32, height: 32)
                .background(Theme.vpn.opacity(0.10), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(Theme.type(.callout, .semibold))
                Text(detail).font(Theme.type(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            LabeledSwitch(title: name, isOn: value, snapshot: app.snapshot, labelVisible: false)
        }
        .padding(.horizontal, 11)
        .frame(height: 54)
        .background(.primary.opacity(0.035), in: .rect(cornerRadius: 11))
    }

    private var readyStep: some View {
        VStack(spacing: 9) {
            let colors = success ? [Theme.good, Theme.direct] : [Theme.vpn, Theme.blue]
            SetupEmblem(symbol: success ? "checkmark" : app.connecting ? "ellipsis" : "power", colors: colors, size: 118)
                .id(success)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.76).combined(with: .opacity))
            Text(success ? L.setupConnected : L.setupReady).font(Theme.type(.largeTitle, .bold))
            if let exit = app.exits.exits.first(where: { $0.id == selection }) {
                HStack(spacing: 8) {
                    ExitKindBadge(transport: exit.transport)
                    Text(exit.name).font(Theme.type(.body, .semibold))
                    Technical(exit.endpoint, font: .caption).foregroundStyle(.secondary)
                }
                .padding(7)
                .padding(.horizontal, 6)
                .background(.primary.opacity(0.045), in: Capsule())
            }
            if let error { InlineIssue(message: error) }
            else if !success { Text(L.setupReadyHint).font(Theme.type(.callout)).foregroundStyle(.secondary) }
            HStack {
                if !success {
                    Button(L.back) { error = nil; step = .settings }
                        .buttonStyle(GozarButtonStyle()).disabled(app.working)
                }
                Button(success ? L.done : app.connecting ? L.connecting : L.connect,
                       systemImage: success ? "checkmark" : "bolt.fill", action: complete)
                    .buttonStyle(GozarButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.working || selection == nil)
            }
            .padding(.top, 7)
        }
        .animation(reduceMotion ? nil : Theme.motion, value: success)
    }

    private func wizardFooter<Accessory: View>(back: @escaping () -> Void, next: @escaping () -> Void,
                                               enabled: Bool, @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(spacing: 12) {
            Divider()
            HStack {
                Button(L.back, action: back).buttonStyle(GozarButtonStyle()).disabled(app.working)
                accessory()
                Spacer()
                Button(L.continueSetup, systemImage: "arrow.left", action: next)
                    .buttonStyle(GozarButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!enabled || app.working)
            }
        }
    }

    private func beginTests(_ ids: [String]) {
        candidates = ids
        selection = nil
        step = .test
        runTests()
    }

    private func runTests() {
        guard !app.working, !candidates.isEmpty else { return }
        error = nil
        Task {
            do {
                let tests = try await app.testExits(candidates)
                selection = ExitTestResult.best(in: tests) ?? selection ?? candidates.first
            } catch {
                self.error = error.localizedDescription
                selection = selection ?? candidates.first
            }
        }
    }

    private func save() {
        error = nil
        Task {
            do {
                try await app.saveWizardSettings(routerMode: routerMode, launch: launch, terminalCommand: terminal)
                step = .ready
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func complete() {
        if success { dismiss(); return }
        guard let selection else { return }
        error = nil
        Task {
            do {
                try await app.connectFromSetup(exit: selection)
                success = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct SetupEmblem: View {
    let symbol: String?
    let colors: [Color]
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(.radialGradient(colors: [colors[0].opacity(0.26), .clear], center: .center,
                                          startRadius: 0, endRadius: size / 2))
                .scaleEffect(1.25)
            Circle().strokeBorder(colors[0].opacity(0.19)).padding(4)
            Circle().strokeBorder(.linearGradient(colors: [colors[0].opacity(0.85), colors[1].opacity(0.15)],
                                                  startPoint: .topTrailing, endPoint: .bottomLeading), lineWidth: 1.2)
                .padding(14)
            Circle().fill(colors[1]).frame(width: 5, height: 5)
                .offset(x: -size * 0.36, y: size * 0.17)
                .shadow(color: colors[1], radius: 7)
            Circle().fill(colors[0]).frame(width: 4, height: 4)
                .offset(x: size * 0.34, y: -size * 0.22)
                .shadow(color: colors[0], radius: 8)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.linearGradient(colors: colors, startPoint: .topTrailing, endPoint: .bottomLeading))
            } else {
                AppMark(size: 102)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
