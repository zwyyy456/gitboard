import SwiftUI

struct MyWorkView: View {
    @Bindable var model: GitBoardModel
    let filter: MyWorkFilter
    let showItemDetail: (ItemInspectorReference) -> Void
    let didOpenProject: () -> Void
    @State private var operationErrorMessage: String?

    private var items: [MyWorkItem] {
        model.myWorkItems(for: filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = operationErrorMessage ?? model.myWorkErrorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                    Spacer()
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
            }

            if model.myWorkStore.followedProjects.isEmpty {
                ContentUnavailableView(
                    "No Projects in My Work",
                    systemImage: "briefcase",
                    description: Text("Open a Project Board and choose Add to My Work from the Project Actions menu.")
                )
            } else if model.projectStore.isLoadingFollowedProjects && model.myWorkProjects.isEmpty {
                ProgressView("Loading My Work…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Nothing in \(filter.rawValue)",
                    systemImage: filter.icon,
                    description: Text("This view is derived locally from your followed Projects.")
                )
            } else {
                List(items) { workItem in
                    MyWorkRow(
                        workItem: workItem,
                        model: model,
                        showDetails: { showDetails(workItem) },
                        openProject: { openProject(workItem.project) },
                        reportError: report
                    )
                }
                .listStyle(.inset)
            }
        }
        .frame(minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 6) {
                    Label(filter.rawValue, systemImage: filter.icon)
                    Text("\(items.count)")
                        .foregroundStyle(.secondary)
                }
                .help("\(items.count) items in \(filter.rawValue)")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(model.myWorkStore.followedProjects) { reference in
                        let title = followedProjectTitle(reference)
                        Button("Remove \(title) from My Work", role: .destructive) {
                            stopFollowing(reference)
                        }
                    }
                } label: {
                    Label(
                        "Projects \(model.myWorkStore.followedProjects.count)",
                        systemImage: "briefcase"
                    )
                }
                .disabled(model.myWorkStore.followedProjects.isEmpty)
                .help("Manage My Work Projects")

                if model.projectStore.isLoadingFollowedProjects {
                    ProgressView()
                        .controlSize(.small)
                        .help("Refreshing My Work")
                } else {
                    Button("Refresh My Work", systemImage: "arrow.clockwise", action: refresh)
                        .labelStyle(.iconOnly)
                        .help("Refresh My Work")
                }
            }
        }
        .focusedSceneValue(\.workspaceCommandContext, commandContext)
    }

    private var commandContext: WorkspaceCommandContext {
        WorkspaceCommandContext(
            refresh: .init(
                id: "refresh-my-work",
                title: "Refresh My Work",
                isEnabled: model.projectStore.isLoadingFollowedProjects == false,
                perform: refresh
            ),
            stopFollowing: model.myWorkStore.followedProjects.map { reference in
                .init(
                    id: "stop-following-\(reference.id)",
                    title: "Remove \(followedProjectTitle(reference)) from My Work",
                    perform: { stopFollowing(reference) }
                )
            }
        )
    }

    private func followedProjectTitle(_ reference: FollowedProject) -> String {
        model.projectStore.followedProject(id: reference.id)?.title
            ?? reference.displayTitle
            ?? reference.owner.login
    }

    private func refresh() {
        Task { await model.refreshMyWork() }
    }

    private func stopFollowing(_ reference: FollowedProject) {
        Task { await model.stopFollowing(reference) }
    }

    private func openProject(_ project: Project) {
        Task {
            await model.openProject(project)
            didOpenProject()
        }
    }

    private func showDetails(_ workItem: MyWorkItem) {
        showItemDetail(
            ItemInspectorReference(
                projectID: workItem.project.id,
                itemID: workItem.item.id
            )
        )
    }

    private func report(_ error: Error) {
        guard (error is CancellationError) == false else { return }
        operationErrorMessage = error.localizedDescription
    }
}

private struct MyWorkRow: View {
    let workItem: MyWorkItem
    @Bindable var model: GitBoardModel
    let showDetails: () -> Void
    let openProject: () -> Void
    let reportError: (Error) -> Void

    var body: some View {
        Button(action: showDetails) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: workItem.item.contentType == .pullRequest
                    ? "arrow.triangle.pull"
                    : "record.circle")
                    .foregroundStyle(workItem.item.contentType == .pullRequest ? .purple : .green)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 5) {
                    Text(workItem.item.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(workItem.project.owner.login)
                        Text("/")
                        Text(workItem.project.title)
                        if let number = workItem.item.number {
                            Text("#\(number)")
                        }
                        if let status = workItem.item.status {
                            Text(status)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    EngineeringSignalsView(item: workItem.item)
                }

                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 5)
        .accessibilityHint("Shows item details")
        .contextMenu {
            Button("Show Details", systemImage: "sidebar.right", action: showDetails)

            Button("Open Project", systemImage: "rectangle.split.3x1") {
                openProject()
            }

            if let urlString = workItem.item.url, let url = URL(string: urlString) {
                Link("Open in GitHub", destination: url)
            }

            if workItem.project.viewerCanUpdate {
                Divider()

                if let statusField = workItem.project.fields.first(where: { $0.name == "Status" }) {
                    Menu("Status") {
                        ForEach(statusField.options) { option in
                            Button(option.name) {
                                Task {
                                    do {
                                        try await model.updateMyWorkField(
                                            on: workItem,
                                            field: statusField,
                                            value: .singleSelect(optionId: option.id, name: option.name)
                                        )
                                    } catch {
                                        reportError(error)
                                    }
                                }
                            }
                        }
                    }
                }

                if let priorityField = workItem.project.fields.first(where: {
                    $0.kind == .singleSelect && $0.name.caseInsensitiveCompare("Priority") == .orderedSame
                }) {
                    Menu("Priority") {
                        ForEach(priorityField.options) { option in
                            Button(option.name) {
                                Task {
                                    do {
                                        try await model.updateMyWorkField(
                                            on: workItem,
                                            field: priorityField,
                                            value: .singleSelect(optionId: option.id, name: option.name)
                                        )
                                    } catch {
                                        reportError(error)
                                    }
                                }
                            }
                        }
                    }
                }

                Divider()

                Button("Archive from Project", systemImage: "archivebox") {
                    Task {
                        do {
                            try await model.archiveMyWorkItem(workItem)
                        } catch {
                            reportError(error)
                        }
                    }
                }
            }
        }
    }
}
