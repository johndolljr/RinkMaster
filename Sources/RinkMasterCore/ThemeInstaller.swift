import Foundation

public enum ThemeInstallError: Error, Equatable, CustomStringConvertible {
    case themeNotFound(String)
    case packingFailed(String)
    case invalidThemeName(String)

    public var description: String {
        switch self {
        case .themeNotFound(let t): return "Theme folder not found for '\(t)'"
        case .packingFailed(let m): return "Failed to create theme archive: \(m)"
        case .invalidThemeName(let n): return "Invalid theme name '\(n)'"
        }
    }
}

public enum ThemeInstallMethod: String, Equatable, Sendable, Codable {
    case service
    case ssh
}

public struct ThemeInstallReport: Equatable, Sendable {
    public let machine: String
    public let frontend: String
    public let theme: String
    public let method: ThemeInstallMethod
    public let files: [String]
    public let activated: Bool
    public let message: String

    public init(machine: String, frontend: String, theme: String, method: ThemeInstallMethod, files: [String], activated: Bool, message: String) {
        self.machine = machine
        self.frontend = frontend
        self.theme = theme
        self.method = method
        self.files = files
        self.activated = activated
        self.message = message
    }
}

public enum ThemeLocator {
    public static func defaultThemeName(for frontend: FrontendType) -> String {
        switch frontend {
        case .emulationStation: return "dll-arcade"
        case .attractMode: return "rink"
        }
    }

    public static func locateTheme(name: String, customRoot: URL? = nil) -> URL? {
        let candidates: [URL] = [
            customRoot?.appendingPathComponent(name),
            Bundle.main.resourceURL?.appendingPathComponent("themes").appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/themes").appendingPathComponent(name),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("themes").appendingPathComponent(name),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("../themes").appendingPathComponent(name)
        ].compactMap { $0 }

        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public static func packTar(directory: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", "-", "-C", directory.path, "."]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw ThemeInstallError.packingFailed("\(error)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ThemeInstallError.packingFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}

public struct ThemeInstaller: Sendable {
    public let machine: Machine
    private let shell: RemoteShell
    private let service: ServiceClient
    private let customRoot: URL?

    public init(machine: Machine, shell: RemoteShell, service: ServiceClient, customRoot: URL? = nil) {
        self.machine = machine
        self.shell = shell
        self.service = service
        self.customRoot = customRoot
    }

    public func install(theme requested: String? = nil, activate: Bool = true, restartFrontend: Bool = false) async throws -> ThemeInstallReport {
        let themeName = (requested?.trimmingCharacters(in: .whitespaces).isEmpty == false)
            ? requested!.trimmingCharacters(in: .whitespaces)
            : ThemeLocator.defaultThemeName(for: machine.frontend)

        guard let localThemeURL = ThemeLocator.locateTheme(name: themeName, customRoot: customRoot) else {
            throw ThemeInstallError.themeNotFound(themeName)
        }

        // 1. Try service installation first
        if let report = try? await installViaService(themeName: themeName, localURL: localThemeURL, activate: activate, restartFrontend: restartFrontend) {
            return report
        }

        // 2. Fall back to SSH shell installation
        return try await installViaSSH(themeName: themeName, localURL: localThemeURL, activate: activate, restartFrontend: restartFrontend)
    }

    private func installViaService(themeName: String, localURL: URL, activate: Bool, restartFrontend: Bool) async throws -> ThemeInstallReport {
        let archive = try ThemeLocator.packTar(directory: localURL)
        let res = try await service.installTheme(name: themeName, archive: archive, activate: activate)
        if restartFrontend {
            _ = try? await service.restartFrontend()
        }
        return ThemeInstallReport(
            machine: machine.name,
            frontend: machine.frontend.rawValue,
            theme: themeName,
            method: .service,
            files: res.files,
            activated: res.activated,
            message: "Installed theme '\(themeName)' via rinkmasterd (\(res.files.count) files)"
        )
    }

    private func installViaSSH(themeName: String, localURL: URL, activate: Bool, restartFrontend: Bool) async throws -> ThemeInstallReport {
        let destDir: String
        switch machine.frontend {
        case .emulationStation:
            destDir = "/opt/retropie/configs/all/emulationstation/themes/\(themeName)"
        case .attractMode:
            destDir = "/opt/retropie/configs/all/attractmode/layouts/\(themeName)"
        }

        _ = try await shell.run("mkdir -p \(ShellQuote.quote(destDir))")
        _ = try await shell.push(localPath: localURL.path + "/", toRemotePath: destDir + "/")

        if activate {
            switch machine.frontend {
            case .emulationStation:
                let activateCmd = """
                cfg=/opt/retropie/configs/all/emulationstation/es_settings.cfg; cp -p "$cfg" "$cfg.bak-theme" 2>/dev/null || true; if grep -q 'name="ThemeSet"' "$cfg" 2>/dev/null; then sed -i 's|<string name="ThemeSet" value="[^"]*" />|<string name="ThemeSet" value="\(themeName)" />|' "$cfg"; else if [ -f "$cfg" ]; then sed -i 's|</config>|<string name="ThemeSet" value="\(themeName)" />\\n</config>|' "$cfg"; else mkdir -p "$(dirname "$cfg")"; echo '<config><string name="ThemeSet" value="\(themeName)" /></config>' > "$cfg"; fi; fi
                """
                _ = try await shell.run(activateCmd)
            case .attractMode:
                let activateCmd = """
                cfg=/opt/retropie/configs/all/attractmode/attract.cfg; cp -p "$cfg" "$cfg.bak-theme" 2>/dev/null || true; if [ -f "$cfg" ]; then sed -i 's/^[[:space:]]*layout[[:space:]]\\+[^\r\n]*/\tlayout               \(themeName)/' "$cfg"; fi
                """
                _ = try await shell.run(activateCmd)
            }
        }

        if restartFrontend {
            switch machine.frontend {
            case .emulationStation:
                _ = try? await shell.run("touch /tmp/es-restart && killall -SIGTERM emulationstation 2>/dev/null || true")
            case .attractMode:
                _ = try? await shell.run("/usr/bin/attract --build-romlist mame-libretro -o mame-libretro 2>/dev/null || true")
            }
        }

        let localFiles = (try? FileManager.default.contentsOfDirectory(atPath: localURL.path)) ?? []
        return ThemeInstallReport(
            machine: machine.name,
            frontend: machine.frontend.rawValue,
            theme: themeName,
            method: .ssh,
            files: localFiles,
            activated: activate,
            message: "Installed theme '\(themeName)' via SSH/rsync (\(localFiles.count) files)"
        )
    }
}
