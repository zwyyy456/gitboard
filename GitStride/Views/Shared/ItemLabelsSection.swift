import SwiftUI

struct ItemLabelsSection: View {
    let store: ProjectStore
    let item: ProjectItem
    @Binding var operationErrorMessage: String?
    let projectID: String
    private var canEdit: Bool { store.canEditProject(id: projectID) }
    @State private var labelName = ""
    @State private var showsLabelPicker = false

    var body: some View {
        ItemPropertySection(String(localized: "Labels")) {
            if item.labels.isEmpty {
                Text("No labels").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(item.labels) { label in
                    HStack {
                        Circle()
                            .fill(Color(hex: label.color))
                            .frame(width: 9, height: 9)
                        Text(label.name)
                        Spacer()
                        if canEdit {
                            Button {
                                operationErrorMessage = nil
                                Task {
                                    do {
                                        try await store.removeLabel(
                                            from: item,
                                            in: projectID,
                                            name: label.name
                                        )
                                    } catch {
                                        report(error)
                                    }
                                }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove label")
                        }
                    }
                }
            }

            if canEdit {
                Button("Add Label…", systemImage: "plus", action: showLabelPicker)
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showsLabelPicker) {
                        labelPicker(item)
                    }
            }
        }
    }

    private func labelPicker(_ item: ProjectItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Label")
                .font(.headline)

            TextField("Existing repository label", text: $labelName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addLabel(to: item) }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showsLabelPicker = false
                }
                Button("Add Label") {
                    addLabel(to: item)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(labelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
    }

    private func showLabelPicker() {
        labelName = ""
        showsLabelPicker = true
    }

    private func addLabel(to item: ProjectItem) {
        let name = labelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return }
        operationErrorMessage = nil
        Task {
            do {
                try await store.addLabel(to: item, in: projectID, name: name)
                labelName = ""
                showsLabelPicker = false
            } catch {
                report(error)
            }
        }
    }

    private func report(_ error: Error) {
        guard (error is CancellationError) == false else { return }
        operationErrorMessage = error.localizedDescription
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0x808080
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
