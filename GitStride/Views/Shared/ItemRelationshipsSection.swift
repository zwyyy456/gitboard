import SwiftUI

struct ItemRelationshipsSection: View {
    let store: ProjectStore
    let item: ProjectItem
    @Binding var operationErrorMessage: String?
    @Binding var isWorking: Bool
    @State private var relationEditor: IssueRelationKind?

    var body: some View {
        Group {
            if case .loaded(let detail) = store.itemDetailState(for: item),
               let metadata = detail.issueMetadata {
                ItemPropertySection("Relationships") {
                    if let parent = metadata.parent {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Parent issue")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            relationshipRow(parent, kind: .parent, item: item, canRemove: metadata.viewerCanUpdate)
                        }
                    }

                    if metadata.subIssues.isEmpty == false {
                        DisclosureGroup(subIssueTitle(metadata)) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(metadata.subIssues) {
                                    relationshipRow(
                                        $0,
                                        kind: .subIssue,
                                        item: item,
                                        canRemove: metadata.viewerCanUpdate
                                    )
                                }
                            }
                            .padding(.top, 6)
                        }
                    }

                    if metadata.blockedBy.isEmpty == false {
                        relationshipGroup(
                            "Blocked by",
                            issues: metadata.blockedBy,
                            kind: .blockedBy,
                            item: item,
                            canRemove: metadata.viewerCanUpdate
                        )
                    }

                    if metadata.blocking.isEmpty == false {
                        relationshipGroup(
                            "Blocking",
                            issues: metadata.blocking,
                            kind: .blocking,
                            item: item,
                            canRemove: metadata.viewerCanUpdate
                        )
                    }

                    if metadata.parent == nil,
                       metadata.subIssues.isEmpty,
                       metadata.blockedBy.isEmpty,
                       metadata.blocking.isEmpty {
                        Text("No relationships").font(.callout).foregroundStyle(.secondary)
                    }

                    if metadata.viewerCanUpdate {
                        Menu {
                            ForEach(IssueRelationKind.allCases) { kind in
                                Button(relationActionTitle(kind, hasParent: metadata.parent != nil)) {
                                    relationEditor = kind
                                }
                            }
                        } label: {
                            Label("Add relationship", systemImage: "plus")
                        }
                        .disabled(isWorking)
                    }
                }
            }
        }
        .sheet(item: $relationEditor) { kind in
            if case .loaded(let detail) = store.itemDetailState(for: item),
               let metadata = detail.issueMetadata {
                IssueRelationEditorView(
                    store: store,
                    item: item,
                    metadata: metadata,
                    kind: kind
                )
            }
        }
    }

    private func relationshipGroup(
        _ title: String,
        issues: [IssueReference],
        kind: IssueRelationKind,
        item: ProjectItem,
        canRemove: Bool
    ) -> some View {
        DisclosureGroup("\(title) \(issues.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(issues) {
                    relationshipRow($0, kind: kind, item: item, canRemove: canRemove)
                }
            }
            .padding(.top, 6)
        }
    }

    private func relationshipRow(
        _ issue: IssueReference,
        kind: IssueRelationKind,
        item: ProjectItem,
        canRemove: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            issueLink(issue)

            if canRemove {
                Button {
                    removeRelation(kind, issue: issue, from: item)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Remove \(relationTitle(kind).lowercased()) relationship")
                .disabled(isWorking)
            }
        }
    }

    private func issueLink(_ issue: IssueReference) -> some View {
        Link(destination: issue.url) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: issue.state == .closed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(issue.state == .closed ? .purple : .green)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(issue.repository)#\(issue.number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(issue.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(issue.repository) issue \(issue.number), \(issue.title), \(issue.state == .closed ? "closed" : "open")")
    }

    private func subIssueTitle(_ metadata: IssueMetadata) -> String {
        guard let progress = metadata.subIssueProgress else {
            return "Sub-issues \(metadata.subIssues.count)"
        }
        return "Sub-issues \(progress.completed)/\(progress.total)"
    }

    private func relationTitle(_ kind: IssueRelationKind) -> String {
        switch kind {
        case .parent: "Parent"
        case .subIssue: "Sub-issue"
        case .blockedBy: "Blocked by"
        case .blocking: "Blocking"
        }
    }

    private func relationActionTitle(_ kind: IssueRelationKind, hasParent: Bool) -> String {
        if kind == .parent, hasParent {
            return "Change parent"
        }
        return "Add \(relationTitle(kind).lowercased())"
    }

    private func removeRelation(
        _ kind: IssueRelationKind,
        issue: IssueReference,
        from item: ProjectItem
    ) {
        isWorking = true
        operationErrorMessage = nil
        Task {
            do {
                try await store.removeRelation(kind, relatedIssue: issue, from: item)
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
