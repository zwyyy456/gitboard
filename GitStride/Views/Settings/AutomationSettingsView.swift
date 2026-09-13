import AppKit
import SwiftUI

struct AutomationSettingsView: View {
    @Bindable var setup: AutomationSetupModel

    var body: some View {
        Section {
            if !setup.automations.isEmpty {
                AutomationConnectionList(setup: setup)
            } else {
                switch setup.phase {
                case .unavailable:
                    Text("Automation is not available in this build.")
                        .foregroundStyle(.secondary)
                case .loadingConnection:
                    ProgressView("Loading connection…")
                case .connectionLoadFailed:
                    Text("The saved connection could not be loaded.")
                    Button("Retry") { Task { await setup.loadConnection() } }
                default:
                    Text("Keep Issue statuses up to date as linked pull requests change.")
                    Button("Set Up Automation…", action: startSetup)
                        .disabled(setup.isPresentingSetup)
                }
            }
            if !setup.isPresentingSetup, let error = setup.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Pull Request Automation")
        } footer: {
            VStack(alignment: .leading) {
                Text("Automation uses its own GitHub connection and continues when GitStride is disconnected.")
                Text("Private Issue content is not stored or logged by the automation service.")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startSetup() {
        Task {
            if let url = await setup.startSetup() {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

struct AutomationSetupSheet: View {
    @Bindable var setup: AutomationSetupModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(setup.phase == .existingConnection ? String(localized: "Connect Existing Automation") : String(localized: "Set Up Automation"))
                    .font(.headline)
                Spacer()
            }
            .padding(20)
            Divider()
            Form {
                switch setup.phase {
                case .configuring:
                    AutomationConfigurationForm(setup: setup)
                case .existingConnection:
                    Section {
                        Label("This GitHub account already has automation set up.", systemImage: "checkmark.circle")
                        Text("Connect this Mac to manage it. Your existing status mapping and pause setting will be preserved.")
                            .foregroundStyle(.secondary)
                    }
                case .waitingForBrowser:
                    Section {
                        Text("Finish authorization in your browser, then return to GitStride.")
                        Button("Open Browser") {
                            if let url = setup.browserURL() { NSWorkspace.shared.open(url) }
                        }
                    }
                case .connectionStorageFailed:
                    Section {
                        Text("Save the connection to Keychain to continue.")
                        Button("Retry Saving") { Task { await setup.retryTokenStorage() } }
                    }
                case .saving:
                    ProgressView("Saving connection…")
                default:
                    ProgressView("Preparing setup…")
                }
                if let error = setup.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { Task { await setup.cancelSetup() } }
                    .keyboardShortcut(.cancelAction)
                    .disabled(setup.phase == .saving || setup.phase == .starting)
                if setup.phase == .configuring {
                    Button("Enable Automation") { Task { await setup.completeSetup() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!setup.canComplete)
                } else if setup.phase == .existingConnection {
                    Button("Connect") { Task { await setup.recoverConnection() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: setup.phase == .configuring ? 580 : 320)
        .interactiveDismissDisabled()
    }
}
