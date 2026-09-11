import SwiftUI

struct ExistingItemSearchState {
    fileprivate var query = ""
    fileprivate var results: [GitHubItemCandidate] = []
    fileprivate var selectedResultID: String?
    fileprivate var showsSearchHelp = false
    fileprivate var searchPhase: SearchPhase = .idle

    fileprivate enum SearchPhase {
        case idle
        case searching
        case finished(query: String)
        case failed(message: String)
    }

    init() {}

    var selectedResult: GitHubItemCandidate? {
        results.first { $0.id == selectedResultID }
    }

    var isSearching: Bool {
        if case .searching = searchPhase { return true }
        return false
    }
}

struct ExistingProjectItemPicker: View {
    let store: ProjectStore
    @Binding var state: ExistingItemSearchState
    @Binding var validationMessage: String?
    @Environment(\.isEnabled) private var isEnabled
    @State private var searchTask: Task<Void, Never>?

    private static let horizontalPadding = AddProjectItemView.horizontalPadding
    private var isSearching: Bool { state.isSearching }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ItemSearchField(
                        text: Binding(get: { state.query }, set: { updateSearchQuery($0) }),
                        onSubmit: searchItems
                    )

                    Button("Search Syntax", systemImage: "questionmark.circle") {
                        state.showsSearchHelp = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Search syntax")
                    .popover(isPresented: $state.showsSearchHelp) {
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
                switch state.searchPhase {
                case .idle:
                    repositorySearchSuggestions
                case .searching:
                    ProgressView(isItemURL ? "Loading item…" : "Searching…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .finished(let searchedQuery):
                    if state.results.isEmpty {
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
        .onDisappear(perform: cancelSearch)
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

    private var searchResults: some View {
        List(state.results, selection: $state.selectedResultID) { item in
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

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        if isSearching { state.searchPhase = .idle }
    }

    private func updateSearchQuery(_ value: String) {
        guard state.query != value else { return }
        state.query = value
        cancelSearch()
        state.results = []
        state.selectedResultID = nil
        state.searchPhase = .idle
        validationMessage = nil
        if isItemURL { searchItems() }
    }

    private func searchItems() {
        guard isEnabled, state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        cancelSearch()
        let submittedQuery = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let loadsURL = isItemURL
        validationMessage = nil
        state.results = []
        state.selectedResultID = nil
        state.searchPhase = .searching
        searchTask = Task {
            do {
                let matches: [GitHubItemCandidate]
                if loadsURL {
                    matches = [try await store.resolveItem(url: submittedQuery)]
                } else {
                    matches = try await store.searchItems(query: submittedQuery)
                }
                try Task.checkCancellation()
                state.results = matches
                state.searchPhase = .finished(query: submittedQuery)
                if loadsURL { state.selectedResultID = matches.first?.id }
            } catch {
                guard Task.isCancelled == false else { return }
                state.searchPhase = .failed(message: error.localizedDescription)
            }
            searchTask = nil
        }
    }

    private func isAlreadyAdded(_ item: GitHubItemCandidate) -> Bool {
        store.selectedProject?.items.contains { $0.contentId == item.id } == true
    }

    private var isItemURL: Bool { GitHubItemAddress(state.query.trimmingCharacters(in: .whitespacesAndNewlines)) != nil }

    private func validationNotice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
