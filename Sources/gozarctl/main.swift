import Darwin
import Foundation
import GozarCore

let process = ProcessInfo.processInfo
let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: process.arguments[0])
let result = ConfCLI.run(Array(process.arguments.dropFirst()), executable: executable, environment: process.environment)
FileHandle.standardOutput.write(Data(result.stdout.utf8))
FileHandle.standardError.write(Data(result.stderr.utf8))
exit(result.code)

