import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Phone preparation is optional and untimed. Everyday capture belongs in the timeline.
struct CaptureSetupView: View {
    @Bindable var store: CaptureStore
    @Bindable var setup: CaptureSetupStore
    @State private var phoneStep = 0
    @State private var showDetails = false
    @State private var showConnectionHelp = false
    @State private var showCheckCode = false
    @State private var showTunnelCode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heading
                progress
                if let error = setup.error { message(error, symbol: "exclamationmark.triangle", color: .red) }
                if let notice = setup.notice { message(notice, symbol: "info.circle", color: .secondary) }
                if let error = store.error { message(error, symbol: "exclamationmark.triangle", color: .orange) }
                if store.hasOwnActiveCapture {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("A Capture Is Already Open").font(.headline)
                            Text("Stop and save the capture before preparing this phone. Your evidence stays available in the timeline.")
                            Button("Open Timeline") { setup.dismiss(store) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                } else {
                    switch setup.step {
                    case .choose: connectDevice
                    case .prepare: preparePhone
                    case .check: checkConnection
                    case .record: completeSetup
                    }
                }
                details
            }
            .frame(maxWidth: 760, alignment: .leading).padding(28)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task { await setup.monitor(store) }
        .task(id: store.doctor.configurationKey(store)) { await store.doctor.refresh(store) }
        .onChange(of: setup.configurationKey(store)) {
            setup.configurationDidChange(store)
            Task { await setup.inspect(store) }
        }
        .onChange(of: store.selectedDeviceID) { phoneStep = 0; showTunnelCode = false }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up Your Device").font(.largeTitle.weight(.semibold))
                Text("Prepare your phone once. Then record from the timeline.").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Timeline") { setup.dismiss(store) }
                .disabled(setup.hasLiveCheck)
                .help(setup.hasLiveCheck ? "Restore the active setup connection before leaving." : "Return to the timeline. Unfinished HTTPS setup remains available from the Capture menu.")
        }
    }

    private var progress: some View {
        HStack(spacing: 12) {
            ForEach(CaptureSetupStore.Step.allCases, id: \.rawValue) { step in
                HStack(spacing: 7) {
                    Image(systemName: setup.step == step ? "circle.inset.filled" : "circle").accessibilityHidden(true)
                    Text(stepTitle(step)).font(.callout.weight(setup.step == step ? .semibold : .regular))
                }
                .foregroundStyle(setup.step == step ? .primary : .secondary)
                .accessibilityLabel("Step \(step.rawValue + 1) of 4, \(stepTitle(step))\(setup.step == step ? ", current step" : "")")
                if step != .record { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true) }
            }
        }
    }

    private var connectDevice: some View {
        VStack(alignment: .leading, spacing: 18) {
            instruction("Connect Your Device", symbol: "cable.connector", text: connectionGuidance)
            Picker("Device", selection: $store.selectedDeviceID) {
                Text("Choose your connected device…").tag("")
                ForEach(store.devices, id: \.selectionID) { device in
                    Text("\(device.name) · \(device.platformName) · \(device.state)").tag(device.selectionID)
                        .selectionDisabled(!device.isReady)
                }
                if !store.selectedDeviceID.isEmpty, store.selectedDevice == nil {
                    Text("Selected device disconnected").tag(store.selectedDeviceID).selectionDisabled(true)
                }
            }.disabled(store.hasActiveCapture || store.isBusy)
            HStack {
                Button("Check Again", systemImage: "arrow.clockwise") {
                    Task { await store.refreshDevices(includeApplications: false); await setup.inspect(store) }
                }.disabled(store.isBusy || setup.isInspecting)
                Button("Check Setup…", systemImage: "stethoscope") { store.showDoctor() }
                    .disabled(store.isBusy || store.hasActiveCapture)
                if setup.isInspecting { ProgressView().controlSize(.small).accessibilityLabel("Checking device availability") }
            }
            Text("The capture tools come with Mobile Capture. Doctor can check missing or damaged components without installing anything.")
                .font(.callout).foregroundStyle(.secondary)
            if store.doctor.isChecking {
                HStack { ProgressView().controlSize(.small); Text("Checking Capture Components…") }
                    .accessibilityElement(children: .combine)
            } else if let issue = firstDoctorIssue {
                Label(issue.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Open Doctor…", systemImage: "stethoscope") { store.showDoctor() }
            }
            if store.selectedDevice?.platform != "iphone" && store.selectedDevice?.platform != "simulator" {
                DisclosureGroup("Android Not Appearing?", isExpanded: $showConnectionHelp) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Use a USB cable that supports data, then unlock the phone.")
                        Text("2. In Settings → About phone, find Build number and tap it seven times. Some phones put it under Software information. Confirm the phone’s screen lock if asked.")
                        Text("3. Return to Settings and search Developer options. Turn on USB debugging.")
                        Text("4. Reconnect the cable. On the phone, approve Allow USB debugging for this Mac, then choose Check Again here.")
                        Link("Official Android Connection Help", destination: URL(string: "https://developer.android.com/studio/debug/dev-options")!)
                    }.font(.callout).padding(.top, 10)
                }
            }
            navigation(next: "Continue") { setup.step = .prepare; Task { await setup.inspect(store) } }
                .disabled(store.selectedDevice?.isReady != true || store.isBusy || store.doctor.hasOperation
                          || !store.doctor.hasCurrentReport(store) || firstDoctorIssue != nil)
        }
    }

    private var preparePhone: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.selectedDevice?.isReady != true {
                instruction("Reconnect Your Device", symbol: "cable.connector", text: connectionGuidance)
                Button("Back to Devices") { setup.step = .choose }.disabled(setup.hasLiveCheck)
            } else if store.selectedDevice?.platform == "android" {
                androidPreparation
            } else if store.selectedDevice?.platform == "iphone" {
                iphonePreparation
            } else {
                simulatorPreparation
            }
            if !setup.hasLiveCheck {
                Button("Set Up HTTPS Later") { setup.deferSetup(store) }
                    .help("Return to the timeline for logs-only capture or saved sessions. HTTPS remains unchecked.")
            }
        }
    }

    private var androidPreparation: some View {
        VStack(alignment: .leading, spacing: 18) {
            if phoneStep == 0 {
                instruction("Copy the Capture Certificate", symbol: "certificate", text:
                    "To capture HTTPS requests, install this app’s capture certificate on your phone. We’ll copy the public certificate to Downloads, then restore the connection.")
                if setup.isPreparingCertificate {
                    HStack { ProgressView().controlSize(.small); Text("Copying Certificate and Restoring Connection…") }
                } else if setup.isCertificatePreparation, setup.hasLiveCheck {
                    instruction("Restore the Setup Connection", symbol: "network.slash", text:
                        "The preparation connection still needs recovery. Restore it before installing the certificate.")
                    Button("Restore Connection", systemImage: "arrow.clockwise") { Task { await setup.stopCheck() } }
                        .buttonStyle(.borderedProminent).disabled(setup.checkCapture?.isBusy == true)
                } else {
                    Button(setup.certificateReadyForInstallation ? "Copy Certificate Again" : "Copy Certificate to Phone", systemImage: "square.and.arrow.down") {
                        Task { await setup.prepareAndroidCertificate(store) }
                    }.buttonStyle(.borderedProminent).disabled(store.hasActiveCapture || store.isBusy)
                    if setup.certificateReadyForInstallation {
                        Label("Certificate Copied · Connection Restored", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                }
                navigation(back: { setup.step = .choose }, backDisabled: setup.hasLiveCheck, next: "Continue to Phone Settings", nextDisabled: !setup.certificateReadyForInstallation || setup.hasLiveCheck) { phoneStep = 1 }
            } else {
                instruction("Install the Certificate on Android", symbol: "iphone", text:
                    "On your phone, open Settings and search “Install a certificate”. Choose CA certificate, then the newest mobile-capture-ca file in Downloads. Complete the phone’s confirmation.")
                certificateIdentity
                Text("Take your time. No setup capture is running. Your test app must also trust this certificate; your engineer prepares that app setting.")
                    .foregroundStyle(.secondary)
                navigation(back: { phoneStep = 0 }, next: "Check Connection") { setup.step = .check }
                Button("I Already Installed This Certificate") { setup.step = .check }
            }
        }
    }

    private var iphonePreparation: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch phoneStep {
            case 0:
                instruction("Add the Capture Connection", symbol: "qrcode", text:
                    "Connect this Mac and iPhone to the same reachable Wi-Fi. Install WireGuard on the iPhone if needed, then import this phone’s private capture profile. Keep the tunnel off for now.")
                Link("WireGuard in the App Store", destination: URL(string: "https://apps.apple.com/app/wireguard/id1441195209")!)
                if store.iphoneTunnelConfiguration == nil {
                    Button("Prepare Capture Profile", systemImage: "qrcode") {
                        if store.prepareIPhoneSetup() { showTunnelCode = true; Task { await setup.inspect(store) } }
                    }.buttonStyle(.borderedProminent).disabled(store.isBusy || store.hasActiveCapture)
                } else {
                    Button(showTunnelCode ? "Hide Private QR Code" : "Show Private QR Code", systemImage: "qrcode") { showTunnelCode.toggle() }
                }
                if showTunnelCode, let configuration = store.iphoneTunnelConfiguration {
                    CaptureSetupQRCode(dataURL: configuration.clientProfile)
                    Text("In WireGuard, choose Add Tunnel → Create from QR Code. Scan this code and name the tunnel Mobile Capture. Approve the iPhone’s VPN request, then leave the tunnel off.")
                    Text("This private profile stays outside captured evidence and exported ZIPs.").font(.callout).foregroundStyle(.secondary)
                }
                navigation(back: { setup.step = .choose }, backDisabled: setup.hasLiveCheck, next: "Profile Added — Continue", nextDisabled: store.iphoneTunnelConfiguration == nil) { phoneStep = 1 }
            case 1:
                instruction("Install the Certificate Profile", symbol: "certificate", text:
                    "Start the setup connection on this Mac, then turn on Mobile Capture in WireGuard on iPhone. In Safari on the phone, open http://mitm.it and download the Apple certificate.")
                preparationConnection
                Text("On iPhone, open Settings → General → VPN & Device Management. Select the downloaded mitmproxy profile and choose Install.")
                certificateIdentity
                navigation(back: { phoneStep = 0 }, next: "Certificate Installed — Continue", nextDisabled: !setup.hasLiveCheck) { phoneStep = 2 }
            default:
                instruction("Enable Full Trust on iPhone", symbol: "checkmark.shield", text:
                    "Open Settings → General → About → Certificate Trust Settings. Under Enable Full Trust for Root Certificates, turn on this capture’s mitmproxy certificate and confirm.")
                certificateIdentity
                Text("Installing the profile and enabling full trust are separate steps. An older mitmproxy certificate may have the same name. Keep the capture tunnel on until the connection check is finished.")
                    .foregroundStyle(.secondary)
                navigation(back: { phoneStep = 1 }, next: "Check Connection", nextDisabled: !setup.hasLiveCheck && !setup.canCheckConnection(store)) { Task { await setup.startCheck(store) } }
            }
            if setup.hasLiveCheck, !setup.isLaunchingCheck, let check = setup.checkCapture {
                stopCheckButton(check)
            }
        }
    }

    private var preparationConnection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if setup.isLaunchingCheck {
                HStack { ProgressView().controlSize(.small); Text("Preparing Setup Connection…") }
            } else if setup.hasLiveCheck {
                Label("Setup Connection Running", systemImage: "network").font(.headline)
                Text("Take your time in iPhone Settings. The Mac keeps forwarding until you turn off the tunnel and stop the connection.")
                    .foregroundStyle(.secondary)
            } else {
                Button("Start Setup Connection", systemImage: "network") {
                    Task { await setup.startIPhonePreparation(store); phoneStep = 1 }
                }.buttonStyle(.borderedProminent).disabled(!setup.canCheckConnection(store))
            }
        }
    }

    private var simulatorPreparation: some View {
        VStack(alignment: .leading, spacing: 16) {
            instruction("Prepare the Simulator", symbol: "iphone", text:
                "Simulator capture is an engineer option using Xcode. Choose the Mac network service used by the Simulator and allow the capture certificate to be imported.")
            Picker("Mac Network Service", selection: $store.networkService) {
                Text("Choose service…").tag("")
                ForEach(store.networkServices, id: \.self) { Text($0).tag($0) }
            }
            Toggle("Trust Capture Certificate in the Selected Simulator", isOn: $store.trustSimulatorCA)
            Text("The check temporarily changes this Mac service’s proxy and can include unrelated Mac traffic.")
                .font(.callout).foregroundStyle(.secondary)
            navigation(back: { setup.step = .choose }, next: "Check Connection", nextDisabled: store.networkService.isEmpty || store.isBusy) { setup.step = .check }
        }.disabled(setup.hasLiveCheck)
    }

    private var checkConnection: some View {
        VStack(alignment: .leading, spacing: 18) {
            instruction("Check Your Phone’s HTTPS Connection", symbol: "network", text:
                "This small check uses a synthetic browser request and no device logs. Other phone network traffic may be included while the connection runs. No app data is sent to an outside test service.")
            if setup.isLaunchingCheck {
                HStack { ProgressView().controlSize(.small); Text("Preparing Connection Check…") }
            } else if setup.hasLiveCheck, let check = setup.checkCapture {
                if check.session?.platform == "iphone" {
                    Label("Turn On Mobile Capture in WireGuard on iPhone", systemImage: "iphone").font(.headline)
                }
                checkLink(check)
                if setup.checkDeadlineReached, check.session?.platform == "iphone" {
                    Text("The short check period has ended. Forwarding stays available while you finish. Turn the phone tunnel off before stopping this connection.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                stopCheckButton(check)
                if let error = check.error { message(error, symbol: "exclamationmark.triangle", color: .orange) }
            } else {
                if let check = setup.verificationCapture, check.session != nil {
                    connectionResult
                    if check.session?.needsPackageRetry == true {
                        Button("Retry Saving Check") { Task { await setup.stopCheck() } }.disabled(check.isBusy)
                    }
                }
                Button(setup.verificationCapture?.session == nil ? "Start Connection Check" : "Try Again", systemImage: "arrow.clockwise") {
                    Task { await setup.startCheck(store) }
                }.buttonStyle(.borderedProminent).disabled(!setup.canCheckConnection(store))
                Text("On Android, the short check restores the connection automatically. On iPhone, forwarding stays available until you turn the tunnel off and confirm Stop Check.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Back to Phone Setup") { setup.step = .prepare }.disabled(setup.hasLiveCheck)
                Spacer()
                Button("Continue", systemImage: "arrow.right") { Task { if await setup.completeSetup(store) { setup.step = .record } } }
                    .buttonStyle(.borderedProminent).disabled(setup.hasLiveCheck || !connectionSucceeded)
            }
            if !setup.hasLiveCheck {
                Button("Save Setup Report…", systemImage: "archivebox") { Task { await setup.exportReadinessReport() } }
                    .disabled(setup.report == nil || setup.isExportingReport)
                Button("Open Timeline Without HTTPS Verification") { setup.deferSetup(store) }
            }
        }
    }

    private func checkLink(_ check: CaptureStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let url = check.setupContext?.checkURL {
                Text("On the phone, open this address and tap Verify HTTPS.").font(.headline)
                Text(url.absoluteString).font(.callout.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Copy Phone Link", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Button(showCheckCode ? "Hide QR Code" : "Show QR Code", systemImage: "qrcode") { showCheckCode.toggle() }
                }
                if showCheckCode { CaptureSetupQRCode(text: url.absoluteString) }
                if setup.browserHTTPSObserved {
                    Label("HTTPS Response Captured", systemImage: "checkmark.circle").foregroundStyle(.green)
                    if !setup.phoneOriginConfirmed {
                        Button("I Opened This Check on the Phone", systemImage: "iphone") {
                            Task { await setup.confirmPhoneOrigin(store) }
                        }.buttonStyle(.borderedProminent)
                    }
                }
                Text("Use the connected phone, not a browser on this Mac. Your confirmation records which device opened the page; HTTPS success comes from the captured response.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func stopCheckButton(_ check: CaptureStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if check.session?.platform == "iphone" {
                Text("When you finish, turn off Mobile Capture in WireGuard on the iPhone, then stop this connection.")
                    .font(.callout.weight(.medium))
            }
            Button(check.session?.needsRoutingRecovery == true ? "Restore Connection & Save Check" : "Stop Check & Restore Connection", systemImage: "stop.fill") {
                Task { await setup.stopCheck(); await setup.inspect(store) }
            }.buttonStyle(.borderedProminent).disabled(check.isBusy)
            if check.isSaving { ProgressView(check.saveStageTitle).controlSize(.small) }
        }
    }

    private var completeSetup: some View {
        VStack(alignment: .leading, spacing: 18) {
            instruction("Device Setup Complete", symbol: "checkmark.circle", text:
                "The phone’s browser HTTPS response was captured and the setup connection has been restored. You can now record from the timeline.")
            Text("Choose your device and capture sources, then Start Capture. Stop & Save creates one ZIP with the shared timeline, logs and network evidence.")
            if store.selectedDevice?.platform == "iphone" {
                Text("For each network recording: start on the Mac, turn the WireGuard tunnel on, then turn it off before Stop & Save.")
                    .foregroundStyle(.secondary)
            }
            Text("This checked the tested browser connection. App certificate trust or SDK pinning can still need your engineer’s help.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Timeline", systemImage: "list.bullet.rectangle") { setup.dismiss(store) }
                .buttonStyle(.borderedProminent)
        }
    }

    private var connectionResult: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(connectionSucceeded ? "HTTPS Connection Checked" : "HTTPS Connection Still Needs Attention",
                  systemImage: connectionSucceeded ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.headline).foregroundStyle(connectionSucceeded ? .green : .orange)
            ForEach(setup.report?.checks.filter { ["device_routing", "https"].contains($0.id) } ?? [], id: \.id) { check in
                Text(check.message).font(.callout).foregroundStyle(.secondary)
            }
            if setup.browserHTTPSObserved, !setup.phoneOriginConfirmed {
                Button("I Opened This Check on the Phone", systemImage: "iphone") {
                    Task { await setup.confirmPhoneOrigin(store) }
                }
                Text("This records your confirmation of the device used; the captured HTTPS response is checked separately.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var certificateIdentity: some View {
        Group {
            if let fingerprint = setup.report?.identity.caFingerprint {
                Text("Current Capture Certificate: …\(fingerprint.suffix(12))")
                    .font(.callout.monospaced()).textSelection(.enabled)
            }
        }
    }

    private var details: some View {
        DisclosureGroup("Help and Setup Details", isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Copying or installing a certificate does not verify trust. Only a fresh decoded HTTPS response can pass the connection check.")
                if let report = setup.report {
                    ForEach(report.checks, id: \.id) { check in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(check.title).font(.callout.weight(.semibold))
                            Text(check.message).font(.callout).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                }
                Button("Open Doctor…", systemImage: "stethoscope") { store.showDoctor() }
                    .disabled(store.hasActiveCapture || store.isBusy)
                Button("Save Setup Report…", systemImage: "archivebox") { Task { await setup.exportReadinessReport() } }
                    .disabled(setup.report == nil || setup.isExportingReport)
                Text("Evidence stays on this Mac. Review requests, bodies and logs before sharing a recording ZIP.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(.top, 12)
        }
    }

    private var connectionSucceeded: Bool {
        setup.isConnectionVerified && setup.verificationCapture?.session?.routingRestored == true && !setup.hasLiveCheck
    }

    private var firstDoctorIssue: CaptureDoctorCheck? {
        guard store.doctor.hasCurrentReport(store) else { return nil }
        return store.doctor.report?.rows.first { $0.status != .ready }
    }

    private var connectionGuidance: String {
        if store.selectedDevice?.isReady == true { return "Keep your phone connected by USB and unlocked. We’ll prepare HTTPS capture next." }
        if store.devices.contains(where: { $0.platform == "android" && !$0.isReady }) {
            return "Unlock Android and approve Allow USB Debugging for this Mac. If that prompt does not appear, use Android Not Appearing below."
        }
        if store.devices.contains(where: { $0.platform == "iphone" && !$0.isReady }) {
            return "Unlock iPhone. If asked, choose Trust This Computer and confirm with the phone’s passcode."
        }
        return "Connect your phone by USB and unlock it. Approve this computer on the phone when asked."
    }

    private func navigation(back: (() -> Void)? = nil, backDisabled: Bool = false, next: String, nextDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            if let back { Button("Back", action: back).disabled(backDisabled) }
            Spacer()
            Button(next, systemImage: "arrow.right", action: action).buttonStyle(.borderedProminent).disabled(nextDisabled)
        }
    }

    private func instruction(_ title: String, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.title2.weight(.semibold))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func message(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).foregroundStyle(color).font(.callout).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepTitle(_ step: CaptureSetupStore.Step) -> String {
        switch step {
        case .choose: "Connect"
        case .prepare: "Prepare Phone"
        case .check: "Check Connection"
        case .record: "Open Timeline"
        }
    }
}
/// The QR stays local. File-backed data is only the explicitly prepared private tunnel profile.
private struct CaptureSetupQRCode: View {
    var text: String?
    var dataURL: URL?
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.none).scaledToFit()
                    .frame(width: 192, height: 192).padding(12).background(.white)
                    .accessibilityLabel(dataURL == nil ? "Device capture check QR code" : "Private WireGuard capture tunnel QR code")
            } else if failed {
                Label("QR code unavailable. Use the displayed address or the saved tunnel profile.", systemImage: "qrcode")
            } else { ProgressView().frame(width: 192, height: 192).accessibilityLabel("Preparing QR code") }
        }
        .task(id: text ?? dataURL?.path) {
            do {
                let data = try text.map { Data($0.utf8) } ?? dataURL.map { try Data(contentsOf: $0) } ?? Data()
                guard !data.isEmpty, data.count <= 65_536 else { throw AppError("QR data is unavailable.") }
                let filter = CIFilter.qrCodeGenerator(); filter.message = data; filter.correctionLevel = "M"
                guard let output = filter.outputImage,
                      let rendered = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                          from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { throw AppError("QR generation failed.") }
                image = rendered; failed = false
            } catch { failed = true; image = nil }
        }
    }
}
