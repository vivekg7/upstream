import SwiftUI
import UpstreamKit

/// Upstream → Settings (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Accounts", systemImage: "person.crop.circle") { AccountsSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}
