import AppKit
import SwiftUI

struct AddProjectItemView: View {
    static let sheetWidth: CGFloat = 620
    private static let sheetHeight: CGFloat = 520
    static let horizontalPadding: CGFloat = 48
    static let windowDefaultSize = CGSize(width: sheetWidth, height: sheetHeight)
    static let windowMinimumSize = CGSize(width: 520, height: 500)

    enum Presentation {
        case sheet
        case window
    }

    @Bindable var store: ProjectStore
    let presentation: Presentation
    let initialQuickEntry: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var mode: Mode = .create
    @State private var maximumSheetHeight: CGFloat?
    @State private var isSubmitting = false
    @State private var validationMessage: String?
    @State private var issueCreation: IssueCreation?
    @State private var draft = NewProjectItemDraft()
    @State private var search = ExistingItemSearchState()

    init(store: ProjectStore, presentation: Presentation = .sheet, initialQuickEntry: String? = nil) {
        self.store = store
        self.presentation = presentation
        self.initialQuickEntry = initialQuickEntry
        _draft = State(initialValue: NewProjectItemDraft(
            quickEntry: initialQuickEntry ?? "", usesQuickEntry: initialQuickEntry != nil
        ))
    }

    private enum Mode {
        case create
        case existing
    }

    private var isWorking: Bool { isSubmitting || issueCreation?.isRunning == true }

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch mode {
                case .create:
                    NewProjectItemEditor(store: store, draft: $draft,
                                         validationMessage: $validationMessage,
                                         statusOptions: statusOptions, priorityOptions: priorityOptions,
                                         reviewQuickEntry: applyQuickEntry)
                case .existing:
                    ExistingProjectItemPicker(store: store, state: $search,
                                              validationMessage: $validationMessage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .disabled(isWorking || issueCreation != nil)

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
            if draft.repository.isEmpty {
                draft.repository = store.defaultIssueRepository
            }
            updateStatusSelection()
            if draft.usesQuickEntry, !QuickCreateParser.parse(draft.quickEntry).title.isEmpty {
                applyQuickEntry()
            }
        }
        .onChange(of: store.selectedProjectId) { _, _ in
            guard presentation == .window, issueCreation == nil else { return }
            draft.repository = store.defaultIssueRepository
            draft.status = defaultStatus
            draft.priority = ""
        }
        .onChange(of: statusOptions) { _, _ in
            updateStatusSelection()
        }
        .onChange(of: store.defaultIssueRepository) { oldValue, newValue in
            guard issueCreation == nil, draft.repository.isEmpty || draft.repository == oldValue else { return }
            draft.repository = newValue
        }
        .onChange(of: mode) { _, _ in
            validationMessage = nil
        }
        .onChange(of: draft.repository) { _, _ in
            draft.repositoryValidationMessage = nil
        }
    }

    private var sheetTitle: String {
        if let project = store.project(id: issueCreation?.projectID ?? store.selectedProjectId ?? "") {
            return String(localized: "Add Item to “\(project.title)”")
        }
        return String(localized: "Add Item to Project")
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                if presentation == .sheet || issueCreation != nil {
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
        .disabled(isWorking || issueCreation != nil)
    }

    private var preferredSheetHeight: CGFloat {
        min(Self.sheetHeight, maximumSheetHeight ?? Self.sheetHeight)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let issueCreation, issueCreation.phase == .unconfirmed,
               let repositoryURL = URL(string: "https://github.com/\(issueCreation.repository)/issues") {
                Link("Check Repository", destination: repositoryURL)
            } else if mode == .create {
                Button(draft.usesQuickEntry ? String(localized: "Show Full Form") : String(localized: "Quick Entry…")) {
                    draft.usesQuickEntry.toggle()
                }
                .disabled(isWorking || issueCreation != nil)
            }

            if isWorking, search.isSearching == false {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }

            Spacer()

            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)

            switch mode {
            case .create:
                if draft.usesQuickEntry {
                    Button("Review Details", action: applyQuickEntry)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || draft.quickEntry.trimmed.isEmpty)
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
        guard let selectedResult = search.selectedResult else { return true }
        return isWorking || search.isSearching || isAlreadyAdded(selectedResult)
    }

    private func addSelectedItem() {
        guard addActionIsDisabled == false, let selectedResult = search.selectedResult else { return }
        add(selectedResult)
    }

    private func performPrimaryAction() {
        switch mode {
        case .create:
            if draft.usesQuickEntry {
                applyQuickEntry()
            } else if createActionIsDisabled == false {
                createItem()
            }
        case .existing:
            addSelectedItem()
        }
    }

    private var createActionTitle: String {
        if isWorking { return String(localized: "Creating…") }
        if let issueCreation {
            switch issueCreation.phase {
            case .addingToProject: return String(localized: "Retry Adding to Project")
            case .applyingFields: return String(localized: "Retry Project Fields")
            case .refreshingProject: return String(localized: "Retry Refresh")
            case .unconfirmed: return String(localized: "Create Issue")
            case .ready, .completed: break
            }
        }
        return draft.itemType == .issue ? String(localized: "Create Issue") : String(localized: "Create Draft")
    }

    private var createActionIsDisabled: Bool {
        if let issueCreation { return isWorking || !issueCreation.canResume }
        return isWorking || draft.title.trimmed.isEmpty
            || (draft.itemType == .issue && (draft.repository.trimmed.isEmpty || needsStatusSelection))
    }

    private var statusOptions: [String] {
        store.selectedProject?.statusOptions.map(\.name) ?? []
    }

    private var defaultStatus: String {
        statusOptions.first { $0.caseInsensitiveCompare("Todo") == .orderedSame } ?? ""
    }

    private var needsStatusSelection: Bool {
        statusOptions.isEmpty == false && statusOptions.contains(draft.status) == false
    }

    private func updateStatusSelection() {
        guard issueCreation == nil else { return }
        if statusOptions.contains(draft.status) == false {
            draft.status = defaultStatus
        }
    }

    private var priorityOptions: [String] {
        guard let field = store.selectedProject?.fields.first(where: {
            $0.kind == .singleSelect && $0.name.caseInsensitiveCompare("Priority") == .orderedSame
        }) else { return [] }
        return field.options.map(\.name)
    }

    private func createItem() {
        guard createActionIsDisabled == false else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        validationMessage = nil
        draft.repositoryValidationMessage = nil
        do {
            if draft.itemType == .issue, issueCreation == nil {
                issueCreation = try store.prepareIssueCreation(
                    repository: draft.repository.trimmed, title: draft.title.trimmed, body: draft.bodyText,
                    labels: draft.labelNames,
                    assignees: draft.assigneeLogins(currentUser: store.currentUserLogin),
                    status: draft.status.trimmed.nilIfEmpty, priority: draft.priority.trimmed.nilIfEmpty
                )
            }
        } catch {
            validationMessage = error.localizedDescription
            return
        }
        isSubmitting = true
        Task {
            do {
                if let issueCreation {
                    try await store.resumeIssueCreation(issueCreation)
                } else {
                    try await store.createDraftIssue(title: draft.title.trimmed, body: draft.bodyText)
                }
                close()
            } catch {
                if (error as? GitHubError) == .invalidRepository {
                    issueCreation = nil
                    draft.repositoryValidationMessage = String(localized: "Use owner/repository, for example octocat/hello-world.")
                } else if let issueCreation {
                    validationMessage = issueCreation.errorMessage ?? error.localizedDescription
                    if issueCreation.phase == .ready { self.issueCreation = nil }
                } else if !(error is CancellationError) {
                    validationMessage = error.localizedDescription
                }
            }
            isSubmitting = false
        }
    }

    private func add(_ item: GitHubItemCandidate) {
        guard isWorking == false else { return }
        isSubmitting = true
        validationMessage = nil
        Task {
            do {
                try await store.addExistingItem(item)
                close()
            } catch is CancellationError {
            } catch {
                validationMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }

    private func isAlreadyAdded(_ item: GitHubItemCandidate) -> Bool {
        store.selectedProject?.items.contains { $0.contentId == item.id } == true
    }

    private func applyQuickEntry() {
        guard !isWorking else { return }
        validationMessage = draft.reviewQuickEntry(
            repositories: store.repositorySuggestions,
            statuses: statusOptions, priorities: priorityOptions
        )
    }

    private func close() {
        switch presentation {
        case .sheet:
            dismiss()
        case .window:
            dismissWindow(id: "quick-add", value: initialQuickEntry ?? "")
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
