import AppKit
import CoreImage
import GozarCore
import SwiftUI
import UniformTypeIdentifiers

struct ExitForm: View {
    enum Tab { case links, ssh }

    let app: AppModel
    let title: String
    var cancelTitle = L.back
    let onCancel: () -> Void
    let onAdded: ([String]) -> Void
    var existing: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @State private var tab = Tab.links
    @State private var pasted = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var password = ""
    @State private var error: String?
    @State private var showedValidation = false
    @State private var pickingImage = false

    private var input: ExitInput {
        get throws {
            switch tab {
            case .links: try .init(paste: pasted)
            case .ssh: try .init(host: host, port: port, user: user, password: password)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            SheetHeading(title, symbol: "server.rack")
            HStack(spacing: 4) {
                tabButton(.links, title: L.linkOrSubscription, icon: "link")
                tabButton(.ssh, title: "SSH", icon: "terminal")
            }
            .padding(4)
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: 12))
            Group {
                if tab == .links {
                    linksEditor
                } else {
                    VStack(spacing: 9) {
                        FieldRow(title: L.relayHost) {
                            TextEntry(title: L.relayHost, text: $host, placeholder: "edge.example.net")
                        }
                        FieldRow(title: L.relayPort) {
                            TextEntry(title: L.relayPort, text: $port)
                        }
                        FieldRow(title: L.relayUser) {
                            TextEntry(title: L.relayUser, text: $user)
                        }
                        FieldRow(title: L.sshPassword) {
                            TextEntry(title: L.sshPassword, text: $password, secure: true)
                        }
                    }
                    .frame(height: 174, alignment: .top)
                }
            }
            let validation = showedValidation ? validationError : nil
            if let message = error ?? validation {
                InlineIssue(message: message)
            }
            Spacer(minLength: 2)
            Divider()
            HStack {
                Button(cancelTitle, action: onCancel)
                    .buttonStyle(GozarButtonStyle())
                    .disabled(app.working)
                if let existing {
                    Button(L.useExisting, action: existing)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.routeInk(.vpn, in: scheme))
                        .font(Theme.type(.caption, .medium))
                        .disabled(app.working)
                }
                Spacer()
                if app.working {
                    ProgressView().controlSize(.small).accessibilityLabel(L.working)
                }
                Button(L.add, systemImage: "plus", action: submit)
                    .buttonStyle(GozarButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.working)
            }
        }
        .fileImporter(isPresented: $pickingImage, allowedContentTypes: [.image]) { result in
            importImage(result)
        }
    }

    private var linksEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L.pasteDescription).font(Theme.type(.callout)).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if pasted.isEmpty {
                    Text(L.pasteLink).font(Theme.type(.callout))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 13)
                        .padding(.top, 11)
                        .allowsHitTesting(false)
                }
                if !app.snapshot {
                    TextEditor(text: $pasted)
                        .font(.system(.callout, design: .monospaced))
                        .environment(\.layoutDirection, .leftToRight)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .accessibilityLabel(L.pasteLink)
                        .onChange(of: pasted) { _, _ in error = nil }
                }
            }
            .frame(height: 93)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.vpn.opacity(0.28)).allowsHitTesting(false) }
            HStack(spacing: 8) {
                Button(L.pasteClipboard, systemImage: "clipboard") {
                    if let text = NSPasteboard.general.string(forType: .string) { pasted = text }
                }
                .buttonStyle(GozarButtonStyle())
                Button(L.importQR, systemImage: "qrcode.viewfinder") { pickingImage = true }
                    .buttonStyle(GozarButtonStyle())
            }
        }
    }

    private func tabButton(_ target: Tab, title: String, icon: String) -> some View {
        Button {
            tab = target
            error = nil
            showedValidation = false
        } label: {
            Label(title, systemImage: icon)
                .font(Theme.type(.callout, .semibold))
                .foregroundStyle(target == tab ? Theme.routeInk(.vpn, in: scheme) : .secondary)
                .frame(maxWidth: .infinity, minHeight: 33)
                .background(target == tab ? Theme.vpn.opacity(0.15) : .clear, in: .rect(cornerRadius: 9))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(target == tab ? .isSelected : [])
        .disabled(app.working)
    }

    private var validationError: String? {
        do { _ = try input; return nil }
        catch { return error.localizedDescription }
    }

    private func submit() {
        showedValidation = true
        error = nil
        guard let submission = try? input else { return }
        Task {
            do {
                let ids = try await app.addExit(submission)
                pasted = ""
                password = ""
                onAdded(ids)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func importImage(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                throw AppError(L.noQR)
            }
            let codes = QRCode.messages(in: image)
            guard !codes.isEmpty else { throw AppError(L.noQR) }
            pasted = codes.joined(separator: "\n")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AddExitSheet: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetSurface {
            ExitForm(app: app, title: L.addExit, cancelTitle: L.cancel,
                     onCancel: { dismiss() }, onAdded: { _ in dismiss() })
        }
        .frame(width: 570, height: 430)
        .interactiveDismissDisabled(app.working)
    }
}

struct InlineIssue: View {
    let message: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(Theme.type(.caption, .medium))
            .foregroundStyle(scheme == .dark ? Theme.failed : Theme.hex(0xAD163E))
            .lineLimit(3)
            .textSelection(.enabled)
    }
}
