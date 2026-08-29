import SwiftUI

struct ItemDescriptionView: View {
    @Bindable var store: ProjectStore
    let reference: ItemInspectorReference

    private var item: ProjectItem? { store.item(for: reference) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            Divider()

            if let item {
                descriptionContent(for: item)
                    .task(id: item.contentId) {
                        await store.loadItemDetail(for: item)
                    }
            } else {
                unavailable
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Description")
                .font(.headline)

            if let item, case .loaded(let detail) = store.itemDetailState(for: item) {
                detailMetadata(detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
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

    @ViewBuilder
    private func detailMetadata(_ detail: ProjectItemDetail) -> some View {
        let author = detail.author.map { "@\($0.login)" }
        let created = detail.createdAt.flatMap(formattedDate)
        let values = [author, created].compactMap { $0 }

        if values.isEmpty == false {
            Text(values.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
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
