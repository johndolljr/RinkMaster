import Foundation

/// An 8-bit RGB color (kept UI-free so it can be tested and shared with a future CLI).
public struct RGB: Equatable, Hashable, Sendable {
    public let r: UInt8, g: UInt8, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// Components scaled to 0...1.
    public var unit: (r: Double, g: Double, b: Double) {
        (Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }
}

/// Colors of the "DLL ARCADE - Skate Town 1984" cabinet theme.
public enum RinkPalette {
    public static let red = RGB(r: 229, g: 36, b: 43)
    public static let amber = RGB(r: 255, g: 176, b: 66)
    public static let teal = RGB(r: 46, g: 196, b: 182)
    public static let pink = RGB(r: 255, g: 79, b: 147)
    public static let purple = RGB(r: 123, g: 44, b: 191)
    public static let blue = RGB(r: 80, g: 120, b: 255)
    /// Muted lavender used for secondary text.
    public static let lavender = RGB(r: 150, g: 130, b: 190)

    /// Carpet confetti colors, in the order the generator indexes them.
    public static let confetti: [RGB] = [teal, pink, purple, amber, blue]

    private static let stops: [(t: Double, color: RGB)] = [
        (0.0, RGB(r: 4, g: 3, b: 10)),
        (0.6, RGB(r: 12, g: 6, b: 24)),
        (1.0, RGB(r: 22, g: 6, b: 16)),
    ]

    /// Vertical background gradient: near-black navy at the top fading to deep maroon at the bottom.
    /// `t` is 0 (top) ... 1 (bottom); out-of-range values are clamped; channels are truncated like the generator.
    public static func background(at t: Double) -> RGB {
        let t = min(max(t, 0), 1)
        // the segment whose end is at or after t (the last segment catches t == 1)
        let i = stops.indices.dropLast().first { t <= stops[$0 + 1].t } ?? stops.count - 2
        let (t0, c0) = stops[i], (t1, c1) = stops[i + 1]
        let u = (t - t0) / (t1 - t0)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8(Double(a) + (Double(b) - Double(a)) * u) }
        return RGB(r: mix(c0.r, c1.r), g: mix(c0.g, c1.g), b: mix(c0.b, c1.b))
    }
}
