import SwiftUI

struct OperationErrorBanner: View {
    let message: String?
    let dismiss: () -> Void

    var body: some View {
        if let message {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .textSelection(.enabled)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss error")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
        }
    }
}

// This file is kept for compatibility but ItemRowView in MenuBarPopoverView is the primary implementation
struct ProjectItemRowView: View {
    let item: ProjectItem
    let showStatus: Bool

    init(item: ProjectItem, showStatus: Bool = true) {
        self.item = item
        self.showStatus = showStatus
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            contentTypeIcon
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(2)
                    .font(.callout)

                HStack(spacing: 8) {
                    if let number = item.number {
                        Text("#\(number)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if showStatus, let status = item.status {
                        Text(status)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }

                EngineeringSignalsView(item: item, limit: 2)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var contentTypeIcon: some View {
        switch item.contentType {
        case .issue:
            Image(systemName: "circle.dotted")
                .foregroundStyle(issueColor)
        case .pullRequest:
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(prColor)
        case .draftIssue:
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
        case .redacted:
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
        }
    }

    private var issueColor: Color {
        guard let state = item.issueState else { return .green }
        switch state {
        case .open: return .green
        case .closed: return .purple
        }
    }

    private var prColor: Color {
        guard let state = item.prState else { return .green }
        switch state {
        case .open: return .green
        case .merged: return .purple
        case .closed: return .red
        }
    }
}
