import Foundation

struct ConfObject: Equatable, ExpressibleByDictionaryLiteral {
    private(set) var keys: [String] = []
    private var values: [String: ConfJSON] = [:]

    init() {}

    init(dictionaryLiteral elements: (String, ConfJSON)...) {
        for (key, value) in elements { self[key] = value }
    }

    subscript(_ key: String) -> ConfJSON? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }
}

indirect enum ConfJSON: Equatable {
    case null, bool(Bool), number(String), string(String), array([ConfJSON]), object(ConfObject)

    static func int(_ value: Int) -> Self { .number(String(value)) }
    static func strings(_ values: [String]) -> Self { .array(values.map(Self.string)) }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var int: Int? { if case .number(let value) = self { return Int(value) }; return nil }
    var isInteger: Bool {
        if case .number(let value) = self {
            return value.last?.isASCII == true && value.last?.isNumber == true && !value.contains(".") && !value.contains("e")
        }
        return false
    }
    var array: [Self]? { if case .array(let value) = self { return value }; return nil }
    var object: ConfObject? { if case .object(let value) = self { return value }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var strings: [String] { array?.compactMap(\.string) ?? [] }
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let value): return value
        case .number(let value): return Double(value) != 0
        case .string(let value): return !value.isEmpty
        case .array(let value): return !value.isEmpty
        case .object(let value): return !value.keys.isEmpty
        }
    }

    init(parsing json: String) throws {
        if json.unicodeScalars.first == "\u{feff}" {
            throw ConfJSONError(line: 1, column: 1, message: "Unexpected UTF-8 BOM (decode using utf-8-sig)")
        }
        var parser = ConfJSONParser(json)
        self = try parser.value()
        parser.skipWhitespace()
        if parser.current != nil { throw parser.error("Extra data") }
    }

    func rendered(ascii: Bool = false) -> String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value
        case .string(let value): return Self.quote(value, ascii: ascii)
        case .array(let values): return "[" + values.map { $0.rendered(ascii: ascii) }.joined(separator: ", ") + "]"
        case .object(let object):
            return "{" + object.keys.map {
                Self.quote($0, ascii: ascii) + ": " + (object[$0] ?? .null).rendered(ascii: ascii)
            }.joined(separator: ", ") + "}"
        }
    }

    var pythonRepr: String {
        switch self {
        case .string(let value):
            let quote: Unicode.Scalar = value.contains("'") && !value.contains("\"") ? "\"" : "'"
            var result = String(quote)
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\\", quote: result += "\\" + String(scalar)
                case "\n": result += "\\n"
                case "\t": result += "\\t"
                case "\r": result += "\\r"
                case " ": result += " "
                default:
                    switch scalar.properties.generalCategory {
                    case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                        switch scalar.value {
                        case ...0xff: result += String(format: "\\x%02x", scalar.value)
                        case ...0xffff: result += String(format: "\\u%04x", scalar.value)
                        default: result += String(format: "\\U%08x", scalar.value)
                        }
                    default: result.unicodeScalars.append(scalar)
                    }
                }
            }
            return result + String(quote)
        case .null: return "None"
        case .bool(let value): return value ? "True" : "False"
        case .array(let values): return "[" + values.map(\.pythonRepr).joined(separator: ", ") + "]"
        case .object(let object):
            return "{" + object.keys.map {
                Self.string($0).pythonRepr + ": " + (object[$0] ?? .null).pythonRepr
            }.joined(separator: ", ") + "}"
        case .number(let value):
            switch value {
            case "NaN": return "nan"
            case "Infinity": return "inf"
            case "-Infinity": return "-inf"
            default: return value
            }
        }
    }

    private static func quote(_ value: String, ascii: Bool) -> String {
        var quoted = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\u{8}": quoted += "\\b"
            case "\u{c}": quoted += "\\f"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            default:
                if scalar.value < 32 || ascii && scalar.value > 126 {
                    for unit in String(scalar).utf16 { quoted += String(format: "\\u%04x", unit) }
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        return quoted + "\""
    }

    func dumped(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = pad + "  "
        switch self {
        case .object(let object) where !object.keys.isEmpty:
            let items = object.keys.map { key in
                inner + Self.quote(key, ascii: false) + ": " + (object[key] ?? .null).dumped(indent: indent + 1)
            }
            return "{\n" + items.joined(separator: ",\n") + "\n" + pad + "}"
        case .array(let values) where !values.isEmpty:
            let strings = values.allSatisfy { $0.string != nil }
            if strings && !values.contains(where: { ($0.string?.unicodeScalars.count ?? 0) > 60 }) {
                var lines: [String] = []
                var line = ""
                for part in values.map({ $0.rendered() }) {
                    if !line.isEmpty && inner.count + line.unicodeScalars.count + part.unicodeScalars.count + 2 > 100 {
                        lines.append(line + ",")
                        line = part
                    } else {
                        line = line.isEmpty ? part : line + ", " + part
                    }
                }
                if lines.isEmpty && pad.count + line.unicodeScalars.count < 90 { return "[" + line + "]" }
                return "[\n" + (lines + [line]).map { inner + $0 }.joined(separator: "\n") + "\n" + pad + "]"
            }
            return "[\n" + values.map {
                inner + $0.dumped(indent: indent + 1)
            }.joined(separator: ",\n") + "\n" + pad + "]"
        default:
            return rendered()
        }
    }
}

struct ConfJSONError: Error {
    let line: Int
    let column: Int
    let message: String
}

private struct ConfJSONParser {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ input: String) { scalars = Array(input.unicodeScalars) }

    var current: Unicode.Scalar? { scalars.indices.contains(index) ? scalars[index] : nil }

    mutating func skipWhitespace() {
        while let current, [" ", "\r", "\n", "\t"].contains(current) { index += 1 }
    }

    private mutating func eat(_ value: Unicode.Scalar) -> Bool {
        guard current == value else { return false }
        index += 1
        return true
    }

    func error(_ message: String, at position: Int? = nil) -> ConfJSONError {
        let before = scalars.prefix(position ?? index)
        let line = before.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
        let column = before.count - (before.lastIndex(of: "\n") ?? -1)
        return ConfJSONError(line: line, column: column, message: message)
    }

    mutating func value(depth: Int = 0) throws -> ConfJSON {
        guard depth < 500 else { throw error("Too many nested values") }
        skipWhitespace()
        if eat("{") {
            var object: ConfObject = [:]
            skipWhitespace()
            if eat("}") { return .object(object) }
            repeat {
                skipWhitespace()
                guard current == "\"" else { throw error("Expecting property name enclosed in double quotes") }
                let key = try string()
                skipWhitespace()
                guard eat(":") else { throw error("Expecting ':' delimiter") }
                object[key] = try value(depth: depth + 1)
                skipWhitespace()
                if eat("}") { return .object(object) }
                guard eat(",") else { throw error("Expecting ',' delimiter") }
            } while true
        }
        if eat("[") {
            var values: [ConfJSON] = []
            skipWhitespace()
            if eat("]") { return .array(values) }
            repeat {
                values.append(try value(depth: depth + 1))
                skipWhitespace()
                if eat("]") { return .array(values) }
                guard eat(",") else { throw error("Expecting ',' delimiter") }
            } while true
        }
        if current == "\"" { return .string(try string()) }
        for (token, literal) in [("null", ConfJSON.null), ("true", .bool(true)), ("false", .bool(false)),
                                 ("NaN", .number("NaN")), ("Infinity", .number("Infinity")), ("-Infinity", .number("-Infinity"))]
        where scalars[index...].starts(with: token.unicodeScalars) {
            index += token.count
            return literal
        }
        let start = index
        _ = eat("-")
        guard digit else { throw error("Expecting value", at: start) }
        if !eat("0") { while digit { index += 1 } }
        if current == ".", digit(at: index + 1) {
            index += 2
            while digit { index += 1 }
        }
        if current == "e" || current == "E" {
            let exponent = index
            index += 1
            if !eat("+") { _ = eat("-") }
            if digit {
                while digit { index += 1 }
            } else {
                index = exponent
            }
        }
        let number = String(String.UnicodeScalarView(scalars[start..<index]))
        return .number(Self.normalizedNumber(number))
    }

    private static func normalizedNumber(_ number: String) -> String {
        guard number.contains(where: { ".eE".contains($0) }) else { return number == "-0" ? "0" : number }
        guard let value = Double(number) else { return number }
        if value.isInfinite { return value.sign == .minus ? "-Infinity" : "Infinity" }
        // Python keeps small powers of ten in decimal form.
        let result = String(value)
        let pieces = result.split(separator: "e")
        if pieces.count == 2, let exponent = Int(pieces[1]), (-4...15).contains(exponent) {
            let sign = result.hasPrefix("-") ? "-" : ""
            let digits = pieces[0].filter(\.isNumber)
            let split = exponent + 1
            if split <= 0 { return sign + "0." + String(repeating: "0", count: -split) + digits }
            if split >= digits.count { return sign + digits + String(repeating: "0", count: split - digits.count) + ".0" }
            return sign + digits.prefix(split) + "." + digits.dropFirst(split)
        }
        return result
    }

    private var digit: Bool { digit(at: index) }

    private func digit(at offset: Int) -> Bool {
        scalars.indices.contains(offset) && (48...57).contains(scalars[offset].value)
    }

    private mutating func string() throws -> String {
        let start = index
        index += 1
        var result = ""
        while let scalar = current {
            index += 1
            if scalar == "\"" { return result }
            if scalar.value < 32 { throw error("Invalid control character at", at: index - 1) }
            guard scalar == "\\" else { result.unicodeScalars.append(scalar); continue }
            guard let escape = current else { break }
            index += 1
            switch escape {
            case "\"", "\\", "/": result.unicodeScalars.append(escape)
            case "b": result += "\u{8}"
            case "f": result += "\u{c}"
            case "n": result += "\n"
            case "r": result += "\r"
            case "t": result += "\t"
            case "u":
                let first = try readHex()
                if (0xd800...0xdbff).contains(first), scalars[index...].starts(with: ["\\", "u"]) {
                    let saved = index
                    index += 2
                    let second = try readHex()
                    if (0xdc00...0xdfff).contains(second) {
                        result += String(decoding: [first, second], as: UTF16.self)
                    } else {
                        index = saved
                        result += "\u{fffd}"
                    }
                } else {
                    result += String(decoding: [first], as: UTF16.self)
                }
            default: throw error("Invalid \\escape", at: index - 2)
            }
        }
        throw error("Unterminated string starting at", at: start)
    }

    private mutating func readHex() throws -> UInt16 {
        guard index + 4 <= scalars.count,
              let value = UInt16(String(String.UnicodeScalarView(scalars[index..<index + 4])), radix: 16) else {
            throw error("Invalid \\uXXXX escape", at: index - 1)
        }
        index += 4
        return value
    }
}

