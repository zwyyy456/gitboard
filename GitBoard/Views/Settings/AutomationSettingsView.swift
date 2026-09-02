import AppKit
import SwiftUI

struct AutomationSettingsView: View {
    @Bindable var setup: AutomationSetupModel

    var body: some View {
        Form {
            Section("Pull Request Automation") {
                switch setup.phase {
                case .unavailable:
                    ContentUnavailableView(
                        "Automation Unavailable",
                        systemImage: "gearshape.2",
                        description: Text("This build does not have an automation service configured.")
                    )
                case .disconnected:
                    Text("Connect a personal GitHub Project to keep closing Issues in sync with pull request progress.")
                        .foregroundStyle(.secondary)
                    Button(
                        "Connect GitHub Automation…",
                        systemImage: "link",
                        action: startSetup
                    )
                case .starting:
                    ProgressView("Starting secure setup…")
                case .waitingForBrowser:
                    Label("Finish authorization and app installation in your browser.", systemImage: "safari")
                    Button("Open Setup Page", systemImage: "arrow.up.forward.app", action: reopenBrowser)
                case .loadingConfiguration:
                    ProgressView("Loading repositories and Projects…")
                case .configuring:
                    AutomationConfigurationForm(setup: setup)
                case .saving:
                    ProgressView("Enabling automation…")
                case .connectionStorageFailed:
                    Label("Automation is enabled, but the connection was not saved locally.", systemImage: "key")
                    Button("Retry Saving to Keychain", action: setup.retryTokenStorage)
                case .connected:
                    Label("GitHub Automation is connected.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Closing Issues can now follow pull request progress without GitBoard running.")
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = setup.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: setup.setupSessionID) {
            await setup.observeSetup()
        }
    }

    private func startSetup() {
        Task {
            if let url = await setup.startSetup() {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func reopenBrowser() {
        if let url = setup.browserURL() {
            NSWorkspace.shared.open(url)
        }
    }

}
