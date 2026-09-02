import SwiftUI

struct StatusOptionPicker: View {
    let title: String
    @Binding var selection: String?
    let options: [AutomationService.StatusOption]

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Choose a status").tag(nil as String?)
            ForEach(options) { option in
                Text(option.name).tag(Optional(option.id))
            }
        }
    }
}
