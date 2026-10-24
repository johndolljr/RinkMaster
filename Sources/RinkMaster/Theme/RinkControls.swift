import SwiftUI

/// Amber-outlined capsule button, the app's standard action style.
struct RinkButtonStyle: ButtonStyle {
    var tint: Color = Rink.amber
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Rink.bebas(20))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(tint)
            .padding(.horizontal, 18).padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.28 : 0.12)))
            .overlay(Capsule().strokeBorder(tint, lineWidth: 2))
            .shadow(color: tint.opacity(0.45), radius: 6)
    }
}

/// Dark rounded field with an amber hairline, used in Settings.
struct RinkFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            // real letter case matters for hosts and paths, so not the all-caps display font
            .font(.system(size: 17, weight: .regular, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Rink.amber.opacity(0.55), lineWidth: 1))
    }
}

/// Small teal tag, e.g. an emulator name.
struct Chip: View {
    let text: String
    var tint: Color = Rink.teal
    var body: some View {
        Text(text)
            .font(Rink.bebas(16))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.7), lineWidth: 1))
    }
}
