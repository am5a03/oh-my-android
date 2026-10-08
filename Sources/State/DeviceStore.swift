import Foundation
import Observation

/// Keeps a sticky device selection, including while that device is disconnected.
@MainActor
@Observable
final class DeviceStore {
    private(set) var devices: [Device] = []
    private(set) var lastError: String?
    var selected: Device? {
        didSet {
            guard let selected else { return }
            defaults.set(selected.serial, forKey: Self.lastSerialKey)
            defaults.set(selected.model, forKey: Self.lastModelKey)
            defaults.set(selected.avdName, forKey: Self.lastAVDKey)
        }
    }
    private static let lastSerialKey = AgentSettings.panelDeviceKey
    private static let lastModelKey = "panel.lastDeviceModel"
    private static let lastAVDKey = "panel.lastDeviceAVD"
    private static let recoveryInterval: Duration = .seconds(4)

    private let adb: ADBClient
    private let tracker: DeviceTracking
    private let defaults: UserDefaults
    private var trackingTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?

    init(adb: ADBClient, tracker: DeviceTracking, defaults: UserDefaults = .standard) {
        self.adb = adb
        self.tracker = tracker
        self.defaults = defaults
        if let serial = defaults.string(forKey: Self.lastSerialKey) {
            selected = Device(serial: serial, model: defaults.string(forKey: Self.lastModelKey) ?? serial,
                              state: .offline, avdName: defaults.string(forKey: Self.lastAVDKey))
        }
    }

    var hasOnlyUnreadyDevices: Bool { !devices.isEmpty && !devices.contains(where: \.isReady) }

    func start(startServer: @escaping @Sendable () async -> Void) {
        trackingTask?.cancel()
        trackingTask = Task { [weak self, tracker] in
            await startServer()
            for await _ in tracker.events() {
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func stop() {
        trackingTask?.cancel()
        recoveryTask?.cancel()
        tracker.stop()
    }

    func refresh() async {
        do {
            let list = try await adb.devices()
            lastError = nil
            if list != devices { devices = list }
        } catch {
            lastError = error.localizedDescription
            devices = []
        }
        if let selected {
            let updated = devices.first {
                // Migrate old serial-only preferences once; subsequent AVD choices use stable names.
                if selected.isEmulator && selected.avdName == nil { return $0.serial == selected.serial }
                return $0.appSelectionKey == selected.appSelectionKey
            }
            if let updated {
                if updated != selected { self.selected = updated }
            } else {
                var disconnected = selected
                disconnected.state = .offline
                if disconnected != selected { self.selected = disconnected }
            }
        } else {
            // First launch only. Once a target exists, a disconnect never selects another device.
            selected = devices.first { $0.isReady }
        }
        updateRecovery()
    }

    func restartServer() async {
        lastError = nil
        try? await adb.restartServer()
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }

    private func updateRecovery() {
        // Preserve the existing bounded recovery loop while the chosen device is unready.
        let needsRecovery = selected?.isReady != true || lastError != nil || devices.contains { $0.isOnline && !$0.isBooted }
        if needsRecovery, recoveryTask == nil {
            recoveryTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.recoveryInterval)
                    guard let self, !Task.isCancelled else { return }
                    await self.refresh()
                }
            }
        } else if !needsRecovery {
            recoveryTask?.cancel()
            recoveryTask = nil
        }
    }
}
