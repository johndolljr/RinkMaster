import Foundation

public enum FrontendType: String, Codable, Equatable, Sendable, CaseIterable {
    case attractMode = "attract-mode"
    case emulationStation = "emulationstation"
}

public enum MachineValidationError: Error, Equatable {
    case emptyName
    case invalidUser
    case invalidHost
    case duplicateName(String)
}

/// One RetroPie cabinet.
public struct Machine: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name.lowercased() }
    public var name: String
    public var user: String
    public var host: String
    public var frontend: FrontendType
    public var romsPath: String
    /// Port of the cabinet's `rinkmasterd` service.
    public var servicePort: Int

    public init(name: String, user: String, host: String, frontend: FrontendType,
                romsPath: String = "/home/pi/RetroPie/roms", servicePort: Int = 8472) {
        self.name = name; self.user = user; self.host = host; self.frontend = frontend
        self.romsPath = romsPath; self.servicePort = servicePort
    }

    private enum CodingKeys: String, CodingKey { case name, user, host, frontend, romsPath, servicePort }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        user = try c.decode(String.self, forKey: .user)
        host = try c.decode(String.self, forKey: .host)
        frontend = try c.decode(FrontendType.self, forKey: .frontend)
        romsPath = try c.decodeIfPresent(String.self, forKey: .romsPath) ?? "/home/pi/RetroPie/roms"
        servicePort = try c.decodeIfPresent(Int.self, forKey: .servicePort) ?? 8472  // settings saved before the service existed
    }

    public var sshTarget: SSHTarget { SSHTarget(user: user, host: host) }

    public var validationError: MachineValidationError? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return .emptyName }
        if !SSHTarget(user: user, host: "ok").isValid { return .invalidUser }
        if !SSHTarget(user: "ok", host: host).isValid { return .invalidHost }
        return nil
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var machines: [Machine]
    public var masterPath: String
    public var arcadeTitle: String
    public var arcadeSubtitle: String
    public var arcadeYear: String
    public var retroArchPath: String
    public var javaPath: String

    public init(machines: [Machine] = [],
                masterPath: String = "",
                arcadeTitle: String = "DLL ARCADE",
                arcadeSubtitle: String = "SKATE TOWN",
                arcadeYear: String = "1984",
                retroArchPath: String = "",
                javaPath: String = "") {
        self.machines = machines
        self.masterPath = masterPath
        self.arcadeTitle = arcadeTitle
        self.arcadeSubtitle = arcadeSubtitle
        self.arcadeYear = arcadeYear
        self.retroArchPath = retroArchPath
        self.javaPath = javaPath
    }

    private enum CodingKeys: String, CodingKey {
        case machines, masterPath, arcadeTitle, arcadeSubtitle, arcadeYear, retroArchPath, javaPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machines = try c.decodeIfPresent([Machine].self, forKey: .machines) ?? []
        masterPath = try c.decodeIfPresent(String.self, forKey: .masterPath) ?? ""
        arcadeTitle = try c.decodeIfPresent(String.self, forKey: .arcadeTitle) ?? "DLL ARCADE"
        arcadeSubtitle = try c.decodeIfPresent(String.self, forKey: .arcadeSubtitle) ?? "SKATE TOWN"
        arcadeYear = try c.decodeIfPresent(String.self, forKey: .arcadeYear) ?? "1984"
        retroArchPath = try c.decodeIfPresent(String.self, forKey: .retroArchPath) ?? ""
        javaPath = try c.decodeIfPresent(String.self, forKey: .javaPath) ?? ""
    }

    public static let defaults = AppSettings(
        machines: [],
        masterPath: "",
        arcadeTitle: "DLL ARCADE",
        arcadeSubtitle: "SKATE TOWN",
        arcadeYear: "1984",
        retroArchPath: "",
        javaPath: "")

    public var validationError: MachineValidationError? {
        var seen = Set<String>()
        for m in machines {
            if let e = m.validationError { return e }
            if !seen.insert(m.name.lowercased()).inserted { return .duplicateName(m.name) }
        }
        return nil
    }
}

public enum MachineStore {
    /// Default location: ~/Library/Application Support/RinkMaster/settings.json (or $RINKMASTER_SETTINGS_PATH)
    public static var defaultURL: URL {
        if let custom = ProcessInfo.processInfo.environment["RINKMASTER_SETTINGS_PATH"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RinkMaster/settings.json")
    }

    /// Missing file means first run, so the defaults; a corrupt file is an error (never silently reset).
    public static func load(from url: URL = defaultURL) throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return .defaults }
        return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url))
    }

    public static func save(_ settings: AppSettings, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
