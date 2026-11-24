import AppKit
import SwiftUI

@MainActor
enum Snapshots {
    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = AppModel(demo: true, snapshot: true)

        for appearance in [ColorScheme.light, ColorScheme.dark] {
            let style = appearance == .light ? "light" : "dark"
            guard let nsAppearance = NSAppearance(named: appearance == .light ? .aqua : .darkAqua) else {
                throw AppError("Could not load the \(style) appearance")
            }
            var result: Result<Void, Error> = .success(())
            nsAppearance.performAsCurrentDrawingAppearance {
                result = Result {
                    for screen in Screen.allCases {
                        let view = Workspace(app: app, previewScreen: screen)
                        try render(view, size: CGSize(width: 1280, height: 800), appearance: appearance,
                                   to: directory.appendingPathComponent("\(screen.rawValue)-\(style).png"))
                    }
                    try render(MenuPanel(app: app), size: CGSize(width: 320, height: 520), appearance: appearance,
                               to: directory.appendingPathComponent("menu-\(style).png"))
                    for step in SetupWizard.Step.allCases {
                        try render(SetupWizard(app: app, step: step), size: CGSize(width: 720, height: 520), appearance: appearance,
                                   to: directory.appendingPathComponent("wizard-\(step)-\(style).png"))
                    }
                    try render(AddSiteSheet(app: app), size: CGSize(width: 570, height: 450), appearance: appearance,
                               to: directory.appendingPathComponent("add-site-\(style).png"))
                    try render(AddExitSheet(app: app), size: CGSize(width: 570, height: 430), appearance: appearance,
                               to: directory.appendingPathComponent("add-exit-\(style).png"))
                }
            }
            try result.get()
        }
    }

    private static func render<Content: View>(_ view: Content, size: CGSize, appearance: ColorScheme, to url: URL) throws {
        let content = view.gozarLocale()
            .environment(\.snapshotRendering, true)
            .environment(\.colorScheme, appearance)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 2
        renderer.isOpaque = false
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw AppError("Could not render \(url.lastPathComponent)")
        }
        try png.write(to: url, options: .atomic)
        print(url.lastPathComponent)
    }
}
