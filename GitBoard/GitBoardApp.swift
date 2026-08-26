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

        Window("", id: "kanban-board") {
            MainWorkspaceView(model: model)
                .background(KanbanWindowBackground())
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        }
        .defaultSize(width: 1000, height: 700)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            GitBoardCommands()
        }

        Window("Command Palette", id: "command-palette") {
            CommandPaletteView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Quick Add", id: "quick-add") {
            QuickAddWindow(model: model)
        }
        .windowResizability(.contentSize)

        Window("Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }

}

private struct GitBoardCommands: Commands {
    @Environment(\.openWindow) private var openWindow

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

// Helper to make window titlebar seamless with content
struct KanbanWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.backgroundColor = NSColor(red: 0x1a/255, green: 0x1a/255, blue: 0x1a/255, alpha: 1)
                window.isMovableByWindowBackground = true
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
