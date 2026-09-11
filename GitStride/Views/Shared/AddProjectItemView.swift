import AppKit
import SwiftUI

struct AddProjectItemView: View {
    static let sheetWidth: CGFloat = 620
    private static let sheetHeight: CGFloat = 520
    private static let horizontalPadding: CGFloat = 48
    private static let labelWidth: CGFloat = 88
    private static let fieldSpacing: CGFloat = 12
    static let windowDefaultSize = CGSize(width: sheetWidth, height: sheetHeight)
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
    @State private var selectedResultID: String?
    @State private var showsSearchHelp = false
    @State private var maximumSheetHeight: CGFloat?
    @State private var searchPhase: SearchPhase = .idle
    @State private var searchTask: Task<Void, Never>?
    @State private var isWorking = false
    @State private var usesQuickEntry = false
    @State private var showsQuickEntryHelp = false
    @State private var validationMessage: String?
    @State private var repositoryValidationMessage: String?
    @State private var pendingCreatedIssue: PendingCreatedIssue?
    @FocusState private var focusedField: Field?

    init(store: ProjectStore, presentation: Presentation = .sheet) {
        self.store = store
        self.presentation = presentation
    }

    private enum Mode {
        case create
        case existing
    }

    private enum NewItemType: String, CaseIterable, Identifiable {
        case issue = "Issue"
        case draft = "Draft"

        var id: Self { self }
    }

    private enum Field {
        case title
        case quickEntry
    }

    private enum SearchPhase {
        case idle
        case searching
        case finished(query: String)
        case failed(message: String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch mode {
                case .create:
                    newItemPane
                case .existing:
                    existingItemForm
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .disabled(isWorking)

            Divider()
            actionBar
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
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            Button("Submit Item", action: performPrimaryAction)
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
        .task {
            if let screen = NSApp.keyWindow?.screen {
                maximumSheetHeight = screen.visibleFrame.height - 80
            }
            validationMessage = nil
            if repository.isEmpty {
                repository = store.repositorySuggestions.first ?? ""
            }
            updateStatusSelection()
            focusedField = .title
        }
        .onChange(of: store.selectedProjectId) { _, _ in
            guard presentation == .window else { return }
            repository = store.repositorySuggestions.first ?? ""
            status = defaultStatus
            priority = ""
        }
        .onChange(of: statusOptions) { _, _ in
            updateStatusSelection()
        }
        .onChange(of: mode) { _, newMode in
            cancelSearch()
            validationMessage = nil
            switch newMode {
            case .create:
                focusedField = usesQuickEntry ? .quickEntry : .title
            case .existing:
                focusedField = nil
            }
        }
        .onChange(of: usesQuickEntry) { _, isQuickEntry in
            validationMessage = nil
            focusedField = isQuickEntry ? .quickEntry : .title
        }
        .onChange(of: repository) { _, _ in
            repositoryValidationMessage = nil
        }
        .onChange(of: quickEntry) { _, _ in
            if mode == .create, usesQuickEntry {
                validationMessage = nil
            }
        }
        .onDisappear {
            cancelSearch()
        }
    }

    private var sheetTitle: String {
        if let project = store.selectedProject {
            return "Add Item to “\(project.title)”"
        }
        return "Add Item to Project"
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                if presentation == .sheet {
                    Text(sheetTitle)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(sheetTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Project")
                        .foregroundStyle(.secondary)
                    ProjectSelectorView(store: store)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Picker("Item source", selection: $mode) {
                Text("Create New").tag(Mode.create)
                Text("Add Existing").tag(Mode.existing)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .disabled(isWorking)
    }

    private var preferredSheetHeight: CGFloat {
        min(Self.sheetHeight, maximumSheetHeight ?? Self.sheetHeight)
    }

    private var newItemPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if usesQuickEntry {
                    quickEntryForm
                } else {
                    createForm
                }

                if usesQuickEntry == false, let message = validationMessage {
                    validationNotice(message)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .defaultScrollAnchor(.top)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var createForm: some View {
        Grid(alignment: .leading, horizontalSpacing: Self.fieldSpacing, verticalSpacing: 14) {
            if itemType == .issue {
                GridRow(alignment: .firstTextBaseline) {
                    fieldLabel("Repository")
                    VStack(alignment: .leading, spacing: 6) {
                        RepositoryComboBox(
                            text: $repository,
                            repositories: store.repositorySuggestions
                        )
                        if let message = repositoryValidationMessage {
                            validationNotice(message)
                        }
                    }
                }
            }

            GridRow(alignment: .firstTextBaseline) {
                fieldLabel("Type")
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    Picker("Type", selection: $itemType) {
                        ForEach(NewItemType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    if itemType == .issue, statusOptions.isEmpty == false {
                        HStack(alignment: .firstTextBaseline, spacing: Self.fieldSpacing) {
                            Text("Status")
                                .fixedSize()
                            statusPicker
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GridRow(alignment: .firstTextBaseline) {
                fieldLabel("Title")
                TextField(itemType == .issue ? "Issue title" : "Draft title", text: $title)
                    .accessibilityLabel("Title, required")
                    .focused($focusedField, equals: .title)
            }

            GridRow(alignment: .top) {
                VStack(alignment: .trailing, spacing: 2) {
                    fieldLabel("Description")
                    Text("Optional")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Description", text: $bodyText, axis: .vertical)
                    .lineLimit(4...6)
                    .accessibilityLabel("Description, optional")
            }

            if itemType == .issue {
                GridRow(alignment: .firstTextBaseline) {
                    fieldLabel("Labels")
                    LabelTokenField(text: $labels, suggestions: labelSuggestions)
                }

                GridRow(alignment: .firstTextBaseline) {
                    fieldLabel("Assignees")
                    HStack(alignment: .firstTextBaseline, spacing: Self.fieldSpacing) {
                        TextField("\(store.currentUserLogin ?? "username"), @me", text: $assignees)
                            .accessibilityLabel("Assignees")
                            .accessibilityHint("Separate usernames with commas. Use @me for yourself.")
                            .help("Separate usernames with commas. Use @me for yourself.")
                            .frame(maxWidth: .infinity)

                        Button("Assign to me") {
                            assignees = (commaSeparated(assignees) + ["@me"]).joined(separator: ", ")
                        }
                        .buttonStyle(.link)
                        .fixedSize()
                        .disabled(hasCurrentUserAssignee)
                    }
                }

                if priorityOptions.isEmpty == false {
                    GridRow(alignment: .firstTextBaseline) {
                        fieldLabel("Priority")
                        priorityPicker.labelsHidden()
                    }
                }
            }
        }
        .pickerStyle(.menu)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .frame(width: Self.labelWidth, alignment: .trailing)
    }

    private var statusPicker: some View {
        Picker("Status", selection: $status) {
            if status.isEmpty {
                Text("Choose Status").tag("").disabled(true)
            }
            ForEach(statusOptions, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .labelsHidden()
        .accessibilityLabel("Status, required")
        .help(status.isEmpty ? "Choose Status" : status)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var priorityPicker: some View {
        Picker("Priority", selection: $priority) {
            Text("Not set").tag("")
            ForEach(priorityOptions, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var labelSuggestions: [String] {
        let items = store.selectedProject?.items ?? []
        return Array(Set(items.filter {
            $0.repositoryName?.caseInsensitiveCompare(repository.trimmed) == .orderedSame
        }.flatMap { $0.labels.map(\.name) })).sorted()
    }

    private var quickEntryForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe the item")
                .font(.subheadline)

            TextField("Title and qualifiers", text: $quickEntry)
                .accessibilityLabel("Quick Entry")
                .focused($focusedField, equals: .quickEntry)
                .onSubmit(applyQuickEntry)

            if let message = validationMessage {
                validationNotice(message)
            }

            Text("Example: Fix login @me #bug")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Review the details before creating the item.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Syntax Help", systemImage: "questionmark.circle") {
                showsQuickEntryHelp = true
            }
            .buttonStyle(.link)
            .font(.caption)
            .popover(isPresented: $showsQuickEntryHelp) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Entry Syntax")
                        .font(.headline)
                    Text("Start with a title, then add any of these qualifiers:")
                    Text("repo:owner/repo\nstatus:Todo\npriority:High\n@me or @username\n#bug")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text(
                        "Use the status and priority names from your project. For names with spaces, select the value in the full form instead."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(width: 300)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var existingItemForm: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ItemSearchField(
                        text: Binding(get: { query }, set: { updateSearchQuery($0) }),
                        onSubmit: searchItems
                    )

                    Button("Search Syntax", systemImage: "questionmark.circle") {
                        showsSearchHelp = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Search syntax")
                    .popover(isPresented: $showsSearchHelp) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("GitHub Search").font(.headline)
                            Text("Paste an issue or pull request URL, or enter keywords and press Return.")
                            Text("repo:owner/name is:open\nis:issue label:bug\nis:pr author:@me")
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                        .frame(width: 320)
                    }
                }

                Text("Press Return to search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Self.horizontalPadding)

            if let message = validationMessage {
                validationNotice(message)
                    .padding(.horizontal, Self.horizontalPadding)
            }

            Group {
                switch searchPhase {
                case .idle:
                    repositorySearchSuggestions
                case .searching:
                    ProgressView(isItemURL ? "Loading item…" : "Searching…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .finished(let searchedQuery):
                    if results.isEmpty {
                        ContentUnavailableView {
                            Label("No Results", systemImage: "magnifyingglass")
                        } description: {
                            Text("No matches for “\(searchedQuery)”. Try different keywords or fewer qualifiers.")
                        }
                    } else {
                        searchResults
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Search Couldn't Complete", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message).textSelection(.enabled)
                    } actions: {
                        Button("Try Again", action: searchItems)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var repositorySearchSuggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search in a Repository")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.horizontalPadding)

            if store.repositorySuggestions.isEmpty == false {
                List(store.repositorySuggestions, id: \.self) { repository in
                    Button {
                        updateSearchQuery("repo:\(repository) is:open")
                        searchItems()
                    } label: {
                        Label(repository, systemImage: "folder")
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Search open issues and pull requests in this repository.")
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: Self.horizontalPadding,
                        bottom: 0,
                        trailing: Self.horizontalPadding
                    ))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No repository suggestions yet.")
                    Text("Paste a GitHub URL or enter a search.")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.horizontalPadding)
            }
        }
    }

    private var selectedResult: GitHubItemCandidate? {
        results.first { $0.id == selectedResultID }
    }

    private var searchResults: some View {
        List(results, selection: $selectedResultID) { item in
            HStack(spacing: 10) {
                Image(
                    systemName: item.contentType == .pullRequest
                        ? "arrow.triangle.pull"
                        : "record.circle"
                )
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
                }
            }
            .padding(.vertical, 3)
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: Self.horizontalPadding,
                bottom: 0,
                trailing: Self.horizontalPadding
            ))
            .tag(item.id)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if mode == .create {
                Button(usesQuickEntry ? "Show Full Form" : "Quick Entry…") {
                    usesQuickEntry.toggle()
                }
                .disabled(isWorking)
            }

            if isWorking, isSearching == false {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }

            Spacer()

            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)

            switch mode {
            case .create:
                if usesQuickEntry {
                    Button("Review Details", action: applyQuickEntry)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || quickEntry.trimmed.isEmpty)
                } else {
                    Button(createActionTitle, action: createItem)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(createActionIsDisabled)
                }
            case .existing:
                Button("Add Item", action: addSelectedItem)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(addActionIsDisabled)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 14)
    }

    private var addActionIsDisabled: Bool {
        guard let selectedResult else { return true }
        return isWorking || isSearching || isAlreadyAdded(selectedResult)
    }

    private func addSelectedItem() {
        guard addActionIsDisabled == false, let selectedResult else { return }
        add(selectedResult)
    }

    private func performPrimaryAction() {
        switch mode {
        case .create:
            if usesQuickEntry {
                applyQuickEntry()
            } else if createActionIsDisabled == false {
                createItem()
            }
        case .existing:
            addSelectedItem()
        }
    }

    private var createActionTitle: String {
        if pendingCreatedIssue != nil { return "Retry Project Fields" }
        return itemType == .issue ? "Create Issue" : "Create Draft"
    }

    private var createActionIsDisabled: Bool {
        if pendingCreatedIssue != nil { return isWorking }
        return isWorking || title.trimmed.isEmpty
            || (itemType == .issue && (repository.trimmed.isEmpty || needsStatusSelection))
    }

    private var isSearching: Bool {
        if case .searching = searchPhase { return true }
        return false
    }

    private func validationNotice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var statusOptions: [String] {
        store.selectedProject?.statusOptions.map(\.name) ?? []
    }

    private var defaultStatus: String {
        statusOptions.first { $0.caseInsensitiveCompare("Todo") == .orderedSame } ?? ""
    }

    private var needsStatusSelection: Bool {
        statusOptions.isEmpty == false && statusOptions.contains(status) == false
    }

    private func updateStatusSelection() {
        if statusOptions.contains(status) == false {
            status = defaultStatus
        }
    }

    private var priorityOptions: [String] {
        guard let field = store.selectedProject?.fields.first(where: {
            $0.kind == .singleSelect && $0.name.caseInsensitiveCompare("Priority") == .orderedSame
        }) else { return [] }
        return field.options.map(\.name)
    }

    private var isItemURL: Bool {
        guard let components = URLComponents(string: query.trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com" else { return false }
        let path = components.path.split(separator: "/")
        return path.count == 4 && (path[2] == "issues" || path[2] == "pull") && Int(path[3]) != nil
    }

    private func createItem() {
        guard createActionIsDisabled == false else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        isWorking = true
        validationMessage = nil
        repositoryValidationMessage = nil
        Task {
            do {
                if let pendingCreatedIssue {
                    try await store.finishCreatedIssue(pendingCreatedIssue)
                } else if itemType == .draft {
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
            } catch let pending as PendingCreatedIssue {
                pendingCreatedIssue = pending
                validationMessage = pending.localizedDescription
            } catch GitHubError.invalidRepository {
                repositoryValidationMessage = "Use owner/repository, for example octocat/hello-world."
            } catch is CancellationError {
            } catch {
                validationMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        if isSearching { searchPhase = .idle }
    }

    private func updateSearchQuery(_ value: String) {
        guard query != value else { return }
        query = value
        cancelSearch()
        results = []
        selectedResultID = nil
        searchPhase = .idle
        validationMessage = nil
        if isItemURL { searchItems() }
    }

    private func searchItems() {
        guard isWorking == false, query.trimmed.isEmpty == false else { return }
        cancelSearch()
        let submittedQuery = query.trimmed
        let loadsURL = isItemURL
        validationMessage = nil
        results = []
        selectedResultID = nil
        searchPhase = .searching
        searchTask = Task {
            do {
                let matches: [GitHubItemCandidate]
                if loadsURL {
                    matches = [try await store.resolveItem(url: submittedQuery)]
                } else {
                    matches = try await store.searchItems(query: submittedQuery)
                }
                try Task.checkCancellation()
                results = matches
                searchPhase = .finished(query: submittedQuery)
                if loadsURL { selectedResultID = matches.first?.id }
            } catch {
                guard Task.isCancelled == false else { return }
                searchPhase = .failed(message: error.localizedDescription)
            }
            searchTask = nil
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

    private var hasCurrentUserAssignee: Bool {
        let currentUser = normalizeAssignee("@me")
        return commaSeparated(assignees).contains {
            normalizeAssignee($0).caseInsensitiveCompare(currentUser) == .orderedSame
        }
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
        if request.status != nil {
            status = matchedStatus ?? ""
        }
        priority = matchedPriority ?? ""

        var unavailableOptions: [String] = []
        if let requestedStatus = request.status, matchedStatus == nil {
            unavailableOptions.append("status \(requestedStatus)")
        }
        if let requestedPriority = request.priority, matchedPriority == nil {
            unavailableOptions.append("priority \(requestedPriority)")
        }

        if unavailableOptions.isEmpty {
            usesQuickEntry = false
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

private struct ItemSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusedSearchField()
        field.placeholderString = "GitHub URL or search query"
        field.setAccessibilityLabel("GitHub URL or search issues and pull requests")
        field.sendsWholeSearchString = true
        field.maximumRecents = 0
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: nsView.intrinsicContentSize.height)
    }

    private final class FocusedSearchField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        @objc func submit(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
            onSubmit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            onSubmit()
            return true
        }
    }
}

private struct LabelTokenField: NSViewRepresentable {
    @Binding var text: String
    let suggestions: [String]
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.placeholderString = "bug, enhancement"
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        field.setAccessibilityLabel("Labels")
        field.setAccessibilityHelp("Type a label, then press comma or Return. Suggestions come from this project's loaded items.")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.suggestions = suggestions
        if context.coordinator.lastText != text {
            field.objectValue = text.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
            context.coordinator.lastText = text
        }
        field.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTokenField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var text: Binding<String>
        var suggestions: [String] = []
        var lastText: String?

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            updateText(from: field)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            field.validateEditing()
            updateText(from: field)
        }

        private func updateText(from field: NSTokenField) {
            let value = (field.objectValue as? [String] ?? []).joined(separator: ", ")
            lastText = value
            text.wrappedValue = value
        }

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            selectedIndex?.pointee = -1
            return suggestions.filter { $0.localizedStandardContains(substring) }
        }
    }
}

private struct RepositoryComboBox: NSViewRepresentable {
    @Binding var text: String
    let repositories: [String]
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.delegate = context.coordinator
        comboBox.placeholderString = "owner/repository"
        comboBox.completes = true
        comboBox.hasVerticalScroller = true
        comboBox.numberOfVisibleItems = 8
        comboBox.font = .systemFont(ofSize: NSFont.systemFontSize)
        comboBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        comboBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        comboBox.setAccessibilityLabel("Repository, required")
        comboBox.toolTip = "Choose a repository used in this project, or type owner/repository."
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.text = $text
        if context.coordinator.repositories != repositories {
            context.coordinator.repositories = repositories
            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: repositories)
        }
        if comboBox.stringValue != text {
            comboBox.stringValue = text
        }
        comboBox.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSComboBox, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.intrinsicContentSize.width,
            height: nsView.intrinsicContentSize.height
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var text: Binding<String>
        var repositories: [String] = []

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            text.wrappedValue = comboBox.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox,
                  let repository = comboBox.objectValueOfSelectedItem as? String else { return }
            text.wrappedValue = repository
        }
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
