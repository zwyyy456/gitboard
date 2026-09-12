import SwiftUI

struct MainWorkspaceView: View {
    @Bindable var model: GitStrideModel
    @Environment(\.openSettings) private var openSettings
    @Binding var requestedItemReference: ItemInspectorReference?
    @Binding var requestsProjectBoard: Bool
    @State private var destination: Destination = .project
    @State private var detailPath = NavigationPath()
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
                        if model.projectStore.isLoading == false {
                            if let error = model.projectStore.error {
                                Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
                                if let error = error as? GitHubError,
                                   [.ghCLINotFound, .notAuthenticated, .missingProjectScope, .accountChanged, .insufficientPermissions].contains(error) {
                                    Button("Open GitHub Settings") {
                                        UserDefaults.standard.set("github", forKey: "selectedSettingsPane")
                                        openSettings()
                                    }
                                } else {
                                    Button("Retry") { Task { await model.projectStore.loadProjects() } }
                                }
                            } else if model.projectStore.projects.isEmpty {
                                Text("No projects").foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Projects")
                            Spacer()
                            Group {
                                if model.projectStore.isLoading {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .help("Loading projects…")
                                        .accessibilityLabel("Loading projects")
                                } else {
                                    RefreshProjectsButton(store: model.projectStore)
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.borderless)
                                }
                            }
                            .frame(width: 16, height: 16)
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
            }
        }
        .onChange(of: model.projectStore.currentUserLogin) { _, login in
            Task { await model.activateMyWork(accountLogin: login) }
        }
        .onChange(of: destination) { _, destination in
            detailPath = NavigationPath()
            guard destination != .project else { return }
            projectSearchText = ""
            isSelectingProjectItems = false
        }
        .onChange(of: requestsProjectBoard, initial: true) { _, requested in
            guard requested else { return }
            destination = .project
            detailPath = NavigationPath()
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
        detailPath = NavigationPath()
        detailPath.append(reference)
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
