import Foundation

// Test doubles only. The test script deliberately excludes production AppKit approval,
// CFPreferences, ToolEnvironment, legacy AppTools and ADB process implementation.
enum AgentAccess: Int, Sendable, Comparable {
    case off, readOnly, full
    static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}
final class AccessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AgentAccess = .full
    func get() -> AgentAccess { lock.withLock { value } }
    func set(_ value: AgentAccess) { lock.withLock { self.value = value } }
}
enum AgentSettings {
    static let box = AccessBox()
    static var access: AgentAccess { box.get() }
    static func selectedPackage(deviceKey: String, userID: Int) -> String? { "com.example.app" }
}
actor ApprovalLog {
    private(set) var messages: [String] = []
    func add(_ message: String) { messages.append(message) }
    func clear() { messages = [] }
}
enum MCPNativeApproval {
    static let log = ApprovalLog()
    @TaskLocal static var handler: @Sendable () async throws -> Void = {}
    static func request(_ summary: String) async throws {
        await log.add(summary)
        try await handler()
    }
}
protocol ADBClient: Sendable {
    func devices() async throws -> [Device]
    func shell(_ device: Device, _ command: String) async throws -> String
    func console(_ device: Device, _ arguments: [String]) async throws -> String
    func execOut(_ device: Device, _ command: String) async throws -> Data
    func run(_ device: Device, _ arguments: [String]) async throws -> String
    func restartServer() async throws
}
struct DeviceContext: Sendable {
    let device: Device
    let adb: any ADBClient
    let foreground: Int
    let host: Int
    @discardableResult func shell(_ command: String) async throws -> String { try await adb.shell(device, command) }
}
struct ToolEnvironment: Sendable {
    let adb: any ADBClient
    func context(serial: String?) async throws -> DeviceContext {
        guard let serial, let device = try await adb.devices().first(where: { $0.serial == serial }), device.isReady else {
            throw AppError("Device unavailable")
        }
        return DeviceContext(device: device, adb: adb, foreground: 0, host: 0)
    }
}
enum AppTools {
    static let listApps = Tool(name: "list_apps", title: "Apps", description: "Apps", effect: .read) { _ in .text("apps") }
    static let logcat = Tool(name: "logcat", title: "Logs", description: "Logs", effect: .read) { _ in .text("logs") }
    static let installAPK = Tool(name: "install_apk", title: "Install", description: "Install", effect: .destructive,
                                 parameters: [.string("path", "Path", required: true)]) { call in
        let context = try await call.device()
        let path = try call.arguments.requiredString("path")
        return .text(try await context.adb.run(context.device, ["install", path]))
    }
}
actor MockADBState {
    private(set) var devices = [Device(serial: "mock-device-a", model: "Test phone"), Device(serial: "mock-device-b", model: "Other phone")]
    private(set) var commands: [String] = []
    private(set) var installedBytes: Data?
    var user = 0
    func disconnect() { devices.removeAll { $0.serial == "mock-device-a" } }
    func changeUser() { user = 10 }
    func execute(_ command: String) throws -> String {
        commands.append(command)
        if command == "am get-current-user" { return String(user) }
        if command.hasPrefix("pm list packages") { return "package:com.example.app\n" }
        if command.hasPrefix("cmd package resolve-activity") { return "com.example.app/.MainActivity\n" }
        if command.hasPrefix("am start") { return "Status: ok\n" }
        if command.hasPrefix("pm clear") || command.hasPrefix("pm uninstall") { return "Success\n" }
        if command.hasPrefix("dumpsys package") {
            return """
              User 0: installed=true
                runtime permissions:
                  android.permission.CAMERA: granted=true, flags=[]
                  android.permission.LOCATION: granted=true, flags=[ POLICY_FIXED ]
              User 10: installed=true
                runtime permissions:
                  android.permission.OTHER: granted=true, flags=[]
            """
        }
        if command.hasPrefix("am force-stop") || command.hasPrefix("pm revoke") || command == "probe" { return "" }
        throw AppError("Unexpected command: \(command)")
    }
    func install(_ path: String) throws -> String {
        installedBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        commands.append("install")
        return "Success"
    }
    var mutations: [String] { commands.filter { $0.hasPrefix("am start") || $0.hasPrefix("am force-stop") || $0.hasPrefix("pm clear") || $0.hasPrefix("pm revoke") || $0 == "install" } }
}
struct MockADB: ADBClient {
    let state: MockADBState
    func devices() async throws -> [Device] { await state.devices }
    func shell(_ device: Device, _ command: String) async throws -> String { try await state.execute(command) }
    func console(_ device: Device, _ arguments: [String]) async throws -> String { throw AppError("Unexpected console") }
    func execOut(_ device: Device, _ command: String) async throws -> Data { throw AppError("Unexpected screenshot") }
    func run(_ device: Device, _ arguments: [String]) async throws -> String { try await state.install(arguments.last!) }
    func restartServer() async throws { throw AppError("Unexpected restart") }
}
