import Foundation

/// One `<game>` of an EmulationStation / ScreenScraper `gamelist.xml`.
public struct GamelistEntry: Equatable, Sendable {
    /// The ROM path as written, e.g. `./Pitfall (USA).zip`.
    public var path = ""
    public var name = ""
    public var desc = ""
    /// `yyyyMMddTHHmmss` as scraped.
    public var releaseDate = ""
    public var developer = ""
    public var publisher = ""
    public var genre = ""

    public init() {}

    /// The ROM file name without folders or extension: the key that ties an entry to its ROM and artwork.
    public var stem: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    public var year: String { releaseDate.count >= 4 && releaseDate.prefix(4).allSatisfy(\.isNumber) ? String(releaseDate.prefix(4)) : "" }

    /// Who made it: the developer, else the publisher.
    public var maker: String { developer.isEmpty ? publisher : developer }
}

/// Reads a `gamelist.xml`. A malformed file yields every game parsed before the error rather than nothing.
public enum Gamelist {
    public static func parse(_ data: Data) -> [String: GamelistEntry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    public static func load(from url: URL) -> [String: GamelistEntry] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [:] }
        return parse(data)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [String: GamelistEntry] = [:]
        private var current: GamelistEntry?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "game" { current = GamelistEntry() }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard current != nil else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "path": current?.path = value
            case "name": current?.name = value
            case "desc": current?.desc = value
            case "releasedate": current?.releaseDate = value
            case "developer": current?.developer = value
            case "publisher": current?.publisher = value
            case "genre": current?.genre = value
            case "game":
                if let entry = current, !entry.stem.isEmpty, entries[entry.stem] == nil { entries[entry.stem] = entry }
                current = nil
            default: break
            }
            text = ""
        }
    }
}
