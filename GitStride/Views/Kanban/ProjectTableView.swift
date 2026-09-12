import SwiftUI

struct ProjectTableView: View {
    let project: Project
    let workControls: ProjectWorkControls
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
    @Binding var collapsedGroups: Set<ProjectTableRow.ID>
    @State private var itemToRemove: ProjectItem?

    init(
        project: Project, items: [ProjectItem], store: ProjectStore,
        preferenceID: String? = nil,
        workControls: ProjectWorkControls,
        collapsedGroups: Binding<Set<ProjectTableRow.ID>>,
        isSelecting: Bool, selectedItemIDs: Binding<Set<String>>,
        showItemDetail: @escaping (ItemInspectorReference) -> Void,
        reportError: @escaping (Error) -> Void
    ) {
        self.project = project
        self.workControls = workControls
        _collapsedGroups = collapsedGroups
        self.items = items
        self.store = store
        self.isSelecting = isSelecting
        _selectedItemIDs = selectedItemIDs
        self.showItemDetail = showItemDetail
        self.reportError = reportError
        let preferences = ProjectDisplayPreferences(id: preferenceID ?? project.id)
        _columns = AppStorage(wrappedValue: TableColumnCustomization(), preferences.key(for: .columns))
        _sortColumn = AppStorage(wrappedValue: "", preferences.key(for: .sortColumn))
        _sortAscending = AppStorage(wrappedValue: true, preferences.key(for: .sortAscending))
        _fieldID = AppStorage(wrappedValue: "", preferences.key(for: .fieldID))
        _groupsByStatus = AppStorage(wrappedValue: true, preferences.key(for: .groupsByStatus))
    }

    private var availableFields: [ProjectField] {
        project.fields.filter { $0.kind != .unsupported && $0.id != project.statusField?.id }
    }

    private var sortOrder: Binding<[ProjectTableSort]> {
        Binding(get: {
            guard !sortColumn.isEmpty else { return [] }
            let selectedFieldID = sortColumn.hasPrefix("field:") ? String(sortColumn.dropFirst(6)) : fieldID
            let optionOrder = project.fields.first { $0.id == selectedFieldID }?.options.map(\.id) ?? []
            return [ProjectTableSort(column: sortColumn, fieldID: fieldID,
                                     order: sortAscending ? .forward : .reverse, optionOrder: optionOrder)]
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
                guard !isSelecting, ids.count == 1, let id = ids.first?.itemID,
                      let item = items.first(where: { $0.id == id }) else { return }
                open(item)
            }
            .onKeyPress(.return) {
                guard !isSelecting, selectedItemIDs.count == 1,
                      let item = items.first(where: { selectedItemIDs.contains($0.id) }) else { return .ignored }
                open(item)
                return .handled
            }
            .onChange(of: items.map(\.id)) { _, ids in
                selectedItemIDs.formIntersection(ids)
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("No Matching Items", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Try removing filters or changing your search.")
                    } actions: {
                        Button("Clear Filters", action: workControls.clearFilters)
                    }
                }
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
            titleColumn
            numberColumn
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
                    Section(isExpanded: expansion(for: group.id)) {
                        ForEach(group.rows) { row in TableRow(row) }
                    } header: {
                        titleCell(group.header)
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
                .frame(minHeight: 26)
        }
        .width(min: 50, ideal: 60, max: 90)
        .customizationID("number")
        .disabledCustomizationBehavior(.visibility)
    }

    private var titleColumn: some TableColumnContent<ProjectTableRow, ProjectTableSort> {
        TableColumn("Title", sortUsing: ProjectTableSort(column: "title")) { (row: ProjectTableRow) in
            titleCell(row)
        }
        .width(min: 280, ideal: 500)
        .customizationID("title")
        .disabledCustomizationBehavior([.visibility, .reorder])
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
        .defaultVisibility(groupsByStatus ? .hidden : .visible)
    }

    private var assigneesColumn: some TableColumnContent<ProjectTableRow, ProjectTableSort> {
        TableColumn("Assignees", sortUsing: ProjectTableSort(column: "assignees")) { (row: ProjectTableRow) in
            if let item = row.item { assigneeCell(item) }
        }
        .width(min: 80, ideal: 110, max: 180)
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
            Text(item.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .help(item.title)
        } else {
            HStack(spacing: 8) {
                Circle().fill(row.status?.swiftUIColor ?? .secondary).frame(width: 8, height: 8)
                Text(row.status?.name ?? "No Status").fontWeight(.semibold)
                Text(row.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
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
                Text("—").foregroundStyle(.tertiary)
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

    private func secondaryCell(_ text: String) -> some View {
        Text(text.isEmpty ? "—" : text).foregroundStyle(.secondary).lineLimit(1).help(text)
    }

    private func open(_ item: ProjectItem) {
        showItemDetail(ItemInspectorReference(projectID: project.id, itemID: item.id))
    }
}

// Presentation rows keep status headers separate from remote Project items and selection IDs.
