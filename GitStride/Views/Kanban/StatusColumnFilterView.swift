import SwiftUI

struct StatusColumnFilterView: View {
    @Bindable var store: ProjectStore
    let project: Project

    private var visibleStatusIDs: Set<String> {
        store.visibleKanbanStatusIDs(in: project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Visible Statuses")
                    .font(.headline)

                Spacer()

                Button("Show All", action: showAllStatuses)
                    .disabled(visibleStatusIDs.count == project.statusOptions.count)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(project.statusOptions) { status in
                        Toggle(isOn: visibilityBinding(for: status)) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(status.swiftUIColor)
                                    .frame(width: 8, height: 8)
                                    .accessibilityHidden(true)

                                Text(status.name)
                                    .lineLimit(2)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(
                            visibleStatusIDs.count == 1
                                && visibleStatusIDs.contains(status.id)
                        )
                    }
                }
            }
            .frame(maxHeight: 360)

            Text("\(visibleStatusIDs.count) of \(project.statusOptions.count) statuses shown")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360, alignment: .leading)
    }

    private func visibilityBinding(for status: StatusOption) -> Binding<Bool> {
        Binding(
            get: { visibleStatusIDs.contains(status.id) },
            set: { store.setKanbanStatus(status, visible: $0, in: project) }
        )
    }

    private func showAllStatuses() {
        store.showAllKanbanStatuses(in: project)
    }
}
