import SwiftUI

struct GitHubSettingsView: View {
    @Bindable var model: GitStrideModel
    @State private var method: GitHubAuthenticationMethod = .oauth

    var body: some View {
        Form {
            Section("Connection") {
                if case .ready(let account) = model.projectStore.sessionState {
                    LabeledContent("Account", value: "@\(account.login)")
                    LabeledContent("Connected using", value: model.authenticationMethod.title)
                    Button("Disconnect GitStride", role: .destructive) {
                        Task { await model.disconnectGitHub() }
                    }
                    .disabled(model.isConnecting)
                } else {
                    Text("Connect your GitHub account to view and edit your Projects.")
                        .foregroundStyle(.secondary)
                }
                #if !APP_STORE
                Picker("Connect using", selection: $method) {
                    ForEach(GitHubAuthenticationMethod.allCases, id: \.self) { method in
                        Text(method.title).tag(method)
                    }
                }
                .disabled(model.isConnecting)
                #endif

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
                    Text("Paste this code into GitHub’s Device activation page, then approve access. GitStride will connect automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if model.isConnecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(model.deviceAuthorization == nil ? "Connecting…" : "Waiting for authorization…")
                        Spacer()
                        Button("Cancel") { model.cancelGitHubLogin() }
                    }
                } else {
                    Button(method == .oauth ? "Log In to GitHub…" : "Use GitHub CLI") {
                        model.connectGitHub(using: method)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let error = model.authenticationError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                } else if let error = model.projectStore.error {
                    Text(error.localizedDescription).foregroundStyle(.secondary)
                }
            }

            if method == .oauth {
                Section("GitHub Access") {
                    Text("GitStride requests Projects access, organization membership access, and GitHub’s repo permission. The repo permission includes reading and writing repository code, including private repositories.")
                    Text("Login credentials are stored in this Mac’s Keychain. Background automation has its own connection.")
                        .foregroundStyle(.secondary)
                }
            }
            #if !APP_STORE
            if method == .cli {
                Section("Existing CLI Login") {
                    Text("Install GitHub CLI and sign in using gh auth login. Projects access may require gh auth refresh -s project,read:org.")
                        .textSelection(.enabled)
                    Text("GitStride uses your current github.com account. Disconnecting here leaves your terminal login intact.")
                        .foregroundStyle(.secondary)
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .onAppear { method = model.authenticationMethod }
        .onChange(of: model.authenticationMethod) { _, value in method = value }
    }
}
