import SwiftUI

struct ItemInspectorView: View {
    @Bindable var store: ProjectStore
    let itemID: String
    @Environment(\.dismiss) private var dismiss

    @State private var userQuery = ""
    @State private var userResults: [Assignee] = []
    @State private var labelName = ""
    @State private var isWorking = false

    private var project: Project? { store.selectedProject }
    private var item: ProjectItem? {
        project?.items.first { $0.id == itemID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let project, let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        assigneeSection(item)
                        if item.contentType == .issue {
                            labelSection(item)
                        }
                        fieldSection(project: project, item: item)

                        if let message = store.operationErrorMessage {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }

                        if project.viewerCanUpdate {
                            Divider()
                            Button("Archive from Project", systemImage: "archivebox") {
                                archive(item)
                            }
                            .disabled(isWorking)
                        }
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView("Item Unavailable", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 500, height: 620)
        .overlay {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task { store.clearOperationError() }
        .onDisappear { store.clearOperationError() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item?.contentType == .pullRequest
                ? "arrow.triangle.pull"
                : "record.circle")
                .font(.title3)
                .foregroundStyle(item?.contentType == .pullRequest ? .purple : .green)

            VStack(alignment: .leading, spacing: 4) {
                Text(item?.title ?? "Item")
                    .font(.title3.bold())
                    .lineLimit(3)
                if let item {
                    Text(itemMetadata(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    EngineeringSignalsView(item: item, limit: 5)
                }
            }

            Spacer()

            if let urlString = item?.url, let url = URL(string: urlString) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open in GitHub")
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    @ViewBuilder
    private func assigneeSection(_ item: ProjectItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assignees")
                .font(.headline)

            if item.assignees.isEmpty {
                Text("No assignees")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

                        Text(assignee.name ?? assignee.login)
                        Text("@\(assignee.login)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()

                        if project?.viewerCanUpdate == true {
                            Button {
                                Task { await store.removeAssignee(from: item, user: assignee) }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove assignee")
                        }
                    }
                }
            }

            if project?.viewerCanUpdate == true, item.contentType != .draftIssue {
                HStack {
                    TextField("Search GitHub users", text: $userQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { searchUsers() }
                    Button("Search") { searchUsers() }
                        .disabled(userQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                ForEach(userResults) { user in
                    HStack {
                        Text(user.name ?? user.login)
                        Text("@\(user.login)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add") {
                            Task {
                                await store.addAssignee(to: item, user: user)
                                userResults.removeAll { $0.id == user.id }
                            }
                        }
                        .disabled(item.assignees.contains { $0.id == user.id })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func labelSection(_ item: ProjectItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Labels")
                .font(.headline)

            if item.labels.isEmpty {
                Text("No labels")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(item.labels) { label in
                    HStack {
                        Circle()
                            .fill(Color(hex: label.color))
                            .frame(width: 9, height: 9)
                        Text(label.name)
                        Spacer()
                        if project?.viewerCanUpdate == true {
                            Button {
                                Task { _ = await store.removeLabel(from: item, name: label.name) }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove label")
                        }
                    }
                }
            }

            if project?.viewerCanUpdate == true {
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

    private func fieldSection(project: Project, item: ProjectItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project Fields")
                .font(.headline)

            ForEach(project.fields.filter(\.isEditable)) { field in
                ProjectFieldEditor(
                    field: field,
                    value: item.fieldValues[field.id],
                    isEditable: project.viewerCanUpdate && isWorking == false
                ) { value in
                    isWorking = true
                    _ = await store.updateField(on: item, field: field, value: value)
                    isWorking = false
                }
            }
        }
    }

    private func itemMetadata(_ item: ProjectItem) -> String {
        let repository = item.repositoryName ?? "Draft item"
        if let number = item.number { return "\(repository) #\(number)" }
        return repository
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
            if await store.addLabel(to: item, name: name) {
                labelName = ""
            }
        }
    }

    private func archive(_ item: ProjectItem) {
        isWorking = true
        Task {
            let succeeded = await store.archiveItem(item)
            isWorking = false
            if succeeded { dismiss() }
        }
    }
}

private struct ProjectFieldEditor: View {
    let field: ProjectField
    let value: ProjectFieldValue?
    let isEditable: Bool
    let update: (ProjectFieldValue?) async -> Void

    @State private var draftValue = ""
    @State private var draftDate = Date()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(field.name)
                .frame(width: 120, alignment: .leading)
                .foregroundStyle(.secondary)

            editor
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: value) {
            draftValue = displayValue
            if case .date(let value) = value, let date = parseDate(value) {
                draftDate = date
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch field.kind {
        case .singleSelect:
            Menu {
                Button("None") { set(nil) }
                Divider()
                ForEach(field.options) { option in
                    Button(option.name) {
                        set(.singleSelect(optionId: option.id, name: option.name))
                    }
                }
            } label: {
                valueLabel
            }
            .disabled(!isEditable)

        case .iteration:
            Menu {
                Button("None") { set(nil) }
                Divider()
                ForEach(field.iterations) { iteration in
                    Button(iteration.title) {
                        set(.iteration(id: iteration.id, title: iteration.title))
                    }
                }
            } label: {
                valueLabel
            }
            .disabled(!isEditable)

        case .date:
            HStack {
                DatePicker("Date", selection: $draftDate, displayedComponents: .date)
                    .labelsHidden()
                    .disabled(!isEditable)
                Button("Save") { set(.date(formatDate(draftDate))) }
                    .disabled(!isEditable || formatDate(draftDate) == displayValue)
                if value != nil {
                    clearButton
                }
            }

        case .number, .text:
            HStack {
                TextField("None", text: $draftValue)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isEditable)
                Button("Save") { saveDraft() }
                    .disabled(!isEditable || draftValue == displayValue || invalidNumber)
                if value != nil {
                    clearButton
                }
            }

        case .unsupported:
            Text(displayValue.isEmpty ? "Not supported" : displayValue)
                .foregroundStyle(.secondary)
        }
    }

    private var valueLabel: some View {
        HStack(spacing: 6) {
            Text(displayValue.isEmpty ? "None" : displayValue)
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
    }

    private var displayValue: String {
        switch value {
        case .singleSelect(_, let name): return name
        case .iteration(_, let title): return title
        case .date(let value): return value
        case .number(let value): return value.formatted()
        case .text(let value): return value
        case nil: return ""
        }
    }

    private var invalidNumber: Bool {
        field.kind == .number
            && draftValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && Double(draftValue) == nil
    }

    private var clearButton: some View {
        Button {
            set(nil)
        } label: {
            Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .disabled(!isEditable)
        .help("Clear field")
    }

    private func saveDraft() {
        let trimmed = draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            set(nil)
            return
        }
        switch field.kind {
        case .number:
            guard let number = Double(trimmed) else { return }
            set(.number(number))
        case .text:
            set(.text(trimmed))
        default:
            break
        }
    }

    private func parseDate(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
        )
    }

    private func formatDate(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func set(_ value: ProjectFieldValue?) {
        Task { await update(value) }
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
