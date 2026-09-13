import SwiftUI

struct ItemPropertiesView: View {
    @Bindable var store: ProjectStore
    let reference: ItemInspectorReference
    @Binding var operationErrorMessage: String?

    @State private var isWorking = false

    private var project: Project? { store.project(id: reference.projectID) }
    private var item: ProjectItem? { store.item(for: reference) }
    private var canEdit: Bool { store.canEditProject(id: reference.projectID) }

    var body: some View {
        ScrollView {
            if let project, let item {
                VStack(alignment: .leading, spacing: 20) {
                    fieldSection(project: project, item: item)

                    if item.contentType == .issue {
                        ItemMilestoneSection(store: store, item: item,
                            operationErrorMessage: $operationErrorMessage, isWorking: $isWorking)
                        ItemRelationshipsSection(store: store, item: item,
                            operationErrorMessage: $operationErrorMessage, isWorking: $isWorking)
                    }

                    ItemAssigneesSection(store: store, item: item,
                            operationErrorMessage: $operationErrorMessage, projectID: reference.projectID)

                    if item.contentType == .issue {
                        ItemLabelsSection(store: store, item: item,
                            operationErrorMessage: $operationErrorMessage, projectID: reference.projectID)
                    }

                    signalsSection(item)

                }
                .padding(20)
            }
        }
        .overlay {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func fieldSection(project: Project, item: ProjectItem) -> some View {
        ItemPropertySection(String(localized: "Project Fields")) {
            ForEach(project.fields.filter(\.isEditable)) { field in
                ProjectFieldEditor(
                    field: field,
                    value: item.fieldValues[field.id],
                    isEditable: canEdit && isWorking == false
                ) { value in
                    isWorking = true
                    operationErrorMessage = nil
                    do {
                        try await store.updateField(
                            on: item,
                            in: reference.projectID,
                            field: field,
                            value: value
                        )
                    } catch {
                        report(error)
                    }
                    isWorking = false
                }
            }
        }
    }

    @ViewBuilder
    private func signalsSection(_ item: ProjectItem) -> some View {
        if (item.contentType == .pullRequest && item.engineeringSignals != nil)
            || item.linkedPR != nil {
            ItemPropertySection(String(localized: "Engineering")) {
                if item.contentType == .pullRequest {
                    EngineeringSignalsView(item: item, limit: 5)
                }

                if let linkedPR = item.linkedPR, let url = URL(string: linkedPR.url) {
                    Link(destination: url) {
                        Label("PR #\(linkedPR.number): \(linkedPR.title)", systemImage: "arrow.triangle.pull")
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func report(_ error: Error) {
        guard (error is CancellationError) == false else { return }
        operationErrorMessage = error.localizedDescription
    }
}
