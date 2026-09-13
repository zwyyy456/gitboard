import AppKit
import SwiftUI

struct ItemSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusedSearchField()
        field.placeholderString = String(localized: "GitHub URL or search query")
        field.setAccessibilityLabel(String(localized: "GitHub URL or search issues and pull requests"))
        field.sendsWholeSearchString = true
        field.maximumRecents = 0
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: nsView.intrinsicContentSize.height)
    }

    private final class FocusedSearchField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        @objc func submit(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
            onSubmit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            onSubmit()
            return true
        }
    }
}

struct LabelTokenField: NSViewRepresentable {
    @Binding var text: String
    let suggestions: [String]
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        if #available(macOS 15.0, *) {
            field.suggestionsDelegate = context.coordinator
        }
        field.placeholderString = "bug, enhancement"
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        field.setAccessibilityLabel(String(localized: "Labels"))
        field.setAccessibilityHelp(String(localized: "Type a label, then press comma or Return. Missing labels will be created in the repository when you submit."))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.suggestions = suggestions
        if context.coordinator.lastText != text {
            field.objectValue = text.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            context.coordinator.lastText = text
        }
        field.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTokenField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var text: Binding<String>
        var suggestions: [String] = []
        var lastText: String?

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            updateText(from: field)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            field.validateEditing()
            updateText(from: field)
        }

        private func updateText(from field: NSTokenField) {
            let value = (field.objectValue as? [String] ?? []).joined(separator: ", ")
            lastText = value
            text.wrappedValue = value
        }

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            if #available(macOS 15.0, *) { return nil }
            selectedIndex?.pointee = -1
            return suggestions.filter { $0.localizedStandardContains(substring) }
        }
    }
}

@available(macOS 15.0, *)
extension LabelTokenField.Coordinator: NSTextSuggestionsDelegate {
    typealias SuggestionItemType = String

    func textField(_ textField: NSTextField, provideUpdatedSuggestions responseHandler: @escaping (ItemResponse) -> Void) {
        guard let editor = textField.currentEditor() as? NSTextView else {
            responseHandler(ItemResponse())
            return
        }
        // The token field's editor includes spaces within the current label in this range.
        let range = editor.rangeForUserCompletion
        guard range.location != NSNotFound, range.length > 0 else {
            responseHandler(ItemResponse())
            return
        }
        let substring = (editor.string as NSString).substring(with: range)
        let items = suggestions.filter { $0.localizedStandardContains(substring) }
            .map { Item(representedValue: $0, title: $0) }
        var response = ItemResponse(items: items)
        response.preferredHighlight = .firstSelectableItem
        responseHandler(response)
    }

    func textField(_ textField: NSTextField, textCompletionFor item: Item) -> String? {
        // Whole-field previews would replace the other labels as well.
        nil
    }

    func textField(_ textField: NSTextField, didSelect item: Item) {
        guard let field = textField as? NSTokenField,
              let editor = field.currentEditor() as? NSTextView else { return }
        let range = editor.rangeForUserCompletion
        guard range.location != NSNotFound, range.length > 0 else { return }
        // Let NSTokenField commit the selected label using its existing comma separator.
        editor.insertText(item.representedValue + ",", replacementRange: range)
        field.validateEditing()
        updateText(from: field)
    }
}

struct RepositoryComboBox: NSViewRepresentable {
    @Binding var text: String
    let repositories: [String]
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.delegate = context.coordinator
        comboBox.placeholderString = "owner/repository"
        comboBox.completes = true
        comboBox.hasVerticalScroller = true
        comboBox.numberOfVisibleItems = 8
        comboBox.font = .systemFont(ofSize: NSFont.systemFontSize)
        comboBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        comboBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        comboBox.setAccessibilityLabel(String(localized: "Repository, required"))
        comboBox.toolTip = String(localized: "Choose a repository linked to or used in this project, or type owner/repository.")
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.text = $text
        if context.coordinator.repositories != repositories {
            context.coordinator.repositories = repositories
            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: repositories)
        }
        if comboBox.stringValue != text {
            comboBox.stringValue = text
        }
        comboBox.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSComboBox, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.intrinsicContentSize.width,
            height: nsView.intrinsicContentSize.height
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var text: Binding<String>
        var repositories: [String] = []

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            text.wrappedValue = comboBox.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox,
                  let repository = comboBox.objectValueOfSelectedItem as? String else { return }
            text.wrappedValue = repository
        }
    }
}
