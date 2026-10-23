import Foundation

public enum ShellQuote {
    /// POSIX single-quote escaping: everything inside stays literal (`$`, backticks, spaces, globs...).
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
