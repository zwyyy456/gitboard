import SwiftUI

struct StatusOptionPicker: View {
    let title: String
    @Binding var selection: String?
    let options: [AutomationService.StatusOption]
    var emptySelectionTitle = "Choose a status"

    var body: some View {
        Picker(title, selection: $selection) {
            Text(emptySelectionTitle).tag(nil as String?)
            ForEach(options) { option in
                Text(option.name).tag(Optional(option.id))
            }
        }
    }
}
