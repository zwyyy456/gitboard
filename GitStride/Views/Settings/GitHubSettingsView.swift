import SwiftUI

struct GitHubSettingsView: View {
    @Bindable var model: GitStrideModel
    @State private var method: GitHubAuthenticationMethod = .oauth

    private var isCheckingConnection: Bool {
        model.projectStore.isLoading && model.projectStore.sessionState == .checking
    }

    var body: some View {
        Form {
            Section {
                if let progress = model.connectionProgress {
                    connectionProgressControls(progress)
                } else if let account = model.projectStore.currentAccount {
                    LabeledContent {
                        Button("Disconnect GitStride", role: .destructive) {
                            Task { await model.disconnectGitHub() }
                        }
                        .buttonStyle(.bordered)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("@\(account.login)")
                                .font(.headline)
                                .textSelection(.enabled)
                            Text("Connected using \(model.authenticationMethod.title)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if isCheckingConnection {
                    ProgressView("Checking GitHub connection…")
                        .controlSize(.small)
                } else {
                    loginControls
                }

                if let error = model.authenticationError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                } else if let error = model.projectStore.error {
                    Text(error.localizedDescription).foregroundStyle(.secondary)
                }
            } header: {
                Text("Account")
            } footer: {
                if model.projectStore.currentAccount != nil || model.connectionProgress == .disconnecting {
                    accountFootnote
                } else if model.connectionProgress != nil || !isCheckingConnection {
                    connectionFootnote
                }
            }

            AutomationSettingsView(setup: model.automationSetup)
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(
            get: { model.automationSetup.isPresentingSetup },
            set: { _ in }
        )) {
            AutomationSetupSheet(setup: model.automationSetup)
        }
        .task(id: model.automationSetup.setupSessionID) {
            await model.automationSetup.observeSetup()
        }
        .task {
            await model.automationSetup.loadConnection()
        }
        .onAppear { method = model.authenticationMethod }
        .onChange(of: model.authenticationMethod) { _, value in method = value }
    }

    @ViewBuilder
    private var loginControls: some View {
        #if !APP_STORE
        Picker("Connection method", selection: $method) {
            ForEach(GitHubAuthenticationMethod.allCases, id: \.self) { method in
                Text(method.title).tag(method)
            }
        }
        #endif

        Button(method == .oauth ? "Log In to GitHub…" : "Use GitHub CLI") {
            model.connectGitHub(using: method)
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func connectionProgressControls(_ progress: GitStrideModel.ConnectionProgress) -> some View {
        if let code = model.deviceAuthorization {
            LabeledContent("Device code") {
                Text(code.userCode)
                    .font(.title3.monospaced().bold())
                    .textSelection(.enabled)
            }
            Button("Copy Code and Open GitHub") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                NSWorkspace.shared.open(code.verificationURL)
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }

        HStack {
            ProgressView().controlSize(.small)
            connectionProgressLabel(progress)
            Spacer()
            if progress != .disconnecting {
                Button("Cancel") { model.cancelGitHubLogin() }
            }
        }
    }

    private func connectionProgressLabel(_ progress: GitStrideModel.ConnectionProgress) -> Text {
        switch progress {
        case .connecting: Text("Connecting…")
        case .authorizing(.waitingForAuthorization): Text("Waiting for authorization…")
        case .authorizing(.retrying): Text("GitHub request timed out. Retrying…")
        case .authorizing(.verifyingAccount): Text("Verifying GitHub account…")
        case .loadingProjects: Text("Loading projects…")
        case .disconnecting: Text("Disconnecting…")
        }
    }

    private var accountFootnote: some View {
        VStack(alignment: .leading) {
            switch model.authenticationMethod {
            case .oauth:
                Text("Login credentials are stored in this Mac’s Keychain.")
                Text("Disconnecting GitStride won’t stop background automation.")
            #if !APP_STORE
            case .cli:
                Text("Disconnecting GitStride won’t sign out of GitHub CLI or stop background automation.")
            #endif
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var connectionFootnote: some View {
        VStack(alignment: .leading) {
            if model.deviceAuthorization != nil {
                Text("Paste the code into GitHub’s Device activation page, then approve access. GitStride will connect automatically.")
            } else if model.connectionProgress == nil {
                Text("Connect your GitHub account to view and edit your Projects.")
            }

            switch method {
            case .oauth:
                Text("Requests access to Projects, organization membership, and read/write access to repository code, including private repositories.")
                Text("Login credentials are stored in this Mac’s Keychain.")
            #if !APP_STORE
            case .cli:
                Text("Uses your existing github.com login from GitHub CLI. Install GitHub CLI and sign in with gh auth login.")
                Text("Required permissions: repo, project, and read:org. To add them, run gh auth refresh -s repo,project,read:org.")
                    .textSelection(.enabled)
            #endif
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
