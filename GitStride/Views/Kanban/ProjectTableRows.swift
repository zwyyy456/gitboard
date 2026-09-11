import Foundation

struct ProjectTableRow: Identifiable {
    enum ID: Hashable {
        case item(String)
        case status(String?)

        var itemID: String? {
            if case .item(let id) = self { return id }
            return nil
        }
    }

    let id: ID
    let item: ProjectItem?
    var status: StatusOption? = nil
    var count = 0

    init(item: ProjectItem) {
        id = .item(item.id)
        self.item = item
    }

    init(status: StatusOption?, count: Int) {
        id = .status(status?.id)
        item = nil
        self.status = status
        self.count = count
    }
}

struct ProjectTableGroup: Identifiable {
    let header: ProjectTableRow
    let rows: [ProjectTableRow]
    var id: ProjectTableRow.ID { header.id }

    static func make(items: [ProjectItem], statuses: [StatusOption], sortOrder: [ProjectTableSort]) -> [Self] {
        let knownIDs = Set(statuses.map(\.id))
        let buckets = Dictionary(grouping: items) { item in
            item.statusOptionId.flatMap { knownIDs.contains($0) ? $0 : nil }
        }
        return (statuses.map(Optional.some) + [nil]).compactMap { status in
            guard let items = buckets[status?.id], !items.isEmpty else { return nil }
            return Self(header: ProjectTableRow(status: status, count: items.count),
                        rows: items.map(ProjectTableRow.init(item:)).sorted(using: sortOrder))
        }
    }
}

struct ProjectTableSort: SortComparator {
    var column: String
    var fieldID: String = ""
    var order: SortOrder = .forward
    var optionOrder: [String] = []

    private var customFieldID: String? {
        if column.hasPrefix("field:") { return String(column.dropFirst(6)) }
        return column == "field" ? fieldID : nil
    }

    func compare(_ lhs: ProjectTableRow, _ rhs: ProjectTableRow) -> ComparisonResult {
        guard let lhs = lhs.item, let rhs = rhs.item else { return .orderedSame }
        let result: ComparisonResult
        if let id = customFieldID, !optionOrder.isEmpty {
            func rank(_ item: ProjectItem) -> Int {
                guard case .singleSelect(let optionID, _) = item.fieldValues[id] else { return optionOrder.count }
                return optionOrder.firstIndex(of: optionID) ?? optionOrder.count
            }
            let left = rank(lhs), right = rank(rhs)
            result = left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
        } else if let id = customFieldID, case .number(let left) = lhs.fieldValues[id],
           case .number(let right) = rhs.fieldValues[id] {
            result = left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
        } else if column == "number" {
            let left = lhs.number ?? 0, right = rhs.number ?? 0
            result = left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
        } else {
            result = value(lhs).localizedStandardCompare(value(rhs))
        }
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private func value(_ item: ProjectItem) -> String {
        if let id = customFieldID { return Self.fieldText(item.fieldValues[id]) }
        switch column {
        case "title": return item.title
        case "status": return item.status ?? ""
        case "assignees": return Self.assignees(item)
        case "updated": return item.updatedAt ?? ""
        case "repository": return item.repositoryName ?? ""
        case "labels": return Self.labels(item)
        default: return ""
        }
    }

    static func assignees(_ item: ProjectItem) -> String {
        item.assignees.map { $0.login }.joined(separator: ", ")
    }

    static func labels(_ item: ProjectItem) -> String {
        item.labels.map(\.name).joined(separator: ", ")
    }

    static func fieldText(_ value: ProjectFieldValue?) -> String {
        switch value {
        case .singleSelect(_, let name): name
        case .iteration(_, let title): title
        case .date(let date): date
        case .number(let number): number.formatted()
        case .text(let text): text
        case nil: ""
        }
    }
}

