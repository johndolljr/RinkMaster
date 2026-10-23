import SwiftUI
import CoreText
import RinkMasterCore

extension Color {
    init(_ rgb: RGB, opacity: Double = 1) {
        let u = rgb.unit
        self.init(.sRGB, red: u.r, green: u.g, blue: u.b, opacity: opacity)
    }
}

/// Colors and fonts of the "DLL ARCADE - Skate Town 1984" cabinet theme.
enum Rink {
    static let red = Color(RinkPalette.red)
    static let amber = Color(RinkPalette.amber)
    static let teal = Color(RinkPalette.teal)
    static let lavender = Color(RinkPalette.lavender)

    /// Benguiat-style serif title (system Didot Bold).
    static func title(_ size: CGFloat) -> Font { .custom("Didot-Bold", size: size) }
    static func bebas(_ size: CGFloat) -> Font { .custom("BebasNeue-Regular", size: size) }
    static func bungee(_ size: CGFloat) -> Font { .custom("Bungee-Regular", size: size) }

    /// Registers the bundled Bungee and Bebas Neue fonts for this process. Looks in the installed app's
    /// Contents/Resources/Fonts first, then in the SwiftPM resource bundle (development runs).
    static func registerFonts() {
        let names = ["BebasNeue-Regular", "Bungee-Regular"]
        for name in names {
            let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf")
            if let url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }
}
