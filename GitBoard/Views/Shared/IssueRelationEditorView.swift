import SwiftUI

struct IssueRelationEditorView: View {
    @Bindable var store: ProjectStore
    let item: ProjectItem
    let metadata: IssueMetadata
    let kind: IssueRelationKind

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [GitHubItemCandidate] = []
    @State private var isSearching = false
    @State private var isAdding = false
    @State private var operationErrorMessage: String?

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

            if let message = operationErrorMessage {
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
        operationErrorMessage = nil
        Task {
            do {
                let candidates = try await store.searchItems(query: query)
                results = candidates.filter {
                    $0.contentType == .issue
                        && $0.id != item.contentId
                        && existingIssueIDs.contains($0.id) == false
                }
            } catch is CancellationError {
            } catch {
                operationErrorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func add(_ candidate: GitHubItemCandidate) {
        isAdding = true
        operationErrorMessage = nil
        Task {
            do {
                try await store.addRelation(kind, target: candidate, on: item)
                dismiss()
            } catch is CancellationError {
            } catch {
                operationErrorMessage = error.localizedDescription
            }
            isAdding = false
        }
    }
}
