import Foundation

/// Which emulators a cabinet has installed per system, as reported by `GET /v1/emulators`.
public struct MachineEmulators: Codable, Equatable, Sendable {
    public struct Emulator: Codable, Equatable, Sendable {
        public let id: String
        public let installed: Bool
        public let command: String?
    }
    public struct System: Codable, Equatable, Sendable {
        public let name: String
        public let defaultEmulator: String?
        public let hasInstalledEmulator: Bool
        public let emulators: [Emulator]
    }

    public let machine: String
    public let systems: [System]

    public func installedEmulators(for system: String) -> [String] {
        systems.first { $0.name == system }?.emulators.filter(\.installed).map(\.id) ?? []
    }

    /// Games can only be added for a system the cabinet can actually run.
    public func canInstall(system: String) -> Bool { !installedEmulators(for: system).isEmpty }

    public func cannotInstallReason(system: String, machine: String) -> String? {
        canInstall(system: system) ? nil : "\(machine) has no emulator installed for \(system)"
    }

    /// The system's default if it is installed, otherwise the first installed emulator.
    public func preferredEmulator(for system: String) -> String? {
        let installed = installedEmulators(for: system)
        if let d = systems.first(where: { $0.name == system })?.defaultEmulator, installed.contains(d) { return d }
        return installed.first
    }
}
