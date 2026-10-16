import Foundation
import Observation

/// Owns a read-only check and, only after a preview is accepted, one cancellable repair.
@MainActor
@Observable
final class CaptureDoctorStore {
    enum DeviceType: String, CaseIterable, Identifiable {
        case automatic, android, iphone, simulator
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .android: "Android"
            case .iphone: "iPhone"
            case .simulator: "iOS Simulator"
            }
        }
        var platform: String? { self == .automatic ? nil : rawValue }
    }

    private(set) var deviceType = DeviceType.automatic
    private(set) var report: CaptureDoctorReport?
    private(set) var preview: CaptureDoctorRepairPreview?
    private(set) var selectedRepair: CaptureDoctorRepair?
    private(set) var isChecking = false
    private(set) var isPreparingPreview = false
    private(set) var isRepairing = false
    private(set) var isCancelling = false
    private(set) var progressMessage: String?
    private(set) var output = ""
    private(set) var error: String?
    private(set) var notice: String?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var repairTask: Task<Void, Never>?
    @ObservationIgnored private var repairConfiguration: String?
    @ObservationIgnored private var repairRevision = UUID()
    @ObservationIgnored private let service: CaptureDoctorService
    @ObservationIgnored private var reportConfiguration: String?

    init(service: CaptureDoctorService = CaptureDoctorService()) { self.service = service }

    var hasOperation: Bool { isChecking || isPreparingPreview || isRepairing }

    func selectDeviceType(_ type: DeviceType, owner: CaptureStore) {
        guard owner.selectedDevice == nil, !owner.hasActiveCapture, !owner.isBusy, !hasOperation else { return }
        guard deviceType != type else { return }
        dismissPreview()
        deviceType = type
        report = nil; reportConfiguration = nil
        error = nil; notice = nil
    }

    func configurationKey(_ owner: CaptureStore) -> String {
        [owner.selectedDeviceID, owner.selectedDevice?.platform ?? deviceType.rawValue, String(owner.isSetupPresented),
         String(owner.isSetupPresented ? false : owner.captureLogs),
         String(owner.isSetupPresented ? true : owner.captureNetwork), owner.outputRoot.path,
         owner.networkService, owner.iphoneEndpointHost, owner.adbPath, owner.mitmdumpPath,
         owner.tools.keys.sorted().map { "\($0)=\(owner.toolPath($0) ?? "")" }.joined(separator: "\n")]
            .joined(separator: "\u{1f}")
    }

    func hasCurrentReport(_ owner: CaptureStore) -> Bool {
        report != nil && reportConfiguration == configurationKey(owner)
    }

    func refresh(_ owner: CaptureStore, force: Bool = false) async {
        while isChecking {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
        }
        guard !isRepairing, !Task.isCancelled else { return }
        let token = UUID()
        let configuration = configurationKey(owner)
        if !force, report != nil, reportConfiguration == configuration { return }
        revision = token
        isChecking = true
        defer { if revision == token { isChecking = false } }
        let result = await service.inspect(request(owner))
        guard !Task.isCancelled, revision == token, configurationKey(owner) == configuration else { return }
        report = result
        reportConfiguration = configuration
    }

    func prepareRepair(_ repair: CaptureDoctorRepair, owner: CaptureStore) async {
        guard !owner.hasActiveCapture, !owner.isBusy, !hasOperation else { return }
        let token = UUID()
        revision = token
        let configuration = configurationKey(owner)
        isPreparingPreview = true
        error = nil; notice = nil
        defer { if revision == token { isPreparingPreview = false } }
        let result = await service.repairPreview(for: repair)
        guard !Task.isCancelled, revision == token, configurationKey(owner) == configuration else { return }
        selectedRepair = repair
        preview = result
        repairConfiguration = configuration
    }

    func dismissPreview() {
        guard !isRepairing else { return }
        preview = nil; selectedRepair = nil; repairConfiguration = nil
    }

    func beginRepair(_ owner: CaptureStore) {
        guard !owner.hasActiveCapture, !owner.isBusy, !hasOperation,
              let repair = selectedRepair, preview?.canRun == true,
              repairConfiguration == configurationKey(owner) else { return }
        let snapshot = request(owner)
        let configuration = configurationKey(owner)
        let repairToken = UUID()
        repairRevision = repairToken
        isRepairing = true
        isCancelling = false
        progressMessage = "Preparing Installation…"
        output = ""; error = nil; notice = nil
        repairTask = Task { [weak self, weak owner] in
            guard let self else { return }
            do {
                let result = try await self.service.repair(repair, request: snapshot) { [weak self] update in
                    Task { @MainActor in self?.receive(update, revision: repairToken) }
                }
                self.output = Self.bounded(result.boundedOutput)
                self.report = result.report
                self.reportConfiguration = configuration
                self.notice = Task.isCancelled ? "Installation cancelled. The component checks have been refreshed." : "Installation finished. Review the new checks below."
            } catch is CancellationError {
                self.notice = "Installation cancelled. You can check the components again or retry."
            } catch {
                if let failure = error as? CaptureDoctorFailure, !failure.boundedOutput.isEmpty {
                    self.output = Self.bounded(self.output + "\n" + failure.boundedOutput)
                }
                self.error = "Installation did not finish. \(error.localizedDescription)"
            }
            self.isRepairing = false; self.isCancelling = false; self.progressMessage = nil; self.repairTask = nil
            self.preview = nil; self.selectedRepair = nil; self.repairConfiguration = nil
            if let owner {
                await owner.refreshDevices(includeApplications: false)
                await self.refresh(owner, force: true)
            }
        }
    }

    func cancelRepair() {
        guard isRepairing else { return }
        isCancelling = true
        progressMessage = "Cancelling Installation…"
        repairTask?.cancel()
    }

    func stopBeforeQuit() async {
        cancelRepair()
        await repairTask?.value
    }

    private func receive(_ update: CaptureDoctorProgress, revision: UUID) {
        guard isRepairing, !isCancelling, repairRevision == revision else { return }
        progressMessage = update.message
        if let text = update.output { output = Self.bounded(output + text) }
    }

    private func request(_ owner: CaptureStore) -> CaptureDoctorRequest {
        let overrides = ["adb": owner.adbPath, "mitmdump": owner.mitmdumpPath].filter { !$0.value.isEmpty }
        return CaptureDoctorRequest(platform: owner.selectedDevice?.platform ?? deviceType.platform, captureLogs: owner.isSetupPresented ? false : owner.captureLogs,
            captureNetwork: owner.isSetupPresented ? true : owner.captureNetwork, tools: owner.tools.compactMapValues { $0 }, toolOverrides: overrides,
            outputDirectory: owner.outputRoot)
    }

    private static func bounded(_ text: String) -> String { String(text.suffix(32_768)) }
}
