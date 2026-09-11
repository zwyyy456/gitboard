import SwiftUI

struct ItemAssigneesSection: View {
    let store: ProjectStore
    let item: ProjectItem
    @Binding var operationErrorMessage: String?
    let projectID: String
    private var canEdit: Bool { store.canEditProject(id: projectID) }
    @State private var userQuery = ""
    @State private var userResults: [Assignee] = []
    @State private var isSearchingUsers = false
    @State private var hasSearchedUsers = false
    @State private var userSearchGeneration = 0
    @State private var showsAssigneePicker = false

    var body: some View {
        ItemPropertySection("Assignees") {
            if item.assignees.isEmpty {
                Text("No assignees").font(.callout).foregroundStyle(.secondary)
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
                                operationErrorMessage = nil
                                Task {
                                    do {
                                        try await store.removeAssignee(
                                            from: item,
                                            in: projectID,
                                            user: assignee
                                        )
                                    } catch {
                                        report(error)
                                    }
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

    private func searchUsers() {
        let query = userQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false, isSearchingUsers == false else { return }
        userSearchGeneration += 1
        let generation = userSearchGeneration
        isSearchingUsers = true
        hasSearchedUsers = true
        operationErrorMessage = nil
        Task {
            do {
                let results = try await store.searchUsers(query: query)
                guard generation == userSearchGeneration else { return }
                if query == userQuery.trimmingCharacters(in: .whitespacesAndNewlines) {
                    userResults = results
                }
            } catch {
                guard generation == userSearchGeneration else { return }
                report(error)
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

    private func addAssignee(_ user: Assignee, to item: ProjectItem) {
        operationErrorMessage = nil
        Task {
            do {
                try await store.addAssignee(
                    to: item,
                    in: projectID,
                    user: user
                )
                userResults.removeAll { $0.id == user.id }
            } catch {
                report(error)
            }
        }
    }

    private func report(_ error: Error) {
        guard (error is CancellationError) == false else { return }
        operationErrorMessage = error.localizedDescription
    }
}
