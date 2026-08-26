import Observation

@MainActor
@Observable
final class GitBoardModel {
    let projectStore = ProjectStore()
    let myWorkStore = MyWorkStore()

    func openProject(_ project: Project) async {
        await projectStore.openProject(FollowedProject(project: project))
    }

    func updateMyWorkField(
        on item: MyWorkItem,
        field: ProjectField,
        value: ProjectFieldValue?
    ) async {
        guard await myWorkStore.updateField(on: item, field: field, value: value) else { return }
        if projectStore.selectedProjectId == item.project.id {
            await projectStore.loadProjectDetails(id: item.project.id)
        }
    }

    func archiveMyWorkItem(_ item: MyWorkItem) async {
        guard await myWorkStore.archive(item) else { return }
        if projectStore.selectedProjectId == item.project.id {
            await projectStore.loadProjectDetails(id: item.project.id)
        }
    }
}
