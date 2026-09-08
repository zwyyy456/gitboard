import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

struct SettingsView: View {
    @Bindable var model: GitStrideModel
    private enum Pane: String {
        case general, automation, shortcuts

        var height: CGFloat {
            switch self {
            case .general: 360
            case .automation: 280
            case .shortcuts: 500
            }
        }
    }

    @AppStorage("selectedSettingsPane") private var selectedTab = Pane.general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(model: model)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(Pane.general)

            AutomationSettingsView(setup: model.automationSetup)
                .tabItem {
                    Label("Automation", systemImage: "arrow.triangle.branch")
                }
                .tag(Pane.automation)

            ShortcutsSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
                .tag(Pane.shortcuts)
        }
        .frame(width: 520, height: selectedTab.height)
    }
}

struct GeneralSettingsView: View {
    @Bindable var model: GitStrideModel
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

                LabeledContent("Quiet hours") {
                    HStack(spacing: 8) {
                        Picker(
                            "Start time",
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
                        .labelsHidden()
                        .fixedSize()

                        Text("to")
                            .foregroundStyle(.secondary)

                        Picker(
                            "End time",
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
                        .labelsHidden()
                        .fixedSize()
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
                Button("Check for Updates…") {
                    UpdateController.shared.checkForUpdates()
                }
                .buttonStyle(.bordered)
                #endif
            } header: {
                Text("Updates")
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

struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section("Global") {
                KeyboardShortcutRow(keys: ["⌥", "⌘", "K"], description: "Open Command Palette")
            }
            Section("In GitStride") {
                KeyboardShortcutRow(keys: ["⌘", "K"], description: "Open Command Palette")
                KeyboardShortcutRow(keys: ["⇧", "⌘", "N"], description: "Add to Project")
                KeyboardShortcutRow(keys: ["⌘", ","], description: "Open Settings")
                KeyboardShortcutRow(keys: ["⌘", "R"], description: "Refresh")
                KeyboardShortcutRow(keys: ["⌥", "⌘", "I"], description: "Show or hide inspector")
            }
            Section {
                KeyboardShortcutRow(keys: ["⌘", "←"], description: "Previous status tab")
                KeyboardShortcutRow(keys: ["⌘", "→"], description: "Next status tab")
                KeyboardShortcutRow(keys: [">"], description: "Add to Project from search")
            } header: {
                Text("In the Menu Bar Popover")
            } footer: {
                Text("Type > into the empty search field when a project is editable. Shortcuts are shown for reference and can’t be edited here.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyboardShortcutRow: View {
    let keys: [String]
    let description: String

    var body: some View {
        LabeledContent(description) {
            Text(keys.joined())
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

struct AboutView: View {
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            Text("GitStride")
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
                Link(destination: URL(string: "https://yogesh.co?utm_source=gitstride")!) {
                    Text("yogesh.co")
                        .font(.system(size: 12))
                }
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Link(destination: URL(string: "https://www.supalytics.co?utm_source=gitstride")!) {
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

            Text("© 2025 Yogesh · MIT License")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 420)
    }
}
