import SwiftUI

struct KanbanBoardView: View {
    @Bindable var store: ProjectStore
    @Bindable var myWorkStore: MyWorkStore
    @Environment(\.openSettings) private var openSettings
    let toggleFollowing: (Project) async -> Void
    let showItemDetail: (ItemInspectorReference) -> Void
    @Binding var searchText: String
    @Binding var isSelecting: Bool
    private var workPreferences = ProjectWorkPreferences()
    @State private var workFilter = ProjectWorkFilter()
    @State private var selectedViewID: String?
    @State private var showsSaveView = false
    @State private var viewName = ""
    @State private var showsAddItem = false
    @State private var collapsedTableGroups: Set<ProjectTableRow.ID> = []
    @State private var selectedItemIDs: Set<String> = []
    @State private var isBulkWorking = false
    @State private var operationErrorMessage: String?

    init(store: ProjectStore, myWorkStore: MyWorkStore,
         toggleFollowing: @escaping (Project) async -> Void,
         showItemDetail: @escaping (ItemInspectorReference) -> Void,
         searchText: Binding<String>, isSelecting: Binding<Bool>) {
        self.store = store
        self.myWorkStore = myWorkStore
        self.toggleFollowing = toggleFollowing
        self.showItemDetail = showItemDetail
        _searchText = searchText
        _isSelecting = isSelecting
    }

    private var usesTable: Bool {
        selectedSavedView?.usesTable ?? (store.selectedProjectId.map { workPreferences.usesTable(projectID: $0) } ?? false)
    }

    private var layoutSelection: Binding<Bool> {
        Binding(get: { usesTable }, set: { useTable in
            guard let id = store.selectedProjectId else { return }
            do {
                try workPreferences.setLayout(usesTable: useTable, projectID: id, viewID: selectedViewID)
            } catch { report(error) }
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
            .onChange(of: tablePreferenceID) { _, _ in collapsedTableGroups.removeAll() }
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
                if projectURL != nil {
                    Button("Open Project in GitHub", systemImage: "arrow.up.right.square", action: openProjectInGitHub)
                        .labelStyle(.iconOnly)
                        .help("Open Project in GitHub")
                }
                Button(myWorkStore.isFollowing(project.id) ? "Remove from My Work" : "Add to My Work",
                       systemImage: myWorkStore.isFollowing(project.id) ? "briefcase.fill" : "briefcase",
                       action: toggleFollowingProject)
                    .labelStyle(.iconOnly)
                    .help(myWorkStore.isFollowing(project.id) ? "Remove from My Work" : "Add to My Work")
                Menu("Saved Views", systemImage: "ellipsis") {
                    workControls(project).savedViewMenuContents
                }.help("Saved Views")
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
                Button("Select Multiple Items", systemImage: "checkmark.circle", action: toggleSelectionMode)
                    .labelStyle(.iconOnly)
                    .disabled(!canEditSelectedProject)
                    .help("Select Multiple Items")
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
        if let project = store.selectedProject {
            ToolbarItem(placement: .automatic) {
                Menu {
                    workControls(project).filterMenuContents
                } label: {
                    Label("Filter", systemImage: workFilter.isActive
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(workFilter.isActive ? Color.accentColor : Color.primary)
                }
                .help("Filter items")
                .accessibilityValue(workFilter.isActive ? "Filters active" : "No filters")
            }
        }
        if let project = store.selectedProject {
            ToolbarItem(placement: .automatic) {
                Group {
                    if usesTable {
                        TableDisplayOptions(project: project, preferenceID: tablePreferenceID,
                                            collapsedGroups: $collapsedTableGroups)
                    } else {
                        BoardDisplayOptions(project: project, preferenceID: tablePreferenceID,
                                            visibleStatusIDs: visibleStatusBinding(project))
                    }
                }
                .id(tablePreferenceID)
            }
        }
        if #available(macOS 26.0, *), !isSelecting {
            ToolbarSpacer(.flexible)
            DefaultToolbarItem(kind: .search)
        }
    }

    private var selectedSavedView: SavedProjectWorkView? {
        workPreferences.views.first { $0.id == selectedViewID && $0.projectID == store.selectedProjectId }
    }

    private var tablePreferenceID: String {
        let projectID = store.selectedProjectId ?? ""
        return ProjectDisplayPreferences(projectID: projectID, viewID: selectedViewID).id
    }

    private func workControls(_ project: Project) -> ProjectWorkControls {
        ProjectWorkControls(
            project: project, items: project.items,
            matchingCount: filteredItems(for: project.items).count,
            currentUserLogin: store.currentUserLogin,
            savedViews: workPreferences.views.filter { $0.projectID == project.id }, selectedViewID: selectedViewID,
            filter: $workFilter, searchText: $searchText,
            selectView: selectWorkView,
            saveView: { viewName = selectedSavedView?.name ?? ""; showsSaveView = true },
            updateView: updateCurrentView, deleteView: deleteCurrentView
        )
    }

    private func visibleStatuses(in project: Project) -> [StatusOption] {
        guard let view = selectedSavedView else { return store.visibleKanbanStatuses(in: project) }
        return project.statusOptions.filter { !view.hiddenStatusIDs.contains($0.id) }
    }

    private func visibleStatusBinding(_ project: Project) -> Binding<Set<String>> {
        Binding(get: { Set(visibleStatuses(in: project).map(\.id)) }, set: { ids in
            if let selectedViewID {
                do {
                    try workPreferences.setHiddenStatuses(
                        Set(project.statusOptions.map(\.id)).subtracting(ids), viewID: selectedViewID
                    )
                } catch { report(error) }
            } else {
                store.showAllKanbanStatuses(in: project)
                for status in project.statusOptions where !ids.contains(status.id) {
                    store.setKanbanStatus(status, visible: false, in: project)
                }
            }
        })
    }

    private func selectWorkView(_ view: SavedProjectWorkView?) {
        selectedViewID = view?.id
        workFilter = view?.filter ?? ProjectWorkFilter()
        searchText = ""
        selectedItemIDs.removeAll()
    }

    private func saveCurrentView() {
        guard let projectID = store.selectedProjectId else { return }
        let view = SavedProjectWorkView(projectID: projectID,
            name: viewName.trimmingCharacters(in: .whitespacesAndNewlines),
            filter: workFilter, usesTable: usesTable,
            hiddenStatusIDs: Set(store.selectedProject?.statusOptions.map(\.id) ?? []).subtracting(
                store.selectedProject.map { Set(visibleStatuses(in: $0).map(\.id)) } ?? []))
        do {
            try workPreferences.save(view, copyingDisplayFrom: tablePreferenceID)
            selectedViewID = view.id
            showsSaveView = false
        } catch { report(error) }
    }

    private func updateCurrentView() {
        guard let selectedViewID else { return }
        do { try workPreferences.setFilter(workFilter, viewID: selectedViewID) }
        catch { report(error) }
    }

    private func deleteCurrentView() {
        guard let selectedViewID else { return }
        do {
            try workPreferences.delete(viewID: selectedViewID)
            selectWorkView(nil)
        } catch { report(error) }
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

    @ViewBuilder
    private func errorView(_ error: Error) -> some View {
        if let error = error as? GitHubError,
           [.ghCLINotFound, .notAuthenticated, .missingProjectScope, .accountChanged, .insufficientPermissions].contains(error) {
            ContentUnavailableView {
                Label("Connect to GitHub", systemImage: "person.crop.circle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Open GitHub Settings") {
                    UserDefaults.standard.set("github", forKey: "selectedSettingsPane")
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
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
                    collapsedGroups: $collapsedTableGroups,
                    isSelecting: isSelecting,
                    selectedItemIDs: $selectedItemIDs,
                    showItemDetail: openItemDetail,
                    reportError: report
                )
                .id(tablePreferenceID)
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
        KanbanColumnsView(
            store: store, project: project, items: filteredItems(for: project.items),
            statuses: visibleStatuses(in: project), preferenceID: tablePreferenceID,
            emptyMessage: workFilter.isActive || !searchText.isEmpty ? "No matching items" : "No items",
            isSelecting: isSelecting, selectedItemIDs: $selectedItemIDs,
            showInspector: openItemDetail, reportError: report
        )
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
