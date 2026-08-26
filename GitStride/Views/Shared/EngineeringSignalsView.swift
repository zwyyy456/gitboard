import SwiftUI

struct EngineeringSignalsView: View {
    let item: ProjectItem
    var limit = 3

    private var badges: [EngineeringSignalBadge] {
        let signals = item.signals
        var badges: [EngineeringSignalBadge] = []

        if signals.isReadyToMerge {
            badges.append(.init(id: "ready", title: "Ready", icon: "checkmark.circle.fill", color: .green))
        } else {
            if signals.isDraft {
                badges.append(.init(id: "draft", title: "Draft", icon: "pencil.circle", color: .secondary))
            }
            if signals.mergeability == .conflicting {
                badges.append(.init(id: "conflict", title: "Conflict", icon: "exclamationmark.triangle.fill", color: .orange))
            }
            switch signals.checkStatus {
            case .failure, .error:
                badges.append(.init(id: "ci-failed", title: "CI Failed", icon: "xmark.circle.fill", color: .red))
            case .pending, .expected:
                badges.append(.init(id: "ci-pending", title: "CI Pending", icon: "clock.fill", color: .yellow))
            case .success:
                badges.append(.init(id: "ci-passed", title: "CI Passed", icon: "checkmark.circle.fill", color: .green))
            case nil:
                break
            }
            switch signals.reviewDecision {
            case .approved:
                badges.append(.init(id: "approved", title: "Approved", icon: "hand.thumbsup.fill", color: .green))
            case .changesRequested:
                badges.append(.init(id: "changes", title: "Changes", icon: "arrow.uturn.backward.circle.fill", color: .orange))
            case .reviewRequired:
                badges.append(.init(id: "review", title: "Review", icon: "person.crop.circle.badge.questionmark", color: .blue))
            case nil:
                break
            }
        }

        if let progress = signals.subIssueProgress {
            badges.append(.init(
                id: "subissues",
                title: "\(progress.completed)/\(progress.total)",
                icon: "checklist",
                color: .blue
            ))
        }
        if signals.blockedByCount > 0 {
            badges.append(.init(
                id: "blocked",
                title: "Blocked \(signals.blockedByCount)",
                icon: "exclamationmark.octagon.fill",
                color: .red
            ))
        }
        if signals.blockingCount > 0 {
            badges.append(.init(
                id: "blocking",
                title: "Blocking \(signals.blockingCount)",
                icon: "arrow.triangle.branch",
                color: .orange
            ))
        }
        return badges
    }

    var body: some View {
        if badges.isEmpty == false {
            HStack(spacing: 5) {
                ForEach(Array(badges.prefix(limit))) { badge in
                    Label(badge.title, systemImage: badge.icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(badge.color.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }
}

private struct EngineeringSignalBadge: Identifiable {
    let id: String
    let title: String
    let icon: String
    let color: Color
}
