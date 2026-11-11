import Foundation
import UpstreamKit

/// One binary, two roles. Run by git as `Upstream credential get`, it is
/// the signed-in forge's credential helper: it answers from the Keychain
/// and exits without starting the UI (docs/plans/002_forges_github_first.md).
/// Run any other way, it is the app.
@main
enum Main {
    @MainActor static func main() {
        let args = CommandLine.arguments.dropFirst()
        guard args.first == "credential" else { return UpstreamApp.main() }
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let answer = CredentialHelper.answer(args.dropFirst().first ?? "", input: input, store: Keychain())
        FileHandle.standardOutput.write(Data(answer.utf8))
    }
}
