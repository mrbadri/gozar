import Foundation

public enum Fmt {
    private static let latin = Locale(identifier: "en_US_POSIX")
    private static let clockLocale = Locale(identifier: "en_GB")

    public static func bytes<T: BinaryInteger>(_ value: T) -> String { size(Double(value)) }

    public static func rate(_ value: Double) -> String { size(value) + "/s" }

    public static func compactRate(_ value: Double) -> String {
        size(value).replacingOccurrences(of: " B", with: "")
            .replacingOccurrences(of: "B", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    public static func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value >= 1000 { return decimal(value / 1000, places: 1) + " s" }
        return decimal(value, places: 0) + " ms"
    }

    public static func duration(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int.max) else { return "—" }
        let seconds = Int(value)
        if seconds >= 86_400 { return "\(seconds / 86_400)d \(seconds / 3_600 % 24)h" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h \(seconds / 60 % 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    public static func percent(_ value: Double?, places: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return decimal(value * 100, places: places) + "%"
    }

    public static func time(_ date: Date) -> String {
        date.formatted(.dateTime.locale(clockLocale).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    public static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.locale(clockLocale).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        value.formatted(.number.locale(latin).grouping(.never).precision(.fractionLength(places)))
    }

    private static func size(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var scaled = value.isFinite ? max(0, value) : 0
        var unit = 0
        while scaled >= 999.95, unit < units.count - 1 {
            scaled /= 1000
            unit += 1
        }
        return decimal(scaled, places: unit == 0 ? 0 : 1) + " " + units[unit]
    }
}
