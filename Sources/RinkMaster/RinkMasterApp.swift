import SwiftUI

@main
struct RinkMasterApp: App {
    @State private var model: AppModel

    init() {
        Rink.registerFonts()
        CommandLineTools.runIfRequested()
        _model = State(initialValue: MainActor.assumeIsolated { AppModel() })
    }

    var body: some Scene {
        WindowGroup("RinkMaster") {
            RootView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    // launched as a bare executable (scripts/run.sh) the app is not frontmost, so keystrokes would
                    // keep going to the terminal; make it a regular, active app so text fields take typing
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    model.startBackgroundScores()
                    model.startBackgroundCatalog()
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
