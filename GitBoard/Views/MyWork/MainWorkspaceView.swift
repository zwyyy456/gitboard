import SwiftUI

struct MainWorkspaceView: View {
    @Bindable var model: GitBoardModel
    @State private var destination: Destination = .project
    @State private var projectSearchText = ""
    @State private var isSelectingProjectItems = false

    private enum Destination: Hashable {
        case project
        case myWork(MyWorkFilter)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Label("Project Board", systemImage: "rectangle.split.3x1")
                    .tag(Destination.project)

                Section {
                    ForEach(model.myWorkStore.filters) { filter in
                        Label(filter.rawValue, systemImage: filter.icon)
                            .tag(Destination.myWork(filter))
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
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            switch destination {
            case .project:
                KanbanBoardView(
                    store: model.projectStore,
                    myWorkStore: model.myWorkStore,
                    toggleFollowing: { await model.toggleFollowing($0) },
                    searchText: $projectSearchText,
                    isSelecting: $isSelectingProjectItems
                )
            case .myWork(let filter):
                MyWorkView(
                    model: model,
                    filter: filter
                ) {
                    destination = .project
                }
            }
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
        .onChange(of: model.projectStore.currentUserLogin) { _, login in
            Task { await model.activateMyWork(accountLogin: login) }
        }
        .onChange(of: destination) { _, destination in
            guard destination != .project else { return }
            projectSearchText = ""
            isSelectingProjectItems = false
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

    private func setFilterVisible(_ filter: MyWorkFilter, visible: Bool) {
        model.myWorkStore.setFilterVisible(filter, visible: visible)
        if visible == false,
           model.myWorkStore.filters.contains(filter) == false,
           destination == .myWork(filter) {
            destination = .project
        }
    }
}
