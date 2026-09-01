import SwiftUI

struct KanbanBoardView: View {
    @Bindable var store: ProjectStore
    @Bindable var myWorkStore: MyWorkStore
    let toggleFollowing: (Project) async -> Void
    let showItemDetail: (ItemInspectorReference) -> Void
    @Binding var searchText: String
    @Binding var isSelecting: Bool
    @State private var showsAddItem = false
    @State private var showsStatusFilter = false
    @State private var selectedItemIDs: Set<String> = []
    @State private var isBulkWorking = false

    private static let minimumColumnWidth: CGFloat = 260
    private static let idealOverflowColumnWidth: CGFloat = 280
    private static let maximumColumnWidth: CGFloat = 420
    private static let columnSpacing: CGFloat = 8

    private var canEditSelectedProject: Bool {
        store.canEditSelectedProject
    }

    private var showsProjectEditingActions: Bool {
        switch store.selectedProjectContentState {
        case .content(let project, _, _), .empty(let project, _, _):
            project.viewerCanUpdate
        case .none, .loading, .failed:
            false
        }
    }

    private var isRefreshing: Bool {
        switch store.selectedProjectContentState {
        case .loading:
            true
        case .content(_, let isRefreshing, _), .empty(_, let isRefreshing, _):
            isRefreshing
        case .none, .failed:
            false
        }
    }

    var body: some View {
        projectSurface
            .toolbar {
                kanbanToolbar
            }
            .focusedSceneValue(\.workspaceCommandContext, commandContext)
            .sheet(isPresented: $showsAddItem) {
                AddProjectItemView(store: store)
            }
            .onChange(of: store.selectedProjectId) { _, _ in
                searchText = ""
                isSelecting = false
                showsStatusFilter = false
                selectedItemIDs.removeAll()
            }
            .onChange(of: isSelecting) { _, isSelecting in
                showsStatusFilter = false
                if isSelecting == false {
                    selectedItemIDs.removeAll()
                }
            }
            .task {
                if store.projects.isEmpty {
                    await store.loadProjects()
                }
            }
    }

    @ViewBuilder
    private var projectSurface: some View {
        if isSelecting {
            boardSurface
        } else {
            boardSurface.searchable(
                text: $searchText,
                placement: .automatic,
                prompt: "Search title, #number, or @assignee"
            )
        }
    }

    private var boardSurface: some View {
        VStack(spacing: 0) {
            OperationErrorBanner(store: store)

            if store.isLoading && store.projects.isEmpty {
                loadingView
            } else if let error = store.error {
                errorView(error)
            } else {
                selectedProjectContent
            }
        }
        .frame(minHeight: 560)
    }

    @ToolbarContentBuilder
    private var kanbanToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            ProjectSelectorView(store: store)
        }

        if isSelecting {
            ToolbarItemGroup(placement: .automatic) {
                Text("\(selectedItemIDs.count) Selected")
                    .foregroundStyle(.secondary)

                Menu("Move To") {
                    ForEach(store.selectedProject?.statusOptions ?? []) { status in
                        Button(status.name) { moveSelection(to: status) }
                    }
                }
                .disabled(selectedItemIDs.isEmpty || isBulkWorking)

                Button(role: .destructive) {
                    archiveSelection()
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .disabled(selectedItemIDs.isEmpty || isBulkWorking)

                Button("Done", action: toggleSelectionMode)
                    .keyboardShortcut(.cancelAction)
            }
        } else {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: refresh) {
                    Label {
                        Text("Refresh Project")
                    } icon: {
                        ZStack {
                            Image(systemName: "arrow.clockwise")
                                .opacity(isRefreshing ? 0 : 1)

                            if isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(width: 16, height: 16)
                    }
                }
                .labelStyle(.iconOnly)
                .disabled(isRefreshing)
                .help(refreshHelp)
                .accessibilityValue(isRefreshing ? "Refreshing" : "")

                if showsProjectEditingActions {
                    Button("Add Item", systemImage: "plus", action: showAddItem)
                        .labelStyle(.iconOnly)
                        .disabled(canEditSelectedProject == false)
                        .help("Add Item")
                }

                if let project = store.selectedProject {
                    if projectURL != nil {
                        Button(
                            "Open Project in GitHub",
                            systemImage: "arrow.up.right.square",
                            action: openProjectInGitHub
                        )
                        .labelStyle(.iconOnly)
                        .help("Open Project in GitHub")
                    }

                    if showsProjectEditingActions {
                        Button(
                            "Select Multiple Items",
                            systemImage: "checkmark.circle",
                            action: toggleSelectionMode
                        )
                        .labelStyle(.iconOnly)
                        .disabled(canEditSelectedProject == false)
                        .help("Select Multiple Items")
                    }

                    let isFollowing = myWorkStore.isFollowing(project.id)
                    let followLabel = isFollowing
                        ? "Remove \(project.title) from My Work"
                        : "Add \(project.title) to My Work"
                    Button(
                        followLabel,
                        systemImage: "briefcase",
                        action: toggleFollowingProject
                    )
                    .labelStyle(.iconOnly)
                    .help(followLabel)
                }
            }

            if let project = store.selectedProject,
               project.statusOptions.isEmpty == false {
                ToolbarItem(placement: .automatic) {
                    Button(
                        "Filter Statuses",
                        systemImage: statusFilterSystemImage(for: project),
                        action: toggleStatusFilter
                    )
                    .labelStyle(.iconOnly)
                    .help(statusFilterHelp(for: project))
                    .accessibilityValue(statusFilterAccessibilityValue(for: project))
                    .popover(isPresented: $showsStatusFilter, arrowEdge: .top) {
                        StatusColumnFilterView(store: store, project: project)
                    }
                }
            }
        }
    }

    private var projectURL: URL? {
        guard let url = store.selectedProject?.url, url.isEmpty == false else { return nil }
        return URL(string: url)
    }

    private var refreshHelp: String {
        guard let lastUpdated = store.lastUpdated else { return "Refresh Project" }
        let updated = lastUpdated.formatted(.relative(presentation: .named))
        return "Refresh Project — Updated \(updated)"
    }

    private var commandContext: WorkspaceCommandContext {
        var context = WorkspaceCommandContext(
            refresh: .init(
                id: "refresh-project",
                title: "Refresh Project",
                isEnabled: isRefreshing == false && isSelecting == false,
                perform: refresh
            )
        )

        context.toggleSelection = showsProjectEditingActions
            ? .init(
                id: "toggle-selection",
                title: isSelecting ? "Done Selecting" : "Select Items",
                isEnabled: isSelecting || canEditSelectedProject,
                perform: toggleSelectionMode
            )
            : nil

        if isSelecting {
            let canWork = selectedItemIDs.isEmpty == false && isBulkWorking == false
            context.moveSelection = (store.selectedProject?.statusOptions ?? []).map { status in
                .init(
                    id: "move-selection-\(status.id)",
                    title: status.name,
                    isEnabled: canWork,
                    perform: { moveSelection(to: status) }
                )
            }
            context.archiveSelection = .init(
                id: "archive-selection",
                title: "Archive Selected Items",
                isEnabled: canWork,
                perform: archiveSelection
            )
            return context
        }

        if showsProjectEditingActions {
            context.addItem = .init(
                id: "add-item",
                title: "Add Item…",
                isEnabled: canEditSelectedProject,
                perform: showAddItem
            )
        }

        if let project = store.selectedProject {
            let isFollowing = myWorkStore.isFollowing(project.id)
            context.toggleFollowing = .init(
                id: "toggle-following",
                title: isFollowing
                    ? "Remove \(project.title) from My Work"
                    : "Add \(project.title) to My Work",
                perform: toggleFollowingProject
            )
        }

        if projectURL != nil {
            context.openInGitHub = .init(
                id: "open-project-in-github",
                title: "Open Project in GitHub",
                perform: openProjectInGitHub
            )
        }

        return context
    }

    private func showAddItem() {
        showsAddItem = true
    }

    private func toggleSelectionMode() {
        isSelecting.toggle()
        if isSelecting {
            searchText = ""
        } else {
            selectedItemIDs.removeAll()
        }
    }

    private func toggleFollowingProject() {
        guard let project = store.selectedProject else { return }
        Task { await toggleFollowing(project) }
    }

    private func refresh() {
        guard isRefreshing == false else { return }
        Task { await store.refresh() }
    }

    private func openProjectInGitHub() {
        guard let projectURL else { return }
        NSWorkspace.shared.open(projectURL)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading project...")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text(error.localizedDescription)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button("Try Again") {
                Task { await store.loadProjects() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text("Select a project to view its board")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var selectedProjectContent: some View {
        switch store.selectedProjectContentState {
        case .none:
            emptyView
        case .loading:
            loadingView
        case .content(let project, _, _):
            boardContent(project)
        case .empty(let project, _, _):
            emptyProjectView(project)
        case .failed(let project, let message):
            projectErrorView(project, message: message)
        }
    }

    private func emptyProjectView(_ project: Project) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("\(project.title) has no items")
                .font(.headline)
            Text("Items added to this GitHub Project will appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func projectErrorView(_ project: Project, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Couldn’t load \(project.title)")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Try Again") {
                Task { await store.loadProjectDetails(id: project.id) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func filteredItems(for items: [ProjectItem]) -> [ProjectItem] {
        items.matching(searchText, currentUserLogin: store.currentUserLogin)
    }

    private func boardContent(_ project: Project) -> some View {
        GeometryReader { geometry in
            let visibleStatuses = store.visibleKanbanStatuses(in: project)
            let includesNoStatus = project.noStatusItems.isEmpty == false
            let columnCount = max(visibleStatuses.count + (includesNoStatus ? 1 : 0), 1)
            let totalSpacing = CGFloat(columnCount - 1) * Self.columnSpacing
            let availableWidth = geometry.size.width - 32 - totalSpacing
            let fittingColumnWidth = availableWidth / CGFloat(columnCount)
            let columnWidth = fittingColumnWidth >= Self.minimumColumnWidth
                ? min(Self.maximumColumnWidth, fittingColumnWidth)
                : Self.idealOverflowColumnWidth

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Self.columnSpacing) {
                    ForEach(visibleStatuses) { status in
                        let statusItems = filteredItems(for: project.items(forStatus: status.name))
                        KanbanColumn(
                            projectID: project.id,
                            status: status,
                            items: statusItems,
                            emptyMessage: searchText.isEmpty ? "No items" : "No matching items",
                            allStatuses: project.statusOptions,
                            store: store,
                            isSelecting: isSelecting,
                            selectedItemIDs: $selectedItemIDs,
                            showInspector: showItemDetail
                        )
                        .frame(width: columnWidth, height: geometry.size.height - 32)
                    }

                    let noStatusFiltered = filteredItems(for: project.noStatusItems)
                    if !project.noStatusItems.isEmpty || !noStatusFiltered.isEmpty {
                        KanbanColumn(
                            projectID: project.id,
                            status: nil,
                            items: noStatusFiltered,
                            emptyMessage: searchText.isEmpty ? "No items" : "No matching items",
                            allStatuses: project.statusOptions,
                            store: store,
                            isSelecting: isSelecting,
                            selectedItemIDs: $selectedItemIDs,
                            showInspector: showItemDetail
                        )
                        .frame(width: columnWidth, height: geometry.size.height - 32)
                    }
                }
                .padding(16)
            }
            .id(boardScrollIdentity(
                project: project,
                visibleStatuses: visibleStatuses,
                includesNoStatus: includesNoStatus
            ))
        }
    }

    private func statusFilterSystemImage(for project: Project) -> String {
        store.visibleKanbanStatuses(in: project).count == project.statusOptions.count
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"
    }

    private func statusFilterHelp(for project: Project) -> String {
        let hiddenCount = project.statusOptions.count
            - store.visibleKanbanStatuses(in: project).count
        return hiddenCount == 0
            ? "Filter Statuses"
            : "Filter Statuses — \(hiddenCount) Hidden"
    }

    private func statusFilterAccessibilityValue(for project: Project) -> String {
        let visibleCount = store.visibleKanbanStatuses(in: project).count
        return "\(visibleCount) of \(project.statusOptions.count) statuses shown"
    }

    private func toggleStatusFilter() {
        showsStatusFilter.toggle()
    }

    private func boardScrollIdentity(
        project: Project,
        visibleStatuses: [StatusOption],
        includesNoStatus: Bool
    ) -> [String] {
        [project.id, includesNoStatus ? "includes-no-status" : "statuses-only"]
            + visibleStatuses.map(\.id)
    }

    private var selectedItems: [ProjectItem] {
        store.selectedProject?.items.filter { selectedItemIDs.contains($0.id) } ?? []
    }

    private func moveSelection(to status: StatusOption) {
        let items = selectedItems
        guard items.isEmpty == false, let projectID = store.selectedProjectId else { return }
        isBulkWorking = true
        Task {
            await store.moveItems(items, to: status, in: projectID)
            selectedItemIDs.removeAll()
            isBulkWorking = false
        }
    }

    private func archiveSelection() {
        let items = selectedItems
        guard items.isEmpty == false, let projectID = store.selectedProjectId else { return }
        isBulkWorking = true
        Task {
            await store.archiveItems(items, in: projectID)
            selectedItemIDs.removeAll()
            isBulkWorking = false
        }
    }
}

// MARK: - Kanban Column

struct KanbanColumn: View {
    let projectID: String
    let status: StatusOption?
    let items: [ProjectItem]
    let emptyMessage: String
    let allStatuses: [StatusOption]
    @Bindable var store: ProjectStore
    let isSelecting: Bool
    @Binding var selectedItemIDs: Set<String>
    let showInspector: (ItemInspectorReference) -> Void

    @State private var isTargeted = false

    var statusName: String {
        status?.name ?? "No Status"
    }

    var statusColor: Color {
        status?.swiftUIColor ?? .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(statusName)
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                Text("\(items.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            // Cards
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    if items.isEmpty {
                        Text(emptyMessage)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(items) { item in
                            if isSelecting {
                                KanbanCard(
                                    projectID: projectID,
                                    item: item,
                                    allStatuses: allStatuses,
                                    store: store,
                                    isSelecting: true,
                                    isSelected: selectedItemIDs.contains(item.id)
                                ) {
                                    toggleSelection(item.id)
                                } showInspector: {
                                    showInspector(
                                        ItemInspectorReference(projectID: projectID, itemID: item.id)
                                    )
                                }
                            } else {
                                KanbanCard(
                                    projectID: projectID,
                                    item: item,
                                    allStatuses: allStatuses,
                                    store: store,
                                    isSelecting: false,
                                    isSelected: false,
                                    onSelect: {},
                                    showInspector: {
                                        showInspector(
                                            ItemInspectorReference(projectID: projectID, itemID: item.id)
                                        )
                                    }
                                )
                                .draggable(item.id) {
                                    KanbanCardPreview(item: item)
                                }
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTargeted ? statusColor.opacity(0.8) : Color.clear, lineWidth: 2)
        )
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .dropDestination(for: String.self) { droppedItems, _ in
            guard let itemId = droppedItems.first,
                  let targetStatus = status,
                  isSelecting == false,
                  store.canEditProject(id: projectID) else { return false }

            // Find the item being dropped from all project items
            if let project = store.project(id: projectID),
               let item = project.items.first(where: { $0.id == itemId }) {
                // Only move if status is different
                if item.status != targetStatus.name {
                    Task {
                        await store.moveItem(item, toStatus: targetStatus, in: projectID)
                    }
                }
            }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    private func toggleSelection(_ itemID: String) {
        if selectedItemIDs.contains(itemID) {
            selectedItemIDs.remove(itemID)
        } else {
            selectedItemIDs.insert(itemID)
        }
    }
}

// MARK: - Kanban Card

struct KanbanCard: View {
    let projectID: String
    let item: ProjectItem
    let allStatuses: [StatusOption]
    @Bindable var store: ProjectStore
    let isSelecting: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let showInspector: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        Button(action: activateCard) {
            KanbanCardContent(item: item)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
                .overlay(cardBorder)
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .padding(8)
                    }
                }
        }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(isSelecting ? "Toggles selection" : "Shows details")
        .contextMenu {
            KanbanCardContextMenu(
                projectID: projectID,
                item: item,
                allStatuses: allStatuses,
                store: store,
                showDeleteConfirmation: $showDeleteConfirmation,
                showInspector: showInspector
            )
        }
        .confirmationDialog(
            removalConfirmationTitle,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task { await store.deleteItem(item, from: projectID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Archive is recommended when you may need the item again.")
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Color.accentColor.opacity(0.06) : Color.clear)
            }
            .shadow(
                color: .black.opacity(0.06),
                radius: 1,
                x: 0,
                y: 1
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(
                isSelected
                    ? Color.accentColor
                    : (isHovered
                        ? Color.accentColor.opacity(0.45)
                        : Color(nsColor: .separatorColor)),
                lineWidth: isSelected ? 2 : 1
            )
    }

    private var accessibilityValue: String {
        guard isSelecting else { return "" }
        return isSelected ? "Selected" : "Not selected"
    }

    private var removalConfirmationTitle: String {
        "Remove \"\(item.title)\" from the project?"
    }

    private var accessibilityLabel: String {
        var parts = [item.title]
        if let number = item.number {
            parts.append("Number \(number)")
        }
        if let status = item.status {
            parts.append("Status \(status)")
        }
        return parts.joined(separator: ", ")
    }

    private func activateCard() {
        if isSelecting {
            onSelect()
        } else {
            showInspector()
        }
    }

}

// MARK: - Drag Preview

struct KanbanCardPreview: View {
    let item: ProjectItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.contentType == .pullRequest ? "arrow.triangle.merge" : "circle.dotted")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            if let number = item.number {
                Text("#\(number)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        )
    }
}
