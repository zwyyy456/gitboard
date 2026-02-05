import SwiftUI

struct ProjectSelectorView: View {
    @Bindable var store: ProjectStore

    var body: some View {
        Picker("Project", selection: Binding(
            get: { store.selectedProjectId ?? "" },
            set: { newValue in
                if let project = store.projects.first(where: { $0.id == newValue }) {
                    Task {
                        await store.selectProject(project)
                    }
                }
            }
        )) {
            ForEach(store.projects) { project in
                Text(project.title)
                    .tag(project.id)
            }
        }
        .pickerStyle(.menu)
        .disabled(store.isLoading)
    }
}
