import AppKit
import Observation
import UniformTypeIdentifiers

/// UI state for the assistant. Inspection never starts a collector or changes device routing.
@MainActor
@Observable
final class CaptureSetupStore {
    enum Step: Int, CaseIterable {
        case choose, prepare, check, record
        var title: String {
            switch self {
            case .choose: "Connect"
            case .prepare: "Prepare Phone"
            case .check: "Check Connection"
            case .record: "Open Timeline"
            }
        }
    }

    var step = Step.choose
    private(set) var report: CaptureSetupReport?
    private(set) var isInspecting = false
    private(set) var isLaunchingCheck = false
    private(set) var checkCapture: CaptureStore?
    private(set) var checkStartedAt: Date?
    private(set) var checkDeadlineReached = false
    private(set) var notice: String?
    private(set) var error: String?
    private(set) var isTransferringCertificate = false
    private(set) var browserHTTPSObserved = false
    private(set) var phoneOriginConfirmed = false
    private(set) var isExportingReport = false
    private(set) var isPreparingCertificate = false
    private(set) var isCertificatePreparation = false
    private(set) var certificateWasCopied = false
    private(set) var certificatePreparationDeviceID: String?
    @ObservationIgnored private let inspector: CaptureSetupInspector
    @ObservationIgnored private var checkDeadline: Task<Void, Never>?
    @ObservationIgnored private var reportRevision = UUID()
    @ObservationIgnored private var checkIdentityFingerprint: String?
    @ObservationIgnored private var checkOwnerConfiguration: String?
    @ObservationIgnored private var reportConfiguration: String?
    @ObservationIgnored private var progressDefaults: UserDefaults?
    private(set) var deviceProgress: [CaptureDeviceSetupProgress] = []
    @ObservationIgnored private var firstRunOffered = false
    private static let progressKey = "capture.setup.devices.v1"
    private static let offeredKey = "capture.setup.offered.v1"

    init(inspector: CaptureSetupInspector = CaptureSetupInspector()) { self.inspector = inspector }

    var hasLiveCheck: Bool { isLaunchingCheck || isPreparingCertificate || checkCapture?.hasActiveCapture == true }
    var verificationCapture: CaptureStore? { isCertificatePreparation ? nil : checkCapture }
    var certificateReadyForInstallation: Bool {
        certificateWasCopied && isCertificatePreparation && !isPreparingCertificate && !isLaunchingCheck
            && checkCapture?.hasActiveCapture != true && checkCapture?.session?.routingRestored == true
    }

    func configurationDidChange(_ owner: CaptureStore) {
        if reportConfiguration != configurationKey(owner) { report = nil; browserHTTPSObserved = false }
        if isCertificatePreparation, certificatePreparationDeviceID != owner.selectedDeviceID, !hasLiveCheck {
            certificateWasCopied = false; certificatePreparationDeviceID = nil
            notice = nil; error = nil
        }
    }

    /// Migrate away from remembered tasks without changing a user's recording configuration.
    func loadProgress(defaults: UserDefaults) {
        progressDefaults = defaults
        defaults.removeObject(forKey: "capture.setup.appliedPlan.v1")
        firstRunOffered = defaults.bool(forKey: Self.offeredKey)
        if let data = defaults.data(forKey: Self.progressKey), data.count <= 131_072,
           let saved = try? JSONDecoder().decode([CaptureDeviceSetupProgress].self, from: data) {
            deviceProgress = Array(saved.filter(\.isValid).suffix(100))
        }
    }

    func offerFirstRunIfNeeded(_ owner: CaptureStore) {
        guard !firstRunOffered, !owner.hasActiveCapture, !owner.isBusy, owner.session == nil,
              !owner.isDoctorPresented else { return }
        firstRunOffered = true
        progressDefaults?.set(true, forKey: Self.offeredKey)
        owner.isSetupPresented = true
        step = .choose
        selectOnlyReadyDevice(owner)
    }

    func selectOnlyReadyDevice(_ owner: CaptureStore) {
        guard owner.selectedDeviceID.isEmpty, !owner.hasActiveCapture else { return }
        let ready = owner.devices.filter(\.isReady)
        if ready.count == 1 { owner.selectedDeviceID = ready[0].selectionID }
    }

    var isConnectionVerified: Bool {
        guard let report, report.identity.fingerprint == checkIdentityFingerprint,
              Date().timeIntervalSince(report.checkedAt) >= -5,
              Date().timeIntervalSince(report.checkedAt) <= 600 else { return false }
        return ["https", "device_routing"].allSatisfy { id in
            report.checks.contains { $0.id == id && $0.state == .verified }
        }
    }

    func canCheckConnection(_ owner: CaptureStore) -> Bool {
        if !isLaunchingCheck, !isPreparingCertificate, !isCertificatePreparation,
           let check = checkCapture, check.session?.platform == "iphone", check.hasActiveCapture,
           checkOwnerConfiguration == configurationKey(owner) { return true }
        return !owner.hasOwnActiveCapture && !owner.isBusy && !owner.doctor.isRepairing
            && !hasLiveCheck && owner.selectedDevice?.isReady == true
            && (owner.selectedDevice?.platform != "simulator" || !owner.networkService.isEmpty)
            && (owner.selectedDevice?.platform != "iphone" || owner.iphoneTunnelConfiguration != nil)
    }

    @discardableResult
    func completeSetup(_ owner: CaptureStore) async -> Bool {
        guard !hasLiveCheck, !isCertificatePreparation, let check = checkCapture,
              check.session?.routingRestored == true,
              checkOwnerConfiguration == configurationKey(owner) else { return false }
        await owner.refreshDevices(includeApplications: false)
        await inspect(owner)
        guard !Task.isCancelled, !hasLiveCheck, reportConfiguration == configurationKey(owner), isConnectionVerified,
              let report, report.prerequisitesReady,
              let progress = CaptureDeviceSetupProgress.completed(report: report) else {
            notice = "The connection check is incomplete or the phone setup changed. Run Check Connection again."
            return false
        }
        saveProgress(progress)
        firstRunOffered = true; progressDefaults?.set(true, forKey: Self.offeredKey)
        step = .record
        notice = "Device setup complete. The browser connection was checked; app-specific trust may still need engineer support."
        return true
    }

    func deferSetup(_ owner: CaptureStore) {
        guard !hasLiveCheck else { noteWindowCloseRequested(); return }
        if let device = owner.selectedDevice {
            let completed = deviceProgress.last { $0.platform == device.platform && $0.deviceID == device.id && $0.status == .completed }
            // Merely returning from setup must not erase completed history for an unchanged phone.
            if completed == nil || report.map({ completed?.matches($0.identity) != true }) == true {
                saveProgress(.deferred(platform: device.platform, deviceID: device.id, identity: report?.identity))
            }
        }
        firstRunOffered = true; progressDefaults?.set(true, forKey: Self.offeredKey)
        owner.isSetupPresented = false
        notice = "HTTPS setup is unfinished. You can inspect saved evidence or record logs, then finish device setup when needed."
    }

    func setupPrompt(_ owner: CaptureStore) -> String? {
        guard owner.captureNetwork, let device = owner.selectedDevice, !owner.isSetupPresented,
              !owner.hasActiveCapture else { return nil }
        guard let report, reportConfiguration == configurationKey(owner) else {
            return "Check this phone's setup before capturing HTTPS."
        }
        let matching = deviceProgress.last { $0.platform == device.platform && $0.deviceID == device.id }
        if matching?.matches(report.identity) == true, matching?.status == .completed { return nil }
        if matching?.status == .deferred { return "HTTPS setup is unfinished for this phone." }
        return matching == nil ? "Set up this phone to capture HTTPS requests." : "The capture certificate or phone connection changed. Check its setup again."
    }

    private func saveProgress(_ progress: CaptureDeviceSetupProgress) {
        deviceProgress.removeAll { $0.platform == progress.platform && $0.deviceID == progress.deviceID }
        deviceProgress.append(progress)
        deviceProgress = Array(deviceProgress.suffix(100))
        if let data = try? JSONEncoder().encode(deviceProgress) { progressDefaults?.set(data, forKey: Self.progressKey) }
    }

    func exportReadinessReport() async {
        guard let report, !isExportingReport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Mobile-Capture-Setup-Report.zip"
        panel.message = "Save a setup report for your engineer. It includes named readiness checks without recorded requests, logs, private keys or tunnel profiles."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingReport = true
        defer { isExportingReport = false }
        do {
            let url = try await CaptureReadinessExport.export(report: report, to: destination)
            notice = "Setup report saved. Send this ZIP to your engineer to investigate the missing prerequisites."
            NSWorkspace.shared.activateFileViewerSelecting([url])
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func monitor(_ owner: CaptureStore) async {
        while !Task.isCancelled, owner.isSetupPresented {
            if !owner.hasActiveCapture && !owner.isBusy {
                await owner.refreshDevices(includeApplications: false)
                guard !Task.isCancelled, owner.isSetupPresented else { return }
                selectOnlyReadyDevice(owner)
                await inspect(owner)
            } else if checkCapture?.hasActiveCapture == true {
                await inspect(owner)
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func inspect(_ owner: CaptureStore) async {
        // A newer configuration must wait for the bounded read, rather than be dropped while
        // SwiftUI cancels an older .task(id:) inspection during a quick device switch.
        while isInspecting {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        let requestedConfiguration = configurationKey(owner)
        let revision = UUID()
        reportRevision = revision
        isInspecting = true
        defer { if reportRevision == revision { isInspecting = false } }
        let usesCheck = !isCertificatePreparation && checkCapture?.session != nil && checkOwnerConfiguration == requestedConfiguration
        let subject = usesCheck ? checkCapture ?? owner : owner
        var request = CaptureSetupRequest(
            device: owner.selectedDevice, captureLogs: false, captureNetwork: true,
            tools: subject.tools.compactMapValues { $0 }, outputDirectory: subject.outputRoot,
            networkServices: subject.networkServices, networkService: subject.networkService,
            logScope: CaptureLogScope(), loggingPolicy: CaptureLoggingPolicy(),
            iphoneEndpointHost: owner.selectedDevice?.platform == "iphone" ? subject.iphoneEndpointHost : nil,
            discoveryCheckedAt: owner.discoveryCheckedAt)
        var result = await inspector.inspect(request)
        if usesCheck {
            if checkIdentityFingerprint == nil { checkIdentityFingerprint = result.identity.fingerprint }
            if let fingerprint = checkIdentityFingerprint,
               var observations = await subject.setupObservations(identityFingerprint: fingerprint) {
                browserHTTPSObserved = observations.httpsResponseNonce != nil && result.identity.fingerprint == fingerprint
                observations.deviceOriginConfirmedByUser = phoneOriginConfirmed && browserHTTPSObserved
                if observations.deviceOriginConfirmedByUser { observations.deviceRoutingNonce = observations.httpsResponseNonce }
                request.observations = observations
                request.expectedCheckSessionID = subject.session?.id
                request.expectedCheckNonce = subject.setupContext?.probeNonce
                result = await inspector.inspect(request)
            }
        } else {
            browserHTTPSObserved = false
            if !isCertificatePreparation, checkCapture?.session != nil { notice = "The capture configuration changed. Run a new check for these choices." }
        }
        guard !Task.isCancelled, reportRevision == revision else { return }
        guard configurationKey(owner) == requestedConfiguration else {
            report = nil; reportConfiguration = nil; browserHTTPSObserved = false
            return
        }
        report = result
        reportConfiguration = requestedConfiguration
    }

    func startCheck(_ owner: CaptureStore) async {
        guard !owner.hasOwnActiveCapture, !owner.isBusy, !owner.doctor.isRepairing,
              !isLaunchingCheck, !isPreparingCertificate else { return }
        await owner.refreshDevices(includeApplications: false, allowSetupCheck: true)
        guard owner.selectedDevice?.isReady == true else {
            error = "Reconnect and unlock the selected phone, then check again. Any active capture connection still needs Stop and restoration."
            return
        }
        if let check = checkCapture, check.hasActiveCapture, check.session?.platform == "iphone",
           checkOwnerConfiguration == configurationKey(owner), !isCertificatePreparation {
            step = .check
            guard let began = checkStartedAt, Date().timeIntervalSince(began) < 480 else {
                notice = "This setup connection is too old for a fresh verification. Turn off Mobile Capture in WireGuard, choose Stop Check & Save, then start a new connection check. Forwarding stays available until you confirm the tunnel is off."
                return
            }
            armCheckDeadline(check); await inspect(owner); return
        }
        guard canCheckConnection(owner) else {
            if hasLiveCheck { notice = "The phone configuration changed. Turn off its capture tunnel if enabled, then stop and restore the current connection before checking again." }
            return
        }
        await launchNetworkCheck(owner, timed: true)
    }

    func startIPhonePreparation(_ owner: CaptureStore) async {
        guard owner.selectedDevice?.platform == "iphone", canCheckConnection(owner) else { return }
        await launchNetworkCheck(owner, timed: false)
    }

    private func launchNetworkCheck(_ owner: CaptureStore, timed: Bool) async {
        error = nil; notice = nil
        isCertificatePreparation = false
        let check = owner.makeSetupCheck()
        check.setupContext = CaptureSessionSetupContext(purpose: .check,
            checks: portableChecks(owner), probeNonce: CaptureSessionSetupContext.freshProbeNonce())
        checkOwnerConfiguration = configurationKey(owner)
        checkIdentityFingerprint = nil; browserHTTPSObserved = false; phoneOriginConfirmed = false
        checkCapture = check
        isLaunchingCheck = true
        step = timed ? .check : .prepare
        checkDeadlineReached = false
        await check.start()
        isLaunchingCheck = false
        guard check.session?.isActive == true || check.session?.needsRoutingRecovery == true else {
            error = check.error ?? "The check could not start. Review the device setup and try again."
            return
        }
        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        checkStartedAt = check.session.flatMap { dateParser.date(from: $0.startedAt) ?? ISO8601DateFormatter().date(from: $0.startedAt) } ?? Date()
        await inspect(owner)
        if timed { armCheckDeadline(check) }
    }

    private func armCheckDeadline(_ check: CaptureStore) {
        checkDeadlineReached = false
        checkDeadline?.cancel()
        checkDeadline = Task { [weak self, weak check] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, let check, check.hasActiveCapture else { return }
            self.checkDeadlineReached = true
            if check.session?.platform == "iphone", check.captureNetwork {
                self.notice = "The check time is complete. Turn off Mobile Capture in WireGuard on iPhone, then choose Stop Check & Save. The Mac keeps forwarding until you confirm."
            } else {
                await self.stopCheck()
            }
        }
    }

    func stopCheck() async {
        guard let checkCapture, !isLaunchingCheck else { return }
        await checkCapture.stop()
        if !checkCapture.hasActiveCapture {
            checkDeadline?.cancel(); checkDeadline = nil
            if isCertificatePreparation {
                if certificateReadyForInstallation { error = nil }
                notice = certificateReadyForInstallation
                    ? "The capture connection is restored. Install the copied certificate on Android at your own pace, then start the capture check."
                    : "The capture connection is restored. Retry Prepare & Copy Certificate if the certificate was not copied."
            } else { notice = checkCapture.session?.packagePath == nil
                ? "Check stopped. The original evidence is retained; use Retry Save if the ZIP is unavailable."
                : "Check saved and the capture connection restored. Open the timeline when the connection is verified." }
        }
    }

    /// Certificate preparation has no phone-side deadline. It briefly uses the existing host to
    /// create/read its stable public CA, copies it, then restores routing before installation help.
    func prepareAndroidCertificate(_ owner: CaptureStore) async {
        guard !owner.hasActiveCapture, !owner.isBusy, owner.selectedDevice?.platform == "android",
              owner.selectedDevice?.isReady == true else { return }
        error = nil; notice = nil
        isPreparingCertificate = true
        isCertificatePreparation = true
        certificateWasCopied = false
        certificatePreparationDeviceID = owner.selectedDeviceID
        defer { isPreparingCertificate = false }
        checkDeadline?.cancel(); checkDeadline = nil
        checkStartedAt = nil; checkDeadlineReached = false
        checkOwnerConfiguration = nil; checkIdentityFingerprint = nil
        browserHTTPSObserved = false; phoneOriginConfirmed = false
        let preparation = owner.makeSetupCheck()
        preparation.captureLogs = false
        preparation.captureNetwork = true
        preparation.setupContext = CaptureSessionSetupContext(purpose: .check,
            probeNonce: CaptureSessionSetupContext.freshProbeNonce())
        checkCapture = preparation
        isLaunchingCheck = true
        await preparation.start()
        isLaunchingCheck = false
        guard preparation.session?.isActive == true || preparation.session?.needsRoutingRecovery == true else {
            error = preparation.error ?? "Certificate preparation could not start. Check the device connection and Mac tools."
            return
        }
        do {
            preparation.markerText = "Certificate preparation only. No reproduction or app-log verification was requested."
            await preparation.addMarker()
            try await preparation.transferSetupCertificate()
            certificateWasCopied = true
        } catch { self.error = error.localizedDescription }
        await preparation.stop()
        if preparation.hasActiveCapture {
            error = "The preparation connection still needs recovery. Choose Restore Connection before installing the certificate or starting a check."
            notice = nil
            return
        }
        if certificateWasCopied, preparation.session?.routingRestored == true {
            notice = "Certificate copied; the capture connection has been restored. In Android Settings, search Install a certificate → CA certificate, choose the newest mobile-capture-ca file in Downloads and complete the phone confirmation. Take your time; no capture is running. Then continue to the capture check."
        } else {
            notice = "The capture connection has been restored. The public certificate was not copied; retry preparation after resolving the error."
        }
    }

    func dismiss(_ owner: CaptureStore) {
        guard !hasLiveCheck else {
            notice = isCertificatePreparation
                ? "Finish restoring the certificate preparation connection before leaving setup."
                : "Finish the capture check before leaving setup. On iPhone, turn the capture tunnel off before Stop Check & Save."
            return
        }
        firstRunOffered = true
        progressDefaults?.set(true, forKey: Self.offeredKey)
        owner.isSetupPresented = false
    }

    func noteWindowCloseRequested() {
        notice = isCertificatePreparation
            ? "Finish restoring the certificate preparation connection before closing this window."
            : "Finish the active capture check before closing this window. Your existing session is still available in the timeline."
    }

    func confirmPhoneOrigin(_ owner: CaptureStore) async {
        guard checkCapture?.session != nil, browserHTTPSObserved else { return }
        phoneOriginConfirmed = true
        await inspect(owner)
    }

    func transferCertificate() async {
        guard let checkCapture, !isTransferringCertificate else { return }
        isTransferringCertificate = true
        defer { isTransferringCertificate = false }
        do {
            try await checkCapture.transferSetupCertificate()
            notice = "Public certificate copied to Android Downloads. In Settings, search Install a certificate, choose CA certificate, then choose the newest mobile-capture-ca file. Complete the phone confirmation and run Verify HTTPS. If this short check has finished, start a new check after installation."
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func recordingContext(_ owner: CaptureStore) -> CaptureSessionSetupContext {
        CaptureSessionSetupContext(purpose: .recording, checks: portableChecks(owner))
    }

    private func portableChecks(_ owner: CaptureStore) -> [CaptureSetupContextCheck] {
        guard reportConfiguration == configurationKey(owner) else { return [] }
        return (report?.checks ?? []).prefix(32).map {
            CaptureSetupContextCheck(id: $0.id, state: $0.state.rawValue, code: $0.code,
                basis: $0.basis.rawValue, checkedAt: $0.checkedAt.formatted(.iso8601),
                detail: String($0.message.prefix(300)))
        }
    }

    /// Only device/network choices affect first-run setup; everyday app/log options are independent.
    func configurationKey(_ owner: CaptureStore) -> String {
        [owner.selectedDeviceID,
         owner.selectedDevice?.platform == "simulator" ? owner.networkService : "",
         owner.selectedDevice?.platform == "simulator" ? String(owner.trustSimulatorCA) : "",
         owner.selectedDevice?.platform == "iphone" ? owner.iphoneEndpointHost : "",
         owner.adbPath, owner.mitmdumpPath, owner.outputRoot.path,
         owner.tools.keys.sorted().map { "\($0)=\(owner.toolPath($0) ?? "")" }.joined(separator: "\n")]
            .joined(separator: "\u{1f}")
    }
}
