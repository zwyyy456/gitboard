import SwiftUI

struct MenuBarPopoverView: View {
    @Bindable var store: ProjectStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissMenuBar) private var dismissMenuBar
    @State private var isRefreshing = false
    @State private var searchText = ""
    @State private var keyMonitor: Any?
    @State private var showsAddItem = false

    private var canEditSelectedProject: Bool {
        store.selectedProject?.viewerCanUpdate == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView

            if store.isLoading && store.projects.isEmpty {
                loadingView
            } else if let error = store.error {
                errorView(error)
            } else if store.projects.isEmpty {
                emptyProjectsView
            } else {
                projectContent
            }
        }
        .frame(width: 400)
        .background(Color.black)
        .sheet(isPresented: $showsAddItem) {
            AddProjectItemView(store: store)
        }
        .task {
            if store.projects.isEmpty {
                await store.loadProjects()
            }
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) {
                    if event.keyCode == 123 {
                        navigateTab(direction: -1)
                        return nil
                    } else if event.keyCode == 124 {
                        navigateTab(direction: 1)
                        return nil
                    } else if event.keyCode == 15 { // R key
                        if !isRefreshing {
                            isRefreshing = true
                            Task {
                                await store.refresh()
                                isRefreshing = false
                            }
                        }
                        return nil
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    private func navigateTab(direction: Int) {
        guard let project = store.selectedProject else { return }
        let statuses = project.statusOptions

        if store.selectedStatusFilter == nil {
            if direction > 0 && !statuses.isEmpty {
                withAnimation(.easeInOut(duration: 0.15)) {
                    store.selectedStatusFilter = statuses[0].name
                }
            }
        } else if let currentFilter = store.selectedStatusFilter,
                  let currentIndex = statuses.firstIndex(where: { $0.name == currentFilter }) {
            let newIndex = currentIndex + direction
            withAnimation(.easeInOut(duration: 0.15)) {
                if newIndex < 0 {
                    store.selectedStatusFilter = nil
                } else if newIndex < statuses.count {
                    store.selectedStatusFilter = statuses[newIndex].name
                }
            }
        }
    }

    private var headerView: some View {
        HStack(spacing: 10) {
            ProjectSelectorView(store: store, compact: true)
                .frame(maxWidth: 200, alignment: .leading)

            Spacer()

            if canEditSelectedProject {
                HeaderButton(icon: "plus", help: "Create or Add Item") {
                    showsAddItem = true
                }
            }

            // Coffee button
            Button {
                if let url = URL(string: "https://donate.stripe.com/aFa14ociW0pndDCa0K8bS00") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HeaderButtonStyle())
            .help("Buy me a coffee")

            // Quit button
            HeaderButton(icon: "power", help: "Quit GitBoard") {
                NSApp.terminate(nil)
            }

            // Settings button
            HeaderButton(icon: "gearshape", help: "Settings") {
                dismissMenuBar()
                openWindow(id: "settings")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.title == "Settings" {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }

            // Expand button
            HeaderButton(icon: "arrow.up.left.and.arrow.down.right", help: "Open Kanban Board") {
                dismissMenuBar()
                openWindow(id: "kanban-board")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.title == "GitBoard" {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }

            // Refresh button
            RefreshButton(isRefreshing: $isRefreshing) {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await store.refresh()
                    isRefreshing = false
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.9)
            Text("Loading projects...")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 16) {
            if let ghError = error as? GitHubError {
                switch ghError {
                case .ghCLINotFound:
                    onboardingView(
                        icon: "terminal",
                        title: "GitHub CLI Required",
                        message: "GitBoard uses the GitHub CLI (gh) for authentication.",
                        buttonTitle: "Install GitHub CLI",
                        buttonAction: {
                            NSWorkspace.shared.open(URL(string: "https://cli.github.com")!)
                        }
                    )

                case .notAuthenticated:
                    onboardingView(
                        icon: "person.crop.circle.badge.questionmark",
                        title: "Sign in to GitHub",
                        message: "Open Terminal and run:\ngh auth login",
                        buttonTitle: "Try Again",
                        buttonAction: {
                            Task { await store.loadProjects() }
                        }
                    )

                case .missingProjectScope:
                    onboardingView(
                        icon: "lock.shield",
                        title: "Project Access Required",
                        message: "Open Terminal and run:\ngh auth refresh -s project",
                        buttonTitle: "Try Again",
                        buttonAction: {
                            Task { await store.loadProjects() }
                        }
                    )

                default:
                    genericErrorView(error)
                }
            } else {
                genericErrorView(error)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func onboardingView(icon: String, title: String, message: String, buttonTitle: String, buttonAction: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.blue)

            Text(title)
                .font(.system(size: 15, weight: .semibold))

            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Button(buttonTitle, action: buttonAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private func genericErrorView(_ error: Error) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)

            Text(error.localizedDescription)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") {
                Task { await store.loadProjects() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var emptyProjectsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("No projects found")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private var projectContent: some View {
        if let project = store.selectedProject {
            statusFilterTabs(project: project)
            searchBar
            itemsList
        }
    }

    private func statusFilterTabs(project: Project) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterTab(
                    title: "All",
                    count: project.items.count,
                    isSelected: store.selectedStatusFilter == nil,
                    color: .secondary
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        store.selectedStatusFilter = nil
                    }
                }

                ForEach(project.statusOptions) { status in
                    FilterTab(
                        title: status.name,
                        count: project.itemCount(forStatus: status.name),
                        isSelected: store.selectedStatusFilter == status.name,
                        color: status.swiftUIColor
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            store.selectedStatusFilter = status.name
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .padding(2)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            TextField(
                canEditSelectedProject
                    ? "Search, #number, @me · Type > to add"
                    : "Search, #number, @me",
                text: $searchText
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .onChange(of: searchText) { oldValue, newValue in
                if canEditSelectedProject && newValue == ">" {
                    searchText = ""
                    showsAddItem = true
                }
            }

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
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var searchedItems: [ProjectItem] {
        let items = store.filteredItems

        guard !searchText.isEmpty else { return items }

        let query = searchText.lowercased().trimmingCharacters(in: .whitespaces)

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

    private var itemsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if searchedItems.isEmpty {
                    emptyFilterView
                } else {
                    ForEach(searchedItems) { item in
                        ItemRow(item: item, store: store, project: store.selectedProject!)
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: 360)
    }

    private var emptyFilterView: some View {
        VStack(spacing: 12) {
            Image(systemName: searchText.isEmpty ? "doc.text.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(searchText.isEmpty ? "No items" : "No results for \"\(searchText)\"")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Header Button Style

struct HeaderButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.1) : Color.clear)
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    NSCursor.pointingHand.push()
                case .ended:
                    NSCursor.pop()
                }
            }
    }
}

struct HeaderButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HeaderButtonStyle())
        .help(help)
    }
}

struct RefreshButton: View {
    @Binding var isRefreshing: Bool
    let action: () -> Void

    @State private var rotation: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isRefreshing ? .blue : .secondary)
                .rotationEffect(.degrees(rotation))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HeaderButtonStyle())
        .disabled(isRefreshing)
        .help("Refresh")
        .onChange(of: isRefreshing) { _, newValue in
            if newValue {
                withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    rotation = 0
                }
            }
        }
    }
}

// MARK: - Filter Tab

struct FilterTab: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))

                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? color : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isSelected ? color.opacity(0.2) : Color.secondary.opacity(0.1))
                    )
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? color.opacity(0.12) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? color.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.pointingHand.push()
            case .ended:
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Item Row

struct ItemRow: View {
    let item: ProjectItem
    @Bindable var store: ProjectStore
    let project: Project

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            itemTypeIcon
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

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
                }
            }

            Spacer()

            if !item.assignees.isEmpty {
                AvatarStack(assignees: item.assignees)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.pointingHand.push()
            case .ended:
                NSCursor.pop()
            }
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

            if project.viewerCanUpdate {
                Divider()

                Menu {
                    ForEach(project.statusOptions) { status in
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
                        Label("Assignees (\(item.assignees.count))", systemImage: "person.2")
                    }
                }
            }
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
            case .redacted:
                Image(systemName: "lock")
            }
        }
        .font(.system(size: 13))
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

// MARK: - Avatar Stack

struct AvatarStack: View {
    let assignees: [Assignee]
    private let size: CGFloat = 22
    private let overlap: CGFloat = 6

    var body: some View {
        HStack(spacing: -overlap) {
            ForEach(Array(assignees.prefix(3).enumerated()), id: \.element.id) { index, assignee in
                AsyncImage(url: URL(string: assignee.avatarUrl)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(Color.secondary.opacity(0.3))
                        .overlay(
                            Text(String(assignee.login.prefix(1)).uppercased())
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        )
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                .zIndex(Double(3 - index))
            }

            if assignees.count > 3 {
                Text("+\(assignees.count - 3)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }
}

// MARK: - PR Badge

struct PRBadge: View {
    let item: ProjectItem
    @State private var isHovered = false

    var body: some View {
        Button {
            if let urlString = item.url, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 9, weight: .semibold))
                if let number = item.number {
                    Text("#\(number)")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .foregroundStyle(isHovered ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(isHovered ? 0.15 : 0.08))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
