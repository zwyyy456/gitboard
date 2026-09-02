import SwiftUI

struct ItemDetailView: View {
    @Bindable var store: ProjectStore
    let reference: ItemInspectorReference
    let allowsOpeningNewWindow: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var isInspectorPresented = true
    @State private var inspectorWidth: CGFloat = 300
    @State private var pendingInspectorWidthUpdate: Task<Void, Never>?
    @State private var isArchiving = false
    @State private var operationErrorMessage: String?

    private static let inspectorMinimumWidth: CGFloat = 260
    private static let inspectorMaximumWidth: CGFloat = 360

    private var item: ProjectItem? { store.item(for: reference) }
    private var isRefreshing: Bool { store.isRefreshingItem(reference) }
    private var canArchive: Bool {
        item != nil && store.canEditProject(id: reference.projectID)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let operationErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(operationErrorMessage)
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") {
                        self.operationErrorMessage = nil
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.12))
            }

            Group {
                if item != nil, store.project(id: reference.projectID) != nil {
                    ItemDescriptionView(store: store, reference: reference)
                } else {
                    ContentUnavailableView("Item Unavailable", systemImage: "archivebox")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(
            minWidth: allowsOpeningNewWindow ? nil : 560,
            minHeight: 520
        )
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

            ToolbarItem(placement: .primaryAction) {
                Button(
                    isInspectorPresented ? "Hide Inspector" : "Show Inspector",
                    systemImage: "sidebar.right",
                    action: toggleInspector
                )
                .labelStyle(.iconOnly)
                .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            ItemPropertiesView(
                store: store,
                reference: reference,
                operationErrorMessage: $operationErrorMessage
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                scheduleInspectorWidthUpdate(width)
            }
            .inspectorColumnWidth(
                min: Self.inspectorMinimumWidth,
                ideal: inspectorWidth,
                max: Self.inspectorMaximumWidth
            )
        }
        .focusedValue(\.workspaceCommandContext, commandContext)
        .task(id: item?.contentId) {
            if let item {
                await store.loadItemDetail(for: item)
            }
        }
        .onDisappear {
            pendingInspectorWidthUpdate?.cancel()
        }
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
        operationErrorMessage = nil
        Task {
            do {
                try await store.refreshItem(reference)
            } catch is CancellationError {
                return
            } catch {
                operationErrorMessage = "Item refresh failed: \(error.localizedDescription)"
            }
        }
    }

    private func toggleInspector() {
        pendingInspectorWidthUpdate?.cancel()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isInspectorPresented.toggle()
        }
    }

    private func scheduleInspectorWidthUpdate(_ width: CGFloat) {
        guard isInspectorPresented,
              Self.inspectorMinimumWidth...Self.inspectorMaximumWidth ~= width else { return }

        pendingInspectorWidthUpdate?.cancel()
        pendingInspectorWidthUpdate = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard Task.isCancelled == false, isInspectorPresented else { return }
            inspectorWidth = width
        }
    }

    private func archiveItem() {
        guard let item, isArchiving == false else { return }
        isArchiving = true
        operationErrorMessage = nil
        Task {
            do {
                try await store.archiveItem(item, in: reference.projectID)
                dismiss()
            } catch is CancellationError {
            } catch {
                operationErrorMessage = error.localizedDescription
            }
            isArchiving = false
        }
    }
}
