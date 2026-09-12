import SwiftUI

struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "rectangle.3.group")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to GitStride")
                    .font(.title.bold())
                Text("Browse and update your GitHub Projects from your workspace or the menu bar.")
                Text("Start by connecting your GitHub account, then choose a Project.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

            Text("Pull request automation is optional. You can set it up later in GitHub settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Set Up Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open GitHub Settings") {
                    UserDefaults.standard.set("github", forKey: "selectedSettingsPane")
                    dismiss()
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
    }
}
