import SwiftUI

struct ItemMilestoneSection: View {
    let store: ProjectStore
    let item: ProjectItem
    @Binding var operationErrorMessage: String?
    @Binding var isWorking: Bool

    @ViewBuilder
    var body: some View {
        ItemPropertySection("Issue Details") {
            switch store.itemDetailState(for: item) {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)

            case .loaded(let detail):
                if let metadata = detail.issueMetadata {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Milestone")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if metadata.viewerCanSetMilestone {
                            milestoneEditor(metadata: metadata, item: item)
                        } else {
                            Text(metadata.milestone?.title ?? "No milestone")
                        }

                        milestoneProgress(metadata.milestone)
                    }
                    .task(id: metadata.repository) {
                        if metadata.viewerCanSetMilestone {
                            await store.loadMilestones(repository: metadata.repository)
                        }
                    }
                }

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func milestoneEditor(metadata: IssueMetadata, item: ProjectItem) -> some View {
        switch store.milestoneState(for: metadata.repository) {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)

        case .loaded(let milestones):
            Menu {
                Button("No milestone") {
                    changeMilestone(nil, on: item)
                }
                .disabled(metadata.milestone == nil)

                if milestones.isEmpty == false {
                    Divider()
                    ForEach(milestones) { milestone in
                        Button {
                            changeMilestone(milestone, on: item)
                        } label: {
                            if milestone.id == metadata.milestone?.id {
                                Label(milestone.title, systemImage: "checkmark")
                            } else {
                                Text(milestone.title)
                            }
                        }
                        .disabled(milestone.id == metadata.milestone?.id)
                    }
                }
            } label: {
                HStack {
                    Text(metadata.milestone?.title ?? "No milestone")
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .disabled(isWorking)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(metadata.milestone?.title ?? "No milestone")
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    Task {
                        await store.loadMilestones(
                            repository: metadata.repository,
                            forceRefresh: true
                        )
                    }
                }
                .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private func milestoneProgress(_ milestone: RepositoryMilestone?) -> some View {
        if let milestone {
            HStack(spacing: 6) {
                if let dueDate = milestone.dueOn.flatMap(formattedDate) {
                    Text("Due \(dueDate)")
                }
                Text("\(milestone.progressPercentage.formatted(.number.precision(.fractionLength(0))))% complete")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ProgressView(value: milestone.progressPercentage, total: 100)
                .frame(maxWidth: 180, alignment: .leading)
                .accessibilityLabel("Milestone progress")
                .accessibilityValue("\(Int(milestone.progressPercentage.rounded())) percent")
        }
    }

    private func formattedDate(_ value: String) -> String? {
        guard let date = try? Date(value, strategy: .iso8601) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func changeMilestone(_ milestone: RepositoryMilestone?, on item: ProjectItem) {
        isWorking = true
        operationErrorMessage = nil
        Task {
            do {
                try await store.setMilestone(milestone, on: item)
            } catch {
                report(error)
            }
            isWorking = false
        }
    }

    private func report(_ error: Error) {
        guard (error is CancellationError) == false else { return }
        operationErrorMessage = error.localizedDescription
    }
}
