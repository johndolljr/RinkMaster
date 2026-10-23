import XCTest
@testable import RinkMasterCore

final class MachineStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rinkmaster-\(UUID().uuidString).json")
    }

    func testDefaultsAreEmptyForOpenSource() {
        let s = AppSettings.defaults
        XCTAssertTrue(s.machines.isEmpty)
        XCTAssertEqual(s.masterPath, "")
        XCTAssertEqual(s.arcadeTitle, "DLL ARCADE")
        XCTAssertEqual(s.arcadeSubtitle, "SKATE TOWN")
        XCTAssertEqual(s.arcadeYear, "1984")
        XCTAssertEqual(s.retroArchPath, "")
        XCTAssertEqual(s.javaPath, "")
    }

    func testBackwardCompatibilityWithLegacySettingsJson() throws {
        let json = """
        {
          "machines": [
            {
              "name": "cab1",
              "user": "pi",
              "host": "cab1.lan",
              "frontend": "emulationstation",
              "romsPath": "/home/pi/RetroPie/roms",
              "servicePort": 8472
            }
          ],
          "masterPath": "/path/to/mame"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.machines.count, 1)
        XCTAssertEqual(s.machines[0].name, "cab1")
        XCTAssertEqual(s.masterPath, "/path/to/mame")
        XCTAssertEqual(s.arcadeTitle, "DLL ARCADE")
        XCTAssertEqual(s.arcadeSubtitle, "SKATE TOWN")
        XCTAssertEqual(s.arcadeYear, "1984")
        XCTAssertEqual(s.retroArchPath, "")
        XCTAssertEqual(s.javaPath, "")
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        var s = AppSettings.defaults
        s.arcadeTitle = "MY ARCADE"
        s.arcadeSubtitle = "BASEMENT"
        s.arcadeYear = "1988"
        s.retroArchPath = "/custom/RetroArch.app"
        s.javaPath = "/custom/bin/java"
        s.machines.append(Machine(name: "bar", user: "pi", host: "bar.lan", frontend: .emulationStation))
        try MachineStore.save(s, to: url)
        let loaded = try MachineStore.load(from: url)
        XCTAssertEqual(loaded, s)
        XCTAssertEqual(loaded.arcadeTitle, "MY ARCADE")
        XCTAssertEqual(loaded.arcadeSubtitle, "BASEMENT")
        XCTAssertEqual(loaded.arcadeYear, "1988")
        XCTAssertEqual(loaded.retroArchPath, "/custom/RetroArch.app")
        XCTAssertEqual(loaded.javaPath, "/custom/bin/java")
    }

    func testLoadMissingFileReturnsDefaults() throws {
        XCTAssertEqual(try MachineStore.load(from: tempURL()), AppSettings.defaults)
    }

    func testLoadCorruptFileThrows() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MachineStore.load(from: url))
    }

    func testValidationRejectsBadMachines() {
        XCTAssertNil(Machine(name: "ok", user: "pi", host: "a.lan", frontend: .attractMode).validationError)
        XCTAssertEqual(Machine(name: " ", user: "pi", host: "a.lan", frontend: .attractMode).validationError, .emptyName)
        XCTAssertEqual(Machine(name: "x", user: "pi", host: "a b", frontend: .attractMode).validationError, .invalidHost)
        XCTAssertEqual(Machine(name: "x", user: "", host: "a.lan", frontend: .attractMode).validationError, .invalidUser)
    }

    func testSettingsRejectDuplicateNames() {
        var s = AppSettings.defaults
        s.machines = [
            Machine(name: "cabinet1", user: "pi", host: "cab1.lan", frontend: .emulationStation),
            Machine(name: "CABINET1", user: "pi", host: "cab2.lan", frontend: .attractMode)
        ]
        XCTAssertEqual(s.validationError, .duplicateName("CABINET1"))
        XCTAssertNil(AppSettings.defaults.validationError)
    }

    func testMachineIDIsLowercasedName() {
        XCTAssertEqual(Machine(name: "ARCADE2", user: "pi", host: "h", frontend: .attractMode).id, "arcade2")
    }

    func testDefaultURLIsInApplicationSupport() {
        XCTAssertTrue(MachineStore.defaultURL.path.hasSuffix("settings.json"))
        setenv("RINKMASTER_SETTINGS_PATH", "/tmp/custom-settings.json", 1)
        XCTAssertEqual(MachineStore.defaultURL.path, "/tmp/custom-settings.json")
        unsetenv("RINKMASTER_SETTINGS_PATH")
    }

    func testSSHTargetFromMachine() {
        let m = Machine(name: "cab", user: "gamer", host: "cab.lan", frontend: .emulationStation)
        XCTAssertEqual(m.sshTarget.destination, "gamer@cab.lan")
    }
}
