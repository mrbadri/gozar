import AppKit
import CoreText

enum AppResources {
    static let development = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let resources = Bundle.main.bundleURL.pathExtension == "app"
        ? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        : development.appendingPathComponent("Resources")
    static let isPackaged = Bundle.main.bundleURL.pathExtension == "app"
    static let bundledCLI = resources.appendingPathComponent("cli/laptop-vpn.sh")
    static let defaultVPN = isPackaged ? bundledCLI.path : development
        .appendingPathComponent("cli/laptop-vpn.sh").path

    static let icon: NSImage? = NSImage(contentsOf: resources.appendingPathComponent(isPackaged ? "AppIcon.icns" : "icon-1024.png"))

    static func registerFonts() {
        for weight in ["Regular", "Medium", "SemiBold", "Bold"] {
            let url = resources.appendingPathComponent("fonts/Vazirmatn-\(weight).ttf")
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
