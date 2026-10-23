import Foundation

/// Machine metadata and ROM-set relationships from a MAME XML dump (`<machine>`, or `<game>` in older dumps).
public struct MameDatabase: Sendable {
    public struct Machine: Equatable, Sendable {
        public var name: String
        public var description = ""
        public var year = ""
        public var manufacturer = ""
        public var cloneOf: String?
        public var romOf: String?
        public var isDevice = false
        public var isBIOS = false
        public var deviceRefs: [String] = []
        public var romCount = 0
    }

    public enum LookupError: Error, Equatable { case unknownGame(String) }

    private let machines: [String: Machine]
    public var count: Int { machines.count }

    public func machine(_ name: String) -> Machine? { machines[name] }

    /// Every ROM set a game needs: itself, its parent/BIOS chain, and the devices that carry ROMs (e.g. namco51).
    public func requiredRomSets(for game: String) throws -> [String] {
        guard machines[game] != nil else { throw LookupError.unknownGame(game) }
        var result: [String] = []
        var seen = Set<String>()
        func visit(_ name: String) {
            guard let m = machines[name], seen.insert(name).inserted else { return }
            result.append(name)
            for parent in [m.romOf, m.cloneOf].compactMap({ $0 }) { visit(parent) }
            for device in m.deviceRefs where (machines[device]?.romCount ?? 0) > 0 { visit(device) }
        }
        visit(game)
        return result
    }

    public static func parse(_ data: Data) throws -> MameDatabase {
        let delegate = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        return MameDatabase(machines: delegate.machines)
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var machines: [String: Machine] = [:]
        private var current: Machine?
        private var text: String?

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            switch element {
            case "machine", "game":
                var m = Machine(name: a["name"] ?? "")
                m.cloneOf = a["cloneof"]; m.romOf = a["romof"]
                m.isDevice = a["isdevice"] == "yes"; m.isBIOS = a["isbios"] == "yes"
                current = m
            case "rom": current?.romCount += 1
            case "device_ref":
                if let n = a["name"], current?.deviceRefs.contains(n) == false { current?.deviceRefs.append(n) }
            case "description", "year", "manufacturer": text = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text? += string }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            switch element {
            case "description": if let t = text { current?.description = t }
            case "year": if let t = text { current?.year = t }
            case "manufacturer": if let t = text { current?.manufacturer = t }
            case "machine", "game":
                if let m = current { machines[m.name] = m }
                current = nil
            default: break
            }
            if ["description", "year", "manufacturer"].contains(element) { text = nil }
        }
    }
}
