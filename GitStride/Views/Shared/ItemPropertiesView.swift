import SwiftUI

struct ItemPropertiesView: View {
    @Bindable var store: ProjectStore
    let reference: ItemInspectorReference

    @State private var userQuery = ""
    @State private var userResults: [Assignee] = []
    @State private var labelName = ""
    @State private var isWorking = false
    @State private var isSearchingUsers = false
    @State private var hasSearchedUsers = false
    @State private var userSearchGeneration = 0
    @State private var showsAssigneePicker = false
    @State private var showsLabelPicker = false
    @State private var relationEditor: IssueRelationKind?

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
        .sheet(item: $relationEditor) { kind in
            if let item,
               case .loaded(let detail) = store.itemDetailState(for: item),
               let metadata = detail.issueMetadata {
                IssueRelationEditorView(
                    store: store,
                    item: item,
                    metadata: metadata,
                    kind: kind
                )
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
        propertySection("Issue Details") {
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
                .frame(maxWidth: 180, alignment: .leading)
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
                        relationshipRow(parent, kind: .parent, item: item, canRemove: metadata.viewerCanUpdate)
                    }
                }

                if metadata.subIssues.isEmpty == false {
                    DisclosureGroup(subIssueTitle(metadata)) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(metadata.subIssues) {
                                relationshipRow(
                                    $0,
                                    kind: .subIssue,
                                    item: item,
                                    canRemove: metadata.viewerCanUpdate
                                )
                            }
                        }
                        .padding(.top, 6)
                    }
                }

                if metadata.blockedBy.isEmpty == false {
                    relationshipGroup(
                        "Blocked by",
                        issues: metadata.blockedBy,
                        kind: .blockedBy,
                        item: item,
                        canRemove: metadata.viewerCanUpdate
                    )
                }

                if metadata.blocking.isEmpty == false {
                    relationshipGroup(
                        "Blocking",
                        issues: metadata.blocking,
                        kind: .blocking,
                        item: item,
                        canRemove: metadata.viewerCanUpdate
                    )
                }

                if metadata.parent == nil,
                   metadata.subIssues.isEmpty,
                   metadata.blockedBy.isEmpty,
                   metadata.blocking.isEmpty {
                    secondaryText("No relationships")
                }

                if metadata.viewerCanUpdate {
                    Menu {
                        ForEach(IssueRelationKind.allCases) { kind in
                            Button(relationActionTitle(kind, hasParent: metadata.parent != nil)) {
                                relationEditor = kind
                            }
                        }
                    } label: {
                        Label("Add relationship", systemImage: "plus")
                    }
                    .disabled(isWorking)
                }
            }
        }
    }

    private func relationshipGroup(
        _ title: String,
        issues: [IssueReference],
        kind: IssueRelationKind,
        item: ProjectItem,
        canRemove: Bool
    ) -> some View {
        DisclosureGroup("\(title) \(issues.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(issues) {
                    relationshipRow($0, kind: kind, item: item, canRemove: canRemove)
                }
            }
            .padding(.top, 6)
        }
    }

    private func relationshipRow(
        _ issue: IssueReference,
        kind: IssueRelationKind,
        item: ProjectItem,
        canRemove: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            issueLink(issue)

            if canRemove {
                Button {
                    removeRelation(kind, issue: issue, from: item)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Remove \(relationTitle(kind).lowercased()) relationship")
                .disabled(isWorking)
            }
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

    private func relationTitle(_ kind: IssueRelationKind) -> String {
        switch kind {
        case .parent: "Parent"
        case .subIssue: "Sub-issue"
        case .blockedBy: "Blocked by"
        case .blocking: "Blocking"
        }
    }

    private func relationActionTitle(_ kind: IssueRelationKind, hasParent: Bool) -> String {
        if kind == .parent, hasParent {
            return "Change parent"
        }
        return "Add \(relationTitle(kind).lowercased())"
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
                Button("Add Assignee…", systemImage: "plus", action: showAssigneePicker)
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showsAssigneePicker) {
                        assigneePicker(item)
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
                Button("Add Label…", systemImage: "plus", action: showLabelPicker)
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showsLabelPicker) {
                        labelPicker(item)
                    }
            }
        }
    }

    private func assigneePicker(_ item: ProjectItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Assignee")
                .font(.headline)

            HStack {
                TextField("Search GitHub users", text: $userQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { searchUsers() }
                Button("Search", systemImage: "magnifyingglass", action: searchUsers)
                    .labelStyle(.iconOnly)
                    .disabled(
                        userQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isSearchingUsers
                    )
                    .help("Search GitHub Users")
            }

            if isSearchingUsers {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Searching GitHub users")
            } else if userResults.isEmpty {
                Text(hasSearchedUsers ? "No matching users" : "Enter a GitHub login or name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
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
                                    addAssignee(user, to: item)
                                }
                                .disabled(item.assignees.contains { $0.id == user.id })
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .padding()
        .frame(width: 320)
    }

    private func labelPicker(_ item: ProjectItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Label")
                .font(.headline)

            TextField("Existing repository label", text: $labelName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addLabel(to: item) }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showsLabelPicker = false
                }
                Button("Add Label") {
                    addLabel(to: item)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(labelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
    }

    @ViewBuilder
    private func signalsSection(_ item: ProjectItem) -> some View {
        if (item.contentType == .pullRequest && item.engineeringSignals != nil)
            || item.linkedPR != nil {
            propertySection("Engineering") {
                if item.contentType == .pullRequest {
                    EngineeringSignalsView(item: item, limit: 5)
                }

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
        guard query.isEmpty == false, isSearchingUsers == false else { return }
        userSearchGeneration += 1
        let generation = userSearchGeneration
        isSearchingUsers = true
        hasSearchedUsers = true
        Task {
            let results = await store.searchUsers(query: query)
            guard generation == userSearchGeneration else { return }
            if query == userQuery.trimmingCharacters(in: .whitespacesAndNewlines) {
                userResults = results
            }
            isSearchingUsers = false
        }
    }

    private func showAssigneePicker() {
        userQuery = ""
        userResults = []
        userSearchGeneration += 1
        isSearchingUsers = false
        hasSearchedUsers = false
        showsAssigneePicker = true
    }

    private func showLabelPicker() {
        labelName = ""
        showsLabelPicker = true
    }

    private func addAssignee(_ user: Assignee, to item: ProjectItem) {
        Task {
            await store.addAssignee(
                to: item,
                in: reference.projectID,
                user: user
            )
            userResults.removeAll { $0.id == user.id }
        }
    }

    private func addLabel(to item: ProjectItem) {
        let name = labelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return }
        Task {
            if await store.addLabel(to: item, in: reference.projectID, name: name) {
                labelName = ""
                showsLabelPicker = false
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

    private func removeRelation(
        _ kind: IssueRelationKind,
        issue: IssueReference,
        from item: ProjectItem
    ) {
        isWorking = true
        Task {
            _ = await store.removeRelation(kind, relatedIssue: issue, from: item)
            isWorking = false
        }
    }

}

private struct IssueRelationEditorView: View {
    @Bindable var store: ProjectStore
    let item: ProjectItem
    let metadata: IssueMetadata
    let kind: IssueRelationKind

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [GitHubItemCandidate] = []
    @State private var isSearching = false
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text("Search GitHub issues across repositories. You can use qualifiers such as repo:owner/name.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Search issues", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("Search") { search() }
                    .disabled(trimmedQuery.isEmpty || isSearching || isAdding)
            }

            if isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if results.isEmpty, trimmedQuery.isEmpty == false {
                Text("No matching issues")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                List(results) { candidate in
                    Button {
                        add(candidate)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "circle")
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(candidate.repository)#\(candidate.number)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(candidate.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                            }

                            Spacer()
                            Image(systemName: "plus")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(isAdding)
                    .accessibilityLabel("Add \(candidate.repository) issue \(candidate.number), \(candidate.title)")
                }
                .listStyle(.inset)
            }

            if let message = store.operationErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
        .onAppear { store.clearOperationError() }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var existingIssueIDs: Set<String> {
        switch kind {
        case .parent:
            Set([metadata.parent?.id].compactMap { $0 })
        case .subIssue:
            Set(metadata.subIssues.map(\.id))
        case .blockedBy:
            Set(metadata.blockedBy.map(\.id))
        case .blocking:
            Set(metadata.blocking.map(\.id))
        }
    }

    private var title: String {
        switch kind {
        case .parent: metadata.parent == nil ? "Add parent issue" : "Change parent issue"
        case .subIssue: "Add sub-issue"
        case .blockedBy: "Add blocking prerequisite"
        case .blocking: "Add issue this blocks"
        }
    }

    private func search() {
        let query = trimmedQuery
        guard query.isEmpty == false else { return }
        isSearching = true
        store.clearOperationError()
        Task {
            let candidates = await store.searchItems(query: query)
            results = candidates.filter {
                $0.contentType == .issue
                    && $0.id != item.contentId
                    && existingIssueIDs.contains($0.id) == false
            }
            isSearching = false
        }
    }

    private func add(_ candidate: GitHubItemCandidate) {
        isAdding = true
        Task {
            let succeeded = await store.addRelation(kind, target: candidate, on: item)
            isAdding = false
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
