import Foundation
import GozarCore

struct CLI: Sendable {
    let vpnPath: String
    let paths: StatePaths

    struct Result: Sendable {
        let code: Int32
        let stdout: String
        let stderr: String

        func checked() throws -> Result {
            guard code == 0 else {
                if let error = try? JSONDecoder().decode(CommandFailure.self, from: Data(stdout.utf8)) {
                    throw AppError(error.error)
                }
                throw AppError(stderr.isEmpty ? L.outcome(code) : stderr)
            }
            return self
        }

        private struct CommandFailure: Decodable { let error: String }

        func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
            _ = try checked()
            do { return try JSONDecoder().decode(type, from: Data(stdout.utf8)) }
            catch {
                if !stderr.isEmpty { throw AppError(stderr) }
                throw error
            }
        }
    }

    private var executable: URL {
        URL(fileURLWithPath: (vpnPath as NSString).expandingTildeInPath)
    }

    var confDir: URL {
        let bundled = AppResources.bundledCLI.deletingLastPathComponent().appendingPathComponent("laptop-vpn.d")
        return AppResources.isPackaged ? bundled :
            executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("laptop-vpn.d")
    }

    private var configurationExecutable: URL {
        let app = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return app.deletingLastPathComponent().appendingPathComponent("gozarctl")
    }

    func run(_ args: [String], json: Bool = false, progress: (@Sendable (String) -> Void)? = nil) async -> Result {
        await run(executable, args: args, state: paths.stateDir, json: json, progress: progress)
    }

    func configuration(
        _ args: [String], state: URL? = nil, progress: (@Sendable (String) -> Void)? = nil
    ) async -> Result {
        await run(
            configurationExecutable, args: args,
            state: state ?? paths.stateDir, json: args.contains("--json"), progress: progress
        )
    }

    private func run(
        _ executable: URL, args: [String], state: URL, json: Bool = false, progress: (@Sendable (String) -> Void)?
    ) async -> Result {
        var environment = ProcessInfo.processInfo.environment
        environment["LAPTOP_VPN_STATE"] = state.path
        environment["LAPTOP_VPN_CONF_DIR"] = confDir.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" +
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        environment["SUDO_ASKPASS"] = AppResources.resources.appendingPathComponent("gozar-askpass").path

        let child = ChildProcess()
        let process = child.process
        process.executableURL = executable
        process.arguments = args
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        return await withTaskCancellationHandler {
            await Task.detached {
                do {
                    try child.start()
                } catch {
                    return Result(code: 1, stdout: "", stderr: error.localizedDescription)
                }

                // Read both pipes concurrently so either stream can exceed the pipe buffer.
                async let stdout = Self.read(output.fileHandleForReading, progress: json ? nil : progress)
                async let stderr = Self.read(errors.fileHandleForReading, progress: progress)
                let streams = await (stdout, stderr)
                process.waitUntilExit()
                return Result(code: process.terminationStatus, stdout: streams.0, stderr: streams.1)
            }.value
        } onCancel: {
            child.cancel()
        }
    }

    private static func read(_ handle: FileHandle, progress: (@Sendable (String) -> Void)?) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                defer { try? handle.close() }
                var contents = Data()
                var partial = Data()
                while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
                    contents.append(chunk)
                    if let progress {
                        partial.append(chunk)
                        while let end = partial.firstIndex(of: 10) {
                            let line = String(decoding: partial[..<end], as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !line.isEmpty { progress(line) }
                            partial.removeSubrange(...end)
                        }
                    }
                }
                if !partial.isEmpty { progress?(String(decoding: partial, as: UTF8.self)) }
                continuation.resume(returning: String(decoding: contents, as: UTF8.self))
            }
        }
    }

    private final class ChildProcess: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var cancelled = false

        func start() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            try process.run()
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
