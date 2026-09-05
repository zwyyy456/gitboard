import SwiftUI

struct AutomationConfigurationForm: View {
    @Bindable var setup: AutomationSetupModel

    var body: some View {
        Text("All repositories available to the GitHub App are included automatically. The Project below defines the Status names used across your personal Projects.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Picker("Mapping template Project", selection: $setup.selectedProjectID) {
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
            title: "Done",
            selection: $setup.doneOptionID,
            options: setup.selectedStatusOptions
        )

        Picker("Ready pull requests", selection: $setup.reviewStatusPolicy) {
            Text("Move to In review")
                .tag(AutomationService.ReviewStatusPolicy.ensureInReview)
            Text("Keep in In progress")
                .tag(AutomationService.ReviewStatusPolicy.useInProgress)
        }
        .pickerStyle(.radioGroup)

        Text(reviewPolicyDescription)
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack {
            Spacer()
            Button("Enable Account Automation", action: completeSetup)
                .buttonStyle(.borderedProminent)
                .disabled(!setup.canComplete)
        }
    }

    private func completeSetup() {
        Task { await setup.completeSetup() }
    }

    private var reviewPolicyDescription: String {
        switch setup.reviewStatusPolicy {
        case .ensureInReview:
            "GitBoard reuses an existing In review option, ignoring case, or adds In review in Orange when a matching Project first needs it."
        case .useInProgress:
            "GitBoard keeps ready pull requests in In progress and does not add a Status option."
        }
    }
}
