import Foundation

/// Per-game write-ups from MAME's `history.dat` (arcade `$info=` entries only).
public struct HistoryDatabase: Sendable {
    public struct Section: Equatable, Sendable {
        public let title: String  // empty for the opening text
        public let body: String
    }

    private let entries: [String: String]
    public var count: Int { entries.count }

    public func text(for game: String) -> String? { entries[game] }

    /// The write-up split at its `- HEADING -` lines (TECHNICAL, TRIVIA, STAFF, ...).
    public func sections(for game: String) -> [Section]? {
        guard let text = entries[game] else { return nil }
        return Self.sections(in: text)
    }

    static func sections(in text: String) -> [Section] {
        var sections: [Section] = []
        var title = "", lines: [String] = []
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty || !title.isEmpty { sections.append(Section(title: title, body: body)) }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("- "), line.hasSuffix(" -"), line.count > 4, line == line.uppercased() {
                flush()
                title = String(line.dropFirst(2).dropLast(2))
            } else {
                lines.append(line)
            }
        }
        flush()
        return sections
    }

    public static func parse(_ source: String) -> HistoryDatabase {
        var entries: [String: String] = [:]
        var names: [String] = []
        var body: [String] = []
        var inBody = false
        func finish() {
            if inBody, !names.isEmpty {
                let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                for n in names { entries[n] = text }
            }
            names = []; body = []; inBody = false
        }
        source.enumerateLines { line, _ in
            if line.hasPrefix("$info=") {
                finish()
                names = line.dropFirst(6).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if line.hasPrefix("$") && line.contains("=") && !line.hasPrefix("$bio") {
                finish()  // another system's entry
            } else if line == "$end" {
                finish()
            } else if line == "$bio" {
                if !names.isEmpty { inBody = true }
            } else if inBody {
                body.append(line)
            }
        }
        finish()
        return HistoryDatabase(entries: entries)
    }

    public static func load(from url: URL) throws -> HistoryDatabase {
        parse(String(decoding: try Data(contentsOf: url), as: UTF8.self))
    }
}
