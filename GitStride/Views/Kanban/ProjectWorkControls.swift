import SwiftUI

struct ProjectWorkControls: View {
    let project: Project
    let items: [ProjectItem]
    let displayedCount: Int
    let currentUserLogin: String?
    let savedViews: [SavedProjectWorkView]
    let selectedViewID: String?
    @Binding var filter: ProjectWorkFilter
    @Binding var searchText: String
    let selectView: (SavedProjectWorkView?) -> Void
    let saveView: () -> Void
    let updateView: () -> Void
    let deleteView: () -> Void
    let hiddenStatusCount: Int
    let showAllColumns: () -> Void

    private var milestones: [ProjectPlanningReference] { unique(items.compactMap(\.milestone)) }
    private var parents: [ProjectPlanningReference] { unique(items.compactMap(\.parentIssue)) }
    private var labels: [IssueLabel] { unique(items.flatMap(\.labels)).sorted { $0.name < $1.name } }
    private var issueTypes: [ProjectIssueType] { unique(items.compactMap(\.issueType)).sorted { $0.name < $1.name } }
    private var selectedView: SavedProjectWorkView? { savedViews.first { $0.id == selectedViewID } }

    var body: some View {
        if filter.isActive || !searchText.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            if filter.assignedToMe { chip("Assignee: Me") { filter.assignedToMe = false } }
                            if !filter.statusIDs.isEmpty {
                                chip("Status: " + statusFilterTitle) {
                                    filter.statusIDs = []
                                }
                            }
                            if let id = filter.labelID {
                                chip("Label: " + (labels.first { $0.id == id }.map(labelTitle) ?? "Unavailable")) { filter.labelID = nil }
                            }
                            if let id = filter.issueTypeID {
                                chip("Type: " + (issueTypes.first { $0.id == id }?.name ?? "Unavailable")) { filter.issueTypeID = nil }
                            }
                            if let id = filter.milestoneID {
                                chip("Milestone: " + (milestones.first { $0.id == id }?.displayName ?? "Unavailable")) { filter.milestoneID = nil }
                            }
                            if let id = filter.parentIssueID {
                                chip("Parent: " + (parents.first { $0.id == id }?.displayName ?? "Unavailable")) { filter.parentIssueID = nil }
                            }
                            if filter.completion != .all { chip(filter.completion.rawValue) { filter.completion = .all } }
                            if !searchText.isEmpty { chip("Search: \(searchText)") { searchText = "" } }
                            if hiddenStatusCount > 0 { chip("\(hiddenStatusCount) hidden columns", remove: showAllColumns) }
                            Button("Clear All", action: clearAll).buttonStyle(.link)
                        }.padding(.vertical, 1)
                    }
                    Text("\(displayedCount) of \(items.count)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize()
                        .accessibilityLabel("\(displayedCount) of \(items.count) items")
                }
                if filter.isDelivery { deliverySummary }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.background)
            Divider()
        }
    }

    private var statusFilterTitle: String {
        let statuses = project.statusOptions.filter { filter.statusIDs.contains($0.id) }
        let missing = filter.statusIDs.count - statuses.count
        var names = statuses.map(\.name)
        if missing > 0 { names.append("\(missing) unavailable") }
        return names.joined(separator: ", ")
    }

    private func labelTitle(_ label: IssueLabel) -> String {
        guard labels.filter({ $0.name == label.name }).count > 1 else { return label.name }
        let repositories = Set(items.filter { $0.labels.contains(where: { $0.id == label.id }) }.compactMap(\.repositoryName))
        return label.name + " · " + repositories.sorted().joined(separator: ", ")
    }

    @ViewBuilder
    var menuContents: some View {
        Text("\(displayedCount) of \(items.count) items")
        Section("Filter") {
            Toggle("Assigned to Me", isOn: $filter.assignedToMe).disabled(currentUserLogin == nil)
            Menu("Status") {
                Button("All Statuses") { filter.statusIDs = [] }
                ForEach(project.statusOptions) { status in
                    Toggle(status.name, isOn: Binding(get: { filter.statusIDs.contains(status.id) }, set: { enabled in
                        if enabled { filter.statusIDs.insert(status.id) } else { filter.statusIDs.remove(status.id) }
                    }))
                }
            }
            Menu("Issue Type") {
                Button("Any Type") { filter.issueTypeID = nil }
                ForEach(issueTypes) { type in
                    Button(type.name) { filter.issueTypeID = type.id }
                }
            }.disabled(issueTypes.isEmpty)
            Menu("Label") {
                Button("Any Label") { filter.labelID = nil }
                ForEach(labels) { label in
                    Button(labelTitle(label)) { filter.labelID = label.id }
                }
            }.disabled(labels.isEmpty)
            Divider()
            Menu("Delivery by Milestone") {
                Button("Any Milestone") { filter.milestoneID = nil }
                ForEach(milestones) { milestone in
                    Button(milestone.displayName) {
                        filter.milestoneID = milestone.id
                        filter.parentIssueID = nil
                    }
                }
            }.disabled(milestones.isEmpty)
            Menu("Delivery by Parent Issue") {
                Button("Any Parent") { filter.parentIssueID = nil }
                ForEach(parents) { parent in
                    Button(parent.displayName) {
                        filter.parentIssueID = parent.id
                        filter.milestoneID = nil
                    }
                }
            }.disabled(parents.isEmpty)
            Picker("Completion", selection: $filter.completion) {
                ForEach(ProjectWorkCompletion.allCases) { value in Text(value.rawValue).tag(value) }
            }
        }
        Button("Clear Filters", action: clearAll)
            .disabled(!filter.isActive && searchText.isEmpty && hiddenStatusCount == 0)
        Menu("Saved Views") {
            Button("None") { selectView(nil) }
            ForEach(savedViews) { view in
                Toggle(view.name, isOn: Binding(get: { selectedViewID == view.id }, set: { _ in selectView(view) }))
            }
            Divider()
            Button("Save Current View…", action: saveView)
            if let selectedView {
                Text(selectedView.name + (selectedView.filter == filter ? "" : " · Modified"))
                Button("Update Saved Filters", action: updateView)
                Button("Delete Saved View", role: .destructive, action: deleteView)
            }
        }
        Divider()
    }

    func clearAll() {
        filter = ProjectWorkFilter()
        searchText = ""
        showAllColumns()
    }

    private var deliverySummary: some View {
        let scope = filter.deliveryItems(in: items)
        let completed = scope.filter(\.isWorkComplete).count
        let blocked = scope.filter { !$0.isWorkComplete && $0.signals.blockedByCount > 0 }.count
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    summaryCounts(completed: completed, total: scope.count, blocked: blocked)
                    Spacer()
                    completionPicker
                }
                VStack(alignment: .leading) {
                    summaryCounts(completed: completed, total: scope.count, blocked: blocked)
                    completionPicker
                }
            }
            Text("Counts cover this project’s issues in the delivery, before other filters. Completed means closed on GitHub.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func summaryCounts(completed: Int, total: Int, blocked: Int) -> some View {
        Text("\(completed) / \(total) completed · \(blocked) unfinished blocked")
            .font(.callout).monospacedDigit()
    }

    private var completionPicker: some View {
        Picker("Show", selection: $filter.completion) {
            ForEach(ProjectWorkCompletion.allCases) { value in Text(value.rawValue).tag(value) }
        }.pickerStyle(.segmented).fixedSize()
    }

    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "xmark").font(.caption2)
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .help("Remove \(title)")
        .accessibilityLabel("Remove filter: \(title)")
    }

    private func unique<T: Identifiable>(_ values: [T]) -> [T] where T.ID: Hashable {
        var seen: Set<T.ID> = []
        return values.filter { seen.insert($0.id).inserted }
    }
}

struct BoardDisplayOptions: View {
    let project: Project
    let workControls: ProjectWorkControls
    @Binding var visibleStatusIDs: Set<String>
    @AppStorage private var fields: String

    init(project: Project, preferenceID: String, workControls: ProjectWorkControls, visibleStatusIDs: Binding<Set<String>>) {
        self.project = project
        self.workControls = workControls
        _visibleStatusIDs = visibleStatusIDs
        _fields = AppStorage(wrappedValue: "assignees,priority", "projectTable.\(preferenceID).cardFields")
    }

    var body: some View {
        Menu("Filter and Display Options", systemImage: "slider.horizontal.3") {
            workControls.menuContents
            Menu("Board Columns") {
                Button("Show All") { visibleStatusIDs = Set(project.statusOptions.map(\.id)) }
                ForEach(project.statusOptions) { status in
                    Toggle(status.name, isOn: Binding(get: { visibleStatusIDs.contains(status.id) }, set: { enabled in
                        if enabled { visibleStatusIDs.insert(status.id) } else { visibleStatusIDs.remove(status.id) }
                    }))
                    .disabled(visibleStatusIDs.count == 1 && visibleStatusIDs.contains(status.id))
                }
            }
            Section("Card Fields") {
                fieldToggle("Assignees", id: "assignees")
                fieldToggle("Priority", id: "priority")
                fieldToggle("Milestone", id: "milestone")
                fieldToggle("Labels", id: "labels")
                fieldToggle("Engineering Signals", id: "signals")
                ForEach(project.fields.filter { $0.isEditable && $0.id != project.statusField?.id && $0.name.caseInsensitiveCompare("Priority") != .orderedSame }) { field in
                    fieldToggle(field.name, id: "field:" + field.id)
                }
            }
            Divider()
            Button("Reset Card Fields") { fields = "assignees,priority" }
        }.help("Filter items and customize the board")
    }

    private func fieldToggle(_ title: String, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { fields.split(separator: ",").contains(Substring(id)) }, set: { enabled in
            var values = Set(fields.split(separator: ",").map(String.init))
            if enabled { values.insert(id) } else { values.remove(id) }
            fields = values.sorted().joined(separator: ",")
        }))
    }
}
