import Foundation

struct SimulatorDevice: Identifiable, Hashable, Codable, Sendable {
    let udid: String
    let name: String
    let runtime: String
    let state: String
    let isAvailable: Bool
    var id: String { udid }
    var isReady: Bool { isAvailable && state == "Booted" }
    var runtimeVersion: String { runtime.components(separatedBy: ".iOS-").last?.replacingOccurrences(of: "-", with: ".") ?? runtime }
    var title: String { "\(name) · iOS \(runtimeVersion)" }
}

struct SimulatorApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let applicationType: String
    var id: String { bundleID }
    var isUserApp: Bool { applicationType == "User" }
    var linkStorageKey: String { "iosSimulator:\(bundleID)" }
}

struct SimulatorTarget: Hashable, Sendable {
    let device: SimulatorDevice
    let app: SimulatorApp
}

struct PreparedSimulatorReinstall: Identifiable, Sendable {
    let id: UUID
    let target: SimulatorTarget
    let source: URL
    let stagedApp: URL
    let directory: URL
    let launchAfter: Bool
}

/// The store depends on capabilities, not Process, Xcode, or a particular command-line format.
protocol SimulatorControlling: AppControlling where Target == SimulatorTarget {
    var simulatorApplication: URL { get }
    func devices() async throws -> [SimulatorDevice]
    func apps(on device: SimulatorDevice) async throws -> [SimulatorApp]
    func boot(_ device: SimulatorDevice) async throws
    func open(_ url: String, stopFirst: Bool, target: SimulatorTarget) async throws -> String
    func prepareReinstall(source: URL, target: SimulatorTarget, launchAfter: Bool) async throws -> PreparedSimulatorReinstall
    func reinstall(_ request: PreparedSimulatorReinstall) async throws -> String
    func discard(_ request: PreparedSimulatorReinstall)
}

enum SimulatorInput {
    static func udid(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else { throw AppError("Invalid Simulator identifier. Refresh the device list.") }
        return value
    }

    static func bundleID(_ value: String) throws -> String {
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*$"#, options: .regularExpression) != nil else {
            throw AppError("Invalid iOS bundle identifier.")
        }
        return value
    }

    static func devices(_ data: Data) throws -> [SimulatorDevice] {
        struct Envelope: Decodable { let devices: [String: [Entry]] }
        struct Entry: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return try envelope.devices.filter { $0.key.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-") }
            .flatMap { runtime, entries in
                try entries.map { entry in
                    SimulatorDevice(udid: try udid(entry.udid), name: entry.name, runtime: runtime,
                                    state: entry.state, isAvailable: entry.isAvailable)
                }
            }
            .sorted { lhs, rhs in
                if lhs.isReady != rhs.isReady { return lhs.isReady }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    /// simctl listapps commonly prints an OpenStep plist; also accept XML/binary plists and JSON.
    static func apps(_ data: Data) throws -> [SimulatorApp] {
        let object: Any
        if let json = try? JSONSerialization.jsonObject(with: data) { object = json }
        else { object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        guard let dictionary = object as? [String: [String: Any]] else {
            throw AppError("Unrecognized simctl app list. Check the selected Xcode version.")
        }
        return try dictionary.map { key, value in
            let identifier = try bundleID(value["CFBundleIdentifier"] as? String ?? key)
            guard identifier == key else { throw AppError("Inconsistent bundle identifier in the Simulator app list.") }
            return SimulatorApp(bundleID: identifier,
                                name: value["CFBundleDisplayName"] as? String ?? value["CFBundleName"] as? String ?? identifier,
                                applicationType: value["ApplicationType"] as? String ?? "Unknown")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
