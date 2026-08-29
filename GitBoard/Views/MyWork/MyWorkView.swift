import SwiftUI

struct MyWorkView: View {
    @Bindable var model: GitBoardModel
    let filter: MyWorkFilter
    let didOpenProject: () -> Void

    private var items: [MyWorkItem] {
        model.myWorkItems(for: filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let errorMessage = model.myWorkErrorMessage {
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
                    "No Followed Projects",
                    systemImage: "star",
                    description: Text("Open a Project Board and click the star to include it in My Work.")
                )
            } else if model.projectStore.isLoadingFollowedProjects && model.myWorkProjects.isEmpty {
                ProgressView("Loading followed projects…")
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
                        openProject: { openProject(workItem.project) }
                    )
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label(filter.rawValue, systemImage: filter.icon)
                .font(.title3.bold())

            Text("\(items.count)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Spacer()

            Menu {
                ForEach(model.myWorkStore.followedProjects) { reference in
                    let title = model.projectStore.followedProject(id: reference.id)?.title
                        ?? reference.displayTitle
                        ?? reference.owner.login
                    Button("Stop Following \(title)", role: .destructive) {
                        Task { await model.stopFollowing(reference) }
                    }
                }
            } label: {
                Label("Following \(model.myWorkStore.followedProjects.count)", systemImage: "star.fill")
            }
            .disabled(model.myWorkStore.followedProjects.isEmpty)

            Button {
                Task { await model.refreshMyWork() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.projectStore.isLoadingFollowedProjects)
            .help("Refresh My Work")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func openProject(_ project: Project) {
        Task {
            await model.openProject(project)
            didOpenProject()
        }
    }
}

private struct MyWorkRow: View {
    let workItem: MyWorkItem
    @Bindable var model: GitBoardModel
    let openProject: () -> Void

    var body: some View {
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

            Button("Open Project") { openProject() }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 5)
        .contextMenu {
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
                                    await model.updateMyWorkField(
                                        on: workItem,
                                        field: statusField,
                                        value: .singleSelect(optionId: option.id, name: option.name)
                                    )
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
                                    await model.updateMyWorkField(
                                        on: workItem,
                                        field: priorityField,
                                        value: .singleSelect(optionId: option.id, name: option.name)
                                    )
                                }
                            }
                        }
                    }
                }

                Divider()

                Button("Archive from Project", systemImage: "archivebox") {
                    Task { await model.archiveMyWorkItem(workItem) }
                }
            }
        }
    }
}
