import SwiftUI

struct AddProjectItemView: View {
    static let sheetWidth: CGFloat = 560
    static let windowDefaultSize = CGSize(width: 560, height: 620)
    static let windowMinimumSize = CGSize(width: 520, height: 500)

    enum Presentation {
        case sheet
        case window
    }

    @Bindable var store: ProjectStore
    let presentation: Presentation

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var mode: Mode = .create
    @State private var itemType: NewItemType = .issue
    @State private var repository = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var quickEntry = ""
    @State private var status = ""
    @State private var priority = ""
    @State private var labels = ""
    @State private var assignees = ""
    @State private var query = ""
    @State private var results: [GitHubItemCandidate] = []
    @State private var isWorking = false
    @State private var showsMoreOptions = false
    @State private var validationMessage: String?
    @FocusState private var focusedField: Field?

    init(store: ProjectStore, presentation: Presentation = .sheet) {
        self.store = store
        self.presentation = presentation
    }

    private enum Mode: String, CaseIterable, Identifiable {
        case create = "New Item"
        case existing = "Existing Item"
        case quickEntry = "Quick Entry"

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
        case quickEntry
    }

    var body: some View {
        VStack(spacing: 0) {
            if presentation == .sheet {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add to Project")
                        .font(.headline)
                    Text(store.selectedProject?.title ?? "No project selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                Divider()
            }

            VStack(alignment: .leading, spacing: 14) {
                if presentation == .window {
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Project")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            ProjectSelectorView(store: store)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: 160, alignment: .leading)

                        Spacer(minLength: 12)

                        Picker("Item source", selection: $mode) {
                            ForEach(Mode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                } else {
                    Picker("Item source", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 20)
                }

                Group {
                    switch mode {
                    case .create:
                        createForm
                    case .existing:
                        existingItemForm
                            .padding(.horizontal, 20)
                    case .quickEntry:
                        quickEntryForm
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if let message = validationMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if presentation == .sheet || mode != .existing {
                Divider()
                actionBar
            }
        }
        .frame(
            width: presentation == .sheet ? Self.sheetWidth : nil,
            height: presentation == .sheet ? preferredSheetHeight : nil
        )
        .frame(
            minWidth: presentation == .window ? Self.windowMinimumSize.width : nil,
            idealWidth: presentation == .window ? Self.windowDefaultSize.width : nil,
            minHeight: presentation == .window ? Self.windowMinimumSize.height : nil,
            idealHeight: presentation == .window ? Self.windowDefaultSize.height : nil
        )
        .task {
            validationMessage = nil
            if repository.isEmpty {
                repository = store.repositorySuggestions.first ?? ""
            }
            focusedField = .title
        }
        .onChange(of: store.selectedProjectId) { _, _ in
            guard presentation == .window else { return }
            repository = store.repositorySuggestions.first ?? ""
            status = ""
            priority = ""
        }
        .onChange(of: mode) { _, newMode in
            validationMessage = nil
            switch newMode {
            case .create:
                focusedField = .title
            case .existing:
                focusedField = .query
            case .quickEntry:
                focusedField = .quickEntry
            }
        }
    }

    private var createForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Type")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Picker("Type", selection: $itemType) {
                            ForEach(NewItemType.allCases) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 132, alignment: .leading)
                    }

                    if itemType == .issue {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Repository")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                TextField("owner/repository", text: $repository)
                                    .accessibilityLabel("Repository")

                                if store.repositorySuggestions.isEmpty == false {
                                    Menu("Recent") {
                                        ForEach(store.repositorySuggestions, id: \.self) { repository in
                                            Button(repository) { self.repository = repository }
                                        }
                                    }
                                    .fixedSize()
                                    .help("Repositories already used in this project")
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text("Title")
                            .font(.subheadline)
                        Text("Required")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Enter a title", text: $title)
                        .accessibilityLabel("Title, required")
                        .focused($focusedField, equals: .title)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text("Description")
                            .font(.subheadline)
                        Text("Optional")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField(
                        "Add context, acceptance criteria, or implementation notes",
                        text: $bodyText,
                        axis: .vertical
                    )
                    .lineLimit(4...8)
                    .accessibilityLabel("Description, optional")
                }

                if itemType == .issue {
                    DisclosureGroup("Issue Options", isExpanded: $showsMoreOptions) {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Labels")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                TextField("bug, enhancement", text: $labels)
                                    .accessibilityLabel("Labels")
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Assignees")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                TextField("octocat, @me", text: $assignees)
                                    .accessibilityLabel("Assignees")
                            }

                            HStack(alignment: .top, spacing: 12) {
                                if statusOptions.isEmpty == false {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Status")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)

                                        Picker("Status", selection: $status) {
                                            Text("None").tag("")
                                            ForEach(statusOptions, id: \.self) { option in
                                                Text(option).tag(option)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .labelsHidden()
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }

                                if priorityOptions.isEmpty == false {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Priority")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)

                                        Picker("Priority", selection: $priority) {
                                            Text("None").tag("")
                                            ForEach(priorityOptions, id: \.self) { option in
                                                Text(option).tag(option)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .labelsHidden()
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
                }
            }
        }
        .scrollIndicators(.automatic)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .disabled(isWorking)
    }

    private var quickEntryForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Describe the item")
                    .font(.subheadline)

                TextField("Title and qualifiers", text: $quickEntry)
                    .accessibilityLabel("Quick Entry")
                    .focused($focusedField, equals: .quickEntry)
                    .onSubmit(applyQuickEntry)

                Text("Example: Fix login repo:owner/repo status:Todo priority:High @me #bug")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .disabled(isWorking)
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
        .disabled(isWorking)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }

            Spacer()

            if presentation == .sheet {
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
            }

            switch mode {
            case .create:
                Button(itemType == .issue ? "Create Issue" : "Create Draft", action: createItem)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(createActionIsDisabled)
            case .quickEntry:
                Button("Apply to Form", action: applyQuickEntry)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || quickEntry.trimmed.isEmpty)
            case .existing:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var createActionIsDisabled: Bool {
        isWorking || title.trimmed.isEmpty || (itemType == .issue && repository.trimmed.isEmpty)
    }

    private var preferredSheetHeight: CGFloat {
        switch mode {
        case .create:
            return showsMoreOptions ? 700 : 560
        case .existing, .quickEntry:
            return 560
        }
    }

    private var statusOptions: [String] {
        store.selectedProject?.statusOptions.map(\.name) ?? []
    }

    private var priorityOptions: [String] {
        guard let field = store.selectedProject?.fields.first(where: {
            $0.kind == .singleSelect && $0.name.caseInsensitiveCompare("Priority") == .orderedSame
        }) else { return [] }
        return field.options.map(\.name)
    }

    private var isItemURL: Bool {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("https://github.com/")
    }

    private func createItem() {
        guard isWorking == false else { return }
        isWorking = true
        validationMessage = nil
        Task {
            do {
                if itemType == .draft {
                    try await store.createDraftIssue(
                        title: title.trimmed,
                        body: bodyText
                    )
                } else {
                    try await store.createIssueAndAdd(
                        repository: repository.trimmed,
                        title: title.trimmed,
                        body: bodyText,
                        labels: commaSeparated(labels),
                        assignees: commaSeparated(assignees).map(normalizeAssignee),
                        status: status.trimmed.nilIfEmpty,
                        priority: priority.trimmed.nilIfEmpty
                    )
                }
                close()
            } catch is CancellationError {
            } catch {
                validationMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func searchOrAdd() {
        guard isWorking == false else { return }
        if isItemURL {
            addURL()
        } else {
            isWorking = true
            validationMessage = nil
            Task {
                do {
                    results = try await store.searchItems(query: query.trimmed)
                } catch is CancellationError {
                    // Closing the sheet cancels the search.
                } catch {
                    validationMessage = error.localizedDescription
                }
                isWorking = false
            }
        }
    }

    private func addURL() {
        isWorking = true
        validationMessage = nil
        Task {
            do {
                try await store.addExistingItem(url: query.trimmed)
                close()
            } catch is CancellationError {
            } catch {
                validationMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func add(_ item: GitHubItemCandidate) {
        guard isWorking == false else { return }
        isWorking = true
        validationMessage = nil
        Task {
            do {
                try await store.addExistingItem(item)
                close()
            } catch is CancellationError {
            } catch {
                validationMessage = error.localizedDescription
            }
            isWorking = false
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

    private func applyQuickEntry() {
        guard isWorking == false else { return }
        validationMessage = nil
        let request = QuickCreateParser.parse(quickEntry)
        guard request.title.isEmpty == false else {
            validationMessage = "Quick Entry needs a title."
            return
        }

        title = request.title
        if let requestedRepository = request.repository {
            repository = resolvedRepository(requestedRepository)
        }
        labels = request.labels.joined(separator: ", ")
        assignees = request.assignees.map { "@\($0)" }.joined(separator: ", ")
        let matchedStatus = matchedOption(request.status, in: statusOptions)
        let matchedPriority = matchedOption(request.priority, in: priorityOptions)
        status = matchedStatus ?? ""
        priority = matchedPriority ?? ""
        showsMoreOptions = request.labels.isEmpty == false
            || request.assignees.isEmpty == false
            || request.status != nil
            || request.priority != nil

        var unavailableOptions: [String] = []
        if let requestedStatus = request.status, matchedStatus == nil {
            unavailableOptions.append("status \(requestedStatus)")
        }
        if let requestedPriority = request.priority, matchedPriority == nil {
            unavailableOptions.append("priority \(requestedPriority)")
        }

        if unavailableOptions.isEmpty {
            mode = .create
            focusedField = .title
        } else {
            validationMessage = "Unavailable project option: \(unavailableOptions.joined(separator: ", "))."
        }
    }

    private func matchedOption(_ requestedValue: String?, in options: [String]) -> String? {
        guard let requestedValue else { return nil }
        return options.first {
            $0.caseInsensitiveCompare(requestedValue) == .orderedSame
        }
    }

    private func close() {
        switch presentation {
        case .sheet:
            dismiss()
        case .window:
            dismissWindow(id: "quick-add")
        }
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
