import Foundation

/// A RetroPie `emulators.cfg`: lines like `lr-mame2010 = "retroarch -L ... %ROM%"`, plus `default = "<id>"`.
/// The same format is used for per-game pins in `all/emulators.cfg` (`mame-libretro_galaga = "lr-mame2003"`).
public struct EmulatorsConfig: Equatable, Sendable {
    public let entries: [String: String]

    public var defaultEmulator: String? { entries["default"] }

    /// Emulator ids defined in the file (everything except `default`), sorted.
    public var emulatorIDs: [String] { entries.keys.filter { $0 != "default" }.sorted() }

    public static func parse(_ text: String) -> EmulatorsConfig {
        var entries: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard !key.isEmpty else { continue }
            entries[key] = value
        }
        return EmulatorsConfig(entries: entries)
    }
}
