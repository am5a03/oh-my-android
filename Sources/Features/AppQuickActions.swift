import Foundation

extension AppCommandRunner {
    init(adb: ADBClient) {
        self.init(shell: { device, command in try await adb.shell(device, command) },
                  devices: { try await adb.devices() })
    }
}
