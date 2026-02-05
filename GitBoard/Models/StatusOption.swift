import SwiftUI

struct StatusOption: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let color: String

    var swiftUIColor: Color {
        switch color.uppercased() {
        case "GRAY":
            return .gray
        case "RED":
            return .red
        case "ORANGE":
            return .orange
        case "YELLOW":
            return .yellow
        case "GREEN":
            return .green
        case "BLUE":
            return .blue
        case "PURPLE":
            return .purple
        case "PINK":
            return .pink
        default:
            return .secondary
        }
    }
}

struct StatusField: Codable {
    let id: String
    let name: String
    let options: [StatusOption]
}
