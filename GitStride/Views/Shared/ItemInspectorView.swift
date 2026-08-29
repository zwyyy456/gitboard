import SwiftUI

struct ItemInspectorView: View {
    @Bindable var store: ProjectStore
    let reference: ItemInspectorReference
    @Environment(\.dismiss) private var dismiss

    private var item: ProjectItem? { store.item(for: reference) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if item != nil, store.project(id: reference.projectID) != nil {
                HSplitView {
                    ItemDescriptionView(store: store, reference: reference)
                        .frame(minWidth: 460, idealWidth: 560, maxWidth: .infinity)

                    ItemPropertiesView(store: store, reference: reference)
                        .frame(minWidth: 260, idealWidth: 280, maxWidth: 340)
                }
            } else {
                ContentUnavailableView("Item Unavailable", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 620, idealHeight: 720)
        .task(id: item?.contentId) {
            store.clearOperationError()
            if let item {
                await store.loadItemDetail(for: item)
            }
        }
        .onDisappear { store.clearOperationError() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item?.contentType == .pullRequest
                ? "arrow.triangle.pull"
                : "record.circle")
                .font(.title3)
                .foregroundStyle(item?.contentType == .pullRequest ? .purple : .green)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(item?.title ?? "Item")
                    .font(.title3.bold())
                    .lineLimit(3)

                if let item {
                    Text(itemMetadata(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 16)

            if let urlString = item?.url, let url = URL(string: urlString) {
                Link(destination: url) {
                    Label("Open in GitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
            }

            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private func itemMetadata(_ item: ProjectItem) -> String {
        let repository = item.repositoryName ?? "Draft item"
        if let number = item.number { return "\(repository) #\(number)" }
        return repository
    }
}
