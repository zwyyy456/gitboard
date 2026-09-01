import SwiftUI

struct ItemDescriptionView: View {
    @Bindable var store: ProjectStore
    let reference: ItemInspectorReference

    private var item: ProjectItem? { store.item(for: reference) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading

            if let item {
                descriptionContent(for: item)
            } else {
                unavailable
            }
        }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 12) {
            if let item {
                Image(systemName: stateSymbol(for: item).name)
                    .font(.title2)
                    .foregroundStyle(stateSymbol(for: item).color)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.title2.bold())
                        .lineLimit(2)
                        .textSelection(.enabled)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            let repository = item.repositoryName ?? "Draft item"
                            let identifier = item.number.map { "\(repository) #\($0)" } ?? repository

                            if let urlString = item.url, let url = URL(string: urlString) {
                                Link(identifier, destination: url)
                            } else {
                                Text(identifier)
                            }

                            Text("· \(stateTitle(for: item))")
                                .foregroundStyle(.secondary)
                        }

                        if let detailMetadata = detailMetadata(for: item) {
                            Text(detailMetadata)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func descriptionContent(for item: ProjectItem) -> some View {
        switch store.itemDetailState(for: item) {
        case .idle, .loading:
            ProgressView("Loading description…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let detail):
            if detail.bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "No Description",
                    systemImage: "text.alignleft",
                    description: Text("This item does not have a description.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GitHubHTMLBodyView(html: detail.bodyHTML)
            }

        case .failed(let message):
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "Description Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )

                Button("Retry") {
                    Task { await store.loadItemDetail(for: item, forceRefresh: true) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private func detailMetadata(for item: ProjectItem) -> String? {
        guard case .loaded(let detail) = store.itemDetailState(for: item) else { return nil }
        var values: [String] = []
        if let author = detail.author {
            values.append("@\(author.login)")
        }
        if let updated = detail.updatedAt.flatMap(formattedDate) {
            values.append("Updated \(updated)")
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func stateTitle(for item: ProjectItem) -> String {
        switch item.contentType {
        case .issue:
            return item.issueState == .closed ? "Closed" : "Open"
        case .pullRequest:
            if item.engineeringSignals?.isDraft == true { return "Draft pull request" }
            switch item.prState {
            case .merged: return "Merged"
            case .closed: return "Closed"
            case .open, .none: return "Open"
            }
        case .draftIssue:
            return "Draft item"
        case .redacted:
            return "Unavailable"
        }
    }

    private func stateSymbol(for item: ProjectItem) -> (name: String, color: Color) {
        switch item.contentType {
        case .issue:
            return item.issueState == .closed
                ? ("checkmark.circle.fill", .purple)
                : ("circle", .green)
        case .pullRequest:
            switch item.prState {
            case .merged: return ("arrow.triangle.merge", .purple)
            case .closed: return ("xmark.circle", .red)
            case .open, .none: return ("arrow.triangle.pull", .green)
            }
        case .draftIssue:
            return ("doc.text", .secondary)
        case .redacted:
            return ("questionmark.square.dashed", .secondary)
        }
    }

    private var unavailable: some View {
        ContentUnavailableView("Item Unavailable", systemImage: "archivebox")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formattedDate(_ value: String) -> String? {
        guard let date = try? Date(value, strategy: .iso8601) else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
