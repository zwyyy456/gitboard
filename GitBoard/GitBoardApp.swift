import SwiftUI
import Carbon.HIToolbox

// Environment key for dismissing menubar
private struct DismissMenuBarKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
    var dismissMenuBar: @MainActor @Sendable () -> Void {
        get { self[DismissMenuBarKey.self] }
        set { self[DismissMenuBarKey.self] = newValue }
    }
}

@main
struct GitBoardApp: App {
    @State private var model = GitBoardModel()
    @State private var menuBarWindow: NSWindow?

    var body: some Scene {
        Window("GitBoard", id: "kanban-board") {
            MainWorkspaceView(model: model)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            GitBoardCommands()
        }

        MenuBarExtra {
            MenuBarPopoverView(store: model.projectStore)
                .environment(\.dismissMenuBar) { @MainActor @Sendable in
                    menuBarWindow?.close()
                }
                .background(MenuBarWindowFinder(window: $menuBarWindow))
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "rectangle.split.3x1")
                if model.attentionCount > 0 {
                    Text(model.attentionCount > 9 ? "9+" : "\(model.attentionCount)")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(.red)
                        .clipShape(Circle())
                        .offset(x: 5, y: -4)
                }
            }
                .task {
                    await model.start()
                    let actions = await NotificationService.shared.actions()
                    for await action in actions {
                        if let url = await model.handleNotificationAction(action) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .background(AppHotKeyInstaller())
        }
        .menuBarExtraStyle(.window)

        Window("Command Palette", id: "command-palette") {
            CommandPaletteView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Add to Project", id: "quick-add") {
            QuickAddWindow(model: model)
        }
        .defaultSize(
            width: AddProjectItemView.windowDefaultSize.width,
            height: AddProjectItemView.windowDefaultSize.height
        )
        .windowResizability(.contentMinSize)

        Window("Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }

}

private struct GitBoardCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspaceCommandContext) private var workspaceCommandContext

    var body: some Commands {
        CommandMenu("GitBoard") {
            Button("Command Palette…") {
                openWindow(id: "command-palette")
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("Quick Add…") {
                openWindow(id: "quick-add")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Workspace") {
            if let addItem = workspaceCommandContext?.addItem {
                Button(addItem.title, action: addItem.perform)
                    .disabled(addItem.isEnabled == false)
            }

            if let toggleSelection = workspaceCommandContext?.toggleSelection {
                Button(toggleSelection.title, action: toggleSelection.perform)
                    .disabled(toggleSelection.isEnabled == false)
            }

            if let moveSelection = workspaceCommandContext?.moveSelection,
               moveSelection.isEmpty == false {
                Menu("Move To") {
                    ForEach(moveSelection) { action in
                        Button(action.title, action: action.perform)
                            .disabled(action.isEnabled == false)
                    }
                }
            }

            if let archiveSelection = workspaceCommandContext?.archiveSelection {
                Button(archiveSelection.title, role: .destructive, action: archiveSelection.perform)
                    .disabled(archiveSelection.isEnabled == false)
            }

            if let toggleFollowing = workspaceCommandContext?.toggleFollowing {
                Button(toggleFollowing.title, action: toggleFollowing.perform)
                    .disabled(toggleFollowing.isEnabled == false)
            }

            if let stopFollowing = workspaceCommandContext?.stopFollowing,
               stopFollowing.isEmpty == false {
                Menu("Following Projects") {
                    ForEach(stopFollowing) { action in
                        Button(action.title, role: .destructive, action: action.perform)
                            .disabled(action.isEnabled == false)
                    }
                }
            }

            Divider()

            Button(workspaceCommandContext?.refresh.title ?? "Refresh") {
                workspaceCommandContext?.refresh.perform()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(workspaceCommandContext?.refresh.isEnabled != true)

            if let openInGitHub = workspaceCommandContext?.openInGitHub {
                Button(openInGitHub.title, action: openInGitHub.perform)
                    .disabled(openInGitHub.isEnabled == false)
            }
        }
    }
}

private struct AppHotKeyInstaller: View {
    @Environment(\.openWindow) private var openWindow
    @State private var controller: GlobalHotKeyController?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard controller == nil else { return }
                controller = GlobalHotKeyController(
                    keyCode: UInt32(kVK_ANSI_K),
                    modifiers: UInt32(cmdKey | optionKey)
                ) {
                    openWindow(id: "command-palette")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

// Helper view to capture the NSWindow reference
struct MenuBarWindowFinder: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if self.window == nil {
                self.window = nsView.window
            }
        }
    }
}
