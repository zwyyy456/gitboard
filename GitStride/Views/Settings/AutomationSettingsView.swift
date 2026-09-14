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
                    Text("Choose an automation service below to connect.")
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
            AutomationServiceSettingsView(currentBaseURL: setup.serviceBaseURL)
        } header: {
            Text("Pull Request Automation")
        } footer: {
            VStack(alignment: .leading) {
                Text("Save and restart GitStride to apply service changes.")
                Text("Changing or disabling the service does not stop automation on the previous server. Pause or delete its connection first if needed.")
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

private struct AutomationServiceSettingsView: View {
    private enum Mode {
        case defaultService, custom, disabled
    }

    let currentBaseURL: URL?
    @AppStorage(AutomationServicePreferences.originKey) private var savedOrigin: String?
    @State private var mode = Mode.defaultService
    @State private var customOrigin = ""

    private var customURL: URL? {
        AutomationServicePreferences.validatedURL(customOrigin)
    }

    private var draftOrigin: String? {
        switch mode {
        case .defaultService: nil
        case .custom: customURL?.absoluteString
        case .disabled: ""
        }
    }

    private var requiresRestart: Bool {
        AutomationServicePreferences.baseURL(savedOrigin: savedOrigin) != currentBaseURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Automation service")
                Spacer(minLength: 12)
                Picker("Automation service", selection: $mode) {
                    Text("Default service").tag(Mode.defaultService)
                    Text("Custom address").tag(Mode.custom)
                    Text("Disabled").tag(Mode.disabled)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Button("Save") { savedOrigin = draftOrigin }
                    .disabled((mode == .custom && customURL == nil) || draftOrigin == savedOrigin)
            }

            if mode != .disabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Service address")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if mode == .custom {
                        TextField("Service address", text: $customOrigin, prompt: Text(verbatim: "https://worker.example.com"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        if customURL == nil {
                            Text("Enter an HTTPS address without a path, query, or fragment.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if let defaultURL = AutomationServicePreferences.baseURL(savedOrigin: nil) {
                        Text(defaultURL.absoluteString)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("No default service is configured.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if requiresRestart {
                Label("Service changes saved. Restart GitStride to apply them.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: loadDraft)
        .onChange(of: savedOrigin) { _, _ in loadDraft() }
    }

    private func loadDraft() {
        if let savedOrigin {
            mode = savedOrigin.isEmpty ? .disabled : .custom
            customOrigin = savedOrigin.isEmpty ? (currentBaseURL?.absoluteString ?? "") : savedOrigin
        } else {
            mode = .defaultService
            customOrigin = AutomationServicePreferences.baseURL(savedOrigin: nil)?.absoluteString ?? ""
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
