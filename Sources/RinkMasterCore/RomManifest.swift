import Foundation

/// A cabinet's `roms-manifest.tsv` as written by `arcade-roms.py plan`:
/// one row per installed ROM zip or non-MAME entry, with the master folder that can reproduce it.
public struct RomManifest: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let system: String
        public let file: String
        public let size: Int
        /// Content signature (zip member CRC hash, or `fp:<files>:<bytes>` for non-MAME entries).
        public let signature: String
        /// Folder in the master (e.g. `sets/0.172`, `extras`), or nil when the master does not have it.
        public let masterDir: String?

        public var isInMaster: Bool { masterDir != nil }

        /// Game name: the file name without a `.zip` extension (folders like `lair.daphne` are kept as is).
        public var gameName: String {
            file.lowercased().hasSuffix(".zip") ? String(file.dropLast(4)) : file
        }
    }

    public enum ParseError: Error, Equatable {
        case badRow(line: Int)
    }

    public let entries: [Entry]

    public var entriesBySystem: [String: [Entry]] {
        Dictionary(grouping: entries, by: \.system)
    }

    public static func parse(_ text: String) throws -> RomManifest {
        var entries: [Entry] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cols = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 5, let size = Int(cols[2]) else {
                throw ParseError.badRow(line: index + 1)
            }
            let dir = cols[4].trimmingCharacters(in: .whitespaces)
            entries.append(Entry(system: cols[0], file: cols[1], size: size, signature: cols[3],
                                 masterDir: dir == "-" ? nil : dir))
        }
        return RomManifest(entries: entries)
    }
}
