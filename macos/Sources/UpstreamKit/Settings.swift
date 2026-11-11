import Foundation

/// The user's global git config, read and written through `git config
/// --global`, so git decides which file that is (`~/.gitconfig`, the XDG one,
/// or `GIT_CONFIG_GLOBAL`, which the tests point at a scratch file)
/// (docs/plans/009_repositories_and_settings.md).
public struct GlobalConfig: Sendable {
    let git: Git
    let environment: [String: String]

    public init(git: Git, environment: [String: String] = [:]) {
        self.git = git
        self.environment = environment
    }

    /// `--global` reads no repository's config, so any folder will do.
    private var directory: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The value, or nil when it is not set (git exits 1).
    public func get(_ key: String) async -> String? {
        guard
            let result = try? await git.run(
                ["config", "--global", "--get", key], in: directory, environment: environment,
                allowedExitCodes: [0, 1]),
            result.status == 0
        else { return nil }
        return result.text.trimmingCharacters(in: .newlines)
    }

    /// Sets the value; an empty one unsets it (git exits 5 when it was not set).
    public func set(_ key: String, _ value: String) async throws {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            try await git.run(
                ["config", "--global", "--unset", key], in: directory, environment: environment,
                allowedExitCodes: [0, 5])
        } else {
            try await git.run(["config", "--global", key, value], in: directory, environment: environment)
        }
    }

    /// Whether `name` is a valid branch name, as git judges it.
    public func isValidBranch(_ name: String) async -> Bool {
        (try? await git.run(["check-ref-format", "refs/heads/\(name)"], in: directory)) != nil
    }

    /// An address git will accept and a forge can match to an account: one
    /// `@` with something on each side, and no spaces or angle brackets,
    /// which would break the `Name <email>` line git writes.
    public static func isValidEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
            && !email.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" })
    }
}

/// git's version, for the warning when it is older than Upstream needs.
public struct GitVersion: Comparable, Sendable, CustomStringConvertible {
    public let numbers: [Int]

    /// 2.38, for `git merge-tree --write-tree`
    /// (docs/plans/001_native_clients_on_system_git.md).
    public static let required = GitVersion(numbers: [2, 38])

    public init(numbers: [Int]) { self.numbers = numbers }

    /// From `git --version`, which has no machine-readable form: the first
    /// word that starts with a digit, read as dot-separated numbers
    /// ("git version 2.39.5 (Apple Git-154)", "2.45.1.windows.1"). It only
    /// decides a warning, so an unreadable version warns about nothing.
    public init?(parsing text: String) {
        guard let word = text.split(separator: " ").first(where: { $0.first?.isNumber == true }) else {
            return nil
        }
        let numbers = word.split(separator: ".").prefix { Int($0) != nil }.map { Int($0)! }
        guard numbers.count >= 2 else { return nil }
        self.numbers = numbers
    }

    public var isSupported: Bool { self >= Self.required }

    /// What the app says when it is not (docs/REQUIREMENTS.md#platforms).
    public var warning: String {
        "Upstream needs git \(Self.required) or later, and this is git \(self). "
            + "Install a newer one (brew install git) and choose it in Settings → General."
    }

    public var description: String { numbers.map(String.init).joined(separator: ".") }

    /// Number by number, so 2.9 is older than 2.38.
    public static func < (a: Self, b: Self) -> Bool {
        for k in 0..<max(a.numbers.count, b.numbers.count) {
            let (x, y) = (k < a.numbers.count ? a.numbers[k] : 0, k < b.numbers.count ? b.numbers[k] : 0)
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Self, b: Self) -> Bool { !(a < b) && !(b < a) }
}

extension Git {
    /// The version this git reports, or nil if it cannot be read.
    public func version() async -> GitVersion? {
        guard let out = try? await run(["--version"], in: FileManager.default.temporaryDirectory) else {
            return nil
        }
        return GitVersion(parsing: out.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
