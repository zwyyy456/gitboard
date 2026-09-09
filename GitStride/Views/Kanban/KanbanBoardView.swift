import SwiftUI

struct KanbanBoardView: View {
    @Bindable var store: ProjectStore
    @Bindable var myWorkStore: MyWorkStore
    let toggleFollowing: (Project) async -> Void
    let showItemDetail: (ItemInspectorReference) -> Void
    @Binding var searchText: String
    @Binding var isSelecting: Bool
    @AppStorage("projectTableLayouts") private var tableLayoutsData = Data()
    @AppStorage("savedProjectWorkViews") private var savedViewsData = Data()
    @State private var workFilter = ProjectWorkFilter()
    @State private var selectedViewID: String?
    @State private var showsSaveView = false
    @State private var viewName = ""
    @State private var showsAddItem = false
    @State private var selectedItemIDs: Set<String> = []
    @State private var isBulkWorking = false
    @State private var operationErrorMessage: String?

    private static let minimumColumnWidth: CGFloat = 260
    private static let idealOverflowColumnWidth: CGFloat = 280
    private static let maximumColumnWidth: CGFloat = 420
    private static let columnSpacing: CGFloat = 8

    private var tableProjectIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: tableLayoutsData)) ?? []
    }

    private var usesTable: Bool {
        selectedSavedView?.usesTable ?? (store.selectedProjectId.map { tableProjectIDs.contains($0) } ?? false)
    }

    private var layoutSelection: Binding<Bool> {
        Binding(get: { usesTable }, set: { useTable in
            guard let id = store.selectedProjectId else { return }
            if let selectedViewID {
                var views = savedViews
                if let index = views.firstIndex(where: { $0.id == selectedViewID }) {
                    views[index].usesTable = useTable
                    persistViews(views)
                }
                return
            }
            var ids = tableProjectIDs
            if useTable { ids.insert(id) } else { ids.remove(id) }
            if let data = try? JSONEncoder().encode(ids) { tableLayoutsData = data }
        })
    }

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
            .navigationTitle(store.selectedProject?.title ?? "Projects")
            .toolbar {
                kanbanToolbar
            }
            .focusedSceneValue(\.workspaceCommandContext, commandContext)
            .sheet(isPresented: $showsAddItem) {
                AddProjectItemView(store: store)
            }
            .onChange(of: store.selectedProjectId) { _, _ in
                searchText = ""
                workFilter = ProjectWorkFilter()
                selectedViewID = nil
                isSelecting = false
                selectedItemIDs.removeAll()
            }
            .sheet(isPresented: $showsSaveView) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Save Work View").font(.headline)
                    TextField("View name", text: $viewName)
                    Text("Saves filters, layout, sorting, and visible fields on this Mac. Search text is temporary. GitHub views are unchanged.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancel") { showsSaveView = false }.keyboardShortcut(.cancelAction)
                        Button("Save", action: saveCurrentView)
                            .keyboardShortcut(.defaultAction)
                            .disabled(viewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(24).frame(width: 420)
            }
            .onChange(of: workFilter) { _, _ in selectedItemIDs.removeAll() }
            .onChange(of: searchText) { _, _ in selectedItemIDs.removeAll() }
            .onChange(of: usesTable) { _, _ in selectedItemIDs.removeAll() }
            .onChange(of: isSelecting) { _, isSelecting in
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

    private var projectSurface: some View {
        boardSurface.searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "Search title, #number, or @assignee"
        )
    }

    private var boardSurface: some View {
        VStack(spacing: 0) {
            OperationErrorBanner(
                message: operationErrorMessage ?? store.operationErrorMessage,
                dismiss: dismissOperationError
            )

            if let project = store.selectedProject {
                workControls(project)
            }
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

            if let project = store.selectedProject {
                Menu("Project Actions", systemImage: "ellipsis") {
                    if projectURL != nil {
                        Button("Open Project in GitHub", systemImage: "arrow.up.right.square", action: openProjectInGitHub)
                    }
                    Button(myWorkStore.isFollowing(project.id) ? "Remove from My Work" : "Add to My Work",
                           systemImage: "briefcase", action: toggleFollowingProject)
                    Button("Select Multiple Items", systemImage: "checkmark.circle", action: toggleSelectionMode)
                        .disabled(!canEditSelectedProject)
                }.help("Project Actions")
            }
        }

        if isSelecting || showsProjectEditingActions {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed)
            }
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
        } else if showsProjectEditingActions {
            ToolbarItemGroup(placement: .automatic) {
                Button("Add Item", systemImage: "plus", action: showAddItem)
                    .labelStyle(.iconOnly)
                    .disabled(canEditSelectedProject == false)
                    .help("Add Item")
            }
        }

        if store.selectedProject != nil {
            ToolbarItem(placement: .automatic) {
                Picker("Project Layout", selection: layoutSelection) {
                    Text("Board").tag(false)
                    Text("Table").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Change project layout")
            }
        }
        if !usesTable, let project = store.selectedProject {
            ToolbarItem(placement: .automatic) {
                BoardDisplayOptions(project: project, preferenceID: tablePreferenceID,
                                    workControls: workControls(project), visibleStatusIDs: visibleStatusBinding(project))
                    .id(tablePreferenceID)
            }
        }
        if #available(macOS 26.0, *), !isSelecting {
            ToolbarSpacer(.flexible)
            DefaultToolbarItem(kind: .search)
        }
    }

    private var savedViews: [SavedProjectWorkView] {
        guard !savedViewsData.isEmpty else { return [] }
        return (try? JSONDecoder().decode([SavedProjectWorkView].self, from: savedViewsData)) ?? []
    }

    private var selectedSavedView: SavedProjectWorkView? {
        savedViews.first { $0.id == selectedViewID && $0.projectID == store.selectedProjectId }
    }

    private var tablePreferenceID: String {
        let projectID = store.selectedProjectId ?? ""
        return selectedViewID.map { "\(projectID).view.\($0)" } ?? projectID
    }

    private func workControls(_ project: Project) -> ProjectWorkControls {
        ProjectWorkControls(
            project: project, items: project.items,
            displayedCount: displayedItems(in: project).count,
            currentUserLogin: store.currentUserLogin,
            savedViews: savedViews.filter { $0.projectID == project.id }, selectedViewID: selectedViewID,
            filter: $workFilter, searchText: $searchText,
            selectView: selectWorkView,
            saveView: { viewName = selectedSavedView?.name ?? ""; showsSaveView = true },
            updateView: updateCurrentView, deleteView: deleteCurrentView,
            hiddenStatusCount: usesTable ? 0 : project.statusOptions.count - visibleStatuses(in: project).count,
            showAllColumns: { visibleStatusBinding(project).wrappedValue = Set(project.statusOptions.map(\.id)) }
        )
    }

    private func visibleStatuses(in project: Project) -> [StatusOption] {
        guard let view = selectedSavedView else { return store.visibleKanbanStatuses(in: project) }
        return project.statusOptions.filter { !view.hiddenStatusIDs.contains($0.id) }
    }

    private func visibleStatusBinding(_ project: Project) -> Binding<Set<String>> {
        Binding(get: { Set(visibleStatuses(in: project).map(\.id)) }, set: { ids in
            if let selectedViewID {
                var views = savedViews
                guard let index = views.firstIndex(where: { $0.id == selectedViewID }) else { return }
                views[index].hiddenStatusIDs = Set(project.statusOptions.map(\.id)).subtracting(ids)
                persistViews(views)
            } else {
                store.showAllKanbanStatuses(in: project)
                for status in project.statusOptions where !ids.contains(status.id) {
                    store.setKanbanStatus(status, visible: false, in: project)
                }
            }
        })
    }

    private func displayedItems(in project: Project) -> [ProjectItem] {
        let items = filteredItems(for: project.items)
        guard !usesTable else { return items }
        let visibleIDs = Set(visibleStatuses(in: project).map(\.id))
        let knownIDs = Set(project.statusOptions.map(\.id))
        return items.filter { item in
            guard let id = item.statusOptionId, knownIDs.contains(id) else { return true }
            return visibleIDs.contains(id)
        }
    }

    private func clearFilters(_ project: Project) {
        workFilter = ProjectWorkFilter()
        searchText = ""
        visibleStatusBinding(project).wrappedValue = Set(project.statusOptions.map(\.id))
    }

    private func selectWorkView(_ view: SavedProjectWorkView?) {
        selectedViewID = view?.id
        workFilter = view?.filter ?? ProjectWorkFilter()
        searchText = ""
        selectedItemIDs.removeAll()
    }

    private func persistViews(_ views: [SavedProjectWorkView]) {
        do { savedViewsData = try JSONEncoder().encode(views) }
        catch { report(error) }
    }

    private func saveCurrentView() {
        guard let projectID = store.selectedProjectId else { return }
        let view = SavedProjectWorkView(projectID: projectID,
            name: viewName.trimmingCharacters(in: .whitespacesAndNewlines),
            filter: workFilter, usesTable: usesTable,
            hiddenStatusIDs: Set(store.selectedProject?.statusOptions.map(\.id) ?? []).subtracting(
                store.selectedProject.map { Set(visibleStatuses(in: $0).map(\.id)) } ?? []))
        let oldPrefix = "projectTable.\(tablePreferenceID)."
        let newPrefix = "projectTable.\(projectID).view.\(view.id)."
        for key in ["columns", "sortColumn", "sortAscending", "fieldID", "groupsByStatus", "cardFields"] {
            if let value = UserDefaults.standard.object(forKey: oldPrefix + key) {
                UserDefaults.standard.set(value, forKey: newPrefix + key)
            }
        }
        persistViews(savedViews + [view])
        selectedViewID = view.id
        showsSaveView = false
    }

    private func updateCurrentView() {
        var views = savedViews
        guard let index = views.firstIndex(where: { $0.id == selectedViewID }) else { return }
        views[index].filter = workFilter
        persistViews(views)
    }

    private func deleteCurrentView() {
        guard let selectedViewID else { return }
        let prefix = "projectTable.\(tablePreferenceID)."
        for key in ["columns", "sortColumn", "sortAscending", "fieldID", "groupsByStatus", "cardFields"] {
            UserDefaults.standard.removeObject(forKey: prefix + key)
        }
        persistViews(savedViews.filter { $0.id != selectedViewID })
        selectWorkView(nil)
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

            Text("Select a project to view its items")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            NewProjectButton()
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
            if usesTable {
                ProjectTableView(
                    project: project,
                    items: filteredItems(for: project.items),
                    store: store,
                    preferenceID: tablePreferenceID,
                    workControls: workControls(project),
                    isSelecting: isSelecting,
                    selectedItemIDs: $selectedItemIDs,
                    showItemDetail: openItemDetail,
                    reportError: report
                )
                .id(tablePreferenceID)
            } else if displayedItems(in: project).isEmpty {
                ContentUnavailableView {
                    Label("No Matching Items", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Try removing filters or changing your search.")
                } actions: {
                    Button("Clear Filters") { clearFilters(project) }
                }
            } else {
                boardContent(project)
            }
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
            Button("Add Item", action: showAddItem).disabled(!project.viewerCanUpdate)
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
        workFilter.apply(to: items, currentUserLogin: store.currentUserLogin)
            .matching(searchText, currentUserLogin: store.currentUserLogin)
    }

    private func boardContent(_ project: Project) -> some View {
        GeometryReader { geometry in
            let visibleStatuses = visibleStatuses(in: project)
            let visibleItems = project.items
            let knownStatusIDs = Set(project.statusOptions.map(\.id))
            let noStatusItems = visibleItems.filter { item in
                item.statusOptionId.map { !knownStatusIDs.contains($0) } ?? true
            }
            let includesNoStatus = !noStatusItems.isEmpty
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
                        let statusItems = filteredItems(for: visibleItems.filter { $0.statusOptionId == status.id })
                        KanbanColumn(
                            projectID: project.id,
                            preferenceID: tablePreferenceID,
                            status: status,
                            items: statusItems,
                            emptyMessage: searchText.isEmpty ? "No items" : "No matching items",
                            allStatuses: project.statusOptions,
                            store: store,
                            isSelecting: isSelecting,
                            selectedItemIDs: $selectedItemIDs,
                            showInspector: openItemDetail,
                            reportError: report
                        )
                        .frame(width: columnWidth, height: geometry.size.height - 32)
                    }

                    let noStatusFiltered = filteredItems(for: noStatusItems)
                    if !noStatusItems.isEmpty {
                        KanbanColumn(
                            projectID: project.id,
                            preferenceID: tablePreferenceID,
                            status: nil,
                            items: noStatusFiltered,
                            emptyMessage: searchText.isEmpty ? "No items" : "No matching items",
                            allStatuses: project.statusOptions,
                            store: store,
                            isSelecting: isSelecting,
                            selectedItemIDs: $selectedItemIDs,
                            showInspector: openItemDetail,
                            reportError: report
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

    private func boardScrollIdentity(
        project: Project,
        visibleStatuses: [StatusOption],
        includesNoStatus: Bool
    ) -> [String] {
        [tablePreferenceID, includesNoStatus ? "includes-no-status" : "statuses-only"]
            + visibleStatuses.map(\.id)
    }

    private func openItemDetail(_ reference: ItemInspectorReference) {
        selectedItemIDs = [reference.itemID]
        showItemDetail(reference)
    }

    private var selectedItems: [ProjectItem] {
        store.selectedProject?.items.filter { selectedItemIDs.contains($0.id) } ?? []
    }

    private func moveSelection(to status: StatusOption) {
        let items = selectedItems
        guard items.isEmpty == false, let projectID = store.selectedProjectId else { return }
        isBulkWorking = true
        operationErrorMessage = nil
        Task {
            do {
                try await store.moveItems(items, to: status, in: projectID)
                selectedItemIDs.removeAll()
            } catch {
                report(error)
            }
            isBulkWorking = false
        }
    }

    private func archiveSelection() {
        let items = selectedItems
        guard items.isEmpty == false, let projectID = store.selectedProjectId else { return }
        isBulkWorking = true
        operationErrorMessage = nil
        Task {
            do {
                try await store.archiveItems(items, in: projectID)
                selectedItemIDs.removeAll()
            } catch {
                report(error)
            }
            isBulkWorking = false
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
}

// MARK: - Kanban Column
