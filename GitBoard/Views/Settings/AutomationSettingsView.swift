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
                    if setup.automations.isEmpty && setup.errorMessage == nil {
                        ProgressView("Loading automation status…")
                    } else if setup.automations.isEmpty {
                        Text("Connection status could not be loaded.")
                            .foregroundStyle(.secondary)
                    } else {
                        AutomationConnectionList(setup: setup)
                    }
                }

                if let errorMessage = setup.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Privacy") {
                Text("The Worker temporarily processes GitHub Project Item responses to run automation, but does not persist or log private Issue content.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task(id: setup.setupSessionID) {
            await setup.observeSetup()
        }
        .task(id: setup.phase) {
            await setup.loadAutomations()
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
