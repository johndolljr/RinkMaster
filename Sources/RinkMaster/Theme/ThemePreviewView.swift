import SwiftUI
import RinkMasterCore

/// Sample screen showing every theme element; used by the app until the real views land, and for snapshots.
struct ThemePreviewView: View {
    private let rows = ["FROGGER", "GALAGA (NAMCO REV. B)", "GALAGA (MIDWAY SET 1)", "GALAXIAN (MIDWAY SET 2)", "MS. PAC-MAN"]

    var body: some View {
        ZStack {
            RinkBackground()
            HStack(alignment: .top, spacing: 40) {
                VStack(spacing: 24) {
                    TitleBanner(size: 78)
                    StripeBand().padding(.horizontal, 20)
                    Spacer(minLength: 0)
                    VStack(spacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, name in
                            if i == 2 {
                                SelectionPill { Text(name).font(Rink.bebas(40)).foregroundStyle(.white) }
                            } else {
                                Text(name).font(Rink.bebas(32)).foregroundStyle(Color(red: 1, green: 0.77, blue: 0.55).opacity(i % 2 == 0 ? 0.5 : 0.75))
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Text("PRESS START").font(Rink.bungee(20)).foregroundStyle(Rink.amber)
                }
                .frame(maxWidth: 560)

                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.55))
                        Text("GAME ART").font(Rink.bebas(44)).foregroundStyle(Rink.lavender)
                    }
                    .glowFrame()
                    .padding(8)
                    HStack {
                        Text("NAMCO (MIDWAY LICENSE)  -  1981").font(Rink.bebas(26)).foregroundStyle(Rink.teal)
                    }
                }
            }
            .padding(36)
        }
    }
}
