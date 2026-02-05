import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 400, height: 350)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("autoCheckForUpdates") private var autoCheckForUpdates = true

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $autoCheckForUpdates)
                    .onChange(of: autoCheckForUpdates) { _, newValue in
                        #if canImport(Sparkle)
                        UpdateController.shared.automaticallyChecksForUpdates = newValue
                        #endif
                    }

                #if canImport(Sparkle)
                HStack {
                    Text("Check for Updates")
                    Spacer()
                    Button("Check Now") {
                        UpdateController.shared.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                #endif
            } header: {
                Text("Updates")
            }

            Section {
                KeyboardShortcutRow(keys: ["⌘", "←"], description: "Previous status tab")
                KeyboardShortcutRow(keys: ["⌘", "→"], description: "Next status tab")
                KeyboardShortcutRow(keys: [">"], description: "Enter quick create mode")
                KeyboardShortcutRow(keys: ["Esc"], description: "Exit quick create mode")
            } header: {
                Text("Keyboard Shortcuts")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            #if canImport(Sparkle)
            UpdateController.shared.automaticallyChecksForUpdates = autoCheckForUpdates
            #endif
        }
    }
}

struct KeyboardShortcutRow: View {
    let keys: [String]
    let description: String

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                        )
                }
            }
            Spacer()
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

struct AboutView: View {
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("GitBoard")
                .font(.system(size: 24, weight: .bold))

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("Native macOS app for GitHub Projects")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("This project is not affiliated with GitHub, Inc.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 12) {
                Text("Created by Yogesh")
                    .font(.system(size: 12, weight: .medium))

                HStack(spacing: 20) {
                    Link(destination: URL(string: "https://yogesh.co?utm_source=gitboard")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                                .font(.system(size: 11))
                            Text("yogesh.co")
                                .font(.system(size: 12))
                        }
                    }

                    Link(destination: URL(string: "https://x.com/yogesharc")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "at")
                                .font(.system(size: 11))
                            Text("yogesharc")
                                .font(.system(size: 12))
                        }
                    }
                }
                .foregroundStyle(.blue)

                Link(destination: URL(string: "https://buymeacoffee.com/yogesh?utm_source=gitboard")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 12))
                        Text("Buy me a coffee")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.top, 8)
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
