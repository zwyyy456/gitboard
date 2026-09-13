import SwiftUI

struct MenuBarConnectionErrorView: View {
    let error: Error
    let retry: () -> Void

    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissMenuBar) private var dismissMenuBar

    var body: some View {
        VStack(spacing: 16) {
            if let error = error as? GitHubError,
               [.ghCLINotFound, .notAuthenticated, .missingProjectScope, .accountChanged, .insufficientPermissions].contains(error) {
                onboardingView(icon: "person.crop.circle", title: String(localized: "Connect to GitHub"),
                               message: error.localizedDescription,
                               buttonTitle: String(localized: "Open GitHub Settings")) {
                    UserDefaults.standard.set("github", forKey: "selectedSettingsPane")
                    dismissMenuBar()
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            } else {
                genericErrorView(error)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func onboardingView(icon: String, title: String, message: String, buttonTitle: String, buttonAction: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.blue)

            Text(title)
                .font(.system(size: 15, weight: .semibold))

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Button(buttonTitle, action: buttonAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private func genericErrorView(_ error: Error) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)

            Text(error.localizedDescription)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") {
                retry()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

}
