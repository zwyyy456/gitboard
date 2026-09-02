import SwiftUI

struct AutomationConfigurationForm: View {
    @Bindable var setup: AutomationSetupModel

    var body: some View {
        Picker("Source repository", selection: $setup.selectedRepositoryID) {
            Text("Choose a repository").tag(nil as Int64?)
            ForEach(setup.repositories) { repository in
                Text(repository.nameWithOwner).tag(Optional(repository.id))
            }
        }

        Picker("Personal Project", selection: $setup.selectedProjectID) {
            Text("Choose a Project").tag(nil as String?)
            ForEach(setup.projects) { project in
                Text(project.title).tag(Optional(project.id))
            }
        }
        .task(id: setup.selectedProjectID) {
            await setup.selectProject(setup.selectedProjectID)
        }

        Picker("Status field", selection: $setup.selectedStatusFieldID) {
            Text("Choose a field").tag(nil as String?)
            ForEach(setup.statusFields) { field in
                Text(field.name).tag(Optional(field.id))
            }
        }
        .onChange(of: setup.selectedStatusFieldID) { _, fieldID in
            setup.selectStatusField(fieldID)
        }

        StatusOptionPicker(
            title: "In progress",
            selection: $setup.inProgressOptionID,
            options: setup.selectedStatusOptions
        )
        StatusOptionPicker(
            title: "In review",
            selection: $setup.inReviewOptionID,
            options: setup.selectedStatusOptions
        )
        StatusOptionPicker(
            title: "Done",
            selection: $setup.doneOptionID,
            options: setup.selectedStatusOptions
        )

        HStack {
            Spacer()
            Button("Enable Automation", action: completeSetup)
                .buttonStyle(.borderedProminent)
                .disabled(!setup.canComplete)
        }
    }

    private func completeSetup() {
        Task { await setup.completeSetup() }
    }
}
