import Foundation
import Security

/// Where the accounts' tokens are kept: the Keychain in the app, memory in
/// the tests, which must neither prompt nor touch the user's Keychain.
public protocol TokenStore: Sendable {
    func token(for host: String) -> (login: String, token: String)?
    func save(_ token: String, login: String, host: String) throws
    func delete(host: String)
}

/// One generic password per host, in the login keychain. The legacy
/// (file-based) keychain, because the data protection keychain needs an
/// entitlement an ad hoc signed app cannot have. The item's access list
/// trusts the app that made it, so the app's own binary run as git's
/// credential helper reads it without a prompt.
public struct Keychain: TokenStore {
    public init() {}

    static func service(_ host: String) -> String { "Upstream: \(host)" }

    public func token(for host: String) -> (login: String, token: String)? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service(host),
            kSecMatchLimit: kSecMatchLimitOne, kSecReturnAttributes: true, kSecReturnData: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let found = item as? [CFString: Any], let login = found[kSecAttrAccount] as? String,
            let data = found[kSecValueData] as? Data
        else { return nil }
        return (login, String(decoding: data, as: UTF8.self))
    }

    public func save(_ token: String, login: String, host: String) throws {
        delete(host: host)
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service(host), kSecAttrAccount: login,
            kSecAttrLabel: Self.service(host), kSecValueData: Data(token.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw ForgeError.signIn("The Keychain refused the token: \(reason)")
        }
    }

    public func delete(host: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service(host),
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// git's credential helper protocol, spoken by the app's own binary when
/// git runs it as `Upstream credential get` (docs/plans/002_forges_github_first.md).
/// git writes `key=value` lines and a blank line; the helper answers with
/// the fields it can fill and exits. Only `get` is answered: `store` and
/// `erase` are no-ops, since the token is the account's, managed in
/// Settings, and a failed push must not delete it.
public enum CredentialHelper {
    public static func answer(_ action: String, input: String, store: any TokenStore) -> String {
        guard action == "get" else { return "" }
        var fields: [String: String] = [:]
        for line in input.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break }
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard fields["protocol"] == "https", let host = fields["host"] else { return "" }
        // git sends `host:port` when the URL has a port; the account may
        // have been added either way.
        let bare = String(host.split(separator: ":").first ?? "")
        guard let saved = store.token(for: host) ?? store.token(for: bare) else { return "" }
        // A username in the remote URL is kept: GitHub ignores it for a token.
        let user = fields["username"] == nil ? "username=\(saved.login)\n" : ""
        return "\(user)password=\(saved.token)\n"
    }

    /// The helper as git's config spells it: `!` makes git run it through
    /// the shell with the action appended, and the single quotes keep a
    /// path with spaces (`/Applications/My Apps/…`) in one word.
    public static func command(executable: String) -> String {
        "!'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' credential"
    }
}
