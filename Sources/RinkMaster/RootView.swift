import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            RinkBackground()
            HStack(spacing: 0) {
                sidebar.frame(width: 300)
                VStack(spacing: 0) {
                    switch model.section {
                    case .machines: MachinesView()
                    case .settings: SettingsView()
                    case .games: GameBrowserView()
                    case .scores: HighScoresView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 18) {
            TitleBanner(title: model.settings.arcadeTitle,
                        subtitle: model.settings.arcadeSubtitle,
                        year: model.settings.arcadeYear,
                        size: 44).padding(.top, 28)
            StripeBand().padding(.horizontal, 24)
            VStack(spacing: 6) {
                ForEach(NavSection.allCases) { s in
                    Button { model.section = s } label: {
                        Group {
                            if model.section == s {
                                SelectionPill { Text(s.rawValue).font(Rink.bebas(28)).foregroundStyle(.white) }
                            } else {
                                Text(s.rawValue).font(Rink.bebas(24)).foregroundStyle(Color(red: 1, green: 0.77, blue: 0.55).opacity(0.8))
                                    .padding(.vertical, 8)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
            Spacer()
            Text("RINKMASTER").font(Rink.bungee(14)).foregroundStyle(Rink.amber.opacity(0.8)).padding(.bottom, 20)
        }
        .padding(.horizontal, 12)
    }
}

struct PlaceholderView: View {
    let title: String
    let note: String
    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(Rink.bungee(34)).foregroundStyle(Rink.amber)
            Text(note).font(Rink.bebas(24)).foregroundStyle(Rink.lavender).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
