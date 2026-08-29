import SwiftUI

struct ProjectFieldEditor: View {
    let field: ProjectField
    let value: ProjectFieldValue?
    let isEditable: Bool
    let update: (ProjectFieldValue?) async -> Void

    @State private var draftValue = ""
    @State private var draftDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.name)
                .font(.caption)
                .foregroundStyle(.secondary)

            editor
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: value) {
            draftValue = displayValue
            if case .date(let value) = value, let date = parseDate(value) {
                draftDate = date
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch field.kind {
        case .singleSelect:
            Menu {
                Button("None") { set(nil) }
                Divider()
                ForEach(field.options) { option in
                    Button(option.name) {
                        set(.singleSelect(optionId: option.id, name: option.name))
                    }
                }
            } label: {
                valueLabel
            }
            .disabled(!isEditable)

        case .iteration:
            Menu {
                Button("None") { set(nil) }
                Divider()
                ForEach(field.iterations) { iteration in
                    Button(iteration.title) {
                        set(.iteration(id: iteration.id, title: iteration.title))
                    }
                }
            } label: {
                valueLabel
            }
            .disabled(!isEditable)

        case .date:
            HStack {
                DatePicker("Date", selection: $draftDate, displayedComponents: .date)
                    .labelsHidden()
                    .disabled(!isEditable)
                Button("Save") { set(.date(formatDate(draftDate))) }
                    .disabled(!isEditable || formatDate(draftDate) == displayValue)
                if value != nil { clearButton }
            }

        case .number, .text:
            HStack {
                TextField("None", text: $draftValue)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isEditable)
                Button("Save") { saveDraft() }
                    .disabled(!isEditable || draftValue == displayValue || invalidNumber)
                if value != nil { clearButton }
            }

        case .unsupported:
            Text(displayValue.isEmpty ? "Not supported" : displayValue)
                .foregroundStyle(.secondary)
        }
    }

    private var valueLabel: some View {
        HStack(spacing: 6) {
            Text(displayValue.isEmpty ? "None" : displayValue)
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
    }

    private var displayValue: String {
        switch value {
        case .singleSelect(_, let name): return name
        case .iteration(_, let title): return title
        case .date(let value): return value
        case .number(let value): return value.formatted()
        case .text(let value): return value
        case nil: return ""
        }
    }

    private var invalidNumber: Bool {
        field.kind == .number
            && draftValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && Double(draftValue) == nil
    }

    private var clearButton: some View {
        Button {
            set(nil)
        } label: {
            Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .disabled(!isEditable)
        .help("Clear field")
    }

    private func saveDraft() {
        let trimmed = draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            set(nil)
            return
        }

        switch field.kind {
        case .number:
            guard let number = Double(trimmed) else { return }
            set(.number(number))
        case .text:
            set(.text(trimmed))
        default:
            break
        }
    }

    private func parseDate(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
        )
    }

    private func formatDate(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func set(_ value: ProjectFieldValue?) {
        Task { await update(value) }
    }
}
