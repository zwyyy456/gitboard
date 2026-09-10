import SwiftUI

struct MainWorkspaceView: View {
    @Bindable var model: GitStrideModel
    @Binding var requestedItemReference: ItemInspectorReference?
    @Binding var requestsProjectBoard: Bool
    @State private var destination: Destination = .project
    @State private var detailPath = NavigationPath()
    @State private var selectedItemReference: ItemInspectorReference?
    @State private var contentWidth: CGFloat = 0
    private var showsInlineDetail: Bool { contentWidth >= 1050 }
    @State private var projectSearchText = ""
    @State private var isSelectingProjectItems = false

    private enum Destination: Hashable {
        case project
        case myWork(MyWorkFilter)
    }

    private enum SidebarSelection: Hashable {
        case project(String)
        case myWork(MyWorkFilter)
    }

    private func projectColor(for id: String) -> Color {
        let palette: [Color] = [.blue, .teal, .green, .orange, .pink, .purple, .indigo]
        // Use a deterministic hash so colors survive relaunches and project renames.
        let hash = id.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(
            get: {
                switch destination {
                case .project:
                    model.projectStore.selectedProjectId.map(SidebarSelection.project)
                case .myWork(let filter):
                    .myWork(filter)
                }
            },
            set: { selection in
                switch selection {
                case .project(let id):
                    guard let project = model.projectStore.project(id: id) else { return }
                    destination = .project
                    detailPath = NavigationPath()
                    Task { await model.projectStore.selectProject(project) }
                case .myWork(let filter):
                    destination = .myWork(filter)
                case nil:
                    break
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Owner", selection: Binding(
                    get: { model.projectStore.selectedOwnerId },
                    set: { id in
                        guard let owner = model.projectStore.owners.first(where: { $0.id == id }) else { return }
                        destination = .project
                        detailPath = NavigationPath()
                        Task { await model.projectStore.selectOwner(owner) }
                    }
                )) {
                    if model.projectStore.selectedOwnerId == nil {
                        Text("Select an owner").tag(String?.none)
                    }
                    ForEach(model.projectStore.owners) { owner in
                        Label(owner.login, systemImage: owner.kind == .organization ? "building.2" : "person")
                            .tag(Optional(owner.id))
                    }
                }
                .padding(12)
                .disabled(model.projectStore.owners.isEmpty)

                List(selection: sidebarSelection) {
                    Section {
                        ForEach(model.projectStore.projects.filter { $0.owner.id == model.projectStore.selectedOwnerId }) { project in
                            HStack(spacing: 8) {
                                Image(systemName: "square.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(projectColor(for: project.id))
                                    .frame(width: 14, height: 14)
                                    .accessibilityHidden(true)
                                Text(project.title)
                            }
                                .accessibilityElement(children: .combine)
                                .lineLimit(1)
                                .help(project.title)
                                .tag(SidebarSelection.project(project.id))
                                .contextMenu {
                                    ProjectManagementMenu(model: model, projectID: project.id)
                                }
                        }
                        if model.projectStore.isLoading {
                            ProgressView("Loading projects…").controlSize(.small)
                        } else if let error = model.projectStore.error {
                            Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
                            Button("Retry") { Task { await model.projectStore.loadProjects() } }
                        } else if model.projectStore.projects.isEmpty {
                            Text("No projects").foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack {
                            Text("Projects")
                            Spacer()
                            NewProjectButton()
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("New Project")
                        }
                    }

                    Section {
                        ForEach(model.myWorkStore.filters) { filter in
                            Label(filter.rawValue, systemImage: filter.icon)
                                .tag(SidebarSelection.myWork(filter))
                                .contextMenu {
                                    Button("Move Up", systemImage: "arrow.up") {
                                        moveFilterUp(filter)
                                    }
                                    .disabled(model.myWorkStore.filters.first == filter)

                                    Button("Move Down", systemImage: "arrow.down") {
                                        moveFilterDown(filter)
                                    }
                                    .disabled(model.myWorkStore.filters.last == filter)

                                    Divider()

                                    Button("Hide from Sidebar", systemImage: "eye.slash") {
                                        hideFilter(filter)
                                    }
                                    .disabled(model.myWorkStore.filters.count == 1)
                                }
                        }
                        .onMove { offsets, destination in
                            model.myWorkStore.moveFilters(
                                fromOffsets: offsets,
                                toOffset: destination
                            )
                        }
                    } header: {
                        HStack {
                            Text("My Work")
                            Spacer()
                            Menu {
                                filterVisibilityControls
                            } label: {
                                Label("Configure My Work", systemImage: "ellipsis.circle")
                                    .labelStyle(.iconOnly)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Configure My Work views")
                        }
                        .contextMenu {
                            filterVisibilityControls
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            HStack(spacing: 0) {
                NavigationStack(path: $detailPath) {
                    Group {
                        switch destination {
                        case .project:
                            KanbanBoardView(
                                store: model.projectStore,
                                myWorkStore: model.myWorkStore,
                                toggleFollowing: { await model.toggleFollowing($0) },
                                showItemDetail: showItemDetail,
                                searchText: $projectSearchText,
                                isSelecting: $isSelectingProjectItems
                            )
                        case .myWork(let filter):
                            MyWorkView(
                                model: model,
                                filter: filter,
                                showItemDetail: showItemDetail
                            ) {
                                destination = .project
                            }
                        }
                    }
                    .navigationDestination(for: ItemInspectorReference.self) { reference in
                        ItemDetailView(
                            store: model.projectStore,
                            reference: reference,
                            allowsOpeningNewWindow: true
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsInlineDetail, let reference = selectedItemReference {
                    Divider()
                    WorkspaceItemPane(store: model.projectStore, reference: reference) {
                        selectedItemReference = nil
                    }
                    .id(reference)
                    .frame(width: min(480, contentWidth * 0.42))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .onChange(of: showsInlineDetail) { _, wide in
            detailPath = NavigationPath()
            if !wide, let reference = selectedItemReference { detailPath.append(reference) }
        }
        .onChange(of: detailPath.count) { _, count in
            if !showsInlineDetail && count == 0 { selectedItemReference = nil }
        }
        .frame(minWidth: 860, minHeight: 600)
        .task {
            if model.projectStore.projects.isEmpty {
                await model.projectStore.loadProjects()
            }
            await model.activateMyWork(accountLogin: model.projectStore.currentUserLogin)
            if model.myWorkStore.followedProjects.isEmpty == false {
                await model.refreshMyWork()
            }
        }
        .onChange(of: model.projectStore.selectedProjectId) { _, _ in
            if destination == .project {
                detailPath = NavigationPath()
                selectedItemReference = nil
            }
        }
        .onChange(of: model.projectStore.currentUserLogin) { _, login in
            Task { await model.activateMyWork(accountLogin: login) }
        }
        .onChange(of: destination) { _, destination in
            detailPath = NavigationPath()
            selectedItemReference = nil
            guard destination != .project else { return }
            projectSearchText = ""
            isSelectingProjectItems = false
        }
        .onChange(of: requestsProjectBoard, initial: true) { _, requested in
            guard requested else { return }
            destination = .project
            detailPath = NavigationPath()
            selectedItemReference = nil
            requestsProjectBoard = false
        }
        .onChange(of: requestedItemReference, initial: true) { _, reference in
            guard let reference else { return }
            showItemDetail(reference)
            requestedItemReference = nil
        }
    }

    @ViewBuilder
    private var filterVisibilityControls: some View {
        ForEach(MyWorkFilter.allCases) { filter in
            Toggle(
                filter.rawValue,
                isOn: Binding(
                    get: { model.myWorkStore.filters.contains(filter) },
                    set: { setFilterVisible(filter, visible: $0) }
                )
            )
            .disabled(
                model.myWorkStore.filters.count == 1
                    && model.myWorkStore.filters.contains(filter)
            )
        }
    }

    private func moveFilterUp(_ filter: MyWorkFilter) {
        model.myWorkStore.moveFilter(filter, offset: -1)
    }

    private func moveFilterDown(_ filter: MyWorkFilter) {
        model.myWorkStore.moveFilter(filter, offset: 1)
    }

    private func hideFilter(_ filter: MyWorkFilter) {
        setFilterVisible(filter, visible: false)
    }

    private func showItemDetail(_ reference: ItemInspectorReference) {
        selectedItemReference = reference
        detailPath = NavigationPath()
        if !showsInlineDetail { detailPath.append(reference) }
    }

    private func setFilterVisible(_ filter: MyWorkFilter, visible: Bool) {
        model.myWorkStore.setFilterVisible(filter, visible: visible)
        if visible == false,
           model.myWorkStore.filters.contains(filter) == false,
           destination == .myWork(filter) {
            destination = .project
        }
    }
}

private struct WorkspaceItemPane: View {
    @Bindable var store: ProjectStore
    let reference: ItemInspectorReference
    let close: () -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var showsProperties = false
    @State private var operationErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Detail Section", selection: $showsProperties) {
                    Text("Description").tag(false)
                    Text("Properties").tag(true)
                }.pickerStyle(.segmented)
                Spacer(minLength: 8)
                Button("Open in New Window", systemImage: "macwindow") {
                    openWindow(id: "item-detail", value: reference)
                }.labelStyle(.iconOnly).help("Open in New Window")
                Button("Close Details", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly).help("Close Details")
            }.padding(12)
            Divider()
            OperationErrorBanner(message: operationErrorMessage) { operationErrorMessage = nil }
            if showsProperties {
                ItemPropertiesView(store: store, reference: reference, operationErrorMessage: $operationErrorMessage)
            } else {
                ItemDescriptionView(store: store, reference: reference)
            }
        }
        .frame(maxHeight: .infinity)
        .background(.background)
        .task(id: store.item(for: reference)?.contentId) {
            if let item = store.item(for: reference) { await store.loadItemDetail(for: item) }
        }
    }
}
