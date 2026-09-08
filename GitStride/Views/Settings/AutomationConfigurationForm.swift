import SwiftUI

struct AutomationConfigurationForm: View {
    @Bindable var setup: AutomationSetupModel

    var body: some View {
        Section {
            Picker("Project", selection: $setup.selectedProjectID) {
                Text("Choose a Project").tag(nil as String?)
                ForEach(setup.projects) { project in
                    Text(project.title).tag(Optional(project.id))
                }
            }
            .task(id: setup.selectedProjectID) {
                await setup.selectProject(setup.selectedProjectID)
            }
        } header: {
            Text("Project Template")
        } footer: {
            Text("Use this Project’s status names across your personal Projects. All repositories accessible to the GitHub App are included.")
        }

        Section {
            Picker("Status field", selection: Binding(
                get: { setup.selectedStatusFieldID },
                set: { setup.selectStatusField($0) }
            )) {
                Text("Choose a field").tag(nil as String?)
                ForEach(setup.statusFields) { field in
                    Text(field.name).tag(Optional(field.id))
                }
            }

            StatusOptionPicker(
                title: "In progress",
                selection: $setup.inProgressOptionID,
                options: setup.selectedStatusOptions
            )
            .disabled(setup.selectedStatusFieldID == nil)
            StatusOptionPicker(
                title: "Done",
                selection: $setup.doneOptionID,
                options: setup.selectedStatusOptions
            )
            .disabled(setup.selectedStatusFieldID == nil)
        } header: {
            Text("Status Mapping")
        } footer: {
            Text("Matching statuses are selected automatically. You can change them before enabling automation.")
        }

        Section {
            Picker("When a pull request is ready", selection: $setup.reviewStatusPolicy) {
                Text("Move to In review")
                    .tag(AutomationService.ReviewStatusPolicy.ensureInReview)
                Text("Keep in In progress")
                    .tag(AutomationService.ReviewStatusPolicy.useInProgress)
            }
            .pickerStyle(.menu)
        } header: {
            Text("Pull Request Behavior")
        } footer: {
            Text(reviewPolicyDescription)
        }
    }

    private var reviewPolicyDescription: String {
        switch setup.reviewStatusPolicy {
        case .ensureInReview:
            "Linked Issues move to In review. This status is added to a Project when first needed."
        case .useInProgress:
            "Linked Issues stay in the selected In progress status. No review status is added."
        }
    }
}
