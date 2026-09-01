import SwiftUI

struct WorkspaceCommandContext {
    struct Action: Identifiable {
        let id: String
        let title: String
        var isEnabled = true
        let perform: () -> Void
    }

    let refresh: Action
    var addItem: Action? = nil
    var toggleSelection: Action? = nil
    var toggleFollowing: Action? = nil
    var toggleInspector: Action? = nil
    var openInGitHub: Action? = nil
    var moveSelection: [Action] = []
    var archiveSelection: Action? = nil
    var stopFollowing: [Action] = []
}

private struct WorkspaceCommandContextKey: FocusedValueKey {
    typealias Value = WorkspaceCommandContext
}

extension FocusedValues {
    var workspaceCommandContext: WorkspaceCommandContext? {
        get { self[WorkspaceCommandContextKey.self] }
        set { self[WorkspaceCommandContextKey.self] = newValue }
    }
}
