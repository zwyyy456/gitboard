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

        Window("GitBoard", id: "kanban-board") {
            KanbanBoardView(store: store)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        }
        .defaultSize(width: 1200, height: 750)
        .windowResizability(.contentMinSize)

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
