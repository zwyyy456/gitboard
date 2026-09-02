import SwiftUI

struct ItemRow: View {
    let item: ProjectItem
    @Bindable var store: ProjectStore
    let project: Project
    let showInspector: () -> Void
    let reportError: (Error) -> Void
    @Environment(\.openWindow) private var openWindow

    @State private var isHovered = false

    var body: some View {
        Button {
            showInspector()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                itemTypeIcon.frame(width: 16)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if let number = item.number {
                            Text("#\(number)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let linkedPR = item.linkedPR {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text("PR #\(linkedPR.number)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    EngineeringSignalsView(item: item, limit: 2)
                }

                Spacer()

                if item.assignees.isEmpty == false {
                    AvatarStack(assignees: item.assignees)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.45) : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.number.map { "\(item.title), number \($0)" } ?? item.title)
        .accessibilityHint("Show item details")
        .onHover { isHovered = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.push()
            case .ended: NSCursor.pop()
            }
        }
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Show Details", systemImage: "sidebar.right", action: showInspector)
        Button("Open in New Window", systemImage: "macwindow", action: openInNewWindow)
        Button("Open in Browser", systemImage: "safari", action: openInBrowser)

        if store.canEditProject(id: project.id) {
            Divider()

            Menu("Move to", systemImage: "arrow.right.circle") {
                ForEach(project.statusOptions) { status in
                    Button {
                        Task {
                            do {
                                try await store.moveItem(item, toStatus: status, in: project.id)
                            } catch {
                                reportError(error)
                            }
                        }
                    } label: {
                        HStack {
                            Circle()
                                .fill(status.swiftUIColor)
                                .frame(width: 8, height: 8)
                            Text(status.name)
                            if item.status == status.name {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(item.status == status.name)
                }
            }

            if item.assignees.isEmpty == false {
                Divider()
                Menu("Assignees (\(item.assignees.count))", systemImage: "person.2") {
                    ForEach(item.assignees) { assignee in
                        Button(assignee.name ?? assignee.login, systemImage: "person.fill.xmark") {
                            Task {
                                do {
                                    try await store.removeAssignee(
                                        from: item,
                                        in: project.id,
                                        user: assignee
                                    )
                                } catch {
                                    reportError(error)
                                }
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Archive from Project", systemImage: "archivebox") {
                Task {
                    do {
                        try await store.archiveItem(item, in: project.id)
                    } catch {
                        reportError(error)
                    }
                }
            }
        }
    }

    private func openInBrowser() {
        guard let urlString = item.url, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openInNewWindow() {
        openWindow(
            id: "item-detail",
            value: ItemInspectorReference(projectID: project.id, itemID: item.id)
        )
    }

    @ViewBuilder
    private var itemTypeIcon: some View {
        Group {
            switch item.contentType {
            case .issue: Image(systemName: "record.circle")
            case .pullRequest: Image(systemName: "arrow.triangle.merge")
            case .draftIssue: Image(systemName: "doc.text")
            case .redacted: Image(systemName: "lock")
            }
        }
        .font(.callout)
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

private struct AvatarStack: View {
    let assignees: [Assignee]
    private let size: CGFloat = 22
    private let overlap: CGFloat = 6

    var body: some View {
        HStack(spacing: -overlap) {
            ForEach(Array(assignees.prefix(3).enumerated()), id: \.element.id) { index, assignee in
                AsyncImage(url: URL(string: assignee.avatarUrl)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(.secondary.opacity(0.3))
                        .overlay {
                            Text(String(assignee.login.prefix(1)).uppercased())
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                .zIndex(Double(3 - index))
            }

            if assignees.count > 3 {
                Text("+\(assignees.count - 3)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }
}
