import SwiftUI

struct ItemPropertiesView: View {
    @Bindable var store: ProjectStore
    let reference: ItemInspectorReference
    @Environment(\.dismiss) private var dismiss

    @State private var userQuery = ""
    @State private var userResults: [Assignee] = []
    @State private var labelName = ""
    @State private var isWorking = false

    private var project: Project? { store.project(id: reference.projectID) }
    private var item: ProjectItem? { store.item(for: reference) }
    private var canEdit: Bool { store.canEditProject(id: reference.projectID) }

    var body: some View {
        ScrollView {
            if let project, let item {
                VStack(alignment: .leading, spacing: 20) {
                    fieldSection(project: project, item: item)

                    if item.contentType == .issue {
                        issueSection(item)
                        relationshipsSection(item)
                    }

                    assigneeSection(item)

                    if item.contentType == .issue {
                        labelSection(item)
                    }

                    signalsSection(item)

                    if let message = store.operationErrorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    if canEdit {
                        Divider()
                        Button("Archive from Project", systemImage: "archivebox") {
                            archive(item)
                        }
                        .disabled(isWorking)
                    }
                }
                .padding(20)
            }
        }
        .overlay {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func fieldSection(project: Project, item: ProjectItem) -> some View {
        propertySection("Project Fields") {
            ForEach(project.fields.filter(\.isEditable)) { field in
                ProjectFieldEditor(
                    field: field,
                    value: item.fieldValues[field.id],
                    isEditable: canEdit && isWorking == false
                ) { value in
                    isWorking = true
                    _ = await store.updateField(
                        on: item,
                        in: reference.projectID,
                        field: field,
                        value: value
                    )
                    isWorking = false
                }
            }
        }
    }

    @ViewBuilder
    private func issueSection(_ item: ProjectItem) -> some View {
        propertySection("Issue") {
            switch store.itemDetailState(for: item) {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)

            case .loaded(let detail):
                if let metadata = detail.issueMetadata {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Milestone")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if metadata.viewerCanSetMilestone {
                            milestoneEditor(metadata: metadata, item: item)
                        } else {
                            Text(metadata.milestone?.title ?? "No milestone")
                        }

                        milestoneProgress(metadata.milestone)
                    }
                    .task(id: metadata.repository) {
                        if metadata.viewerCanSetMilestone {
                            await store.loadMilestones(repository: metadata.repository)
                        }
                    }
                }

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func milestoneEditor(metadata: IssueMetadata, item: ProjectItem) -> some View {
        switch store.milestoneState(for: metadata.repository) {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)

        case .loaded(let milestones):
            Menu {
                Button("No milestone") {
                    changeMilestone(nil, on: item)
                }
                .disabled(metadata.milestone == nil)

                if milestones.isEmpty == false {
                    Divider()
                    ForEach(milestones) { milestone in
                        Button {
                            changeMilestone(milestone, on: item)
                        } label: {
                            if milestone.id == metadata.milestone?.id {
                                Label(milestone.title, systemImage: "checkmark")
                            } else {
                                Text(milestone.title)
                            }
                        }
                        .disabled(milestone.id == metadata.milestone?.id)
                    }
                }
            } label: {
                HStack {
                    Text(metadata.milestone?.title ?? "No milestone")
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .disabled(isWorking)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(metadata.milestone?.title ?? "No milestone")
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    Task {
                        await store.loadMilestones(
                            repository: metadata.repository,
                            forceRefresh: true
                        )
                    }
                }
                .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private func milestoneProgress(_ milestone: RepositoryMilestone?) -> some View {
        if let milestone {
            HStack(spacing: 6) {
                if let dueDate = milestone.dueOn.flatMap(formattedDate) {
                    Text("Due \(dueDate)")
                }
                Text("\(milestone.progressPercentage.formatted(.number.precision(.fractionLength(0))))% complete")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ProgressView(value: milestone.progressPercentage, total: 100)
                .accessibilityLabel("Milestone progress")
                .accessibilityValue("\(Int(milestone.progressPercentage.rounded())) percent")
        }
    }

    @ViewBuilder
    private func relationshipsSection(_ item: ProjectItem) -> some View {
        if case .loaded(let detail) = store.itemDetailState(for: item),
           let metadata = detail.issueMetadata {
            propertySection("Relationships") {
                if let parent = metadata.parent {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Parent issue")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        issueLink(parent)
                    }
                }

                if metadata.subIssues.isEmpty == false {
                    DisclosureGroup(subIssueTitle(metadata)) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(metadata.subIssues) { issueLink($0) }
                        }
                        .padding(.top, 6)
                    }
                }

                if metadata.blockedBy.isEmpty == false {
                    relationshipGroup("Blocked by", issues: metadata.blockedBy)
                }

                if metadata.blocking.isEmpty == false {
                    relationshipGroup("Blocking", issues: metadata.blocking)
                }

                if metadata.parent == nil,
                   metadata.subIssues.isEmpty,
                   metadata.blockedBy.isEmpty,
                   metadata.blocking.isEmpty {
                    secondaryText("No relationships")
                }
            }
        }
    }

    private func relationshipGroup(_ title: String, issues: [IssueReference]) -> some View {
        DisclosureGroup("\(title) \(issues.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(issues) { issueLink($0) }
            }
            .padding(.top, 6)
        }
    }

    private func issueLink(_ issue: IssueReference) -> some View {
        Link(destination: issue.url) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: issue.state == .closed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(issue.state == .closed ? .purple : .green)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(issue.repository)#\(issue.number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(issue.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(issue.repository) issue \(issue.number), \(issue.title), \(issue.state == .closed ? "closed" : "open")")
    }

    private func subIssueTitle(_ metadata: IssueMetadata) -> String {
        guard let progress = metadata.subIssueProgress else {
            return "Sub-issues \(metadata.subIssues.count)"
        }
        return "Sub-issues \(progress.completed)/\(progress.total)"
    }

    private func formattedDate(_ value: String) -> String? {
        guard let date = try? Date(value, strategy: .iso8601) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func assigneeSection(_ item: ProjectItem) -> some View {
        propertySection("Assignees") {
            if item.assignees.isEmpty {
                secondaryText("No assignees")
            } else {
                ForEach(item.assignees) { assignee in
                    HStack {
                        AsyncImage(url: URL(string: assignee.avatarUrl)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(.secondary.opacity(0.2))
                        }
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 1) {
                            Text(assignee.name ?? assignee.login)
                            if assignee.name != nil {
                                Text("@\(assignee.login)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if canEdit {
                            Button {
                                Task {
                                    await store.removeAssignee(
                                        from: item,
                                        in: reference.projectID,
                                        user: assignee
                                    )
                                }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove assignee")
                        }
                    }
                }
            }

            if canEdit, item.contentType != .draftIssue {
                HStack {
                    TextField("Search GitHub users", text: $userQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { searchUsers() }
                    Button("Search") { searchUsers() }
                        .disabled(userQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                ForEach(userResults) { user in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(user.name ?? user.login)
                            Text("@\(user.login)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add") {
                            Task {
                                await store.addAssignee(
                                    to: item,
                                    in: reference.projectID,
                                    user: user
                                )
                                userResults.removeAll { $0.id == user.id }
                            }
                        }
                        .disabled(item.assignees.contains { $0.id == user.id })
                    }
                }
            }
        }
    }

    private func labelSection(_ item: ProjectItem) -> some View {
        propertySection("Labels") {
            if item.labels.isEmpty {
                secondaryText("No labels")
            } else {
                ForEach(item.labels) { label in
                    HStack {
                        Circle()
                            .fill(Color(hex: label.color))
                            .frame(width: 9, height: 9)
                        Text(label.name)
                        Spacer()
                        if canEdit {
                            Button {
                                Task {
                                    _ = await store.removeLabel(
                                        from: item,
                                        in: reference.projectID,
                                        name: label.name
                                    )
                                }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove label")
                        }
                    }
                }
            }

            if canEdit {
                HStack {
                    TextField("Existing repository label", text: $labelName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addLabel(to: item) }
                    Button("Add") { addLabel(to: item) }
                        .disabled(labelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func signalsSection(_ item: ProjectItem) -> some View {
        if item.engineeringSignals != nil || item.linkedPR != nil {
            propertySection("Engineering") {
                EngineeringSignalsView(item: item, limit: 5)

                if let linkedPR = item.linkedPR, let url = URL(string: linkedPR.url) {
                    Link(destination: url) {
                        Label("PR #\(linkedPR.number): \(linkedPR.title)", systemImage: "arrow.triangle.pull")
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func propertySection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func secondaryText(_ value: String) -> some View {
        Text(value)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func searchUsers() {
        let query = userQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return }
        Task { userResults = await store.searchUsers(query: query) }
    }

    private func addLabel(to item: ProjectItem) {
        let name = labelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return }
        Task {
            if await store.addLabel(to: item, in: reference.projectID, name: name) {
                labelName = ""
            }
        }
    }

    private func changeMilestone(_ milestone: RepositoryMilestone?, on item: ProjectItem) {
        isWorking = true
        Task {
            _ = await store.setMilestone(milestone, on: item)
            isWorking = false
        }
    }

    private func archive(_ item: ProjectItem) {
        isWorking = true
        Task {
            let succeeded = await store.archiveItem(item, in: reference.projectID)
            isWorking = false
            if succeeded { dismiss() }
        }
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0x808080
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
