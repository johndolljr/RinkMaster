import XCTest
@testable import RinkMasterCore

final class ThemeInstallerTests: XCTestCase {
    private var tempDir: URL!
    private let esMachine = Machine(name: "xarcade", user: "pi", host: "xarcade.lan", frontend: .emulationStation)
    private let attractMachine = Machine(name: "arcade2", user: "pi", host: "arcade2.lan", frontend: .attractMode)

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Create mock theme directories
        let esTheme = tempDir.appendingPathComponent("dll-arcade")
        try FileManager.default.createDirectory(at: esTheme.appendingPathComponent("art"), withIntermediateDirectories: true)
        try "theme xml content".write(to: esTheme.appendingPathComponent("theme.xml"), atomically: true, encoding: .utf8)
        try "bg png".write(to: esTheme.appendingPathComponent("art/bg.png"), atomically: true, encoding: .utf8)

        let attractTheme = tempDir.appendingPathComponent("rink")
        try FileManager.default.createDirectory(at: attractTheme, withIntermediateDirectories: true)
        try "layout nut content".write(to: attractTheme.appendingPathComponent("layout.nut"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testThemeLocatorDefaults() {
        XCTAssertEqual(ThemeLocator.defaultThemeName(for: .emulationStation), "dll-arcade")
        XCTAssertEqual(ThemeLocator.defaultThemeName(for: .attractMode), "rink")
    }

    func testThemeLocatorFindsThemeInCustomRoot() {
        let found = ThemeLocator.locateTheme(name: "dll-arcade", customRoot: tempDir)
        XCTAssertNotNil(found)
        XCTAssertTrue(FileManager.default.fileExists(atPath: found!.path))

        let missing = ThemeLocator.locateTheme(name: "nonexistent", customRoot: tempDir)
        XCTAssertNil(missing)
    }

    func testPackTarCreatesArchive() throws {
        let folder = tempDir.appendingPathComponent("dll-arcade")
        let data = try ThemeLocator.packTar(directory: folder)
        XCTAssertFalse(data.isEmpty)
        XCTAssertGreaterThan(data.count, 512) // POSIX tar blocks are 512 bytes
    }

    func testInstallViaServiceWhenOnline() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/v1/theme/install")
            XCTAssertTrue(req.url?.query?.contains("name=dll-arcade") == true)
            let json = """
            {"frontend":"emulationstation","theme":"dll-arcade","destDir":"/opt/themes","files":["theme.xml","art/bg.png"],"activated":true,"machine":"xarcade"}
            """
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        let shell = RecordingShell()
        let service = ServiceClient(host: "xarcade.lan", port: 8472, session: StubURLProtocol.session)
        let installer = ThemeInstaller(machine: esMachine, shell: shell, service: service, customRoot: tempDir)

        let report = try await installer.install(activate: true, restartFrontend: false)
        XCTAssertEqual(report.method, .service)
        XCTAssertEqual(report.theme, "dll-arcade")
        XCTAssertEqual(report.frontend, "emulationstation")
        XCTAssertTrue(report.activated)
        XCTAssertEqual(report.files, ["theme.xml", "art/bg.png"])
        XCTAssertTrue(shell.pushes.isEmpty) // Service was used, not SSH push
    }

    func testInstallFallsBackToSSHWhenServiceOffline() async throws {
        StubURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let shell = RecordingShell()
        let service = ServiceClient(host: "xarcade.lan", port: 8472, session: StubURLProtocol.session)
        let installer = ThemeInstaller(machine: esMachine, shell: shell, service: service, customRoot: tempDir)

        let report = try await installer.install(activate: true, restartFrontend: true)
        XCTAssertEqual(report.method, .ssh)
        XCTAssertEqual(report.theme, "dll-arcade")
        XCTAssertTrue(report.activated)
        XCTAssertEqual(shell.pushes.count, 1)
        XCTAssertTrue(shell.pushes[0].remote.contains("/opt/retropie/configs/all/emulationstation/themes/dll-arcade"))
        XCTAssertTrue(shell.commands.contains { $0.contains("ThemeSet") })
        XCTAssertTrue(shell.commands.contains { $0.contains("es-restart") })
    }

    func testInstallAttractModeViaSSH() async throws {
        StubURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let shell = RecordingShell()
        let service = ServiceClient(host: "arcade2.lan", port: 8472, session: StubURLProtocol.session)
        let installer = ThemeInstaller(machine: attractMachine, shell: shell, service: service, customRoot: tempDir)

        let report = try await installer.install(activate: true, restartFrontend: true)
        XCTAssertEqual(report.method, .ssh)
        XCTAssertEqual(report.theme, "rink")
        XCTAssertEqual(report.frontend, "attract-mode")
        XCTAssertEqual(shell.pushes.count, 1)
        XCTAssertTrue(shell.pushes[0].remote.contains("/opt/retropie/configs/all/attractmode/layouts/rink"))
        XCTAssertTrue(shell.commands.contains { $0.contains("attract.cfg") })
        XCTAssertTrue(shell.commands.contains { $0.contains("attract --build-romlist") })
    }

    func testThemeNotFoundThrows() async throws {
        let shell = RecordingShell()
        let service = ServiceClient(host: "xarcade.lan", port: 8472, session: StubURLProtocol.session)
        let installer = ThemeInstaller(machine: esMachine, shell: shell, service: service, customRoot: tempDir)

        do {
            _ = try await installer.install(theme: "nonexistent")
            XCTFail("Should have thrown")
        } catch let e as ThemeInstallError {
            XCTAssertEqual(e, .themeNotFound("nonexistent"))
            XCTAssertTrue(e.description.contains("nonexistent"))
        }
    }

    func testServiceClientThemeMethods() async throws {
        StubURLProtocol.handler = { req in
            switch req.url?.path {
            case "/v1/theme":
                let json = """
                {"frontend":"emulationstation","activeTheme":"dll-arcade","installedThemes":["carbon","dll-arcade"],"themesDir":"/opt/themes","machine":"xarcade"}
                """
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            case "/v1/theme/activate":
                let json = """
                {"frontend":"emulationstation","theme":"dll-arcade","activeTheme":"dll-arcade","previousTheme":"carbon","changed":true,"backup":"/opt/es.bak","machine":"xarcade"}
                """
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            case "/v1/theme/install":
                let json = """
                {"frontend":"emulationstation","theme":"dll-arcade","destDir":"/opt/themes/dll-arcade","files":["theme.xml"],"activated":true,"machine":"xarcade"}
                """
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let service = ServiceClient(host: "xarcade.lan", port: 8472, session: StubURLProtocol.session)
        let status = try await service.themeStatus()
        XCTAssertEqual(status.frontend, "emulationstation")
        XCTAssertEqual(status.activeTheme, "dll-arcade")
        XCTAssertEqual(status.installedThemes, ["carbon", "dll-arcade"])

        let activate = try await service.activateTheme(name: "dll-arcade")
        XCTAssertEqual(activate.activeTheme, "dll-arcade")
        XCTAssertTrue(activate.changed)

        let install = try await service.installTheme(name: "dll-arcade", archive: Data("archive".utf8), activate: true)
        XCTAssertEqual(install.theme, "dll-arcade")
        XCTAssertTrue(install.activated)

        let installNoActivate = try await service.installTheme(name: "dll-arcade", archive: Data("archive".utf8), activate: false)
        XCTAssertEqual(installNoActivate.theme, "dll-arcade")
    }
}
