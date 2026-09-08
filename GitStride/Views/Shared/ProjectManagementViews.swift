import SwiftUI

struct NewProjectButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissMenuBar) private var dismissMenuBar

    var body: some View {
        Button("New Project…", systemImage: "plus") {
            dismissMenuBar()
            openWindow(id: "new-project")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct CreateProjectView: View {
    @Bindable var store: ProjectStore
    let onCreated: () -> Void
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var title = ""
    @State private var ownerID: String?
    @State private var repositoryID: String?
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    private var owner: ProjectOwner? {
        store.owners.first { $0.id == ownerID }
    }

    private var repositorySelectionIsValid: Bool {
        guard let repositoryID else { return true }
        guard let owner else { return false }
        return store.repositoryListState(ownerID: owner.id).repositories.contains { $0.id == repositoryID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Project").font(.title2.bold())
            Form {
                TextField("Name", text: $title)
                    .focused($titleFocused)
                Picker("Owner", selection: $ownerID) {
                    Text("Select an owner").tag(String?.none)
                    ForEach(store.owners) { owner in
                        Text(owner.login).tag(Optional(owner.id))
                    }
                }
            }
            .disabled(store.isCreatingProject)
            if let owner {
                RepositorySelectionView(store: store, owner: owner, selection: $repositoryID, optional: true)
                    .disabled(store.isCreatingProject)
            }
            if store.owners.isEmpty {
                if store.isLoading {
                    ProgressView("Loading accounts…")
                } else {
                    Text(store.error?.localizedDescription ?? "Load your GitHub accounts to create a project.")
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await store.loadProjects() }
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if store.isCreatingProject {
                    ProgressView().controlSize(.small)
                    Text("Creating project…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismissWindow(id: "new-project") }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isCreatingProject)
                Button("Create") {
                    guard let owner else { return }
                    let repository = store.repositoryListState(ownerID: owner.id).repositories.first { $0.id == repositoryID }
                    guard repositoryID == nil || repository != nil else { return }
                    errorMessage = nil
                    Task {
                        do {
                            try await store.createProject(
                                owner: owner,
                                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                repository: repository
                            )
                            onCreated()
                            title = ""
                            dismissWindow(id: "new-project")
                            openWindow(id: "kanban-board")
                            NSApp.activate(ignoringOtherApps: true)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(owner == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isCreatingProject || !repositorySelectionIsValid)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 560)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            if store.owners.isEmpty && !store.isLoading { await store.loadProjects() }
            ownerID = store.selectedOwnerId ?? store.owners.first?.id
            titleFocused = true
        }
        .onChange(of: ownerID) { _, _ in repositoryID = nil }
        .onChange(of: store.owners) { _, owners in
            if ownerID == nil { ownerID = store.selectedOwnerId ?? owners.first?.id }
        }
    }
}

struct RepositorySelectionView: View {
    @Bindable var store: ProjectStore
    let owner: ProjectOwner
    @Binding var selection: String?
    var optional = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(optional ? "Repository (optional)" : "Repository", selection: $selection) {
                Text(optional ? "None" : "Select a repository").tag(String?.none)
                ForEach(store.repositoryListState(ownerID: owner.id).repositories) { repository in
                    Text(repository.nameWithOwner).tag(Optional(repository.id))
                }
            }
            .disabled(!optional && store.repositoryListState(ownerID: owner.id).repositories.isEmpty)

            switch store.repositoryListState(ownerID: owner.id) {
            case .idle, .loading:
                ProgressView("Loading repositories…").controlSize(.small)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry Loading Repositories") {
                    Task { await store.loadRepositories(owner: owner) }
                }
            case .loaded(let repositories):
                if repositories.isEmpty {
                    Text("No accessible repositories found for this owner.")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Links the project to a repository owned by \(owner.login).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: owner.id) { await store.loadRepositories(owner: owner) }
    }
}

struct LinkProjectRepositoryView: View {
    @Bindable var store: ProjectStore
    let projectID: String
    @Environment(\.dismiss) private var dismiss
    @State private var repositoryID: String?
    @State private var errorMessage: String?

    private var isLinking: Bool { store.linkingRepositoryProjectIDs.contains(projectID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Link Repository").font(.title2.bold())
            if let project = store.project(id: projectID) {
                Text(project.title)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                RepositorySelectionView(
                    store: store, owner: project.owner, selection: $repositoryID
                )
                .disabled(isLinking)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if isLinking {
                        ProgressView("Linking…").controlSize(.small)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isLinking)
                    Button("Link") {
                        guard let repository = selectedRepository(owner: project.owner) else { return }
                        errorMessage = nil
                        Task {
                            do {
                                try await store.linkRepository(repository, to: projectID)
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLinking || !project.viewerCanUpdate || selectedRepository(owner: project.owner) == nil)
                }
            } else {
                Text("This project is no longer available. Select it again to link a repository.")
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func selectedRepository(owner: ProjectOwner) -> ProjectRepository? {
        store.repositoryListState(ownerID: owner.id).repositories.first { $0.id == repositoryID }
    }
}
