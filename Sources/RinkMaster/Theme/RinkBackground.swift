import SwiftUI
import RinkMasterCore

/// Black/navy gradient with a red floor glow, spotlight beams, rink-carpet confetti and a vignette.
struct RinkBackground: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let stops = [0.0, 0.6, 1.0].map { Gradient.Stop(color: Color(RinkPalette.background(at: $0)), location: $0) }
            context.fill(Path(rect), with: .linearGradient(Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            // red glow rising from the bottom, like the rink floor under the lights
            let glow = CGRect(x: -size.width * 0.3, y: size.height * 0.62, width: size.width * 1.6, height: size.height * 0.9)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: min(size.width, size.height) * 0.08))
                layer.fill(Path(ellipseIn: glow), with: .color(Rink.red.opacity(0.31)))
            }

            // spotlight beams from the top corners and center
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 26))
                for (cx, color) in [(size.width * 0.08, Rink.teal), (size.width * 0.92, Color(RinkPalette.pink)), (size.width * 0.5, Rink.amber)] {
                    for spread in [1.0, 0.6] {
                        var beam = Path()
                        let drift = (size.width / 2 - cx) * 0.6
                        let reach = min(size.width, 1200) * 0.28 * spread
                        beam.move(to: CGPoint(x: cx - 8, y: 0))
                        beam.addLine(to: CGPoint(x: cx + 8, y: 0))
                        beam.addLine(to: CGPoint(x: cx + reach + drift, y: size.height * 0.85))
                        beam.addLine(to: CGPoint(x: cx - reach + drift, y: size.height * 0.85))
                        beam.closeSubpath()
                        layer.fill(beam, with: .color(color.opacity(0.055)))
                    }
                }
            }

            // carpet confetti, denser toward the edges
            var generator = ConfettiGenerator(seed: 1984)
            let count = min(2200, Int(size.width * size.height * 0.00053))
            for piece in generator.pieces(count: count, width: size.width, height: size.height) {
                let half = Double(piece.length) / 2
                var line = Path()
                line.move(to: CGPoint(x: piece.x - cos(piece.angle) * half, y: piece.y - sin(piece.angle) * half))
                line.addLine(to: CGPoint(x: piece.x + cos(piece.angle) * half, y: piece.y + sin(piece.angle) * half))
                context.stroke(line, with: .color(Color(RinkPalette.confetti[piece.colorIndex], opacity: Double(piece.alpha) / 255)),
                               style: StrokeStyle(lineWidth: CGFloat(piece.thickness) * 0.7, lineCap: .round))
            }

            // vignette
            context.fill(Path(rect), with: .radialGradient(
                Gradient(colors: [.clear, .black.opacity(0.62)]),
                center: CGPoint(x: size.width / 2, y: size.height / 2),
                startRadius: min(size.width, size.height) * 0.45,
                endRadius: max(size.width, size.height) * 0.78))
        }
        .ignoresSafeArea()
    }
}
