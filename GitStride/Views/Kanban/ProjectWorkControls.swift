import SwiftUI

struct ProjectWorkControls: View {
    let project: Project
    let items: [ProjectItem]
    let matchingCount: Int
    let currentUserLogin: String?
    let savedViews: [SavedProjectWorkView]
    let selectedViewID: String?
    @Binding var filter: ProjectWorkFilter
    @Binding var searchText: String
    let selectView: (SavedProjectWorkView?) -> Void
    let saveView: () -> Void
    let updateView: () -> Void
    let deleteView: () -> Void

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
                            if filter.assignedToMe { chip(String(localized: "Assignee: Me")) { filter.assignedToMe = false } }
                            if !filter.statusIDs.isEmpty {
                                chip(String(localized: "Status: \(statusFilterTitle)")) {
                                    filter.statusIDs = []
                                }
                            }
                            if let id = filter.labelID {
                                chip(String(localized: "Label: \(labels.first { $0.id == id }.map(labelTitle) ?? String(localized: "Unavailable"))")) { filter.labelID = nil }
                            }
                            if let id = filter.issueTypeID {
                                chip(String(localized: "Type: \(issueTypes.first { $0.id == id }?.name ?? String(localized: "Unavailable"))")) { filter.issueTypeID = nil }
                            }
                            if let id = filter.milestoneID {
                                chip(String(localized: "Milestone: \(milestones.first { $0.id == id }?.displayName ?? String(localized: "Unavailable"))")) { filter.milestoneID = nil }
                            }
                            if let id = filter.parentIssueID {
                                chip(String(localized: "Parent: \(parents.first { $0.id == id }?.displayName ?? String(localized: "Unavailable"))")) { filter.parentIssueID = nil }
                            }
                            if filter.completion != .all { chip(filter.completion.title) { filter.completion = .all } }
                            if !searchText.isEmpty { chip(String(localized: "Search: \(searchText)")) { searchText = "" } }
                            Button("Clear Filters", action: clearFilters).buttonStyle(.link)
                        }.padding(.vertical, 1)
                    }
                    Text("\(matchingCount) of \(items.count) match")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize()
                        .accessibilityLabel("\(matchingCount) of \(items.count) items match")
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
        if missing > 0 { names.append(String(localized: "\(missing) unavailable")) }
        return names.joined(separator: ", ")
    }

    private func labelTitle(_ label: IssueLabel) -> String {
        guard labels.filter({ $0.name == label.name }).count > 1 else { return label.name }
        let repositories = Set(items.filter { $0.labels.contains(where: { $0.id == label.id }) }.compactMap(\.repositoryName))
        return label.name + " · " + repositories.sorted().joined(separator: ", ")
    }

    @ViewBuilder
    var filterMenuContents: some View {
        Text("\(matchingCount) of \(items.count) items match")
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
            Menu("More Conditions") {
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
                    ForEach(ProjectWorkCompletion.allCases) { value in Text(value.title).tag(value) }
                }
            }
        }
        Button("Clear Filters", action: clearFilters)
            .disabled(!filter.isActive && searchText.isEmpty)
    }

    @ViewBuilder
    var savedViewMenuContents: some View {
            Button("None") { selectView(nil) }
            ForEach(savedViews) { view in
                Toggle(view.name, isOn: Binding(get: { selectedViewID == view.id }, set: { _ in selectView(view) }))
            }
            Divider()
            Button("Save Current View…", action: saveView)
            if let selectedView {
                Text(selectedView.filter == filter ? selectedView.name : String(localized: "\(selectedView.name) · Modified"))
                Button("Update Saved Filters", action: updateView)
                Button("Delete Saved View", role: .destructive, action: deleteView)
            }
    }

    func clearFilters() {
        filter = ProjectWorkFilter()
        searchText = ""
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
            ForEach(ProjectWorkCompletion.allCases) { value in Text(value.title).tag(value) }
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
    @Binding var visibleStatusIDs: Set<String>
    @AppStorage private var fields: String

    init(project: Project, preferenceID: String, visibleStatusIDs: Binding<Set<String>>) {
        self.project = project
        _visibleStatusIDs = visibleStatusIDs
        _fields = AppStorage(wrappedValue: "assignees", ProjectDisplayPreferences(id: preferenceID).key(for: .cardFields))
    }

    var body: some View {
        Menu("Display Options", systemImage: "slider.horizontal.3") {
            Menu("Show Fields") {
                fieldToggle(String(localized: "Assignees"), id: "assignees")
                fieldToggle(String(localized: "Milestone"), id: "milestone")
                fieldToggle(String(localized: "Labels"), id: "labels")
                fieldToggle(String(localized: "Engineering Signals"), id: "signals")
                ForEach(project.fields.filter { $0.isEditable && $0.id != project.statusField?.id }) { field in
                    fieldToggle(field.name, id: "field:" + field.id)
                }
            }
            Menu("Board Columns") {
                Text("\(visibleStatusIDs.count) of \(project.statusOptions.count) columns shown")
                Button("Show All Columns") { visibleStatusIDs = Set(project.statusOptions.map(\.id)) }
                ForEach(project.statusOptions) { status in
                    Toggle(status.name, isOn: Binding(get: { visibleStatusIDs.contains(status.id) }, set: { enabled in
                        if enabled { visibleStatusIDs.insert(status.id) } else { visibleStatusIDs.remove(status.id) }
                    }))
                    .disabled(visibleStatusIDs.count == 1 && visibleStatusIDs.contains(status.id))
                }
            }
            Divider()
            Button("Reset Card Fields") { fields = "assignees" }
        }.help("Choose board columns and card fields")
    }

    private func fieldToggle(_ title: String, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { fields.split(separator: ",").contains(Substring(id)) }, set: { enabled in
            var values = Set(fields.split(separator: ",").map(String.init))
            if enabled { values.insert(id) } else { values.remove(id) }
            fields = values.sorted().joined(separator: ",")
        }))
    }
}
