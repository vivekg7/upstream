import Foundation

/// Runs the system's `git` (docs/plans/001_native_clients_on_system_git.md).
/// Every repository operation goes through here, so hooks, credential
/// helpers, signing, LFS and the user's config behave exactly as they do in
/// a terminal.
public struct Git: Sendable {
    public let executable: URL

    public init(executable: URL) { self.executable = executable }

    /// The first git found, in this order: a path the user chose, then
    /// Homebrew's, then Apple's. `/usr/bin/git` is only a shim until the
    /// Command Line Tools are installed; run without them it opens Apple's
    /// install prompt instead of answering, so it counts only once
    /// `xcode-select -p` names a developer directory.
    public static func locate(preferred: String? = nil) -> Git? {
        let fm = FileManager.default
        for path in [preferred, "/opt/homebrew/bin/git", "/usr/local/bin/git"].compactMap({ $0 })
        where fm.isExecutableFile(atPath: path) {
            return Git(executable: URL(fileURLWithPath: path))
        }
        if fm.isExecutableFile(atPath: "/usr/bin/git"), developerDirectoryExists() {
            return Git(executable: URL(fileURLWithPath: "/usr/bin/git"))
        }
        return nil
    }

    private static func developerDirectoryExists() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Options on every call. Output is parsed, so no colour, no pager and
    /// paths as raw UTF-8 rather than octal-quoted.
    static let baseArguments = ["-c", "color.ui=false", "-c", "core.quotepath=false", "--no-pager"]

    /// Never let git wait on a terminal nobody is looking at. Background
    /// reads take no optional locks, so a status refresh never collides with
    /// a commit the user is running in a terminal.
    static let baseEnvironment = ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]

    /// Runs `git <arguments>` in `directory` and returns what it printed.
    /// Throws `GitError` on a non-zero exit unless `allowedExitCodes` names it
    /// (`diff --no-index` exits 1 when the files differ). `environment` adds
    /// to the base, as `GIT_INDEX_FILE` does for a commit. Cancelling the task
    /// terminates the process.
    @discardableResult
    public func run(
        _ arguments: [String], in directory: URL, input: Data? = nil,
        environment: [String: String] = [:], allowedExitCodes: Set<Int32> = [0]
    ) async throws -> GitResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.baseArguments + arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment
            .merging(Self.baseEnvironment) { $1 }.merging(environment) { $1 }
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin

        let result: GitResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try process.run() } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    // Both pipes are drained at once: a process that fills
                    // one while we block on the other would never exit.
                    let err = DataBox()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        err.data = stderr.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    if let input {
                        try? stdin.fileHandleForWriting.write(contentsOf: input)
                        try? stdin.fileHandleForWriting.close()
                    }
                    let out = stdout.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    continuation.resume(
                        returning: GitResult(status: process.terminationStatus, stdout: out, stderr: err.data)
                    )
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard allowedExitCodes.contains(result.status) else {
            // Some refusals go to stdout: `commit` prints "nothing to commit" there.
            let message =
                result.errorText.isEmpty
                ? result.text.trimmingCharacters(in: .whitespacesAndNewlines) : result.errorText
            throw GitError(arguments: arguments, status: result.status, message: message)
        }
        return result
    }
}

public struct GitResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var text: String { String(decoding: stdout, as: UTF8.self) }
    public var errorText: String {
        String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct GitError: Error, LocalizedError, Sendable {
    public let arguments: [String]
    public let status: Int32
    public let message: String

    public var errorDescription: String? {
        message.isEmpty ? "git \(arguments.first ?? "") failed (exit \(status))" : message
    }
}

/// Written by one queue and read by another only after `DispatchGroup.wait`,
/// which orders the two.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
