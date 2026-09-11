import SwiftUI

struct KanbanColumnsView: View {
    let store: ProjectStore
    let project: Project
    let items: [ProjectItem]
    let statuses: [StatusOption]
    let preferenceID: String
    let emptyMessage: String
    let isSelecting: Bool
    @Binding var selectedItemIDs: Set<String>
    let showInspector: (ItemInspectorReference) -> Void
    let reportError: (Error) -> Void

    private static let minimumColumnWidth: CGFloat = 260
    private static let idealOverflowColumnWidth: CGFloat = 280
    private static let maximumColumnWidth: CGFloat = 420
    private static let columnSpacing: CGFloat = 8

    private struct Column: Identifiable {
        let status: StatusOption?
        var id: String? { status?.id }
    }

    var body: some View {
        let showsRepository = Set(project.items.compactMap(\.repositoryName)).count > 1
        let cardFields = project.fields.filter { $0.isEditable && $0.id != project.statusField?.id }
        let knownStatusIDs = Set(project.statusOptions.map(\.id))
        let includesNoStatus = project.items.contains { hasNoStatus($0, knownIDs: knownStatusIDs) }
        let columns = statuses.map { Column(status: $0) } + (includesNoStatus ? [Column(status: nil)] : [])
        GeometryReader { geometry in
            let columnCount = max(columns.count, 1)
            let totalSpacing = CGFloat(columnCount - 1) * Self.columnSpacing
            let fittingWidth = (geometry.size.width - 32 - totalSpacing) / CGFloat(columnCount)
            let columnWidth = fittingWidth >= Self.minimumColumnWidth
                ? min(Self.maximumColumnWidth, fittingWidth) : Self.idealOverflowColumnWidth

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Self.columnSpacing) {
                    ForEach(columns) { column in
                        let status = column.status
                        let columnItems = items.filter { item in
                            status.map { item.statusOptionId == $0.id } ?? hasNoStatus(item, knownIDs: knownStatusIDs)
                        }
                        KanbanColumn(
                            projectID: project.id, preferenceID: preferenceID,
                            showsRepository: showsRepository, availableFields: cardFields,
                            status: status, items: columnItems, emptyMessage: emptyMessage,
                            allStatuses: project.statusOptions, store: store,
                            isSelecting: isSelecting, selectedItemIDs: $selectedItemIDs,
                            showInspector: showInspector, reportError: reportError
                        )
                        .frame(width: columnWidth, height: geometry.size.height - 32)
                    }
                }
                .padding(16)
            }
            .id([preferenceID, includesNoStatus ? "includes-no-status" : "statuses-only"] + statuses.map(\.id))
        }
    }

    private func hasNoStatus(_ item: ProjectItem, knownIDs: Set<String>) -> Bool {
        item.statusOptionId.map { !knownIDs.contains($0) } ?? true
    }
}
