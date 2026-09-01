import SwiftUI

struct KanbanCardContent: View {
    let item: ProjectItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                itemTypeIcon

                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            EngineeringSignalsView(item: item, limit: 2)

            HStack(spacing: 4) {
                if let number = item.number {
                    Text("#\(number)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                if let linkedPR = item.linkedPR {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                    Text("PR #\(linkedPR.number)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if item.assignees.isEmpty == false {
                    HStack(spacing: -5) {
                        ForEach(item.assignees.prefix(3)) { assignee in
                            AsyncImage(url: URL(string: assignee.avatarUrl)) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Circle().fill(.secondary.opacity(0.3))
                            }
                            .frame(width: 20, height: 20)
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
