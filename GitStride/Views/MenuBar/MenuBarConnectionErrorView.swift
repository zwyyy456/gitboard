import SwiftUI

struct MenuBarConnectionErrorView: View {
    let error: Error
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let ghError = error as? GitHubError {
                switch ghError {
                case .ghCLINotFound:
                    onboardingView(
                        icon: "terminal",
                        title: "GitHub CLI Required",
                        message: "GitStride uses the GitHub CLI (gh) for authentication.",
                        buttonTitle: "Install GitHub CLI",
                        buttonAction: {
                            NSWorkspace.shared.open(URL(string: "https://cli.github.com")!)
                        }
                    )

                case .notAuthenticated:
                    onboardingView(
                        icon: "person.crop.circle.badge.questionmark",
                        title: "Sign in to GitHub",
                        message: "Open Terminal and run:\ngh auth login",
                        buttonTitle: "Try Again",
                        buttonAction: {
                            retry()
                        }
                    )

                case .missingProjectScope:
                    onboardingView(
                        icon: "lock.shield",
                        title: "Project Access Required",
                        message: "Open Terminal and run:\ngh auth refresh -s project",
                        buttonTitle: "Try Again",
                        buttonAction: {
                            retry()
                        }
                    )

                default:
                    genericErrorView(error)
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
                .font(.system(size: 12, design: .monospaced))
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
