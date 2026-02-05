import SwiftUI

struct StatusSummaryView: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(project.statusCounts, id: \.status.id) { item in
                HStack {
                    Circle()
                        .fill(item.status.swiftUIColor)
                        .frame(width: 8, height: 8)

                    Text(item.status.name)
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("\(item.count)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(item.status.swiftUIColor.opacity(0.2))
                        .clipShape(Capsule())
                }
            }

            if !project.noStatusItems.isEmpty {
                HStack {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 8, height: 8)

                    Text("No Status")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(project.noStatusItems.count)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }
}
