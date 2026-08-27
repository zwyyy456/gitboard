import SwiftUI

struct CommandPaletteView: View {
    @Bindable var model: GitBoardModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var selection: String?
    @State private var keyMonitor: Any?
    @FocusState private var searchFocused: Bool

    private struct Entry: Identifiable {
        enum Target {
            case quickAdd
            case refresh
            case settings
            case project(String)
            case item(String)
        }

        let id: String
        let title: String
        let subtitle: String?
        let icon: String
        let target: Target
    }

    private var entries: [Entry] {
        var entries = [
            Entry(id: "action:add", title: "Quick Add", subtitle: "Create or add an item", icon: "plus", target: .quickAdd),
            Entry(id: "action:refresh", title: "Refresh", subtitle: "Reload the current workspace", icon: "arrow.clockwise", target: .refresh),
            Entry(id: "action:settings", title: "Settings", subtitle: nil, icon: "gearshape", target: .settings)
        ]
        entries += paletteProjects.map {
            Entry(
                id: "project:\($0.id)",
                title: $0.title,
                subtitle: "\($0.owner.login) · Project",
                icon: "rectangle.split.3x1",
                target: .project($0.id)
            )
        }
        let workItems = model.myWorkStore.snapshots.values.flatMap { project in
            project.items.map { MyWorkItem(project: project, item: $0) }
        }
        entries += workItems.map {
            Entry(
                id: "item:\($0.id)",
                title: $0.item.title,
                subtitle: "\($0.project.owner.login)/\($0.project.title)\($0.item.number.map { " #\($0)" } ?? "")",
                icon: $0.item.contentType == .pullRequest ? "arrow.triangle.pull" : "record.circle",
                target: .item($0.id)
            )
        }

        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return entries }
        return entries.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var paletteProjects: [Project] {
        var projects = Dictionary(uniqueKeysWithValues: model.projectStore.projects.map { ($0.id, $0) })
        for project in model.myWorkStore.snapshots.values {
            projects[project.id] = project
        }
        return projects.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Search commands, Projects, issues, and pull requests", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(14)

            Divider()

            List(entries, selection: $selection) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.icon)
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                        if let subtitle = entry.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .tag(entry.id)
                .onTapGesture(count: 2) { perform(entry) }
            }
            .listStyle(.inset)

            Divider()
            Text("↑↓ Navigate   ↩ Open   Esc Close")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(width: 620, height: 440)
        .onAppear {
            selection = entries.first?.id
            searchFocused = true
            installKeyMonitor()
        }
        .onChange(of: query) { _, _ in selection = entries.first?.id }
        .onDisappear { removeKeyMonitor() }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125:
                moveSelection(by: 1)
                return nil
            case 126:
                moveSelection(by: -1)
                return nil
            case 36, 76:
                if let entry = entries.first(where: { $0.id == selection }) {
                    perform(entry)
                }
                return nil
            case 53:
                dismiss()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func moveSelection(by offset: Int) {
        guard entries.isEmpty == false else { return }
        let index = selection.flatMap { id in entries.firstIndex { $0.id == id } } ?? 0
        selection = entries[min(max(index + offset, 0), entries.count - 1)].id
    }

    private func perform(_ entry: Entry) {
        switch entry.target {
        case .quickAdd:
            openWindow(id: "quick-add")
            dismiss()
        case .refresh:
            Task {
                await model.projectStore.refresh()
                await model.myWorkStore.refresh()
                dismiss()
            }
        case .settings:
            openWindow(id: "settings")
            dismiss()
        case .project(let id):
            guard let project = paletteProjects.first(where: { $0.id == id }) else { return }
            Task {
                await model.openProject(project)
                openWorkspace()
            }
        case .item(let id):
            let workItem = model.myWorkStore.snapshots.values
                .flatMap { project in
                    project.items.map { MyWorkItem(project: project, item: $0) }
                }
                .first { $0.id == id }
            if let url = workItem?.item.url.flatMap(URL.init(string:)) {
                NSWorkspace.shared.open(url)
                dismiss()
            }
        }
    }

    private func openWorkspace() {
        openWindow(id: "kanban-board")
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }
}

struct QuickAddWindow: View {
    @Bindable var model: GitBoardModel

    var body: some View {
        AddProjectItemView(store: model.projectStore, presentation: .window)
        .task {
            if model.projectStore.projects.isEmpty {
                await model.projectStore.loadProjects()
            }
        }
    }
}
