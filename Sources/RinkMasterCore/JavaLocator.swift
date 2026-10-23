import Foundation

/// Finds the Java that runs hi2txt: JAVA_HOME, else the installed JDK reported by /usr/libexec/java_home, else the system launcher.
public enum JavaLocator {
    public static func path(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let home = environment["JAVA_HOME"] ?? javaHomeTool()
        if let home, FileManager.default.isExecutableFile(atPath: home + "/bin/java") { return home + "/bin/java" }
        return "/usr/bin/java"
    }

    private static func javaHomeTool() -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !text.isEmpty ? text : nil
    }
}
