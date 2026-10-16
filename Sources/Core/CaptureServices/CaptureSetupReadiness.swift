import CryptoKit
import Foundation

nonisolated enum CaptureSetupState: String, Codable, Sendable {
    case checking, actionNeeded, readyToTry, verified, unavailable, needsEngineerHelp
    case waitingForAppActivity, unverified, notRequested
}

nonisolated enum CaptureSetupBasis: String, Codable, Sendable {
    case localInspection, deviceDiscovery, installedApplicationMetadata
    case observedDeviceTraffic, observedHTTPSExchange, observedApplicationLog, userReported, unknown
}

nonisolated enum CaptureSetupAction: String, Codable, Sendable, CaseIterable {
    case refresh, connectDevice, unlockDevice, authorizeUSB, chooseApp, chooseOutputFolder
    case prepareDevice, installCertificate, trustCertificate, setUpIPhoneTunnel
    case turnOnIPhoneTunnel, turnOffIPhoneTunnel, runCheck, openSelectedApp, askEngineer
    case restoreConnection, chooseNetworkService, chooseEndpoint, installDeveloperTools
}

nonisolated struct CaptureSetupCheck: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let state: CaptureSetupState
    let title: String
    let message: String
    let code: String
    let basis: CaptureSetupBasis
    let checkedAt: Date
    let actions: [CaptureSetupAction]
    var isPrerequisite = true
}

/// Public identities only. No certificate/private-profile contents, local paths or control secrets.
nonisolated struct CaptureSetupIdentity: Codable, Sendable, Equatable {
    let platform: String?
    let deviceID: String?
    let applicationID: String?
    let appBuild: String?
    let osVersion: String?
    let engineVersion: String?
    let caFingerprint: String?
    let profileFingerprint: String?
    let endpoint: String?
    let planID: String?
    let planVersion: Int?
    let fingerprint: String
}

nonisolated struct CaptureSetupReport: Codable, Sendable, Equatable {
    let identity: CaptureSetupIdentity
    let checkedAt: Date
    let checks: [CaptureSetupCheck]

    /// Prerequisites permit an attempt; they do not establish certificate trust or captured evidence.
    var prerequisitesReady: Bool {
        let prerequisites = checks.filter(\.isPrerequisite)
        return !prerequisites.isEmpty && prerequisites.allSatisfy { [.readyToTry, .verified, .notRequested].contains($0.state) }
    }
    var hasVerifiedEvidence: Bool { checks.contains { !$0.isPrerequisite && $0.state == .verified } }
}

/// Constructed only from fresh evidence in the owned check session. Counts alone cannot prove TLS.
nonisolated struct CaptureSetupObservations: Codable, Sendable, Equatable {
    let identityFingerprint: String
    let sessionID: String
    let sessionStartedAt: Date
    let observedAt: Date
    var deviceRoutingNonce: String? = nil
    var httpsResponseNonce: String? = nil
    var selectedAppLogRecords = 0
    var logScopeVerified = false
    var certificateRejections = 0
    var collectorStarted = false
    var deviceOriginConfirmedByUser = false
    var deviceTransportVerified = false
}

nonisolated struct CaptureSetupRequest: Sendable {
    let device: CaptureDevice?
    var application: CaptureLogApplication? = nil
    var captureLogs = false
    var captureNetwork = true
    var tools: [String: String] = [:]
    var outputDirectory = CaptureSessionRegistry.defaultRoot
    var networkServices: [String] = []
    var networkService: String? = nil
    var logScope = CaptureLogScope()
    var loggingPolicy = CaptureLoggingPolicy()
    var iphoneEndpointHost: String? = nil
    var planID: String? = nil
    var planVersion: Int? = nil
    var appBuild: String? = nil
    var osVersion: String? = nil
    var engineVersion: String? = nil
    var discoveryCheckedAt: Date? = nil
    var observations: CaptureSetupObservations? = nil
    var expectedCheckSessionID: String? = nil
    var expectedCheckNonce: String? = nil
}

/// Pure inspection plus bounded local reads. It never discovers a device, starts a collector,
/// prepares a profile/certificate, takes a routing lease, or changes proxy/trust settings.
nonisolated struct CaptureSetupInspector: Sendable {
    var applicationBundle: URL? = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil
    var caDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Capture Companion/mitmproxy", isDirectory: true)
    var iphoneProfileRoot: URL = IPhoneCaptureSetup.defaultRootDirectory
    var routingLockDirectory: URL = CaptureSetupLocalInspection.defaultRoutingDirectory
    var now: @Sendable () -> Date = { Date() }
    var availableDiskBytes: (@Sendable (URL) -> Int64?)? = nil

    @concurrent func inspect(_ request: CaptureSetupRequest) async -> CaptureSetupReport {
        let checkedAt = now()
        let local = CaptureSetupLocalInspection(applicationBundle: applicationBundle, caDirectory: caDirectory,
            iphoneProfileRoot: iphoneProfileRoot, routingLockDirectory: routingLockDirectory, availableDiskBytes: availableDiskBytes)
        let certificate = local.publicCertificate()
        let profile = local.iphoneProfile(deviceID: request.device?.id)
        let engineVersion = request.engineVersion ?? local.engineVersion()
        let identity = identity(request, certificate: certificate.fingerprint, profile: profile.fingerprint, engineVersion: engineVersion)
        var checks: [CaptureSetupCheck] = []
        func check(_ id: String, _ state: CaptureSetupState, _ title: String, _ message: String,
                   _ code: String, _ basis: CaptureSetupBasis = .localInspection,
                   _ actions: [CaptureSetupAction] = [], prerequisite: Bool = true) {
            checks.append(CaptureSetupCheck(id: id, state: state, title: title, message: message, code: code,
                basis: basis, checkedAt: checkedAt, actions: actions, isPrerequisite: prerequisite))
        }
        if !request.captureLogs && !request.captureNetwork {
            check("sources", .actionNeeded, "Choose Capture Sources", "Choose logs, network, or both for this task.", "no_sources", .unknown)
        }
        let required = requiredTools(request)
        let missing = required.filter { name in
            guard let path = request.tools[name], path.hasPrefix("/") else { return true }
            return !FileManager.default.isExecutableFile(atPath: path)
        }
        if !missing.isEmpty {
            let iphone = request.device?.platform == "iphone"
            check("host_tools", iphone ? .needsEngineerHelp : .unavailable, "Mac Capture Tools",
                iphone ? "This iPhone route is engineer-assisted until its USB tools are packaged and tested on a clean Mac. Missing: \(missing.joined(separator: ", "))."
                    : "Required capture tools are missing: \(missing.joined(separator: ", ")). Use a complete Mobile Capture build.",
                "missing_tools", .localInspection, [.askEngineer])
        } else {
            check("host_tools", .readyToTry, "Mac Capture Tools", "Required executable files are present. The capture check still needs to verify device access and emitted evidence.", "tools_present")
        }
        if request.device?.platform == "iphone", request.tools["devicectl"] == nil,
           request.tools["idevice_id"] == nil || request.tools["ideviceinfo"] == nil {
            check("iphone_discovery", .needsEngineerHelp, "iPhone Discovery Tools",
                "This build needs full Xcode discovery or the candidate USB discovery tools. A clean-Mac iPhone path has not been validated.",
                "iphone_discovery_missing", .localInspection, [.askEngineer])
        }
        if request.device?.platform == "iphone" {
            let usbNames = request.captureLogs ? ["idevice_id", "ideviceinfo", "ideviceinstaller", "idevicesyslog"] : ["idevice_id", "ideviceinfo"]
            let bundled = applicationBundle.map { bundle in
                usbNames.allSatisfy { request.tools[$0]?.hasPrefix(bundle.path + "/Contents/") == true }
            } ?? false
            check("iphone_host_distribution", .readyToTry, bundled ? "Bundled iPhone Tools Candidate" : "Engineer-Assisted iPhone Tools",
                bundled ? "The candidate USB tools are inside this app. Clean-Mac pairing, supported iOS versions and notarization still require acceptance testing."
                    : "This Mac uses externally installed USB tools or Xcode discovery. An engineer must prepare those dependencies; this is not a verified no-developer-tools installation.",
                bundled ? "bundled_usb_candidate_unproven" : "external_iphone_dependencies", .localInspection, [.askEngineer], prerequisite: false)
        }
        let storage = local.storage(directory: request.outputDirectory, minimumBytes: request.captureLogs
            ? max(0, min(200_000_000, request.loggingPolicy.max_bytes)) * 4 + 64_000_000 : 256_000_000)
        check("storage", storage.state, "Local Evidence Storage", storage.message, storage.code, .localInspection,
              storage.state == .readyToTry ? [] : [.chooseOutputFolder])
        let owner = local.routingOwner()
        check("routing_owner", owner.state, "Capture Connection Ownership", owner.message, owner.code, .localInspection,
              owner.state == .readyToTry ? [] : [.restoreConnection])
        if let device = request.device {
            let fresh = request.discoveryCheckedAt.map { checkedAt.timeIntervalSince($0) >= -5 && checkedAt.timeIntervalSince($0) <= 120 } ?? false
            if !device.isReady {
                let unauthorized = device.state.lowercased().contains("unauthor") || device.state.lowercased().contains("trust")
                check("device", .actionNeeded, "Connect Your Device", unauthorized ? "Unlock the selected device and approve this Mac's USB/debugging trust request." : "Reconnect or start the selected device, then check again.",
                      unauthorized ? "device_needs_trust" : "device_unavailable", .deviceDiscovery,
                      unauthorized ? [.unlockDevice, .authorizeUSB, .refresh] : [.connectDevice, .refresh])
            } else if !fresh {
                check("device", .unverified, "Refresh Device Connection", "The device selection has no fresh discovery observation. Check its connection again.",
                      "device_discovery_stale", .unknown, [.refresh])
            } else {
                check("device", .readyToTry, "Device Detected", device.platform == "iphone"
                    ? "The selected iPhone was detected. Keep it unlocked and connected by USB for logs; the capture check verifies collector access."
                    : "The selected device was detected. Its capture sources still need an evidence check.", "device_detected", .deviceDiscovery)
            }
        } else {
            check("device", .actionNeeded, "Connect Your Device", "Connect and select the device you want to capture.", "device_not_selected", .unknown, [.connectDevice, .refresh])
        }
        if request.captureLogs {
            do { _ = try request.loggingPolicy.validated(); check("log_limits", .readyToTry, "Bounded Device Logs", "Logs stop at the first configured byte, record or time limit. Network can continue independently.", "log_limits_valid") }
            catch { check("log_limits", .actionNeeded, "Choose Log Limits", error.localizedDescription, "invalid_log_limits", .localInspection, [.askEngineer]) }
            if request.logScope.mode == .wholeDevice {
                check("application_scope", .readyToTry, "Whole-Device Log Scope", "Whole-device logging was explicitly requested. It can include unrelated apps and does not prove selected-app ownership.", "whole_device_scope", .unknown)
            } else if let app = request.application, app.platform == request.device?.platform,
                      app.id == request.logScope.applicationID, CaptureLogDiscovery.validApplicationID(app.id) {
                do {
                    _ = try request.logScope.helperProcessNames.map(CaptureLogDiscovery.executableName)
                    _ = try request.logScope.executableOverride.map(CaptureLogDiscovery.executableName)
                    if request.device?.platform == "iphone", request.logScope.executableOverride == nil,
                       app.executable == nil || app.executableIsAmbiguous {
                        check("application_scope", .needsEngineerHelp, "Verify the App's Log Identity", "Installed metadata does not provide one unambiguous executable. Ask an engineer for the exact executable/helper configuration.", "app_executable_unverified", .installedApplicationMetadata, [.askEngineer])
                    } else {
                        check("application_scope", .readyToTry, "Selected App", "Installed app metadata matches the requested scope. The capture host revalidates its UID/process identity before collecting logs.", "installed_app_selected", .installedApplicationMetadata)
                    }
                } catch { check("application_scope", .needsEngineerHelp, "Verify the App's Log Identity", error.localizedDescription, "invalid_process_identity", .installedApplicationMetadata, [.askEngineer]) }
            } else {
                check("application_scope", .actionNeeded, "Choose Your App", "Choose an installed app for logs. A manual or previously selected identifier is not installation proof.", "app_not_verified_installed", .unknown, [.chooseApp])
            }
        }
        if request.captureNetwork {
            check("certificate", certificate.state, "Current Capture Certificate", certificate.message, certificate.code, .localInspection,
                  certificate.fingerprint == nil ? [.prepareDevice] : [])
            if request.device?.platform == "simulator" {
                if let service = request.networkService, request.networkServices.contains(service) {
                    check("network_service", .readyToTry, "Mac Network Service", "The selected Mac service is available. Its exact proxy settings will be restored by the capture host.", "network_service_selected")
                } else {
                    check("network_service", .actionNeeded, "Choose the Mac Network Service", "Choose the service used by the Simulator before preparing a capture check.", "network_service_missing", .unknown, [.chooseNetworkService])
                }
            }
            if request.device?.platform == "iphone" {
                if profile.state != .readyToTry {
                    check("iphone_profile", profile.state, "Saved iPhone Capture Tunnel", profile.message, profile.code, .localInspection,
                          profile.state == .needsEngineerHelp ? [.askEngineer] : [.setUpIPhoneTunnel, .chooseEndpoint])
                } else if let host = request.iphoneEndpointHost, (try? IPhoneCaptureSetup.validatedEndpointHost(host)) != nil,
                   profile.endpoint == host {
                    check("iphone_profile", profile.state, "Saved iPhone Capture Tunnel", profile.message, profile.code, .localInspection,
                          profile.state == .readyToTry ? [.setUpIPhoneTunnel] : [.setUpIPhoneTunnel, .chooseEndpoint])
                } else {
                    check("iphone_profile", .actionNeeded, "Prepare the iPhone Capture Tunnel", "Prepare or update this phone's saved profile for the selected Mac address. A saved profile alone does not prove it is imported or active on the phone.", "iphone_profile_missing_or_endpoint_changed", .localInspection, [.setUpIPhoneTunnel, .chooseEndpoint])
                }
            }
        }
        appendEvidenceChecks(request, identity: identity, checkedAt: checkedAt, checks: &checks)
        return CaptureSetupReport(identity: identity, checkedAt: checkedAt, checks: checks)
    }

    private func requiredTools(_ request: CaptureSetupRequest) -> [String] {
        var tools: [String] = []
        if request.device?.platform == "android" { tools.append("adb") }
        if request.device?.platform == "simulator" { tools.append("simctl") }
        if request.captureNetwork { tools.append("mitmdump") }
        if request.captureLogs, request.device?.platform == "iphone" { tools.append("idevicesyslog") }
        return tools
    }

    private func identity(_ request: CaptureSetupRequest, certificate: String?, profile: String?, engineVersion: String?) -> CaptureSetupIdentity {
        struct Configuration: Encodable {
            let platform: String?; let deviceID: String?; let applicationID: String?; let appBuild: String?; let osVersion: String?
            let engineVersion: String?; let certificate: String?; let profile: String?; let endpoint: String?; let networkService: String?
            let planID: String?; let planVersion: Int?; let logs: Bool; let network: Bool
            let scope: CaptureLogScope; let policy: CaptureLoggingPolicy; let tools: [String: String]; let outputLocation: String
        }
        let app = request.application?.id ?? request.logScope.applicationID
        let configuration = Configuration(platform: request.device?.platform, deviceID: request.device?.id, applicationID: app,
            appBuild: request.appBuild, osVersion: request.osVersion, engineVersion: engineVersion, certificate: certificate,
            profile: profile, endpoint: request.iphoneEndpointHost, networkService: request.networkService,
            planID: request.planID, planVersion: request.planVersion, logs: request.captureLogs, network: request.captureNetwork,
            scope: request.logScope, policy: request.loggingPolicy, tools: request.tools,
            outputLocation: request.outputDirectory.standardizedFileURL.resolvingSymlinksInPath().path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = (try? encoder.encode(configuration)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "invalid_configuration"
        return CaptureSetupIdentity(platform: request.device?.platform, deviceID: request.device?.id, applicationID: app,
            appBuild: request.appBuild, osVersion: request.osVersion, engineVersion: engineVersion,
            caFingerprint: certificate, profileFingerprint: profile, endpoint: request.iphoneEndpointHost,
            planID: request.planID, planVersion: request.planVersion, fingerprint: digest)
    }

    private func appendEvidenceChecks(_ request: CaptureSetupRequest, identity: CaptureSetupIdentity, checkedAt: Date, checks: inout [CaptureSetupCheck]) {
        let observed = request.observations
        let fresh = observed.map { value in
            value.identityFingerprint == identity.fingerprint && identity.fingerprint != "invalid_configuration"
                && !value.sessionID.isEmpty && value.sessionID == request.expectedCheckSessionID
                && value.observedAt >= value.sessionStartedAt
                && checkedAt.timeIntervalSince(value.observedAt) >= -5 && checkedAt.timeIntervalSince(value.observedAt) <= 600
                && checkedAt.timeIntervalSince(value.sessionStartedAt) >= -5 && checkedAt.timeIntervalSince(value.sessionStartedAt) <= 600
        } ?? false
        let nonce = request.expectedCheckNonce
        let validNonce = nonce.map { $0.utf8.count == 32 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } ?? false
        func append(_ id: String, _ state: CaptureSetupState, _ title: String, _ message: String, _ code: String,
                    _ basis: CaptureSetupBasis, _ actions: [CaptureSetupAction]) {
            checks.append(CaptureSetupCheck(id: id, state: state, title: title, message: message, code: code,
                basis: basis, checkedAt: fresh ? observed?.observedAt ?? checkedAt : checkedAt, actions: actions, isPrerequisite: false))
        }
        if request.captureNetwork {
            let https = fresh && validNonce && observed?.httpsResponseNonce == nonce && identity.caFingerprint != nil
            let transport = observed?.deviceTransportVerified == true
            let userConfirmed = observed?.deviceOriginConfirmedByUser == true && https
            let routing = fresh && validNonce && observed?.deviceRoutingNonce == nonce && (transport || userConfirmed)
            append("device_routing", routing ? .verified : .unverified, "Device Traffic Reaches This Mac",
                routing ? (transport
                    ? "An independently verified device transport delivered this fresh check token. This does not establish selected-app attribution."
                    : "You confirmed opening this exact check on the phone, and its fresh HTTPS response was observed. Device origin was user-confirmed, not independently verified from transport metadata.")
                    : "No fresh device-origin check has been confirmed. Same Wi-Fi, a saved profile, loopback proxy address or a running proxy is insufficient.",
                routing ? (transport ? "device_transport_nonce_observed" : "device_action_user_confirmed") : "device_route_unverified",
                routing ? (transport ? .observedDeviceTraffic : .userReported) : .unknown,
                routing ? [] : [.runCheck])
            if !https, fresh, observed?.certificateRejections ?? 0 > 0 {
                append("https", .actionNeeded, "Check HTTPS Trust", "A client rejected this capture certificate. Install/fully trust the current public certificate; if the selected app still rejects it, ask its engineer about debug trust or pinning.", "certificate_rejected", .observedDeviceTraffic, [.installCertificate, .trustCertificate, .askEngineer])
            } else {
                append("https", https ? .verified : .unverified, "Basic Browser HTTPS",
                    https ? "The fresh synthetic HTTPS response token was decoded through the current capture CA. This verifies that browser/client only, not upstream internet or every app/SDK."
                        : "HTTPS trust has not been demonstrated by a fresh synthetic response. Installing a profile or acknowledging instructions is not proof.",
                    https ? "browser_https_nonce_verified" : "https_unverified", https ? .observedHTTPSExchange : .unknown,
                    https ? [] : [.runCheck, .trustCertificate])
            }
            if https, let rejected = observed?.certificateRejections, rejected > 0 {
                append("other_certificate_rejections", .actionNeeded, "Other HTTPS Connections Need Attention",
                    "The browser connection check succeeded. \(rejected) other connection(s) rejected the capture certificate; their app or SDK may need engineer help. This does not invalidate the tested browser connection or identify which app sent those connections.",
                    "other_clients_rejected_certificate", .observedDeviceTraffic, [.askEngineer])
            }
        }
        if request.captureLogs {
            let verified = fresh && request.logScope.mode == .app && observed?.logScopeVerified == true
                && (observed?.selectedAppLogRecords ?? 0) > 0 && request.application?.id == request.logScope.applicationID
            let waiting = fresh && observed?.collectorStarted == true && (observed?.selectedAppLogRecords ?? 0) == 0
            append("application_logs", verified ? .verified : waiting ? .waitingForAppActivity : .unverified, "Selected-App Logs",
                verified ? "Fresh emitted records match this check's resolved app scope. Suppressed/redacted values and excluded helper processes can still leave gaps."
                    : waiting ? "The collector is running but no matching app records have been observed. Open the selected app and perform its test action."
                    : "No fresh emitted records have verified this app's scope. Collector launch and connection notices do not prove app logs.",
                verified ? "scoped_logs_observed" : waiting ? "waiting_for_app_activity" : "app_logs_unverified",
                verified ? .observedApplicationLog : .unknown, verified ? [] : [.openSelectedApp, .runCheck])
        }
    }
}
