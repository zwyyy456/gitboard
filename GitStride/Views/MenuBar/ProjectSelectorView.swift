import SwiftUI

struct ProjectSelectorView: View {
    @Bindable var store: ProjectStore
    var compact = false

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
                .help(store.selectedOwner?.login ?? "Select owner")
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
            } label: {
                HStack(spacing: 6) {
                    Text(store.selectedProject?.title ?? "Select Project")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.bold())
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(store.projects.isEmpty || store.isLoading)

            if store.selectedProject?.viewerCanUpdate == false {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Read-only project")
                    .accessibilityLabel("Read-only project")
            }
        }
        .font(.callout.bold())
    }

    @ViewBuilder
    private var ownerLabel: some View {
        let title = store.selectedOwner?.login ?? "Owner"
        let icon = store.selectedOwner?.kind == .organization ? "building.2" : "person"
        if compact {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: icon)
        }
    }
}
