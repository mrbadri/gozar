import Foundation
import SwiftUI

struct SettingsScreen: View {
    let app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: ConnectionDraft
    @State private var savedDraft: ConnectionDraft
    @State private var original: Data?
    @State private var configError: String?
    @State private var vpnPath: String
    @State private var grafanaURL: String
    @State private var token = ""
    @State private var ip = ""
    @State private var password = false
    @State private var confirmReset = false
    @State private var confirmForget = false

    init(app: AppModel) {
        self.app = app
        let loaded = try? app.loadDraft()
        let initial = loaded?.draft ?? ConnectionDraft()
        _draft = State(initialValue: initial)
        _savedDraft = State(initialValue: initial)
        _original = State(initialValue: loaded?.original)
        _vpnPath = State(initialValue: app.vpnPath)
        _grafanaURL = State(initialValue: app.grafanaURL)
    }

    var body: some View {
        ScreenPage(screen: .settings) {
            Button(L.setup, systemImage: "wand.and.stars") { app.setupPresented = true }
                .buttonStyle(GozarButtonStyle())
                .accessibilityLabel(L.setup)
            Button(L.about, systemImage: "info.circle") { app.about = true }
                .buttonStyle(GozarButtonStyle())
                .accessibilityLabel(L.about)
        } content: {
            PageScroll {
                HStack(alignment: .top, spacing: Theme.gap) {
                    VStack(spacing: Theme.gap) {
                        relayCard
                        routerCard
                        accessCard
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: Theme.gap) {
                        integrationCard
                        startupCard
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: app.settingsRevision) {
            guard !app.snapshot else { return }
            do {
                let settings = try app.loadDraft()
                if draft == savedDraft || draft == settings.draft || configError != nil {
                    draft = settings.draft
                    savedDraft = settings.draft
                    original = settings.original
                }
                configError = nil
            } catch {
                configError = error.localizedDescription
            }
        }
        .sheet(isPresented: $password) {
            SingleInputSheet(title: L.changePassword, initial: "", allowsEmpty: false, secure: true, submit: app.savePassword)
        }
        .confirmationDialog(L.resetHostKey, isPresented: $confirmReset, titleVisibility: .visible) {
            Button(L.reset, role: .destructive, action: app.resetHostKey).accessibilityLabel(L.resetHostKey)
            Button(L.cancel, role: .cancel) {}.accessibilityLabel(L.cancel)
        } message: { Text(L.confirmResetHostKey) }
        .confirmationDialog(L.forgetPassword, isPresented: $confirmForget, titleVisibility: .visible) {
            Button(L.forgetPassword, role: .destructive, action: app.forgetPassword).accessibilityLabel(L.forgetPassword)
            Button(L.cancel, role: .cancel) {}.accessibilityLabel(L.cancel)
        } message: { Text(L.confirmForget) }
    }

    private var relayCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L.localSettings, "network")
                if let configError {
                    Text(configError).font(Theme.type(.callout)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                setting(L.localPort, $draft.localPort)
                Text(L.keepalive).font(Theme.type(.caption, .semibold)).foregroundStyle(.secondary)
                setting(L.interval, $draft.keepaliveInterval)
                setting(L.missed, $draft.keepaliveMissed)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var routerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L.routerMode, "point.3.connected.trianglepath.dotted")
                LabeledSwitch(title: L.enabled, isOn: $draft.routerEnabled, snapshot: app.snapshot)
                setting(L.upstreamPort, $draft.upstreamPort).disabled(!draft.routerEnabled)
                setting(L.controlPort, $draft.controlPort).disabled(!draft.routerEnabled)
                Divider()
                HStack {
                    Spacer()
                    Button(L.save, systemImage: "checkmark") { app.saveConnection(draft, original: original) }
                        .buttonStyle(GozarButtonStyle(prominent: true))
                        .accessibilityLabel(L.save)
                        .disabled((draft == savedDraft && !app.snapshot) || app.working || configError != nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var accessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L.credentials, "key.horizontal")
                if let exit = app.exits.activeExit {
                    HStack(spacing: 8) {
                        ExitKindBadge(transport: exit.transport)
                        Text(exit.name).font(Theme.type(.callout, .semibold))
                        Technical(exit.endpoint, font: .caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                HStack {
                    Button(L.changePassword, systemImage: "key", action: { password = true })
                        .accessibilityLabel(L.changePassword)
                    Button(L.forgetPassword, systemImage: "trash", action: { confirmForget = true })
                        .accessibilityLabel(L.forgetPassword)
                }
                .buttonStyle(GozarButtonStyle())
                .disabled(app.working || app.exits.activeExit?.kind != .ssh)
                Divider()
                FieldRow(title: L.tryBox) {
                    HStack(spacing: 6) {
                        TextEntry(title: L.alternateIP, text: $ip, placeholder: "203.0.113.24", snapshot: app.snapshot)
                            .onSubmit(tryBox)
                        IconAction(title: L.tryBox, symbol: "arrow.turn.up.left", action: tryBox)
                            .disabled(ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.working)
                    }
                }
                HStack {
                    Button(L.backToNormal, systemImage: "arrow.counterclockwise", action: app.backToNormal)
                        .accessibilityLabel(L.backToNormal)
                    Button(L.resetHostKey, action: { confirmReset = true }).accessibilityLabel(L.resetHostKey)
                }
                .buttonStyle(GozarButtonStyle())
                .disabled(app.working)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var integrationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L.grafana, "chart.xyaxis.line")
                setting(L.grafanaURL, $grafanaURL)
                FieldRow(title: L.grafanaToken) {
                    TextEntry(title: L.grafanaToken, text: $token, placeholder: app.hasToken ? "••••••••••••••" : L.grafanaToken,
                              snapshot: app.snapshot, secure: true)
                        .onSubmit(saveGrafana)
                }
                HStack {
                    Label(app.hasToken ? L.tokenSaved : L.tokenMissing, systemImage: app.hasToken ? "lock.fill" : "key")
                        .font(Theme.type(.caption)).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    Link(destination: Guide.url) { Text(L.tokenGuide) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.routeInk(.vpn, in: colorScheme))
                        .font(Theme.type(.caption))
                        .accessibilityLabel(L.tokenGuide)
                    Button(L.save, action: saveGrafana)
                        .buttonStyle(GozarButtonStyle())
                        .accessibilityLabel(L.save)
                        .disabled((grafanaURL == app.grafanaURL && token.isEmpty) || app.working)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var startupCard: some View {
        @Bindable var model = app
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L.startupSettings, "gearshape")
                setting(L.vpnPath, $vpnPath)
                LabeledSwitch(title: L.menuRate, isOn: $model.menuRate, snapshot: app.snapshot)
                LabeledSwitch(title: L.launchAtLogin, isOn: Binding(get: { app.loginEnabled }, set: app.setLogin), snapshot: app.snapshot)
                Divider()
                HStack {
                    Spacer()
                    Button(L.save, systemImage: "checkmark", action: savePreferences)
                        .buttonStyle(GozarButtonStyle())
                        .accessibilityLabel(L.save)
                        .disabled(vpnPath == app.vpnPath || app.working)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setting(_ title: String, _ value: Binding<String>) -> some View {
        FieldRow(title: title) {
            TextEntry(title: title, text: value, snapshot: app.snapshot)
        }
    }

    private func tryBox() { app.tryBox(ip.trimmingCharacters(in: .whitespacesAndNewlines)) }

    private func savePreferences() {
        if app.savePreferences(path: vpnPath, grafana: app.grafanaURL) { vpnPath = app.vpnPath }
    }

    private func saveGrafana() {
        guard app.savePreferences(path: app.vpnPath, grafana: grafanaURL) else { return }
        grafanaURL = app.grafanaURL
        if !token.isEmpty, app.saveToken(token) {
            token = ""
        }
    }
}

struct FieldRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Theme.type(.callout))
                .foregroundStyle(.secondary)
                .frame(width: 126, alignment: .leading)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity)
        }
    }
}

struct SingleInputSheet: View {
    let title: String
    let allowsEmpty: Bool
    let technical: Bool
    let secure: Bool
    let submit: (String) -> Bool
    @State private var value: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(title: String, initial: String, allowsEmpty: Bool, technical: Bool = true,
         secure: Bool = false, submit: @escaping (String) -> Bool) {
        self.title = title
        self.allowsEmpty = allowsEmpty
        self.technical = technical
        self.secure = secure
        self.submit = submit
        _value = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Theme.headline)
            TextEntry(title: title, text: $value, technical: technical, secure: secure)
                .focused($focused)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button(L.cancel, role: .cancel) { dismiss() }.accessibilityLabel(L.cancel)
                Button(L.save, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(L.save)
                    .disabled(!valid)
            }
        }
        .padding(22)
        .frame(width: 395)
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear { focused = true }
    }

    private var valid: Bool { allowsEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func commit() {
        guard valid, submit(value) else { return }
        value = ""
        dismiss()
    }
}
