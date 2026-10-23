import Foundation

/// One scrap of rink-carpet confetti.
public struct ConfettiPiece: Equatable, Sendable {
    public let x: Double, y: Double
    /// Angle in radians, 0...pi.
    public let angle: Double
    public let length: Int
    public let thickness: Int
    /// Index into `RinkPalette.confetti`.
    public let colorIndex: Int
    /// Opacity as 0...255 (the cabinet art uses 38...85 so the carpet stays subtle).
    public let alpha: Int
}

/// Deterministic generator: the same seed always gives the same carpet (SplitMix64).
public struct ConfettiGenerator: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    private mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    /// `count` pieces over a `width` x `height` area, denser toward the left and right edges
    /// (acceptance 25% in the middle rising to 100% at the edges), like the cabinet theme.
    public mutating func pieces(count: Int, width: Double, height: Double) -> [ConfettiPiece] {
        guard count > 0, width > 0, height > 0 else { return [] }
        var out: [ConfettiPiece] = []
        out.reserveCapacity(count)
        while out.count < count {
            let x = unit() * width
            let y = unit() * height
            let edge = abs(x - width / 2) / (width / 2)
            guard unit() <= 0.25 + 0.75 * edge else { continue }
            out.append(ConfettiPiece(
                x: x, y: y,
                angle: unit() * Double.pi,
                length: int(10...26),
                thickness: int(3...6),
                colorIndex: int(0...(RinkPalette.confetti.count - 1)),
                alpha: int(38...85)))
        }
        return out
    }
}
