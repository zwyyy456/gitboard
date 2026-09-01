import SwiftUI

struct ItemDetailView: View {
    @Bindable var store: ProjectStore
    let reference: ItemInspectorReference
    let allowsOpeningNewWindow: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var isInspectorPresented = true
    @State private var isArchiving = false

    private var item: ProjectItem? { store.item(for: reference) }
    private var isRefreshing: Bool { store.isRefreshingItem(reference) }
    private var canArchive: Bool {
        item != nil && store.canEditProject(id: reference.projectID)
    }

    var body: some View {
        Group {
            if item != nil, store.project(id: reference.projectID) != nil {
                ItemDescriptionView(store: store, reference: reference)
            } else {
                ContentUnavailableView("Item Unavailable", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .navigationTitle(item?.title ?? "Item")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing item")
                        .help("Refreshing Item")
                } else {
                    Button(
                        "Refresh Item",
                        systemImage: "arrow.clockwise",
                        action: refreshItem
                    )
                    .labelStyle(.iconOnly)
                    .disabled(isArchiving)
                    .help("Refresh Item")
                }

                if itemURL != nil {
                    Button(action: openInGitHub) {
                        Label(openInGitHubTitle, systemImage: "arrow.up.right.square")
                            .labelStyle(.iconOnly)
                    }
                    .help(openInGitHubHelp)
                }

                if allowsOpeningNewWindow {
                    Button(
                        "Open in New Window",
                        systemImage: "macwindow",
                        action: openInNewWindow
                    )
                    .labelStyle(.iconOnly)
                    .help("Open in New Window")
                }

                if canArchive {
                    if isArchiving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Archiving item")
                            .help("Archiving Item")
                    } else {
                        Button(role: .destructive, action: archiveItem) {
                            Label("Archive from Project", systemImage: "archivebox")
                                .labelStyle(.iconOnly)
                        }
                        .disabled(isRefreshing)
                        .help("Archive from Project")
                    }
                }
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            ItemPropertiesView(
                store: store,
                reference: reference
            )
            .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
        }
        .focusedValue(\.workspaceCommandContext, commandContext)
        .task(id: item?.contentId) {
            store.clearOperationError()
            if let item {
                await store.loadItemDetail(for: item)
            }
        }
        .onDisappear { store.clearOperationError() }
    }

    private var itemURL: URL? {
        item?.url.flatMap(URL.init(string:))
    }

    private var openInGitHubTitle: String {
        switch item?.contentType {
        case .issue: "Open Issue"
        case .pullRequest: "Open Pull Request"
        case .draftIssue: "Open Draft Item"
        case .redacted, .none: "Open in GitHub"
        }
    }

    private var openInGitHubHelp: String {
        if let number = item?.number {
            return "\(openInGitHubTitle) #\(number) in GitHub"
        }
        return "\(openInGitHubTitle) in GitHub"
    }

    private var commandContext: WorkspaceCommandContext {
        WorkspaceCommandContext(
            refresh: .init(
                id: "refresh-item",
                title: "Refresh Item",
                isEnabled: isRefreshing == false && isArchiving == false,
                perform: refreshItem
            ),
            toggleInspector: .init(
                id: "toggle-item-inspector",
                title: isInspectorPresented ? "Hide Inspector" : "Show Inspector",
                perform: toggleInspector
            ),
            openInGitHub: itemURL.map { _ in
                .init(
                    id: "open-item-in-github",
                    title: openInGitHubTitle,
                    perform: openInGitHub
                )
            }
        )
    }

    private func openInGitHub() {
        guard let itemURL else { return }
        NSWorkspace.shared.open(itemURL)
    }

    private func openInNewWindow() {
        openWindow(id: "item-detail", value: reference)
    }

    private func refreshItem() {
        Task { await store.refreshItem(reference) }
    }

    private func toggleInspector() {
        isInspectorPresented.toggle()
    }

    private func archiveItem() {
        guard let item, isArchiving == false else { return }
        isArchiving = true
        Task {
            let succeeded = await store.archiveItem(item, in: reference.projectID)
            isArchiving = false
            if succeeded { dismiss() }
        }
    }
}
