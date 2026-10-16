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
            case .choose: "Choose Capture"
            case .prepare: "Prepare Device"
            case .check: "Check Capture"
            case .record: "Record & Save"
            }
        }
    }

    var step = Step.choose
    var appSearch = ""
    private(set) var report: CaptureSetupReport?
    private(set) var isInspecting = false
    private(set) var isLaunchingCheck = false
    private(set) var checkCapture: CaptureStore?
    private(set) var checkStartedAt: Date?
    private(set) var checkDeadlineReached = false
    private(set) var pendingPlan: CapturePlan?
    private(set) var appliedPlan: CapturePlan?
    private(set) var notice: String?
    private(set) var error: String?
    private(set) var isTransferringCertificate = false
    private(set) var recordingSessionID: String?
    private(set) var browserHTTPSObserved = false
    private(set) var phoneOriginConfirmed = false
    private(set) var isExportingReport = false
    private(set) var isPreparingCertificate = false
    private(set) var isCertificatePreparation = false
    private(set) var certificateWasCopied = false
    private(set) var certificatePreparationDeviceID: String?
    @ObservationIgnored private var checkDeadline: Task<Void, Never>?
    @ObservationIgnored private var reportRevision = UUID()
    @ObservationIgnored private var checkIdentityFingerprint: String?
    @ObservationIgnored private var checkOwnerConfiguration: String?
    @ObservationIgnored private var reportConfiguration: String?
    @ObservationIgnored private var rememberedPlanDefaults: UserDefaults?
    private static let rememberedPlanKey = "capture.setup.appliedPlan.v1"

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

    func restoreRememberedPlan(_ owner: CaptureStore, defaults: UserDefaults) {
        rememberedPlanDefaults = defaults
        guard let data = defaults.data(forKey: Self.rememberedPlanKey) else { return }
        do {
            try reviewPlan(data: data)
            applyPendingPlan(owner)
            notice = "Your last capture task is ready. Reconnect its device; setup checks will run again."
            owner.isSetupPresented = true
        } catch {
            notice = "The saved capture task could not be read. Open a new plan or choose manual capture."
        }
    }

    func exportReadinessReport() async {
        guard let report, !isExportingReport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Mobile-Capture-Setup-Report.zip"
        panel.message = "Save a setup report for your engineer. It includes named readiness checks and the capture task, without recorded requests, logs, private keys or tunnel profiles."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingReport = true
        defer { isExportingReport = false }
        do {
            let url = try await CaptureReadinessExport.export(report: report, plan: appliedPlan, to: destination)
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
                await inspect(owner)
            } else if checkCapture?.hasActiveCapture == true {
                await inspect(owner)
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func inspect(_ owner: CaptureStore) async {
        guard !isInspecting else { return }
        let requestedConfiguration = configurationKey(owner)
        let revision = UUID()
        reportRevision = revision
        isInspecting = true
        defer { if reportRevision == revision { isInspecting = false } }
        let usesCheck = !isCertificatePreparation && checkCapture?.session != nil && checkOwnerConfiguration == requestedConfiguration
            && checkCapture?.setupContext?.plan == appliedPlan
        let subject = usesCheck ? checkCapture ?? owner : owner
        var request = CaptureSetupRequest(
            device: subject.selectedDevice, application: subject.selectedApplication,
            captureLogs: subject.captureLogs, captureNetwork: subject.captureNetwork,
            tools: subject.tools.compactMapValues { $0 }, outputDirectory: subject.outputRoot,
            networkServices: subject.networkServices, networkService: subject.networkService,
            logScope: CaptureLogScope(mode: subject.logScopeMode,
                applicationID: subject.targetApp.isEmpty ? nil : subject.targetApp,
                helperProcessNames: subject.logHelpers.split(separator: ",").map(String.init),
                executableOverride: subject.logExecutableOverride.isEmpty ? nil : subject.logExecutableOverride),
            loggingPolicy: loggingPolicy(subject), iphoneEndpointHost: subject.iphoneEndpointHost,
            planID: appliedPlan?.id, planVersion: appliedPlan?.version,
            discoveryCheckedAt: subject.discoveryCheckedAt)
        let inspector = CaptureSetupInspector()
        var result = await inspector.inspect(request)
        if usesCheck {
            if checkIdentityFingerprint == nil { checkIdentityFingerprint = result.identity.fingerprint }
            if let fingerprint = checkIdentityFingerprint,
               var observations = await subject.setupObservations(identityFingerprint: fingerprint) {
                browserHTTPSObserved = observations.httpsResponseNonce != nil
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
        guard reportRevision == revision else { return }
        guard configurationKey(owner) == requestedConfiguration else {
            report = nil; reportConfiguration = nil; browserHTTPSObserved = false
            return
        }
        report = result
        reportConfiguration = requestedConfiguration
    }

    func startCheck(_ owner: CaptureStore) async {
        guard owner.canStart, !hasLiveCheck else { return }
        error = nil; notice = nil
        isCertificatePreparation = false
        let check = owner.makeSetupCheck()
        check.setupContext = CaptureSessionSetupContext(purpose: .check, plan: appliedPlan,
            checks: portableChecks(owner), probeNonce: CaptureSessionSetupContext.freshProbeNonce())
        checkOwnerConfiguration = configurationKey(owner)
        checkIdentityFingerprint = nil; browserHTTPSObserved = false; phoneOriginConfirmed = false
        checkCapture = check
        isLaunchingCheck = true
        step = .check
        checkDeadlineReached = false
        await check.start()
        isLaunchingCheck = false
        guard check.session?.isActive == true || check.session?.needsRoutingRecovery == true else {
            error = check.error ?? "The check could not start. Review the device setup and try again."
            return
        }
        checkStartedAt = Date()
        await inspect(owner)
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
                : "Check saved separately. Review the observed sources below before recording the issue." }
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

    func startRecording(_ owner: CaptureStore) async {
        guard owner.canStart, !hasLiveCheck else { return }
        owner.setupContext = recordingContext(owner)
        await owner.start()
        if owner.session?.isActive == true { recordingSessionID = owner.session?.id }
    }

    func recordingContext(_ owner: CaptureStore) -> CaptureSessionSetupContext {
        CaptureSessionSetupContext(purpose: .recording, plan: appliedPlan, checks: portableChecks(owner))
    }

    func configurationIssue(_ owner: CaptureStore) -> String? {
        guard let plan = appliedPlan else { return nil }
        if owner.selectedDevice?.platform != plan.platform.rawValue {
            return "This capture plan requires a \(plan.platform.rawValue) device. Choose that device, or switch to manual capture."
        }
        if owner.targetApp != plan.applicationID {
            return "Choose \(plan.applicationID) for this capture plan, or switch to manual capture."
        }
        if owner.captureLogs, owner.logScopeMode != .app {
            return "This capture plan uses selected-app logs. Turn off whole-device logging, or switch to manual capture."
        }
        return nil
    }

    private func portableChecks(_ owner: CaptureStore) -> [CaptureSetupContextCheck] {
        guard reportConfiguration == configurationKey(owner) else { return [] }
        return (report?.checks ?? []).prefix(32).map {
            CaptureSetupContextCheck(id: $0.id, state: $0.state.rawValue, code: $0.code,
                basis: $0.basis.rawValue, checkedAt: $0.checkedAt.formatted(.iso8601),
                detail: String($0.message.prefix(300)))
        }
    }

    func importPlan() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Open an engineer-provided capture plan. Review its scope before applying it."
        panel.prompt = "Review Plan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= 65_536 else {
                throw AppError("Capture plans must be regular JSON files no larger than 64 KB.")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try reviewPlan(data: handle.read(upToCount: CapturePlan.maximumFileBytes + 1) ?? Data())
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func discardPendingPlan() { pendingPlan = nil }

    func reviewPlan(data: Data) throws { pendingPlan = try CapturePlan.decode(data) }

    func applyPendingPlan(_ owner: CaptureStore) {
        guard let plan = pendingPlan, !owner.hasActiveCapture, !owner.isBusy else { return }
        appliedPlan = plan; pendingPlan = nil
        owner.captureLogs = plan.captureLogs; owner.captureNetwork = plan.captureNetwork
        owner.targetApp = plan.applicationID; owner.logScopeMode = .app
        owner.logHelpers = plan.helperProcessNames.joined(separator: ",")
        owner.logExecutableOverride = plan.executableName ?? ""
        owner.logLimitMB = Int((plan.logLimits.maxBytes + 999_999) / 1_000_000)
        owner.logLimitRecords = Int(plan.logLimits.maxRecords)
        owner.logLimitMinutes = Int(ceil(plan.logLimits.maxDurationSeconds / 60))
        // Exact plan budgets are retained separately for the runtime request; visible fields explain them.
        owner.appliedSetupLoggingPolicy = plan.loggingPolicy
        if let rememberedPlanDefaults {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(plan) { rememberedPlanDefaults.set(data, forKey: Self.rememberedPlanKey) }
        }
        let platformName = plan.platform == .iphone ? "iPhone" : plan.platform.rawValue
        notice = "Capture plan applied. Connect its \(platformName) device and review the requested sources."
        step = .choose
    }

    /// A device change clears process identities in the base workspace. Restore the reviewed scope
    /// after an explicit matching device selection; its platform is still checked before Start.
    func restoreReviewedAppScope(_ owner: CaptureStore) {
        guard let plan = appliedPlan, !owner.hasActiveCapture else { return }
        owner.targetApp = plan.applicationID
        owner.logScopeMode = .app
        owner.logHelpers = plan.helperProcessNames.joined(separator: ",")
        owner.logExecutableOverride = plan.executableName ?? ""
    }

    func useManualCapture(_ owner: CaptureStore) {
        guard !owner.hasActiveCapture, !owner.isBusy else { return }
        appliedPlan = nil; owner.appliedSetupLoggingPolicy = nil; owner.setupContext = nil
        rememberedPlanDefaults?.removeObject(forKey: Self.rememberedPlanKey)
        notice = "Manual capture selected. Review the app and sources before checking."
    }

    func missingRequiredSources(_ owner: CaptureStore) -> [String] {
        guard let plan = appliedPlan else { return [] }
        let required = [("Device logs", plan.sources.logs), ("Decoded HTTPS Requests & Responses", plan.sources.network)]
            .compactMap { $0.1 == .required ? $0.0 : nil }
        guard !isCertificatePreparation, checkOwnerConfiguration == configurationKey(owner), checkCapture?.setupContext?.plan == plan,
              let session = checkCapture?.session else { return required }
        let scope = session.context?.value(for: "log_scope")
        let appLogs = scope?.value(for: "mode")?.stringValue == "app"
            && scope?.value(for: "application_id")?.stringValue == plan.applicationID
            && (checkCapture?.latestSnapshot?.parsedLogEvents ?? 0) > 0
        let https = (checkCapture?.latestSnapshot?.networkDiagnostics["complete_task_https_exchanges", default: 0] ?? 0) > 0
        return [("Device logs", plan.sources.logs, appLogs),
                ("Decoded HTTPS Requests & Responses", plan.sources.network, https)]
            .compactMap { title, requirement, observed in requirement == .required && !observed ? title : nil }
    }

    private func loggingPolicy(_ owner: CaptureStore) -> CaptureLoggingPolicy {
        if let exact = owner.appliedSetupLoggingPolicy { return exact }
        let bytes = Int64(owner.logLimitMB) * 1_000_000, records = Int64(owner.logLimitRecords)
        let seconds = Double(owner.logLimitMinutes * 60)
        return CaptureLoggingPolicy(max_bytes: bytes, max_records: records, max_duration_seconds: seconds,
            warning_bytes: max(1, bytes * 4 / 5), warning_records: max(1, records * 4 / 5),
            warning_duration_seconds: seconds * 0.8)
    }

    func configurationKey(_ owner: CaptureStore) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let plan = appliedPlan.flatMap { try? encoder.encode($0) }?.base64EncodedString() ?? ""
        let exactPolicy = owner.appliedSetupLoggingPolicy.flatMap { try? encoder.encode($0) }?.base64EncodedString() ?? ""
        return [owner.selectedDeviceID, owner.targetApp, String(owner.captureLogs), String(owner.captureNetwork),
         owner.logScopeMode.rawValue, owner.logHelpers, owner.logExecutableOverride, String(owner.logLimitMB),
         String(owner.logLimitRecords), String(owner.logLimitMinutes), owner.networkService,
         String(owner.trustSimulatorCA), owner.iphoneEndpointHost, owner.adbPath, owner.mitmdumpPath,
         owner.outputRoot.path, plan, exactPolicy]
            .joined(separator: "\u{1f}")
    }
}
