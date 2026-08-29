import SwiftUI

struct MenuBarPopoverView: View {
    @Bindable var store: ProjectStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissMenuBar) private var dismissMenuBar
    @State private var isRefreshing = false
    @State private var isMoreHovered = false
    @State private var searchText = ""
    @State private var keyMonitor: Any?
    @State private var inspectorReference: ItemInspectorReference?

    private var canEditSelectedProject: Bool {
        store.canEditSelectedProject
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView

            OperationErrorBanner(store: store)

            if store.isLoading && store.projects.isEmpty {
                loadingView
            } else if let error = store.error {
                errorView(error)
            } else if store.projects.isEmpty {
                emptyProjectsView
            } else {
                selectedProjectContent
            }
        }
        .frame(width: 400)
        .sheet(item: $inspectorReference) { reference in
            ItemInspectorView(store: store, reference: reference)
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
                        refresh()
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
        HStack(spacing: 8) {
            ProjectSelectorView(store: store, compact: true)
                .frame(maxWidth: 200, alignment: .leading)

            Spacer(minLength: 8)

            if canEditSelectedProject {
                HeaderButton(
                    icon: "plus",
                    help: "Create or Add Item",
                    isProminent: true
                ) {
                    openQuickAdd()
                }
            }

            HeaderButton(icon: "rectangle.split.3x1", help: "Open Kanban Board") {
                openKanbanBoard()
            }

            RefreshButton(isRefreshing: $isRefreshing, action: refresh)

            Menu {
                Button(action: openSettings) {
                    Label("Settings…", systemImage: "gearshape")
                }

                Button(action: openCoffeePage) {
                    Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                }

                Divider()

                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit GitBoard", systemImage: "power")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.medium))
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isMoreHovered ? Color.primary.opacity(0.10) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .onHover { hovering in
                isMoreHovered = hovering
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func refresh() {
        guard isRefreshing == false else { return }
        isRefreshing = true
        Task {
            await store.refresh()
            isRefreshing = false
        }
    }

    private func openCoffeePage() {
        guard let url = URL(string: "https://donate.stripe.com/aFa14ociW0pndDCa0K8bS00") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openQuickAdd() {
        dismissMenuBar()
        openWindow(id: "quick-add")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title == "Add to Project" {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func openSettings() {
        dismissMenuBar()
        openWindow(id: "settings")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title == "Settings" {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func openKanbanBoard() {
        dismissMenuBar()
        openWindow(id: "kanban-board")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title == "GitBoard" {
                window.makeKeyAndOrderFront(nil)
            }
        }
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
    private var selectedProjectContent: some View {
        switch store.selectedProjectContentState {
        case .none:
            emptyProjectsView
        case .loading:
            projectLoadingView
        case .content(let project, _, _), .empty(let project, _, _):
            statusFilterTabs(project: project)
            searchBar
            itemsList(project: project)
        case .failed(let project, let message):
            projectErrorView(project, message: message)
        }
    }

    private var projectLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Loading project items...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func projectErrorView(_ project: Project, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Couldn’t load \(project.title)")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Try Again") {
                Task { await store.loadProjectDetails(id: project.id) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
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
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            TextField(
                "Search items, #number, or @assignee",
                text: $searchText
            )
            .textFieldStyle(.plain)
            .font(.callout)
            .accessibilityLabel("Search project items")
            .onChange(of: searchText) { oldValue, newValue in
                if canEditSelectedProject && newValue == ">" {
                    searchText = ""
                    openQuickAdd()
                }
            }

            if !searchText.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    searchText = ""
                }
                .labelStyle(.iconOnly)
                .font(.callout)
                .foregroundStyle(.tertiary)
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

    private func searchedItems(in project: Project) -> [ProjectItem] {
        let items = if let filter = store.selectedStatusFilter {
            project.items.filter { $0.status == filter }
        } else {
            project.items
        }

        return items.matching(searchText, currentUserLogin: store.currentUserLogin)
    }

    private func itemsList(project: Project) -> some View {
        let items = searchedItems(in: project)
        return ScrollView {
            LazyVStack(spacing: 0) {
                if items.isEmpty {
                    emptyFilterView
                } else {
                    ForEach(items) { item in
                        ItemRow(item: item, store: store, project: project) {
                            inspectorReference = ItemInspectorReference(
                                projectID: project.id,
                                itemID: item.id
                            )
                        }
                    }
                }
            }
        }
        .scrollIndicators(.automatic)
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
    let isProminent: Bool

    @State private var isHovered = false

    init(isProminent: Bool = false) {
        self.isProminent = isProminent
    }

    func makeBody(configuration: Configuration) -> some View {
        let backgroundColor = isProminent ? Color.accentColor : Color.primary
        let backgroundOpacity = if configuration.isPressed {
            0.16
        } else if isHovered {
            0.10
        } else {
            0.0
        }

        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor.opacity(backgroundOpacity))
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
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(help, systemImage: icon, action: action)
            .labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .imageScale(.large)
            .foregroundStyle(isProminent ? Color.accentColor : Color.secondary)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        .buttonStyle(HeaderButtonStyle(isProminent: isProminent))
        .help(help)
    }
}

struct RefreshButton: View {
    @Binding var isRefreshing: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation: Double = 0

    var body: some View {
        Button("Refresh", systemImage: "arrow.clockwise", action: action)
            .labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .imageScale(.large)
            .foregroundStyle(isRefreshing ? .blue : .secondary)
            .rotationEffect(.degrees(rotation))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        .buttonStyle(HeaderButtonStyle())
        .disabled(isRefreshing)
        .help("Refresh")
        .onChange(of: isRefreshing) { _, newValue in
            if newValue {
                guard reduceMotion == false else {
                    rotation = 0
                    return
                }
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
                    .font(.callout.weight(isSelected ? .semibold : .regular))

                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(count == 0 ? Color.secondary : color)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) items")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    let showInspector: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            showInspector()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                itemTypeIcon
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if let number = item.number {
                            Text("#\(number)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let linkedPR = item.linkedPR {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text("PR #\(linkedPR.number)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    EngineeringSignalsView(item: item, limit: 2)
                }

                Spacer()

                if !item.assignees.isEmpty {
                    AvatarStack(assignees: item.assignees)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.45) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.number.map { "\(item.title), number \($0)" } ?? item.title)
        .accessibilityHint("Show item details")
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
        .contextMenu {
            Button {
                showInspector()
            } label: {
                Label("Show Details", systemImage: "sidebar.right")
            }

            Button {
                if let urlString = item.url, let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }

            if store.canEditProject(id: project.id) {
                Divider()

                Menu {
                    ForEach(project.statusOptions) { status in
                        Button {
                            Task {
                                await store.moveItem(item, toStatus: status, in: project.id)
                            }
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
                                Task {
                                    await store.removeAssignee(
                                        from: item,
                                        in: project.id,
                                        user: assignee
                                    )
                                }
                            } label: {
                                Label(assignee.name ?? assignee.login, systemImage: "person.fill.xmark")
                            }
                        }
                    } label: {
                        Label("Assignees (\(item.assignees.count))", systemImage: "person.2")
                    }
                }

                Divider()

                Button {
                    Task { _ = await store.archiveItem(item, in: project.id) }
                } label: {
                    Label("Archive from Project", systemImage: "archivebox")
                }
            }
        }
    }

    @ViewBuilder
    private var itemTypeIcon: some View {
        Group {
            switch item.contentType {
            case .issue:
                Image(systemName: "record.circle")
            case .pullRequest:
                Image(systemName: "arrow.triangle.merge")
            case .draftIssue:
                Image(systemName: "doc.text")
            case .redacted:
                Image(systemName: "lock")
            }
        }
        .font(.callout)
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
