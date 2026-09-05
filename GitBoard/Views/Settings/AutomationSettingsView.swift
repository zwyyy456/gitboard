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
                    Text("Connect once to keep closing Issues in matching personal Projects synchronized across every repository available to the GitHub App.")
                        .foregroundStyle(.secondary)
                    Button(
                        "Connect GitHub Automation…",
                        systemImage: "link",
                        action: startSetup
                    )
                case .loadingConnection:
                    ProgressView("Loading automation status…")
                case .connectionLoadFailed:
                    Text("The saved automation connection could not be loaded.")
                        .foregroundStyle(.secondary)
                    Button(
                        "Retry Loading",
                        systemImage: "arrow.clockwise",
                        action: retryConnectionLoad
                    )
                case .starting:
                    ProgressView("Starting secure setup…")
                case .waitingForBrowser:
                    Label("Finish authorization and app installation in your browser.", systemImage: "safari")
                    Button("Open Setup Page", systemImage: "arrow.up.forward.app", action: reopenBrowser)
                    Button("Cancel Setup", role: .cancel, action: cancelSetup)
                case .loadingConfiguration:
                    ProgressView("Loading Projects…")
                    Button("Cancel Setup", role: .cancel, action: cancelSetup)
                case .configuring:
                    AutomationConfigurationForm(setup: setup)
                    Button("Cancel Setup", role: .cancel, action: cancelSetup)
                case .saving:
                    ProgressView("Enabling account automation…")
                case .connectionStorageFailed:
                    Label("The connection could not be saved locally, so automation was not enabled.", systemImage: "key")
                    Button("Retry Saving to Keychain", action: retryTokenStorage)
                    Button("Cancel Setup", role: .cancel, action: cancelSetup)
                case .connected:
                    if setup.automations.isEmpty && setup.errorMessage != nil {
                        Text("Connection status could not be loaded.")
                            .foregroundStyle(.secondary)
                        Button(
                            "Retry Loading",
                            systemImage: "arrow.clockwise",
                            action: reloadAutomations
                        )
                    } else if setup.automations.isEmpty {
                        Text("No automation connections were found.")
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
        .task {
            await setup.loadConnection()
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

    private func retryConnectionLoad() {
        Task { await setup.loadConnection() }
    }

    private func reloadAutomations() {
        Task { await setup.loadAutomations() }
    }

    private func retryTokenStorage() {
        Task { await setup.retryTokenStorage() }
    }

    private func cancelSetup() {
        Task { await setup.cancelSetup() }
    }
}
