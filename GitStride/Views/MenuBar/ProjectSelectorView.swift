import SwiftUI

struct ProjectSelectorView: View {
    @Bindable var store: ProjectStore
    var compact = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissMenuBar) private var dismissMenuBar

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            if store.owners.count > 1 {
                Menu {
                    ForEach(store.owners) { owner in
                        Button {
                            Task { await store.selectOwner(owner) }
                        } label: {
                            Label(
                                owner.login,
                                systemImage: owner.kind == .organization ? "building.2" : "person"
                            )
                        }
                    }
                } label: {
                    ownerLabel
                }
                .menuIndicator(compact ? .hidden : .visible)
                .help(store.selectedOwner?.login ?? String(localized: "Select owner"))
                .accessibilityLabel("Select owner, current owner \(store.selectedOwner?.login ?? String(localized: "None"))")
            }

            Menu {
                ForEach(store.projects) { project in
                    Button {
                        Task { await store.selectProject(project) }
                    } label: {
                        if project.id == store.selectedProjectId {
                            Label(project.title, systemImage: "checkmark")
                        } else {
                            Text(project.title)
                        }
                    }
                }
                Divider()
                NewProjectButton()
                if let project = store.selectedProject, project.viewerCanUpdate, !store.isShowingCachedData {
                    Button("Link Repository…", systemImage: "link") {
                        dismissMenuBar()
                        openWindow(id: "link-project-repository", value: project.id)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            } label: {
                Text(store.selectedProject?.title ?? String(localized: "Select Project"))
                    .lineLimit(1)
            }
            .help("Select project")
            .accessibilityLabel("Select project, current project \(store.selectedProject?.title ?? String(localized: "None"))")

            if store.selectedProject?.viewerCanUpdate == false,
               store.isShowingCachedData == false {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Read-only project")
                    .accessibilityLabel("Read-only project")
            }
        }
        .font(.callout.weight(.semibold))
    }

    @ViewBuilder
    private var ownerLabel: some View {
        let title = store.selectedOwner?.login ?? String(localized: "Owner")
        let icon = store.selectedOwner?.kind == .organization ? "building.2" : "person"
        if compact {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: icon)
        }
    }
}
