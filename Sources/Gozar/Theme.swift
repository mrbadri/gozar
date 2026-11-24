import AppKit
import Charts
import GozarCore
import SwiftUI

enum Theme {
    static let vpn = hex(0x7C5CFF)
    static let blue = hex(0x3B82F6)
    static let cyan = hex(0x22D3EE)
    static let direct = hex(0x14B8A6)
    static let cisco = hex(0xF59E0B)
    static let good = hex(0x22C55E)
    static let failed = hex(0xF43F5E)
    static let radius: CGFloat = 20
    static let gap: CGFloat = 16
    static let headline = type(.title2, .semibold)
    static let number = type(.largeTitle, .semibold, size: 52).monospacedDigit()
    static let window = Color(nsColor: .windowBackgroundColor)
    static let motion = Animation.spring(response: 0.4, dampingFraction: 0.8)

    static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255)
    }

    static func type(_ role: Font.TextStyle = .body, _ weight: Font.Weight = .regular, size: CGFloat? = nil) -> Font {
        let points: CGFloat = switch role {
        case .largeTitle: 32
        case .title: 28
        case .title2: 24
        case .title3: 19
        case .headline: 16
        case .subheadline, .body: 14
        case .callout: 13
        case .caption: 12
        case .caption2: 11
        default: 12
        }
        let face = switch weight {
        case .medium: "Vazirmatn-Medium"
        case .semibold: "Vazirmatn-SemiBold"
        case .bold: "Vazirmatn-Bold"
        default: "Vazirmatn"
        }
        return .custom(face, size: size ?? points, relativeTo: role)
    }

    static var gradient: LinearGradient {
        LinearGradient(colors: [vpn, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func color(_ route: Route) -> Color {
        switch route {
        case .vpn: vpn
        case .direct: direct
        case .cisco: cisco
        }
    }

    static func symbol(_ route: Route) -> String {
        switch route {
        case .vpn: "lock.shield"
        case .direct: "arrow.right"
        case .cisco: "building.2"
        }
    }

    static func routeInk(_ route: Route, in scheme: ColorScheme) -> Color {
        // Maintain the route hues while giving small labels contrast on both materials.
        if scheme == .dark {
            return route == .vpn ? Color(red: 0.67, green: 0.62, blue: 1) : color(route)
        }
        return switch route {
        case .vpn: Color(red: 0.33, green: 0.26, blue: 0.77)
        case .direct: Color(red: 0.02, green: 0.43, blue: 0.38)
        case .cisco: Color(red: 0.55, green: 0.32, blue: 0.04)
        }
    }

    static func health(_ value: Double?, threshold: Double, loss: Double? = nil,
                       redAt: Double? = nil, textOn scheme: ColorScheme? = nil) -> Color {
        let red = scheme == .light ? hex(0xAD163E) : failed
        if let loss, loss >= 0.05 { return red }
        guard let value else { return .gray }
        if redAt.map({ value >= $0 }) ?? (value > threshold * 2) { return red }
        if value >= threshold || (loss ?? 0) >= 0.01 {
            return scheme == .light ? hex(0x925210) : cisco
        }
        return scheme == .light ? hex(0x15723C) : good
    }

    @MainActor
    static func accent(_ app: AppModel) -> Color {
        app.problem ? .orange : app.on || app.connecting ? vpn : .gray
    }
}

struct WindowBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        let dark = scheme == .dark
        GeometryReader { area in
            let width = area.size.width
            let height = area.size.height
            ZStack {
                LinearGradient(colors: dark ? [Theme.hex(0x0A0C18), Theme.hex(0x121530)] :
                                [Theme.hex(0xF7F8FC), Theme.hex(0xECEEF8)], startPoint: .top, endPoint: .bottom)
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || snapshot)) { time in
                    let phase = reduceMotion || snapshot ? 0 : time.date.timeIntervalSinceReferenceDate * .pi / 20
                    let opacity = dark ? 0.16 : 0.10
                    Ellipse().fill(Theme.vpn.opacity(opacity))
                        .frame(width: width * 0.75, height: height * 0.85)
                        .blur(radius: 120)
                        .position(x: width * (0.73 + 0.08 * sin(phase)), y: height * (0.17 + 0.07 * cos(phase)))
                    Ellipse().fill(Theme.cyan.opacity(opacity))
                        .frame(width: width * 0.69, height: height * 0.65)
                        .blur(radius: 120)
                        .position(x: width * (0.17 + 0.09 * cos(phase)), y: height * (0.85 + 0.08 * sin(phase)))
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(padding)
            .background { GlassSurface() }
            .offset(y: hovering && !reduceMotion ? -2 : 0)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : Theme.motion, value: hovering)
    }
}

struct GlassSurface: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.snapshotRendering) private var snapshot
    var radius: CGFloat = Theme.radius

    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tint = dark ? Color.white : Color.black
        ZStack {
            if !snapshot { shape.fill(.ultraThinMaterial) }
            shape.fill(.linearGradient(
                colors: dark ? [.white.opacity(0.068), .white.opacity(0.025)] : [.white.opacity(0.67), .white.opacity(0.35)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            shape.strokeBorder(.linearGradient(colors: [tint.opacity(dark ? 0.16 : 0.08),
                                                        tint.opacity(dark ? 0.03 : 0.02)],
                                               startPoint: .top, endPoint: .bottom))
            shape.inset(by: 1).strokeBorder(.linearGradient(colors: [.white.opacity(dark ? 0.06 : 0.65), .clear],
                                                             startPoint: .top, endPoint: .center))
        }
        .shadow(color: .black.opacity(dark ? 0.25 : 0.08), radius: 24, y: 12)
        .allowsHitTesting(false)
    }
}

struct Technical: View {
    let value: String
    var font: Font? = nil

    init(_ value: String, font: Font? = nil) {
        self.value = value
        self.font = font
    }

    var body: some View {
        Text(verbatim: "\u{2066}\(value)\u{2069}")
            .font((font ?? .system(.body, design: .monospaced)).monospaced())
            .monospacedDigit()
            .environment(\.layoutDirection, .leftToRight)
    }
}

struct RouteChip: View {
    let route: Route
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label(L.route(route), systemImage: Theme.symbol(route))
            .font(Theme.type(.caption, .semibold))
            .foregroundStyle(Theme.routeInk(route, in: colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.linearGradient(colors: [Theme.color(route).opacity(0.18), Theme.color(route).opacity(0.08)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.color(route).opacity(0.35)) }
            .fixedSize()
    }
}

struct HealthDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: color.opacity(0.40), radius: 18)
            .accessibilityHidden(true)
    }
}

struct SectionHeading<Accessory: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(Theme.type(.callout, .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(Theme.type(.headline, .semibold))
            Spacer(minLength: 4)
            accessory
        }
    }
}

extension SectionHeading where Accessory == EmptyView {
    init(_ title: String, _ symbol: String) {
        self.init(title: title, symbol: symbol) { EmptyView() }
    }
}

struct ScreenPage<Actions: View, Content: View>: View {
    @Environment(\.openAddSite) private var openAddSite
    let screen: Screen
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(screen.title).font(Theme.type(.largeTitle, .bold, size: 31)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                actions
                Button(L.addSite, systemImage: "plus.circle", action: openAddSite)
                    .buttonStyle(GozarButtonStyle())
                    .accessibilityLabel(L.addSite)
            }
            .padding(.horizontal, 24)
            .padding(.top, 2)
            .padding(.bottom, 14)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension ScreenPage where Actions == EmptyView {
    init(_ screen: Screen, @ViewBuilder content: () -> Content) {
        self.init(screen: screen, actions: { EmptyView() }, content: content)
    }
}

struct PageScroll<Content: View>: View {
    @Environment(\.snapshotRendering) private var snapshot
    var spacing: CGFloat = Theme.gap
    @ViewBuilder var content: Content

    var body: some View {
        if snapshot {
            GeometryReader { viewport in
                contents
                    .frame(width: viewport.size.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: viewport.size.height, alignment: .top)
                    .clipped()
            }
        } else {
            ScrollView { contents }
        }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .padding(.bottom, 24)
            .frame(maxWidth: 1480)
            .frame(maxWidth: .infinity)
    }
}

struct IconAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(minWidth: 18) }
            .buttonStyle(GozarButtonStyle())
            .accessibilityLabel(title)
            .help(title)
    }
}

struct GozarButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.type(.callout, .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .foregroundStyle(prominent && enabled ? .white : .primary)
            .background(prominent && enabled ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.045)),
                        in: .rect(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.08)).allowsHitTesting(false) }
            .shadow(color: prominent && enabled ? Theme.vpn.opacity(0.33) : .clear, radius: 12, y: 4)
            .opacity(enabled ? configuration.isPressed ? 0.72 : 1 : 0.45)
    }
}

private struct SnapshotRendering: EnvironmentKey {
    static let defaultValue = false
}

private struct OpenAddSite: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var snapshotRendering: Bool {
        get { self[SnapshotRendering.self] }
        set { self[SnapshotRendering.self] = newValue }
    }
    var openAddSite: () -> Void {
        get { self[OpenAddSite.self] }
        set { self[OpenAddSite.self] = newValue }
    }
}

struct ActionLabel: View {
    let title: String
    let symbol: String

    init(_ title: String, _ symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View { Label(title, systemImage: symbol).lineLimit(1) }
}

struct TextEntry: View {
    let title: String
    @Binding var text: String
    var placeholder = ""
    var technical = true
    var snapshot = false
    var secure = false

    var body: some View {
        Group {
            if snapshot {
                HStack(spacing: 7) {
                    Text(text.isEmpty ? placeholder : text)
                        .monospacedDigit()
                        .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 25)
                .background(.quaternary.opacity(0.34), in: .rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.08)) }
            } else if secure {
                SecureField(title, text: $text, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(title, text: $text, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
            }
        }
        .font(technical ? .system(.callout, design: .monospaced) : Theme.type(.callout))
        .environment(\.layoutDirection, technical ? .leftToRight : .rightToLeft)
        .accessibilityLabel(title)
    }
}

struct LabeledSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var snapshot = false
    var labelVisible = true

    var body: some View {
        if snapshot {
            if labelVisible {
                HStack(spacing: 12) {
                    Text(title).font(Theme.type(.callout))
                    Spacer(minLength: 0)
                    painted
                }
                .accessibilityLabel(title)
            } else {
                painted.accessibilityLabel(title)
            }
        } else if labelVisible {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).accessibilityLabel(title)
        } else {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().accessibilityLabel(title)
        }
    }

    private var painted: some View {
        Capsule().fill(isOn ? Theme.vpn : Color.secondary.opacity(0.25))
            .frame(width: 34, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(Color(nsColor: .alternateSelectedControlTextColor))
                    .frame(width: 14, height: 14)
                    .padding(.horizontal, 2)
            }
    }
}

struct EmptyMessage: View {
    let title: String
    let symbol: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
                .font(Theme.headline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

struct MetricChart: View {
    let points: [MetricPoint]
    let color: Color
    let axes: Bool
    let axisLabels: Int
    let format: (Double) -> String

    init(_ points: [MetricPoint], color: Color, axes: Bool = false, axisLabels: Int = 3,
         format: @escaping (Double) -> String = Fmt.rate) {
        self.points = points
        self.color = color
        self.axes = axes
        self.axisLabels = axisLabels
        self.format = format
    }

    var body: some View {
        let top = max(1e-9, (points.map(\.value).max() ?? 1) * 1.10)
        Chart {
            RuleMark(y: .value("Baseline", 0)).foregroundStyle(Color.gray.opacity(0.27))
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.at), y: .value("Value", point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.at), y: .value("Value", point.value))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(color)
            }
        }
        .chartYScale(domain: 0...top)
        .shadow(color: color.opacity(0.32), radius: 4)
        .chartXScale(range: .plotDimension(padding: 2))
        .chartXAxis {
            if axes {
                AxisMarks(values: timeMarks) { value in
                    AxisValueLabel(centered: false, anchor: .top, collisionResolution: .greedy) {
                        if let at = value.as(Date.self) {
                            Technical(Fmt.clock(at), font: .caption2)
                                .foregroundStyle(.primary.opacity(0.72))
                                .fixedSize()
                        }
                    }
                }
            }
        }
        .chartYAxis {
            if axes {
                AxisMarks(position: .leading, values: [0, top / 2, top]) { value in
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Technical(format(number), font: .caption2).foregroundStyle(.primary.opacity(0.72)) }
                    }
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var timeMarks: [Date] {
        guard let first = points.first?.at, let last = points.last?.at, first < last else { return [] }
        let interval = last.timeIntervalSince(first)
        if interval < 60 { return [first.addingTimeInterval(interval / 2)] }
        // Keep label centers inside the plot so narrow inspector charts never clip a timestamp.
        let fractions = axisLabels == 2 ? [0.19, 0.81] : [0.16, 0.5, 0.84]
        return fractions.map { first.addingTimeInterval(interval * $0) }
    }
}

struct RouteActions: View {
    let app: AppModel
    let domain: String
    var allowCopy = true

    var body: some View {
        Button(L.sendViaVPN, systemImage: Theme.symbol(.vpn)) { app.changeRoute(domain, to: .vpn) }.accessibilityLabel(L.sendViaVPN)
        Button(L.sendDirect, systemImage: Theme.symbol(.direct)) { app.changeRoute(domain, to: .direct) }.accessibilityLabel(L.sendDirect)
        Button(L.sendCisco, systemImage: Theme.symbol(.cisco)) { app.changeRoute(domain, to: .cisco) }.accessibilityLabel(L.sendCisco)
        Divider()
        Button(L.removeFromRules, systemImage: "minus.circle") { app.changeRoute(domain, to: nil) }.accessibilityLabel(L.removeFromRules)
        if allowCopy {
            Button(L.copyName, systemImage: "document.on.document") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(domain, forType: .string)
            }
            .accessibilityLabel(L.copyName)
        }
    }
}
