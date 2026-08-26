import SwiftUI

struct AddProjectItemView: View {
    @Bindable var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .create
    @State private var itemType: NewItemType = .issue
    @State private var repository = ""
    @State private var title = ""
    @State private var quickEntry = ""
    @State private var status = ""
    @State private var priority = ""
    @State private var labels = ""
    @State private var assignees = ""
    @State private var query = ""
    @State private var results: [GitHubItemCandidate] = []
    @State private var isWorking = false
    @FocusState private var focusedField: Field?

    private enum Mode: String, CaseIterable, Identifiable {
        case create = "Create"
        case existing = "Add Existing"

        var id: Self { self }
    }

    private enum NewItemType: String, CaseIterable, Identifiable {
        case issue = "Issue"
        case draft = "Draft"

        var id: Self { self }
    }

    private enum Field {
        case title
        case query
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add to Project")
                        .font(.title3.bold())
                    Text(store.selectedProject?.title ?? "No project selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch mode {
                case .create:
                    createForm
                case .existing:
                    existingItemForm
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if let message = store.operationErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .task {
            store.clearOperationError()
            if repository.isEmpty {
                repository = store.repositorySuggestions.first ?? ""
            }
            focusedField = .title
        }
        .onChange(of: mode) { _, newMode in
            store.clearOperationError()
            focusedField = newMode == .create ? .title : .query
        }
        .onDisappear {
            store.clearOperationError()
        }
    }

    private var createForm: some View {
        Form {
            LabeledContent("Quick Entry") {
                TextField("> title repo:owner/repo status:Todo priority:High @me #bug", text: $quickEntry)
                    .onSubmit { submitQuickEntry() }
            }

            Text("Press Return to parse and create. Qualifier values are matched without case sensitivity.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Create as", selection: $itemType) {
                ForEach(NewItemType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.radioGroup)

            if itemType == .issue {
                LabeledContent("Repository") {
                    HStack {
                        TextField("owner/repository", text: $repository)
                        if store.repositorySuggestions.isEmpty == false {
                            Menu {
                                ForEach(store.repositorySuggestions, id: \.self) { repository in
                                    Button(repository) { self.repository = repository }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Repositories already used in this project")
                        }
                    }
                }
            }

            LabeledContent("Title") {
                TextField("Required", text: $title)
                    .focused($focusedField, equals: .title)
            }

            if itemType == .issue {
                LabeledContent("Labels") {
                    TextField("bug, enhancement", text: $labels)
                }
                LabeledContent("Assignees") {
                    TextField("octocat, @me", text: $assignees)
                }
                LabeledContent("Status") {
                    TextField("Optional Project option", text: $status)
                }
                LabeledContent("Priority") {
                    TextField("Optional Project option", text: $priority)
                }
            }

            HStack {
                Spacer()
                Button(itemType == .issue ? "Create and Add" : "Create Draft") {
                    createItem()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (itemType == .issue && repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .formStyle(.grouped)
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var existingItemForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("GitHub URL or search query", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .query)
                    .onSubmit { searchOrAdd() }

                Button(isItemURL ? "Add URL" : "Search") {
                    searchOrAdd()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Search accepts GitHub qualifiers such as repo:owner/name and is:open.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if results.isEmpty {
                ContentUnavailableView(
                    "Find an Issue or Pull Request",
                    systemImage: "text.magnifyingglass",
                    description: Text("Paste its GitHub URL to add it directly, or search across accessible repositories.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.contentType == .pullRequest
                            ? "arrow.triangle.pull"
                            : "record.circle")
                            .foregroundStyle(item.contentType == .pullRequest ? .purple : .green)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .lineLimit(2)
                            Text("\(item.repository) #\(item.number)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if isAlreadyAdded(item) {
                            Text("Added")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Add") { add(item) }
                                .disabled(isWorking)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .overlay {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var isItemURL: Bool {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("https://github.com/")
    }

    private func createItem() {
        guard isWorking == false else { return }
        isWorking = true
        Task {
            let succeeded: Bool
            if itemType == .draft {
                succeeded = await store.createDraftIssue(title: title.trimmed)
            } else {
                succeeded = await store.createIssueAndAdd(
                    repository: repository.trimmed,
                    title: title.trimmed,
                    labels: commaSeparated(labels),
                    assignees: commaSeparated(assignees).map(normalizeAssignee),
                    status: status.trimmed.nilIfEmpty,
                    priority: priority.trimmed.nilIfEmpty
                )
            }
            isWorking = false
            if succeeded { dismiss() }
        }
    }

    private func searchOrAdd() {
        guard isWorking == false else { return }
        if isItemURL {
            addURL()
        } else {
            isWorking = true
            Task {
                results = await store.searchItems(query: query.trimmed)
                isWorking = false
            }
        }
    }

    private func addURL() {
        isWorking = true
        Task {
            let succeeded = await store.addExistingItem(url: query.trimmed)
            isWorking = false
            if succeeded { dismiss() }
        }
    }

    private func add(_ item: GitHubItemCandidate) {
        guard isWorking == false else { return }
        isWorking = true
        Task {
            let succeeded = await store.addExistingItem(item)
            isWorking = false
            if succeeded { dismiss() }
        }
    }

    private func isAlreadyAdded(_ item: GitHubItemCandidate) -> Bool {
        store.selectedProject?.items.contains { $0.contentId == item.id } == true
    }

    private func commaSeparated(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private func normalizeAssignee(_ value: String) -> String {
        let login = value.hasPrefix("@") ? String(value.dropFirst()) : value
        if login.lowercased() == "me", let currentUserLogin = store.currentUserLogin {
            return currentUserLogin
        }
        return login
    }

    private func submitQuickEntry() {
        guard isWorking == false else { return }
        let request = QuickCreateParser.parse(quickEntry)
        guard request.title.isEmpty == false else {
            store.operationErrorMessage = "Quick Entry needs a title."
            return
        }

        title = request.title
        if let requestedRepository = request.repository {
            repository = resolvedRepository(requestedRepository)
        }
        labels = request.labels.joined(separator: ", ")
        assignees = request.assignees.map { "@\($0)" }.joined(separator: ", ")
        status = request.status ?? ""
        priority = request.priority ?? ""
        createItem()
    }

    private func resolvedRepository(_ value: String) -> String {
        guard value.contains("/") == false else { return value }
        let matches = store.repositorySuggestions.filter {
            $0.split(separator: "/").last?.caseInsensitiveCompare(value) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : value
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
