import SwiftUI

struct KanbanCardContextMenu: View {
    let projectID: String
    let item: ProjectItem
    let allStatuses: [StatusOption]
    @Bindable var store: ProjectStore
    @Binding var showDeleteConfirmation: Bool
    let showInspector: () -> Void
    let reportError: (Error) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Details", systemImage: "sidebar.right", action: showInspector)

        Button("Open in New Window", systemImage: "macwindow", action: openInNewWindow)

        Button("Open in Browser", systemImage: "safari", action: openInBrowser)
            .disabled(itemURL == nil)

        if store.canEditSelectedProject {
            Divider()

            Menu("Move To", systemImage: "arrow.right.circle") {
                ForEach(allStatuses) { status in
                    Button(status.name) {
                        Task {
                            do {
                                try await store.moveItem(item, toStatus: status, in: projectID)
                            } catch {
                                reportError(error)
                            }
                        }
                    }
                    .disabled(item.status == status.name)
                }
            }

            Divider()

            if item.assignees.isEmpty == false {
                Menu("Remove Assignee", systemImage: "person.badge.minus") {
                    ForEach(item.assignees) { assignee in
                        Button(assignee.name ?? assignee.login, systemImage: "person.fill.xmark") {
                            Task {
                                do {
                                    try await store.removeAssignee(
                                        from: item,
                                        in: projectID,
                                        user: assignee
                                    )
                                } catch {
                                    reportError(error)
                                }
                            }
                        }
                    }
                }

                Divider()
            }

            Button("Archive from Project", systemImage: "archivebox") {
                Task {
                    do {
                        try await store.archiveItem(item, in: projectID)
                    } catch {
                        reportError(error)
                    }
                }
            }

            Divider()

            Button("Remove from Project", systemImage: "trash", role: .destructive) {
                showDeleteConfirmation = true
            }
        }
    }

    private var itemURL: URL? {
        item.url.flatMap(URL.init(string:))
    }

    private func openInBrowser() {
        guard let itemURL else { return }
        NSWorkspace.shared.open(itemURL)
    }

    private func openInNewWindow() {
        openWindow(
            id: "item-detail",
            value: ItemInspectorReference(projectID: projectID, itemID: item.id)
        )
    }
}
