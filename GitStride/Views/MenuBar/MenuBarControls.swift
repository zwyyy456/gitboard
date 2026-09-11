import SwiftUI

// MARK: - Header Button Style

struct HeaderButtonStyle: ButtonStyle {
    let isProminent: Bool

    @State private var isHovered = false

    init(isProminent: Bool = false) {
        self.isProminent = isProminent
    }

    func makeBody(configuration: Configuration) -> some View {
        let backgroundColor = isProminent ? Color.accentColor : Color.primary
        let backgroundOpacity = if configuration.isPressed {
            0.16
        } else if isHovered {
            0.10
        } else {
            0.0
        }

        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor.opacity(backgroundOpacity))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    NSCursor.pointingHand.push()
                case .ended:
                    NSCursor.pop()
                }
            }
    }
}

struct HeaderButton: View {
    let icon: String
    let help: String
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(help, systemImage: icon, action: action)
            .labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .imageScale(.large)
            .foregroundStyle(isProminent ? Color.accentColor : Color.secondary)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        .buttonStyle(HeaderButtonStyle(isProminent: isProminent))
        .help(help)
    }
}

struct RefreshButton: View {
    @Binding var isRefreshing: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation: Double = 0

    var body: some View {
        Button("Refresh", systemImage: "arrow.clockwise", action: action)
            .labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .imageScale(.large)
            .foregroundStyle(isRefreshing ? .blue : .secondary)
            .rotationEffect(.degrees(rotation))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        .buttonStyle(HeaderButtonStyle())
        .disabled(isRefreshing)
        .help("Refresh")
        .onChange(of: isRefreshing) { _, newValue in
            if newValue {
                guard reduceMotion == false else {
                    rotation = 0
                    return
                }
                withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    rotation = 0
                }
            }
        }
    }
}

// MARK: - Filter Tab

struct FilterTab: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))

                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(count == 0 ? Color.secondary : color)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) items")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering in
            isHovered = hovering
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.pointingHand.push()
            case .ended:
                NSCursor.pop()
            }
        }
    }
}
