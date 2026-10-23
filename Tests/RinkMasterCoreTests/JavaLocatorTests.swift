import XCTest
@testable import RinkMasterCore

final class JavaLocatorTests: XCTestCase {
    func testJavaHomeWinsWhenItHasAJava() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("jh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let java = home.appendingPathComponent("bin/java")
        try "#!/bin/sh\n".write(to: java, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(JavaLocator.path(environment: ["JAVA_HOME": home.path]), java.path)
    }

    func testABrokenJavaHomeFallsBackToAnExecutablePath() {
        let p = JavaLocator.path(environment: ["JAVA_HOME": "/nonexistent"])
        XCTAssertTrue(p.hasSuffix("/java"))
        XCTAssertTrue(p.hasPrefix("/"))
    }

    func testWithoutJavaHomeItAsksTheSystemOrUsesTheLauncher() {
        let p = JavaLocator.path(environment: [:])
        XCTAssertTrue(p.hasSuffix("/java"))
    }
}
