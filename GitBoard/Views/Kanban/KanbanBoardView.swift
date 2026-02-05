import SwiftUI
import UniformTypeIdentifiers

struct KanbanBoardView: View {
    @Bindable var store: ProjectStore
    @State private var refreshRotation: Double = 0
    @State private var isRefreshing = false
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()

            // Board content
            if store.isLoading && store.selectedProject == nil {
                loadingView
            } else if let error = store.error {
                errorView(error)
            } else if let project = store.selectedProject {
                boardContent(project)
            } else {
                emptyView
            }
        }
        .frame(minWidth: 1000, minHeight: 650)
        .background(Color.black)
        .task {
            if store.projects.isEmpty {
                await store.loadProjects()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            // Project selector
            if store.projects.count > 1 {
                Menu {
                    ForEach(store.projects) { project in
                        Button {
                            Task { await store.selectProject(project) }
                        } label: {
                            HStack {
                                Text(project.title)
                                if project.id == store.selectedProjectId {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(store.selectedProject?.title ?? "Select Project")
                            .font(.system(size: 15, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            } else if let project = store.selectedProject {
                Text(project.title)
                    .font(.system(size: 15, weight: .semibold))
            }

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)

                TextField("Search title, #number, @me...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(minWidth: 150, maxWidth: 250)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer()

            // Last updated
            if let lastUpdated = store.lastUpdated {
                Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            // Refresh button
            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    refreshRotation = 360
                }
                Task {
                    await store.refresh()
                    withAnimation(.easeOut(duration: 0.2)) {
                        refreshRotation = 0
                        isRefreshing = false
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isRefreshing ? .blue : .secondary)
                    .rotationEffect(.degrees(refreshRotation))
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)

            // Open in GitHub
            if let project = store.selectedProject, !project.url.isEmpty,
               let url = URL(string: project.url) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading project...")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text(error.localizedDescription)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button("Try Again") {
                Task { await store.loadProjects() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text("Select a project to view its board")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func filteredItems(for items: [ProjectItem]) -> [ProjectItem] {
        guard !searchText.isEmpty else { return items }

        let query = searchText.lowercased().trimmingCharacters(in: .whitespaces)

        // Handle @me shortcut
        if query == "@me" {
            guard let myLogin = store.currentUserLogin?.lowercased() else { return items }
            return items.filter { item in
                item.assignees.contains { $0.login.lowercased() == myLogin }
            }
        }

        let isAssigneeSearch = query.hasPrefix("@")
        let searchQuery = isAssigneeSearch ? String(query.dropFirst()) : query

        return items.filter { item in
            if item.title.lowercased().contains(searchQuery) {
                return true
            }

            let numberQuery = searchQuery.hasPrefix("#") ? String(searchQuery.dropFirst()) : searchQuery
            if let number = item.number, String(number).contains(numberQuery) {
                return true
            }

            let matchesAssignee = item.assignees.contains { assignee in
                assignee.login.lowercased().contains(searchQuery) ||
                (assignee.name?.lowercased().contains(searchQuery) ?? false)
            }
            if matchesAssignee {
                return true
            }

            return false
        }
    }

    private func boardContent(_ project: Project) -> some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(project.statusOptions) { status in
                        let statusItems = filteredItems(for: project.items(forStatus: status.name))
                        KanbanColumn(
                            status: status,
                            items: statusItems,
                            allStatuses: project.statusOptions,
                            store: store
                        )
                        .frame(height: geometry.size.height - 32)
                    }

                    let noStatusFiltered = filteredItems(for: project.noStatusItems)
                    if !project.noStatusItems.isEmpty || !noStatusFiltered.isEmpty {
                        KanbanColumn(
                            status: nil,
                            items: noStatusFiltered,
                            allStatuses: project.statusOptions,
                            store: store
                        )
                        .frame(height: geometry.size.height - 32)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Kanban Column

struct KanbanColumn: View {
    let status: StatusOption?
    let items: [ProjectItem]
    let allStatuses: [StatusOption]
    @Bindable var store: ProjectStore

    @State private var isTargeted = false

    var statusName: String {
        status?.name ?? "No Status"
    }

    var statusColor: Color {
        status?.swiftUIColor ?? .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(statusName)
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                Text("\(items.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            // Cards
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        KanbanCard(item: item, allStatuses: allStatuses, store: store)
                            .draggable(item.id) {
                                KanbanCardPreview(item: item)
                            }
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTargeted ? statusColor.opacity(0.8) : Color.clear, lineWidth: 2)
        )
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .dropDestination(for: String.self) { droppedItems, _ in
            guard let itemId = droppedItems.first,
                  let targetStatus = status else { return false }

            // Find the item being dropped from all project items
            if let project = store.selectedProject,
               let item = project.items.first(where: { $0.id == itemId }) {
                // Only move if status is different
                if item.status != targetStatus.name {
                    Task {
                        await store.moveItem(item, toStatus: targetStatus)
                    }
                }
            }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

// MARK: - Kanban Card

struct KanbanCard: View {
    let item: ProjectItem
    let allStatuses: [StatusOption]
    @Bindable var store: ProjectStore

    @State private var isHovered = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with icon and title
            HStack(alignment: .top, spacing: 8) {
                itemTypeIcon

                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Footer
            HStack(spacing: 4) {
                if let number = item.number {
                    Text("#\(number)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                if let linkedPR = item.linkedPR {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                    Text("PR #\(linkedPR.number)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // Assignees
                if !item.assignees.isEmpty {
                    HStack(spacing: -5) {
                        ForEach(item.assignees.prefix(3)) { assignee in
                            AsyncImage(url: URL(string: assignee.avatarUrl)) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Circle().fill(.secondary.opacity(0.3))
                            }
                            .frame(width: 20, height: 20)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
                        }

                        if item.assignees.count > 3 {
                            Text("+\(item.assignees.count - 3)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 6 : 3, x: 0, y: isHovered ? 3 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            if let urlString = item.url, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
        .contextMenu {
            Button {
                if let urlString = item.url, let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }

            Divider()

            Menu {
                ForEach(allStatuses) { status in
                    Button {
                        Task { await store.moveItem(item, toStatus: status) }
                    } label: {
                        HStack {
                            Circle()
                                .fill(status.swiftUIColor)
                                .frame(width: 8, height: 8)
                            Text(status.name)
                            if item.status == status.name {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(item.status == status.name)
                }
            } label: {
                Label("Move to", systemImage: "arrow.right.circle")
            }

            Divider()

            if !item.assignees.isEmpty {
                Menu {
                    ForEach(item.assignees) { assignee in
                        Button {
                            Task { await store.removeAssignee(from: item, user: assignee) }
                        } label: {
                            Label(assignee.name ?? assignee.login, systemImage: "person.fill.xmark")
                        }
                    }
                } label: {
                    Label("Remove Assignee", systemImage: "person.badge.minus")
                }

                Divider()
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete from Project", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete \"\(item.title)\"?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await store.deleteItem(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the item from the project.")
        }
    }

    @ViewBuilder
    private var itemTypeIcon: some View {
        Group {
            switch item.contentType {
            case .issue:
                Image(systemName: "circle.dotted")
            case .pullRequest:
                Image(systemName: "arrow.triangle.merge")
            case .draftIssue:
                Image(systemName: "doc.text")
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(stateColor)
    }

    private var stateColor: Color {
        if let state = item.issueState {
            return state == .open ? .green : .purple
        }
        if let state = item.prState {
            switch state {
            case .open: return .green
            case .merged: return .purple
            case .closed: return .red
            }
        }
        return .secondary
    }
}

// MARK: - Drag Preview

struct KanbanCardPreview: View {
    let item: ProjectItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.contentType == .pullRequest ? "arrow.triangle.merge" : "circle.dotted")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            if let number = item.number {
                Text("#\(number)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
    }
}
