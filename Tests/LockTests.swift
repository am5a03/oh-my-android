import Foundation

actor Barrier {
    var entered = false
    var done = false
    func enter() { entered = true }
    func release() { done = true }
}

@main struct LockTests {
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--probe" {
            do {
                _ = try await DeviceOperationLock.withLock("android:device-a", directory: URL(fileURLWithPath: CommandLine.arguments[2])) { 0 }
                exit(1)
            } catch { exit(0) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let barrier = Barrier()
        let holder = Task {
            try await DeviceOperationLock.withLock("android:device-a", directory: root) {
                await barrier.enter()
                while !(await barrier.done) { try await Task.sleep(for: .milliseconds(5)) }
                return 1
            }
        }
        while !(await barrier.entered) { try await Task.sleep(for: .milliseconds(5)) }
        var refused = false
        do { _ = try await DeviceOperationLock.withLock("android:device-a", directory: root) { 2 } }
        catch { refused = true }
        precondition(refused, "same-device overlap must fail closed")
        let other = try await DeviceOperationLock.withLock("android:device-b", directory: root) { 3 }
        precondition(other == 3)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--probe", root.path]
        try child.run()
        child.waitUntilExit()
        precondition(child.terminationStatus == 0, "another process must see the held lock")
        await barrier.release()
        _ = try await holder.value
        let released = try await DeviceOperationLock.withLock("android:device-a", directory: root) { 4 }
        precondition(released == 4)
        let nested = try await DeviceOperationLock.withLock("android:device-a", directory: root) {
            try await DeviceOperationLock.withLock("android:device-a", directory: root) { 5 }
        }
        precondition(nested == 5)
        do {
            _ = try await DeviceOperationLock.withLock("error", directory: root) { () throws -> Int in throw AppError("expected") }
        } catch {}
        _ = try await DeviceOperationLock.withLock("error", directory: root) { 6 }
        print("6 device-lock checks passed")
    }
}
