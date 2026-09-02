import SwiftUI

struct MenuBarPopoverView: View {
    @Bindable var store: ProjectStore
    @Binding var requestedItemReference: ItemInspectorReference?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissMenuBar) private var dismissMenuBar
    @State private var isRefreshing = false
    @State private var isMoreHovered = false
    @State private var searchText = ""
    @State private var keyMonitor: Any?
    @State private var operationErrorMessage: String?

    private var canEditSelectedProject: Bool {
        store.canEditSelectedProject
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView

            OperationErrorBanner(
                message: operationErrorMessage ?? store.operationErrorMessage,
                dismiss: dismissOperationError
            )

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

    private func report(_ error: Error) {
        guard (error is CancellationError) == false else { return }
        operationErrorMessage = error.localizedDescription
    }

    private func dismissOperationError() {
        if operationErrorMessage != nil {
            operationErrorMessage = nil
        } else {
            store.clearOperationError()
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
                        ItemRow(
                            item: item,
                            store: store,
                            project: project,
                            showInspector: {
                                openItemDetails(
                                    ItemInspectorReference(
                                        projectID: project.id,
                                        itemID: item.id
                                    )
                                )
                            },
                            reportError: report
                        )
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

    private func openItemDetails(_ reference: ItemInspectorReference) {
        requestedItemReference = reference
        openKanbanBoard()
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
