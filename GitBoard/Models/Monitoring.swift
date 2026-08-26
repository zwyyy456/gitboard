import Foundation

enum ProjectChangeKind: Hashable, Sendable {
    case status(from: String?, to: String?)
    case assignedToMe
    case unassignedFromMe
    case dueSoon
    case overdue
    case blocked
    case unblocked
}

struct ProjectChange: Identifiable, Hashable, Sendable {
    let id: UUID
    let projectID: String
    let projectTitle: String
    let itemID: String
    let itemTitle: String
    let itemURL: String?
    let kind: ProjectChangeKind
    let statusFieldID: String?
    let doneOptionID: String?

    init(
        projectID: String,
        projectTitle: String,
        itemID: String,
        itemTitle: String,
        itemURL: String?,
        kind: ProjectChangeKind,
        statusFieldID: String?,
        doneOptionID: String?
    ) {
        id = UUID()
        self.projectID = projectID
        self.projectTitle = projectTitle
        self.itemID = itemID
        self.itemTitle = itemTitle
        self.itemURL = itemURL
        self.kind = kind
        self.statusFieldID = statusFieldID
        self.doneOptionID = doneOptionID
    }
}

struct MonitoringPolicy: Sendable {
    let interval: Duration
    let quietStartHour: Int
    let quietEndHour: Int

    func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietStartHour != quietEndHour else { return false }
        let hour = calendar.component(.hour, from: date)
        if quietStartHour < quietEndHour {
            return hour >= quietStartHour && hour < quietEndHour
        }
        return hour >= quietStartHour || hour < quietEndHour
    }
}

enum ProjectMonitorEvent: Sendable {
    case change(ProjectChange)
    case digest([ProjectChange])
    case rateLimited(String?)
    case failed(String)
}

enum MonitoredDueState: Hashable, Sendable {
    case none
    case upcoming
    case overdue
}

struct MonitoredItemState: Hashable, Sendable {
    let projectID: String
    let itemID: String
    let status: String?
    let assignedToCurrentUser: Bool
    let dueState: MonitoredDueState
    let isBlocked: Bool
}

struct ProjectChangeDetector {
    static func states(
        for projects: [Project],
        currentUserLogin: String,
        now: Date
    ) -> [String: MonitoredItemState] {
        Dictionary(uniqueKeysWithValues: projects.flatMap { project in
            project.items.map { item in
                let workItem = MyWorkItem(project: project, item: item)
                let dueState: MonitoredDueState
                if let dueDate = workItem.dueDate {
                    if dueDate < Calendar.current.startOfDay(for: now) {
                        dueState = .overdue
                    } else if dueDate <= now.addingTimeInterval(3 * 24 * 60 * 60) {
                        dueState = .upcoming
                    } else {
                        dueState = .none
                    }
                } else {
                    dueState = .none
                }
                let isBlocked = MyWorkFilter.blocked.includes(
                    workItem,
                    currentUserLogin: currentUserLogin,
                    now: now
                )
                let assigned = item.assignees.contains {
                    $0.login.caseInsensitiveCompare(currentUserLogin) == .orderedSame
                }
                let key = "\(project.id):\(item.id)"
                return (
                    key,
                    MonitoredItemState(
                        projectID: project.id,
                        itemID: item.id,
                        status: item.status,
                        assignedToCurrentUser: assigned,
                        dueState: dueState,
                        isBlocked: isBlocked
                    )
                )
            }
        })
    }

    static func changes(
        from previous: [String: MonitoredItemState],
        to current: [String: MonitoredItemState],
        projects: [Project]
    ) -> [ProjectChange] {
        let contexts = Dictionary(uniqueKeysWithValues: projects.flatMap { project in
            project.items.map { item in ("\(project.id):\(item.id)", (project, item)) }
        })
        var changes: [ProjectChange] = []

        for (key, currentState) in current {
            guard let previousState = previous[key],
                  let (project, item) = contexts[key] else { continue }

            func append(_ kind: ProjectChangeKind) {
                let doneOption = project.statusOptions.first {
                    ["done", "completed", "complete"].contains($0.name.lowercased())
                }
                changes.append(
                    ProjectChange(
                        projectID: project.id,
                        projectTitle: project.title,
                        itemID: item.id,
                        itemTitle: item.title,
                        itemURL: item.url,
                        kind: kind,
                        statusFieldID: project.statusField?.id,
                        doneOptionID: doneOption?.id
                    )
                )
            }

            if previousState.status != currentState.status {
                append(.status(from: previousState.status, to: currentState.status))
            }
            if previousState.assignedToCurrentUser != currentState.assignedToCurrentUser {
                append(currentState.assignedToCurrentUser ? .assignedToMe : .unassignedFromMe)
            }
            if previousState.dueState != currentState.dueState {
                switch currentState.dueState {
                case .upcoming: append(.dueSoon)
                case .overdue: append(.overdue)
                case .none: break
                }
            }
            if previousState.isBlocked != currentState.isBlocked {
                append(currentState.isBlocked ? .blocked : .unblocked)
            }
        }
        return changes
    }
}
