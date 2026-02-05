import SwiftUI

// Environment key for dismissing menubar
private struct DismissMenuBarKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var dismissMenuBar: () -> Void {
        get { self[DismissMenuBarKey.self] }
        set { self[DismissMenuBarKey.self] = newValue }
    }
}

@main
struct GitBoardApp: App {
    @State private var store = ProjectStore()
    @State private var menuBarWindow: NSWindow?

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(store: store)
                .environment(\.dismissMenuBar, dismissMenuBar)
                .background(MenuBarWindowFinder(window: $menuBarWindow))
        } label: {
            Image(systemName: "rectangle.split.3x1")
        }
        .menuBarExtraStyle(.window)

        Window("", id: "kanban-board") {
            KanbanBoardView(store: store)
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

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }

    init() {
        Task {
            await NotificationService.shared.requestPermission()
        }
    }

    private func dismissMenuBar() {
        menuBarWindow?.close()
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
