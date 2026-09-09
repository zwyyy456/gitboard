import SwiftUI

struct ProjectTableView: View {
    let project: Project
    let items: [ProjectItem]
    @Bindable var store: ProjectStore
    let isSelecting: Bool
    @Binding var selectedItemIDs: Set<String>
    let showItemDetail: (ItemInspectorReference) -> Void
    let reportError: (Error) -> Void

    @AppStorage private var columns: TableColumnCustomization<ProjectTableRow>
    @AppStorage private var sortColumn: String
    @AppStorage private var sortAscending: Bool
    @AppStorage private var fieldID: String
    @AppStorage private var groupsByStatus: Bool
    @State private var collapsedGroups: Set<ProjectTableRow.ID> = []
    @State private var itemToRemove: ProjectItem?

    init(
        project: Project, items: [ProjectItem], store: ProjectStore,
        isSelecting: Bool, selectedItemIDs: Binding<Set<String>>,
        showItemDetail: @escaping (ItemInspectorReference) -> Void,
        reportError: @escaping (Error) -> Void
    ) {
        self.project = project
        self.items = items
        self.store = store
        self.isSelecting = isSelecting
        _selectedItemIDs = selectedItemIDs
        self.showItemDetail = showItemDetail
        self.reportError = reportError
        let prefix = "projectTable.\(project.id)."
        _columns = AppStorage(wrappedValue: TableColumnCustomization(), prefix + "columns")
        _sortColumn = AppStorage(wrappedValue: "", prefix + "sortColumn")
        _sortAscending = AppStorage(wrappedValue: true, prefix + "sortAscending")
        _fieldID = AppStorage(wrappedValue: "", prefix + "fieldID")
        _groupsByStatus = AppStorage(wrappedValue: true, prefix + "groupsByStatus")
    }

    private var availableFields: [ProjectField] {
        project.fields.filter { $0.kind != .unsupported && $0.id != project.statusField?.id }
    }

    private var sortOrder: Binding<[ProjectTableSort]> {
        Binding(get: {
            guard !sortColumn.isEmpty else { return [] }
            return [ProjectTableSort(column: sortColumn, fieldID: fieldID,
                                     order: sortAscending ? .forward : .reverse)]
        }, set: { values in
            sortColumn = values.first?.column ?? ""
            sortAscending = values.first?.order != .reverse
        })
    }

    private var selection: Binding<Set<ProjectTableRow.ID>> {
        Binding(get: { Set(selectedItemIDs.map(ProjectTableRow.ID.item)) }, set: { ids in
            selectedItemIDs = Set(ids.compactMap(\.itemID))
        })
    }

    var body: some View {
        table
            .tableStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .font(.system(size: 13))
            .contextMenu(forSelectionType: ProjectTableRow.ID.self) { ids in
                itemContextMenu(ids)
            } primaryAction: { ids in
                guard !isSelecting, let id = ids.first?.itemID,
                      let item = items.first(where: { $0.id == id }) else { return }
                open(item)
            }
            .overlay {
                if items.isEmpty { ContentUnavailableView.search }
            }
            .onChange(of: availableFields.map(\.id), initial: true) { _, ids in
                if !fieldID.isEmpty && !ids.contains(fieldID) {
                    fieldID = ""
                    columns[visibility: "field"] = .hidden
                    if sortColumn == "field" { sortColumn = "" }
                }
                if sortColumn.hasPrefix("field:"), !ids.contains(String(sortColumn.dropFirst(6))) {
                    sortColumn = ""
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) { displayOptions }
            }
            .confirmationDialog(
                "Remove \"\(itemToRemove?.title ?? "")\" from the project?",
                isPresented: Binding(get: { itemToRemove != nil }, set: { if !$0 { itemToRemove = nil } }),
                titleVisibility: .visible, presenting: itemToRemove
            ) { item in
                Button("Remove", role: .destructive) {
                    Task {
                        do { try await store.deleteItem(item, from: project.id) }
                        catch { reportError(error) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Archive is recommended when you may need the item again.")
            }
    }

    @ViewBuilder
    private func itemContextMenu(_ ids: Set<ProjectTableRow.ID>) -> some View {
        if ids.count == 1, let id = ids.first?.itemID,
           let item = items.first(where: { $0.id == id }) {
            KanbanCardContextMenu(
                projectID: project.id, item: item, allStatuses: project.statusOptions, store: store,
                showDeleteConfirmation: Binding(
                    get: { itemToRemove?.id == item.id }, set: { itemToRemove = $0 ? item : nil }
                ), showInspector: { open(item) }, reportError: reportError
            )
        }
    }

    @ViewBuilder
    private var table: some View {
        if #available(macOS 14.4, *) {
            dynamicTable
        } else {
            makeTable { legacyFieldColumn }
        }
    }

    @available(macOS 14.4, *)
    private var dynamicTable: some View {
        makeTable {
            TableColumnForEach(availableFields) { field in customFieldColumn(field) }
        }
    }

    private func makeTable<Fields: TableColumnContent>(
        @TableColumnBuilder<ProjectTableRow, ProjectTableSort> fields: () -> Fields
    ) -> some View where Fields.TableRowValue == ProjectTableRow,
                         Fields.TableColumnSortComparator == ProjectTableSort {
        Table(of: ProjectTableRow.self, selection: selection,
              sortOrder: sortOrder, columnCustomization: $columns) {
            numberColumn
            titleColumn
            statusColumn
            assigneesColumn
            updatedColumn
            repositoryColumn
            labelsColumn
            fields()
        } rows: {
            if groupsByStatus {
                ForEach(ProjectTableGroup.make(items: items, statuses: project.statusOptions,
                                              sortOrder: sortOrder.wrappedValue)) { group in
                    DisclosureTableRow(group.header, isExpanded: expansion(for: group.id)) {
                        ForEach(group.rows) { row in TableRow(row) }
                    }
                }
            } else {
                ForEach(items.map(ProjectTableRow.init(item:)).sorted(using: sortOrder.wrappedValue)) { row in
                    TableRow(row)
                }
            }
        }
    }

    private func expansion(for id: ProjectTableRow.ID) -> Binding<Bool> {
        Binding(get: { !collapsedGroups.contains(id) }, set: { expanded in
            if expanded { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
        })
    }

    private var numberColumn: some TableColumnContent<ProjectTableRow, ProjectTableSort> {
        TableColumn("ID", sortUsing: ProjectTableSort(column: "number")) { (row: ProjectTableRow) in
            Text(row.item?.number.map { "#\($0)" } ?? "")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minHeight: 38)
        }
        .width(min: 65, ideal: 76, max: 110)
        .customizationID("number")
        .disabledCustomizationBehavior(.visibility)
    }

    private var titleColumn: some TableColumnContent<ProjectTableRow, ProjectTableSort> {
        TableColumn("Title", sortUsing: ProjectTableSort(column: "title")) { (row: ProjectTableRow) in
            titleCell(row)
        }
        .width(min: 280, ideal: 500)
        .customizationID("title")
        .disabledCustomizationBehavior(.visibility)
    }

    private var statusColumn: some TableColumnContent<ProjectTableRow, ProjectTableSort> {
        TableColumn("Status", sortUsing: ProjectTableSort(column: "status")) { (row: ProjectTableRow) in
            if let item = row.item {
                HStack(spacing: 7) {
                    Circle().fill(status(for: item)?.swiftUIColor ?? .secondary).frame(width: 7, height: 7)
                    Text(item.status ?? "No Status").foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .width(min: 100, ideal: 120, max: 180)
        .customizationID("status")
    }

    private var assigneesColumn: some TableColumnContent<ProjectTableRow, ProjectTableSort> {
        TableColumn("Assignees", sortUsing: ProjectTableSort(column: "assignees")) { (row: ProjectTableRow) in
            if let item = row.item { assigneeCell(item) }
        }
        .width(min: 90, ideal: 130, max: 220)
        .customizationID("assignees")
    }

    private var updatedColumn: some TableColumnContent<ProjectTableRow, ProjectTableSort> {
        TableColumn("Updated", sortUsing: ProjectTableSort(column: "updated")) { (row: ProjectTableRow) in
            if let item = row.item { updatedCell(item) }
        }
        .width(min: 72, ideal: 90, max: 130)
        .customizationID("updated")
    }

    private var repositoryColumn: some TableColumnContent<ProjectTableRow, ProjectTableSort> {
        TableColumn("Repository", sortUsing: ProjectTableSort(column: "repository")) { (row: ProjectTableRow) in
            if let item = row.item { secondaryCell(item.repositoryName ?? "") }
        }
        .width(min: 100, ideal: 160, max: 280)
        .customizationID("repository")
        .defaultVisibility(.hidden)
    }

    private var labelsColumn: some TableColumnContent<ProjectTableRow, ProjectTableSort> {
        TableColumn("Labels", sortUsing: ProjectTableSort(column: "labels")) { (row: ProjectTableRow) in
            if let item = row.item { secondaryCell(ProjectTableSort.labels(item)) }
        }
        .width(min: 100, ideal: 160, max: 280)
        .customizationID("labels")
        .defaultVisibility(.hidden)
    }

    private func customFieldColumn(_ field: ProjectField) -> some TableColumnContent<ProjectTableRow, ProjectTableSort> {
        TableColumn(field.name, sortUsing: ProjectTableSort(column: "field:\(field.id)")) { (row: ProjectTableRow) in
            if let item = row.item { secondaryCell(ProjectTableSort.fieldText(item.fieldValues[field.id])) }
        }
        .width(min: 100, ideal: 140, max: 280)
        .customizationID("field:\(field.id)")
        .defaultVisibility(.hidden)
    }

    private var legacyFieldColumn: some TableColumnContent<ProjectTableRow, ProjectTableSort> {
        TableColumn(availableFields.first { $0.id == fieldID }?.name ?? "Project Field",
                    sortUsing: ProjectTableSort(column: "field", fieldID: fieldID)) { (row: ProjectTableRow) in
            if let item = row.item { secondaryCell(ProjectTableSort.fieldText(item.fieldValues[fieldID])) }
        }
        .width(min: 100, ideal: 140, max: 280)
        .customizationID("field")
        .defaultVisibility(.hidden)
    }

    @ViewBuilder
    private func titleCell(_ row: ProjectTableRow) -> some View {
        if let item = row.item {
            Button {
                if isSelecting {
                    if selectedItemIDs.contains(item.id) { selectedItemIDs.remove(item.id) }
                    else { selectedItemIDs.insert(item.id) }
                } else {
                    open(item)
                }
            } label: {
                Text(item.title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.title)
            .accessibilityHint(isSelecting ? "Toggles selection" : "Shows details")
        } else {
            HStack(spacing: 8) {
                Circle().fill(row.status?.swiftUIColor ?? .secondary).frame(width: 8, height: 8)
                Text(row.status?.name ?? "No Status").fontWeight(.semibold)
                Text(row.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(minHeight: 38)
            .accessibilityElement(children: .combine)
        }
    }

    private func assigneeCell(_ item: ProjectItem) -> some View {
        HStack(spacing: 6) {
            if let assignee = item.assignees.first {
                AsyncImage(url: URL(string: assignee.avatarUrl)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").foregroundStyle(.tertiary)
                }
                .frame(width: 20, height: 20)
                .clipShape(Circle())
                .accessibilityHidden(true)
                Text(assignee.name ?? assignee.login).lineLimit(1)
                if item.assignees.count > 1 { Text("+\(item.assignees.count - 1)").font(.caption) }
            } else {
                Image(systemName: "person.crop.circle.dashed").foregroundStyle(.tertiary)
                    .accessibilityLabel("Unassigned")
            }
        }
        .foregroundStyle(.secondary)
        .help(item.assignees.isEmpty ? "Unassigned" : ProjectTableSort.assignees(item))
    }

    @ViewBuilder
    private func updatedCell(_ item: ProjectItem) -> some View {
        if let value = item.updatedAt, let date = try? Date(value, strategy: .iso8601) {
            let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
            Text(date, format: sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.year().month(.abbreviated).day())
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help(date.formatted(date: .complete, time: .shortened))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func status(for item: ProjectItem) -> StatusOption? {
        project.statusOptions.first { $0.id == item.statusOptionId }
    }

    private var displayOptions: some View {
        Menu("Display Options", systemImage: "slider.horizontal.3") {
            Picker("Group By", selection: $groupsByStatus) {
                Text("None").tag(false)
                Text("Status").tag(true)
            }
            if groupsByStatus {
                Button("Expand All Groups") { collapsedGroups.removeAll() }
            }
            Divider()
            Menu("Show Fields") {
                columnToggle("Status", id: "status")
                columnToggle("Assignees", id: "assignees")
                columnToggle("Updated", id: "updated")
                columnToggle("Repository", id: "repository", defaultVisible: false)
                columnToggle("Labels", id: "labels", defaultVisible: false)
                if !availableFields.isEmpty {
                    Divider()
                    if #available(macOS 14.4, *) {
                        ForEach(availableFields) { field in
                            columnToggle(field.name, id: "field:\(field.id)", defaultVisible: false)
                        }
                    } else {
                        Menu("Project Field") {
                            Button("None") { columns[visibility: "field"] = .hidden }
                            ForEach(availableFields) { field in legacyFieldToggle(field) }
                        }
                    }
                }
            }
            Menu("Sort By") {
                sortOption("Project Order", id: "")
                sortOption("ID", id: "number")
                sortOption("Title", id: "title")
                sortOption("Status", id: "status")
                sortOption("Assignees", id: "assignees")
                sortOption("Updated", id: "updated")
                Divider()
                Toggle("Ascending", isOn: $sortAscending).disabled(sortColumn.isEmpty)
            }
            Divider()
            Button("Reset Columns") {
                columns = TableColumnCustomization()
                fieldID = ""
                sortColumn = ""
            }
        }
        .help("Grouping, visible fields, and sorting")
    }

    private func sortOption(_ title: String, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { sortColumn == id }, set: { _ in sortColumn = id }))
    }

    private func legacyFieldToggle(_ field: ProjectField) -> some View {
        Toggle(field.name, isOn: Binding(
            get: { fieldID == field.id && columns[visibility: "field"] == .visible },
            set: { visible in
                fieldID = field.id
                columns[visibility: "field"] = visible ? .visible : .hidden
            }
        ))
    }

    private func secondaryCell(_ text: String) -> some View {
        Text(text.isEmpty ? "—" : text).foregroundStyle(.secondary).lineLimit(1).help(text)
    }

    private func columnToggle(_ title: String, id: String, defaultVisible: Bool = true) -> some View {
        Toggle(title, isOn: Binding(
            get: {
                let visibility = columns[visibility: id]
                return visibility == .visible || (visibility == .automatic && defaultVisible)
            }, set: { columns[visibility: id] = $0 ? .visible : .hidden }
        ))
    }

    private func open(_ item: ProjectItem) {
        showItemDetail(ItemInspectorReference(projectID: project.id, itemID: item.id))
    }
}

// Presentation rows keep status headers separate from remote Project items and selection IDs.
struct ProjectTableRow: Identifiable {
    enum ID: Hashable {
        case item(String)
        case status(String?)

        var itemID: String? {
            if case .item(let id) = self { return id }
            return nil
        }
    }

    let id: ID
    let item: ProjectItem?
    var status: StatusOption? = nil
    var count = 0

    init(item: ProjectItem) {
        id = .item(item.id)
        self.item = item
    }

    init(status: StatusOption?, count: Int) {
        id = .status(status?.id)
        item = nil
        self.status = status
        self.count = count
    }
}

struct ProjectTableGroup: Identifiable {
    let header: ProjectTableRow
    let rows: [ProjectTableRow]
    var id: ProjectTableRow.ID { header.id }

    static func make(items: [ProjectItem], statuses: [StatusOption], sortOrder: [ProjectTableSort]) -> [Self] {
        let knownIDs = Set(statuses.map(\.id))
        let buckets = Dictionary(grouping: items) { item in
            item.statusOptionId.flatMap { knownIDs.contains($0) ? $0 : nil }
        }
        return (statuses.map(Optional.some) + [nil]).compactMap { status in
            guard let items = buckets[status?.id], !items.isEmpty else { return nil }
            return Self(header: ProjectTableRow(status: status, count: items.count),
                        rows: items.map(ProjectTableRow.init(item:)).sorted(using: sortOrder))
        }
    }
}

struct ProjectTableSort: SortComparator {
    var column: String
    var fieldID: String = ""
    var order: SortOrder = .forward

    private var customFieldID: String? {
        if column.hasPrefix("field:") { return String(column.dropFirst(6)) }
        return column == "field" ? fieldID : nil
    }

    func compare(_ lhs: ProjectTableRow, _ rhs: ProjectTableRow) -> ComparisonResult {
        guard let lhs = lhs.item, let rhs = rhs.item else { return .orderedSame }
        let result: ComparisonResult
        if let id = customFieldID, case .number(let left) = lhs.fieldValues[id],
           case .number(let right) = rhs.fieldValues[id] {
            result = left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
        } else if column == "number" {
            let left = lhs.number ?? 0, right = rhs.number ?? 0
            result = left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
        } else {
            result = value(lhs).localizedStandardCompare(value(rhs))
        }
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private func value(_ item: ProjectItem) -> String {
        if let id = customFieldID { return Self.fieldText(item.fieldValues[id]) }
        switch column {
        case "title": return item.title
        case "status": return item.status ?? ""
        case "assignees": return Self.assignees(item)
        case "updated": return item.updatedAt ?? ""
        case "repository": return item.repositoryName ?? ""
        case "labels": return Self.labels(item)
        default: return ""
        }
    }

    static func assignees(_ item: ProjectItem) -> String {
        item.assignees.map { $0.login }.joined(separator: ", ")
    }

    static func labels(_ item: ProjectItem) -> String {
        item.labels.map(\.name).joined(separator: ", ")
    }

    static func fieldText(_ value: ProjectFieldValue?) -> String {
        switch value {
        case .singleSelect(_, let name): name
        case .iteration(_, let title): title
        case .date(let date): date
        case .number(let number): number.formatted()
        case .text(let text): text
        case nil: ""
        }
    }
}
