import Foundation

struct ConfArguments {
    struct Option {
        let name: String
        var type: String? = nil
        var choices: [String] = []
        var required = false
    }

    enum Help: Error { case requested }

    let positionals: [String]
    let options: [String: String]
    let flags: Set<String>

    init(_ arguments: [String], required: [String], optional: Int = 0, variadic: Bool = false,
         options spec: [Option] = [], positionalChoices: [Int: [String]] = [:], redact: Bool = false) throws {
        var positionals: [String] = []
        var options: [String: String] = [:]
        var flags = Set<String>()
        var unknown: [String] = []
        var index = 0
        var literal = false

        func isOption(_ value: String) -> Bool {
            value.hasPrefix("-") && value != "-" && value.range(
                of: #"\A-(?:[0-9]+|[0-9]*\.[0-9]+)\z"#, options: .regularExpression
            ) == nil && !value.contains(" ")
        }

        func check(_ value: String, argument: String, choices: [String]) throws {
            if !choices.isEmpty, !choices.contains(value) {
                let choice = redact ? "value" : ConfJSON.string(value).pythonRepr
                throw ConfigError("argument \(argument): invalid choice: \(choice) (choose from \(choices.map { "'\($0)'" }.joined(separator: ", ")))")
            }
        }

        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if literal || !isOption(argument) {
                if let choices = positionalChoices[positionals.count] {
                    try check(argument, argument: required[positionals.count], choices: choices)
                }
                positionals.append(argument)
                continue
            }
            if argument == "--" { literal = true; continue }
            if ["-h", "--help"].contains(argument) { throw Help.requested }
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let optionName = String(parts[0])
            guard let option = spec.first(where: { $0.name == optionName }) else {
                unknown.append(argument)
                continue
            }
            if let type = option.type {
                let value: String
                if parts.count == 2 {
                    value = String(parts[1])
                } else {
                    guard index < arguments.count, !isOption(arguments[index]) else {
                        throw ConfigError("argument \(optionName): expected one argument")
                    }
                    value = arguments[index]
                    index += 1
                }
                if type == "int" {
                    let normalized = pythonStrip(value)
                    let pattern = #"\A[+-]?\p{Nd}(?:_?\p{Nd})*\z"#
                    guard normalized.range(of: pattern, options: .regularExpression) != nil else {
                        let display = redact ? "value" : ConfJSON.string(value).pythonRepr
                        throw ConfigError("argument \(optionName): invalid int value: \(display)")
                    }
                    options[optionName] = normalized.compactMap { char in
                        char.wholeNumberValue.map(String.init) ?? (char == "+" || char == "-" ? String(char) : nil)
                    }.joined()
                } else {
                    try check(value, argument: optionName, choices: option.choices)
                    options[optionName] = value
                }
            } else {
                guard parts.count == 1 else {
                    let display = redact ? "value" : ConfJSON.string(String(parts[1])).pythonRepr
                    throw ConfigError("argument \(optionName): ignored explicit argument \(display)")
                }
                flags.insert(optionName)
            }
        }
        let missing = Array(required.dropFirst(positionals.count)) + spec.filter {
            $0.required && options[$0.name] == nil
        }.map(\.name)
        if !missing.isEmpty { throw ConfigError("the following arguments are required: \(missing.joined(separator: ", "))") }
        let extra = variadic ? [] : Array(positionals.dropFirst(required.count + optional))
        if !unknown.isEmpty || !extra.isEmpty {
            let message = redact ? "" : ": " + (unknown + extra).joined(separator: " ")
            throw ConfigError("unrecognized arguments\(message)")
        }
        self.positionals = positionals
        self.options = options
        self.flags = flags
    }
}

