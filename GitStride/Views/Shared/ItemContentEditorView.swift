import SwiftUI

struct ItemContentEditorView: View {
    let store: ProjectStore
    let reference: ItemInspectorReference
    let detail: ProjectItemDetail

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isTitleFocused: Bool

    init(store: ProjectStore, reference: ItemInspectorReference, detail: ProjectItemDetail) {
        self.store = store
        self.reference = reference
        self.detail = detail
        _title = State(initialValue: detail.title)
        _description = State(initialValue: detail.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit title and description")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.callout.weight(.medium))
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTitleFocused)
            }
            .disabled(isSaving)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Description")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("Markdown supported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: $description)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .frame(minHeight: 160)
                    .accessibilityLabel("Description")
            }
            .disabled(isSaving)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                if isSaving {
                    ProgressView().controlSize(.small)
                    Text("Saving…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isSaving || trimmedTitle.isEmpty || !hasChanges)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 440)
        .interactiveDismissDisabled(isSaving || hasChanges)
        .onAppear { isTitleFocused = true }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasChanges: Bool { trimmedTitle != detail.title || description != detail.body }

    private func save() {
        guard !isSaving, !trimmedTitle.isEmpty, hasChanges else { return }
        isSaving = true
        errorMessage = nil
        let title = trimmedTitle
        let description = description
        Task {
            defer { isSaving = false }
            do {
                try await store.updateItemContent(reference, contentID: detail.id, title: title, body: description)
                dismiss()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
