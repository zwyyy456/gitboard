import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

struct SettingsView: View {
    @Bindable var model: GitBoardModel
    @State private var selectedTab = 1  // Default to About tab

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(model: model)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(1)
        }
        .frame(width: 440, height: 500)
    }
}

struct GeneralSettingsView: View {
    @Bindable var model: GitBoardModel
    @AppStorage("autoCheckForUpdates") private var autoCheckForUpdates = true

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Monitor followed Projects",
                    isOn: Binding(
                        get: { model.monitoringEnabled },
                        set: { enabled in
                            Task { await model.setMonitoringEnabled(enabled) }
                        }
                    )
                )

                Picker(
                    "Refresh interval",
                    selection: Binding(
                        get: { model.monitoringIntervalMinutes },
                        set: { minutes in
                            Task { await model.updateMonitoringSchedule(intervalMinutes: minutes) }
                        }
                    )
                ) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
                .disabled(!model.monitoringEnabled)

                HStack {
                    Picker(
                        "Quiet from",
                        selection: Binding(
                            get: { model.quietStartHour },
                            set: { hour in
                                Task { await model.updateMonitoringSchedule(quietStartHour: hour) }
                            }
                        )
                    ) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(hourLabel(hour)).tag(hour)
                        }
                    }

                    Picker(
                        "to",
                        selection: Binding(
                            get: { model.quietEndHour },
                            set: { hour in
                                Task { await model.updateMonitoringSchedule(quietEndHour: hour) }
                            }
                        )
                    ) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(hourLabel(hour)).tag(hour)
                        }
                    }
                }
                .disabled(!model.monitoringEnabled)

                if let status = model.monitoringStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.mutedProjectCount > 0 {
                    Button("Clear \(model.mutedProjectCount) Muted Project\(model.mutedProjectCount == 1 ? "" : "s")") {
                        model.clearMutedProjects()
                    }
                }
            } header: {
                Text("Monitoring")
            }

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
                KeyboardShortcutRow(keys: ["⌘", "R"], description: "Refresh")
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

    private func hourLabel(_ hour: Int) -> String {
        DateComponents(calendar: .current, hour: hour)
            .date?
            .formatted(date: .omitted, time: .shortened) ?? "\(hour):00"
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
        VStack(spacing: 12) {
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

            Text("Not affiliated with GitHub, Inc.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link(destination: URL(string: "https://yogesh.co?utm_source=gitboard")!) {
                    Text("yogesh.co")
                        .font(.system(size: 12))
                }
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Link(destination: URL(string: "https://www.supalytics.co?utm_source=gitboard")!) {
                    Text("supalytics.co")
                        .font(.system(size: 12))
                }
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Link(destination: URL(string: "https://x.com/yogesharc")!) {
                    Text("@yogesharc")
                        .font(.system(size: 12))
                }
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .foregroundStyle(.blue)
            .padding(.top, 8)

            Spacer()

            Text("© 2025 Yogesh · MIT License")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
