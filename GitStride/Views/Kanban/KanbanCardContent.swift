import SwiftUI

struct KanbanCardContent: View {
    let item: ProjectItem
    let project: Project?
    @AppStorage private var fields: String

    init(item: ProjectItem, project: Project? = nil, preferenceID: String? = nil) {
        self.item = item
        self.project = project
        _fields = AppStorage(wrappedValue: "assignees,priority", "projectTable.\(preferenceID ?? project?.id ?? "").cardFields")
    }

    private var visibleFields: Set<String> { Set(fields.split(separator: ",").map(String.init)) }
    private var showsRepository: Bool {
        Set(project?.items.compactMap(\.repositoryName) ?? []).count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                itemTypeIcon

                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !item.isWorkComplete && item.signals.blockedByCount > 0 {
                Label("Blocked by \(item.signals.blockedByCount)", systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.orange)
            }
            if visibleFields.contains("signals") { EngineeringSignalsView(item: item, limit: 2) }
            optionalFields

            HStack(spacing: 4) {
                if showsRepository, let repository = item.repositoryName {
                    Text(repository).lineLimit(1).truncationMode(.middle)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let number = item.number {
                    Text("#\(number)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                if visibleFields.contains("signals"), let linkedPR = item.linkedPR {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                    Text("PR #\(linkedPR.number)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if visibleFields.contains("assignees"), item.assignees.isEmpty == false {
                    HStack(spacing: -5) {
                        ForEach(item.assignees.prefix(3)) { assignee in
                            AsyncImage(url: URL(string: assignee.avatarUrl)) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Circle().fill(.secondary.opacity(0.3))
                            }
                            .frame(width: 20, height: 20)
                            .help(assignee.login)
                            .clipShape(Circle())
                            .overlay(
                                Circle().stroke(
                                    Color(nsColor: .controlBackgroundColor),
                                    lineWidth: 1.5
                                )
                            )
                        }

                        if item.assignees.count > 3 {
                            Text("+\(item.assignees.count - 3)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var optionalFields: some View {
        if visibleFields.contains("milestone"), let milestone = item.milestone {
            Label(milestone.title, systemImage: "flag").font(.caption).foregroundStyle(.secondary)
        }
        if visibleFields.contains("labels"), !item.labels.isEmpty {
            Text(item.labels.map(\.name).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        ForEach(project?.fields.filter { field in
            field.id != project?.statusField?.id && (visibleFields.contains("field:" + field.id)
                || (visibleFields.contains("priority") && field.name.caseInsensitiveCompare("Priority") == .orderedSame))
        } ?? []) { field in
            if let value = item.fieldValues[field.id] {
                Text("\(field.name): \(fieldText(value))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func fieldText(_ value: ProjectFieldValue) -> String {
        switch value {
        case .singleSelect(_, let name): name
        case .iteration(_, let title): title
        case .date(let date): date
        case .number(let number): number.formatted()
        case .text(let text): text
        }
    }

    @ViewBuilder
    private var itemTypeIcon: some View {
        Group {
            switch item.contentType {
            case .issue:
                Image(systemName: "circle.dotted")
            case .pullRequest:
                Image(systemName: "arrow.triangle.merge")
            case .draftIssue:
                Image(systemName: "doc.text")
            case .redacted:
                Image(systemName: "lock")
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(stateColor)
    }

    private var stateColor: Color {
        if let state = item.issueState {
            return state == .open ? .green : .purple
        }
        if let state = item.prState {
            switch state {
            case .open: return .green
            case .merged: return .purple
            case .closed: return .red
            }
        }
        return .secondary
    }
}
