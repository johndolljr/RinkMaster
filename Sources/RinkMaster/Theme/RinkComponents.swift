import SwiftUI
import RinkMasterCore

/// Title banner with red serif title, double rules above, amber tagline below. Configurable per arcade.
struct TitleBanner: View {
    var title: String = "DLL ARCADE"
    var subtitle: String = "S K A T E   T O W N"
    var year: String = "1 9 8 4"
    var size: CGFloat = 96

    var body: some View {
        VStack(spacing: size * 0.06) {
            VStack(spacing: 5) {
                Rectangle().fill(Rink.red.opacity(0.8)).frame(height: 2)
                Rectangle().fill(Rink.red.opacity(0.8)).frame(height: 2)
            }
            .padding(.horizontal, size * 0.4)

            let cleanTitle = title.trimmingCharacters(in: .whitespaces)
            Text(cleanTitle.isEmpty ? "RINKMASTER" : cleanTitle.uppercased())
                .font(Rink.title(size))
                .tracking(-size * 0.03)
                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.27, blue: 0.27), Rink.red, Color(red: 0.59, green: 0.05, blue: 0.09)],
                                                startPoint: .top, endPoint: .bottom))
                .shadow(color: Rink.red.opacity(0.9), radius: size * 0.10)
                .shadow(color: Rink.red.opacity(0.55), radius: size * 0.22)
                .lineLimit(1)
                .minimumScaleFactor(0.4)

            let cleanSub = subtitle.trimmingCharacters(in: .whitespaces)
            let cleanYear = year.trimmingCharacters(in: .whitespaces)
            if !cleanSub.isEmpty || !cleanYear.isEmpty {
                HStack(spacing: size * 0.18) {
                    if !cleanSub.isEmpty {
                        Text(spaced(cleanSub.uppercased()))
                    }
                    if !cleanSub.isEmpty && !cleanYear.isEmpty {
                        RoundedRectangle(cornerRadius: 2).fill(Rink.teal).frame(width: size * 0.2, height: 4)
                    }
                    if !cleanYear.isEmpty {
                        Text(spaced(cleanYear.uppercased()))
                    }
                }
                .font(Rink.bebas(size * 0.26))
                .foregroundStyle(Rink.amber)
            }
        }
    }

    private func spaced(_ text: String) -> String {
        if text.contains(" ") { return text }
        return text.map(String.init).joined(separator: " ")
    }
}

/// Red / amber / teal retro stripes with a soft glow.
struct StripeBand: View {
    var body: some View {
        VStack(spacing: 6) {
            ForEach([Rink.red, Rink.amber, Rink.teal], id: \.self) { c in
                Rectangle().fill(c.opacity(0.92)).frame(height: 5)
            }
        }
        .shadow(color: Rink.red.opacity(0.45), radius: 8)
    }
}

/// Glowing red rounded frame with an amber inner line, like the game-screen frame on the cabinet.
struct GlowFrame: ViewModifier {
    var radius: CGFloat = 26
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Rink.red, lineWidth: 5))
            .overlay(RoundedRectangle(cornerRadius: radius - 8).strokeBorder(Rink.amber.opacity(0.65), lineWidth: 1.5).padding(10))
            // glow is blurred strokes behind the frame so the interior stays dark
            .background(RoundedRectangle(cornerRadius: radius).stroke(Rink.red.opacity(0.9), lineWidth: 8).blur(radius: 10))
            .background(RoundedRectangle(cornerRadius: radius).stroke(Rink.red.opacity(0.5), lineWidth: 18).blur(radius: 26))
    }
}

extension View {
    func glowFrame(radius: CGFloat = 26) -> some View { modifier(GlowFrame(radius: radius)) }
}

/// The selected row: a glowing red pill with an amber outline.
struct SelectionPill<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
            .background(Capsule().fill(Rink.red.opacity(0.30)))
            .overlay(Capsule().strokeBorder(Rink.amber, lineWidth: 3))
            .shadow(color: Rink.red.opacity(0.8), radius: 12)
    }
}
