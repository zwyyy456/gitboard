import SwiftUI

struct TableDisplayOptions: View {
    let project: Project
    @Binding var collapsedGroups: Set<ProjectTableRow.ID>
    @AppStorage private var columns: TableColumnCustomization<ProjectTableRow>
    @AppStorage private var sortColumn: String
    @AppStorage private var sortAscending: Bool
    @AppStorage private var fieldID: String
    @AppStorage private var groupsByStatus: Bool

    init(project: Project, preferenceID: String, collapsedGroups: Binding<Set<ProjectTableRow.ID>>) {
        self.project = project
        _collapsedGroups = collapsedGroups
        let preferences = ProjectDisplayPreferences(id: preferenceID)
        _columns = AppStorage(wrappedValue: TableColumnCustomization(), preferences.key(for: .columns))
        _sortColumn = AppStorage(wrappedValue: "", preferences.key(for: .sortColumn))
        _sortAscending = AppStorage(wrappedValue: true, preferences.key(for: .sortAscending))
        _fieldID = AppStorage(wrappedValue: "", preferences.key(for: .fieldID))
        _groupsByStatus = AppStorage(wrappedValue: true, preferences.key(for: .groupsByStatus))
    }

    private var availableFields: [ProjectField] {
        project.fields.filter { $0.isEditable && $0.id != project.statusField?.id }
    }

    var body: some View {
        Menu("Display Options", systemImage: "slider.horizontal.3") {
            Menu("Show Fields") {
                columnToggle(String(localized: "Status"), id: "status", defaultVisible: !groupsByStatus)
                columnToggle(String(localized: "Assignees"), id: "assignees")
                columnToggle(String(localized: "Updated"), id: "updated")
                columnToggle(String(localized: "Repository"), id: "repository", defaultVisible: false)
                columnToggle(String(localized: "Labels"), id: "labels", defaultVisible: false)
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
            Picker("Group By", selection: $groupsByStatus) {
                Text("None").tag(false)
                Text("Status").tag(true)
            }
            if groupsByStatus {
                Button("Expand All Groups") { collapsedGroups.removeAll() }
            }
            Divider()
            Menu("Sort By") {
                sortOption(String(localized: "Project Order"), id: "")
                sortOption("ID", id: "number")
                sortOption(String(localized: "Title"), id: "title")
                sortOption(String(localized: "Status"), id: "status")
                sortOption(String(localized: "Assignees"), id: "assignees")
                sortOption(String(localized: "Updated"), id: "updated")
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
        .help("Group, sort, and choose visible fields")
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

    private func columnToggle(_ title: String, id: String, defaultVisible: Bool = true) -> some View {
        Toggle(title, isOn: Binding(
            get: {
                let visibility = columns[visibility: id]
                return visibility == .visible || (visibility == .automatic && defaultVisible)
            }, set: { columns[visibility: id] = $0 ? .visible : .hidden }
        ))
    }

}
