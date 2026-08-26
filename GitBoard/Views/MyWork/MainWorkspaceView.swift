import SwiftUI

struct MainWorkspaceView: View {
    @Bindable var model: GitBoardModel
    @State private var destination: Destination = .project

    private enum Destination: Hashable {
        case project
        case myWork(MyWorkFilter)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Label("Project Board", systemImage: "rectangle.split.3x1")
                    .tag(Destination.project)

                Section("My Work") {
                    ForEach(model.myWorkStore.filters) { filter in
                        Label(filter.rawValue, systemImage: filter.icon)
                            .tag(Destination.myWork(filter))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .toolbar {
                Menu {
                    ForEach(MyWorkFilter.allCases) { filter in
                        Toggle(
                            filter.rawValue,
                            isOn: Binding(
                                get: { model.myWorkStore.filters.contains(filter) },
                                set: { model.myWorkStore.setFilterVisible(filter, visible: $0) }
                            )
                        )

                        if model.myWorkStore.filters.contains(filter) {
                            Button("Move Up") { model.myWorkStore.moveFilter(filter, offset: -1) }
                            Button("Move Down") { model.myWorkStore.moveFilter(filter, offset: 1) }
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("Configure My Work views")
            }
        } detail: {
            switch destination {
            case .project:
                KanbanBoardView(
                    store: model.projectStore,
                    myWorkStore: model.myWorkStore,
                    toggleFollowing: { await model.toggleFollowing($0) }
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
        .task {
            if model.projectStore.projects.isEmpty {
                await model.projectStore.loadProjects()
            }
            await model.activateMyWork(accountLogin: model.projectStore.currentUserLogin)
            if model.myWorkStore.followedProjects.isEmpty == false {
                await model.myWorkStore.refresh()
            }
        }
        .onChange(of: model.projectStore.currentUserLogin) { _, login in
            Task { await model.activateMyWork(accountLogin: login) }
        }
    }
}
