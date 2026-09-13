import SwiftUI

struct MenuBarPopoverView: View {
    @Bindable var store: ProjectStore
    @Binding var requestedItemReference: ItemInspectorReference?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var showSettings
    @Environment(\.dismissMenuBar) private var dismissMenuBar
    @State private var isRefreshing = false
    @State private var isMoreHovered = false
    @State private var searchText = ""
    @State private var keyMonitor: Any?
    @State private var operationErrorMessage: String?

    private var canEditSelectedProject: Bool {
        store.canEditSelectedProject
    }

    private var isQuickCreating: Bool { searchText.hasPrefix(">") }
    private var itemSearchText: String { isQuickCreating ? "" : searchText }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView

            OperationErrorBanner(
                message: operationErrorMessage ?? store.operationErrorMessage,
                dismiss: dismissOperationError
            )

            if store.isLoading && store.projects.isEmpty {
                loadingView
            } else if let error = store.error {
                MenuBarConnectionErrorView(error: error) {
                    Task { await store.loadProjects() }
                }
            } else if store.projects.isEmpty {
                emptyProjectsView
            } else {
                selectedProjectContent
            }
        }
        .frame(width: 400)
        .task {
            if store.projects.isEmpty {
                await store.loadProjects()
            }
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) {
                    if event.keyCode == 123 {
                        navigateTab(direction: -1)
                        return nil
                    } else if event.keyCode == 124 {
                        navigateTab(direction: 1)
                        return nil
                    } else if event.keyCode == 15 { // R key
                        refresh()
                        return nil
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    private func navigateTab(direction: Int) {
        guard let project = store.selectedProject else { return }
        let statuses = project.statusOptions

        if store.selectedStatusFilter == nil {
            if direction > 0 && !statuses.isEmpty {
                withAnimation(.easeInOut(duration: 0.15)) {
                    store.selectedStatusFilter = statuses[0].name
                }
            }
        } else if let currentFilter = store.selectedStatusFilter,
                  let currentIndex = statuses.firstIndex(where: { $0.name == currentFilter }) {
            let newIndex = currentIndex + direction
            withAnimation(.easeInOut(duration: 0.15)) {
                if newIndex < 0 {
                    store.selectedStatusFilter = nil
                } else if newIndex < statuses.count {
                    store.selectedStatusFilter = statuses[newIndex].name
                }
            }
        }
    }

    private func report(_ error: Error) {
        guard (error is CancellationError) == false else { return }
        operationErrorMessage = error.localizedDescription
    }

    private func dismissOperationError() {
        if operationErrorMessage != nil {
            operationErrorMessage = nil
        } else {
            store.clearOperationError()
        }
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            ProjectSelectorView(store: store, compact: true)
                .frame(maxWidth: 200, alignment: .leading)

            Spacer(minLength: 8)

            if canEditSelectedProject {
                HeaderButton(
                    icon: "plus",
                    help: String(localized: "Create or Add Item"),
                    isProminent: true
                ) {
                    openQuickAdd()
                }
            }

            HeaderButton(icon: "rectangle.split.3x1", help: String(localized: "Open Kanban Board")) {
                openKanbanBoard()
            }

            RefreshButton(isRefreshing: $isRefreshing, action: refresh)

            Menu {
                Button(action: openSettings) {
                    Label("Settings…", systemImage: "gearshape")
                }

                Button(action: openCoffeePage) {
                    Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                }

                Divider()

                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit GitStride", systemImage: "power")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.medium))
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isMoreHovered ? Color.primary.opacity(0.10) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .onHover { hovering in
                isMoreHovered = hovering
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func refresh() {
        guard isRefreshing == false else { return }
        isRefreshing = true
        Task {
            await store.refresh()
            isRefreshing = false
        }
    }

    private func openCoffeePage() {
        guard let url = URL(string: "https://donate.stripe.com/aFa14ociW0pndDCa0K8bS00") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openQuickAdd(initialQuickEntry: String = "") {
        dismissMenuBar()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "quick-add", value: initialQuickEntry)
    }

    private func submitQuickCreate() {
        guard isQuickCreating, canEditSelectedProject else { return }
        let input = searchText
        searchText = ""
        openQuickAdd(initialQuickEntry: input)
    }

    private func openSettings() {
        dismissMenuBar()
        NSApp.activate(ignoringOtherApps: true)
        showSettings()
    }

    private func openKanbanBoard() {
        dismissMenuBar()
        openWindow(id: "kanban-board")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title == "GitStride" {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.9)
            Text("Loading projects...")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyProjectsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("No projects found")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            NewProjectButton()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private var selectedProjectContent: some View {
        switch store.selectedProjectContentState {
        case .none:
            emptyProjectsView
        case .loading:
            projectLoadingView
        case .content(let project, _, _), .empty(let project, _, _):
            statusFilterTabs(project: project)
            searchBar
            if isQuickCreating {
                Text(canEditSelectedProject
                     ? String(localized: "Press Return to review the new item. Press Esc to cancel.")
                     : String(localized: "This project is read-only."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            itemsList(project: project)
        case .failed(let project, let message):
            projectErrorView(project, message: message)
        }
    }

    private var projectLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Loading project items...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func projectErrorView(_ project: Project, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Couldn’t load \(project.title)")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Try Again") {
                Task { await store.loadProjectDetails(id: project.id) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func statusFilterTabs(project: Project) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterTab(
                    title: String(localized: "All"),
                    count: project.items.count,
                    isSelected: store.selectedStatusFilter == nil,
                    color: .secondary
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        store.selectedStatusFilter = nil
                    }
                }

                ForEach(project.statusOptions) { status in
                    FilterTab(
                        title: status.name,
                        count: project.itemCount(forStatus: status.name),
                        isSelected: store.selectedStatusFilter == status.name,
                        color: status.swiftUIColor
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            store.selectedStatusFilter = status.name
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: isQuickCreating ? "plus" : "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            TextField(
                "Search items, #number, or @assignee",
                text: $searchText
            )
            .textFieldStyle(.plain)
            .font(.callout)
            .accessibilityLabel("Search project items")
            .onSubmit(submitQuickCreate)
            .onExitCommand(perform: isQuickCreating ? { searchText = "" } : nil)

            if !searchText.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    searchText = ""
                }
                .labelStyle(.iconOnly)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func searchedItems(in project: Project) -> [ProjectItem] {
        let items = if let filter = store.selectedStatusFilter {
            project.items.filter { $0.status == filter }
        } else {
            project.items
        }

        return items.matching(itemSearchText, currentUserLogin: store.currentUserLogin)
    }

    private func itemsList(project: Project) -> some View {
        let items = searchedItems(in: project)
        return ScrollView {
            LazyVStack(spacing: 0) {
                if items.isEmpty {
                    emptyFilterView
                } else {
                    ForEach(items) { item in
                        ItemRow(
                            item: item,
                            store: store,
                            project: project,
                            showInspector: {
                                openItemDetails(
                                    ItemInspectorReference(
                                        projectID: project.id,
                                        itemID: item.id
                                    )
                                )
                            },
                            reportError: report
                        )
                    }
                }
            }
        }
        .scrollIndicators(.automatic)
        .frame(height: 360)
    }

    private var emptyFilterView: some View {
        VStack(spacing: 12) {
            Image(systemName: itemSearchText.isEmpty ? "doc.text.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(itemSearchText.isEmpty ? String(localized: "No items") : String(localized: "No results for \"\(itemSearchText)\""))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func openItemDetails(_ reference: ItemInspectorReference) {
        requestedItemReference = reference
        openKanbanBoard()
    }
}
