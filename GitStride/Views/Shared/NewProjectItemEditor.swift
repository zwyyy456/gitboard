import SwiftUI

struct NewProjectItemDraft {
    enum ItemType: String, CaseIterable, Identifiable {
        case issue = "Issue"
        case draft = "Draft"

        var title: String {
            switch self {
            case .issue: String(localized: "Issue")
            case .draft: String(localized: "Draft")
            }
        }

        var id: Self { self }
    }

    var itemType: ItemType = .issue
    var repository = ""
    var title = ""
    var bodyText = ""
    var quickEntry = ""
    var status = ""
    var priority = ""
    var labels = ""
    var assignees = ""
    var usesQuickEntry = false
    var repositoryValidationMessage: String?

    var labelNames: [String] { Self.commaSeparated(labels) }

    func assigneeLogins(currentUser: String?) -> [String] {
        Self.commaSeparated(assignees).map { Self.normalizeAssignee($0, currentUser: currentUser) }
    }

    func hasCurrentUserAssignee(currentUser: String?) -> Bool {
        let login = Self.normalizeAssignee("@me", currentUser: currentUser)
        return assigneeLogins(currentUser: currentUser).contains { $0.caseInsensitiveCompare(login) == .orderedSame }
    }

    mutating func assignToMe() {
        assignees = (Self.commaSeparated(assignees) + ["@me"]).joined(separator: ", ")
    }

    private static func commaSeparated(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeAssignee(_ value: String, currentUser: String?) -> String {
        let login = value.hasPrefix("@") ? String(value.dropFirst()) : value
        return login.lowercased() == "me" ? (currentUser ?? login) : login
    }

    mutating func reviewQuickEntry(repositories: [String], statuses: [String], priorities: [String]) -> String? {
        let request = QuickCreateParser.parse(quickEntry)
        guard request.title.isEmpty == false else {
            return String(localized: "Quick Entry needs a title.")
        }

        title = request.title
        if let requestedRepository = request.repository {
            repository = Self.resolvedRepository(requestedRepository, suggestions: repositories)
        }
        labels = request.labels.joined(separator: ", ")
        assignees = request.assignees.map { "@\($0)" }.joined(separator: ", ")
        let matchedStatus = Self.matchedOption(request.status, in: statuses)
        let matchedPriority = Self.matchedOption(request.priority, in: priorities)
        if request.status != nil {
            status = matchedStatus ?? ""
        }
        priority = matchedPriority ?? ""

        var unavailableOptions: [String] = []
        if let requestedStatus = request.status, matchedStatus == nil {
            unavailableOptions.append(String(localized: "status \(requestedStatus)"))
        }
        if let requestedPriority = request.priority, matchedPriority == nil {
            unavailableOptions.append(String(localized: "priority \(requestedPriority)"))
        }

        if unavailableOptions.isEmpty {
            usesQuickEntry = false
            return nil
        } else {
            return String(localized: "Unavailable project option: \(unavailableOptions.joined(separator: ", ")).")
        }
    }

    private static func matchedOption(_ requestedValue: String?, in options: [String]) -> String? {
        guard let requestedValue else { return nil }
        return options.first {
            $0.caseInsensitiveCompare(requestedValue) == .orderedSame
        }
    }

    private static func resolvedRepository(_ value: String, suggestions: [String]) -> String {
        guard value.contains("/") == false else { return value }
        let matches = suggestions.filter {
            $0.split(separator: "/").last?.caseInsensitiveCompare(value) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : value
    }
}

struct NewProjectItemEditor: View {
    let store: ProjectStore
    @Binding var draft: NewProjectItemDraft
    @Binding var validationMessage: String?
    let statusOptions: [String]
    let priorityOptions: [String]
    let reviewQuickEntry: () -> Void

    @State private var showsQuickEntryHelp = false
    @FocusState private var focusedField: Field?
    private enum Field { case title, quickEntry }
    private static let horizontalPadding = AddProjectItemView.horizontalPadding
    private static let labelWidth: CGFloat = 88
    private static let fieldSpacing: CGFloat = 12

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if draft.usesQuickEntry {
                    quickEntryForm
                } else {
                    createForm
                }

                if draft.usesQuickEntry == false, let message = validationMessage {
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
        .onAppear { focusEditor() }
        .onChange(of: draft.usesQuickEntry) { _, _ in
            validationMessage = nil
            focusEditor()
        }
        .onChange(of: draft.quickEntry) { _, _ in
            if draft.usesQuickEntry { validationMessage = nil }
        }
    }

    private var createForm: some View {
        Grid(alignment: .leading, horizontalSpacing: Self.fieldSpacing, verticalSpacing: 14) {
            if draft.itemType == .issue {
                GridRow(alignment: .firstTextBaseline) {
                    fieldLabel(String(localized: "Repository"))
                    VStack(alignment: .leading, spacing: 6) {
                        RepositoryComboBox(
                            text: $draft.repository,
                            repositories: store.repositorySuggestions
                        )
                        if let message = draft.repositoryValidationMessage {
                            validationNotice(message)
                        }
                    }
                }
            }

            GridRow(alignment: .firstTextBaseline) {
                fieldLabel(String(localized: "Type"))
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    Picker("Type", selection: $draft.itemType) {
                        ForEach(NewProjectItemDraft.ItemType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    if draft.itemType == .issue, statusOptions.isEmpty == false {
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
                fieldLabel(String(localized: "Title"))
                TextField(draft.itemType == .issue ? String(localized: "Issue title") : String(localized: "Draft title"), text: $draft.title)
                    .accessibilityLabel("Title, required")
                    .focused($focusedField, equals: .title)
            }

            GridRow(alignment: .top) {
                VStack(alignment: .trailing, spacing: 2) {
                    fieldLabel(String(localized: "Description"))
                    Text("Optional")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Description", text: $draft.bodyText, axis: .vertical)
                    .lineLimit(4...6)
                    .accessibilityLabel("Description, optional")
            }

            if draft.itemType == .issue {
                GridRow(alignment: .firstTextBaseline) {
                    fieldLabel(String(localized: "Labels"))
                    LabelTokenField(text: $draft.labels, suggestions: labelSuggestions)
                }

                GridRow(alignment: .firstTextBaseline) {
                    fieldLabel(String(localized: "Assignees"))
                    HStack(alignment: .firstTextBaseline, spacing: Self.fieldSpacing) {
                        TextField("\(store.currentUserLogin ?? "username"), @me", text: $draft.assignees)
                            .accessibilityLabel("Assignees")
                            .accessibilityHint("Separate usernames with commas. Use @me for yourself.")
                            .help("Separate usernames with commas. Use @me for yourself.")
                            .frame(maxWidth: .infinity)

                        Button("Assign to me") {
                            draft.assignToMe()
                        }
                        .buttonStyle(.link)
                        .fixedSize()
                        .disabled(draft.hasCurrentUserAssignee(currentUser: store.currentUserLogin))
                    }
                }

                if priorityOptions.isEmpty == false {
                    GridRow(alignment: .firstTextBaseline) {
                        fieldLabel(String(localized: "Priority"))
                        priorityPicker.labelsHidden()
                    }
                }
            }
        }
        .pickerStyle(.menu)
    }

    private func fieldLabel(_ labelTitle: String) -> some View {
        Text(labelTitle)
            .frame(width: Self.labelWidth, alignment: .trailing)
    }

    private var statusPicker: some View {
        Picker("Status", selection: $draft.status) {
            if draft.status.isEmpty {
                Text("Choose Status").tag("").disabled(true)
            }
            ForEach(statusOptions, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .labelsHidden()
        .accessibilityLabel("Status, required")
        .help(draft.status.isEmpty ? String(localized: "Choose Status") : draft.status)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var priorityPicker: some View {
        Picker("Priority", selection: $draft.priority) {
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
            $0.repositoryName?.caseInsensitiveCompare(draft.repository.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }.flatMap { $0.labels.map(\.name) })).sorted()
    }

    private var quickEntryForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe the item")
                .font(.subheadline)

            TextField("Title and qualifiers", text: $draft.quickEntry)
                .accessibilityLabel("Quick Entry")
                .focused($focusedField, equals: .quickEntry)
                .onSubmit(reviewQuickEntry)

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

    private func validationNotice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func focusEditor() {
        focusedField = draft.usesQuickEntry ? .quickEntry : .title
    }
}
