import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A task workspace inside the capture window; opening it never changes routing or evidence.
struct CaptureSetupView: View {
    @Bindable var store: CaptureStore
    @Bindable var setup: CaptureSetupStore
    @State private var showAdvanced = false
    @State private var showAllChecks = false
    @State private var showTunnelImport = false
    @State private var showCheckCode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heading
                progress
                if let notice = store.externalRequestNotice {
                    HStack(alignment: .top, spacing: 12) {
                        message(notice, symbol: "info.circle", color: .secondary)
                        Button("Dismiss") { store.dismissExternalRequestNotice() }
                    }
                }
                if let error = setup.error { message(error, symbol: "exclamationmark.triangle", color: .red) }
                if let notice = setup.notice { message(notice, symbol: "info.circle", color: .secondary) }
                if let error = store.error { message(error, symbol: "exclamationmark.triangle", color: .orange) }
                if store.hasOwnActiveCapture, setup.step != .record {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("A Capture Is Already Open", systemImage: "record.circle").font(.headline)
                            Text("Finish the active capture or restore its connection before running a setup check. Its timeline and evidence remain available.")
                            Button("Return to Capture") { setup.dismiss(store) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                } else {
                    switch setup.step {
                    case .choose: chooseCapture
                    case .prepare: prepareDevice
                    case .check: checkCapture
                    case .record: recordIssue
                    }
                }
                if let report = setup.report {
                    DisclosureGroup("Setup Details", isExpanded: $showAllChecks) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(report.checks, id: \.id) { check in
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("\(check.title) · \(stateTitle(check.state))", systemImage: stateSymbol(check.state))
                                        .font(.callout.weight(.medium))
                                    Text(check.message).font(.callout).foregroundStyle(.secondary)
                                    Text("Checked \(check.checkedAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.accessibilityElement(children: .combine)
                            }
                            if let fingerprint = report.identity.caFingerprint {
                                LabeledContent("Capture CA") { Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled) }
                            }
                            Button(setup.isExportingReport ? "Exporting Setup Report…" : "Export Setup Report…", systemImage: "archivebox") {
                                Task { await setup.exportReadinessReport() }
                            }.disabled(setup.isExportingReport)
                        }.padding(.top, 12)
                    }
                }
                Text("Everything is saved on this Mac. Review requests, bodies and logs before sharing the ZIP with an engineer or an AI service.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task { await setup.monitor(store) }
        .onChange(of: setup.configurationKey(store)) {
            setup.configurationDidChange(store)
            Task { await setup.inspect(store) }
        }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up Capture").font(.largeTitle.weight(.semibold))
                Text("Collect the app activity your engineer needs, one step at a time.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Capture Timeline", systemImage: "list.bullet.rectangle") { setup.dismiss(store) }
                .disabled(setup.hasLiveCheck)
                .help(setup.hasLiveCheck ? "Stop and save the check before leaving setup." : "Return to the existing session. Setup choices are retained.")
        }
    }

    private var progress: some View {
        HStack(spacing: 0) {
            ForEach(CaptureSetupStore.Step.allCases, id: \.rawValue) { step in
                HStack(spacing: 8) {
                    Image(systemName: setup.step == step ? "circle.inset.filled" : "circle")
                        .accessibilityHidden(true)
                    Text(step.title).font(.callout.weight(setup.step == step ? .semibold : .regular))
                    if step != .record { Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true) }
                }
                .foregroundStyle(setup.step == step ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Step \(step.rawValue + 1) of 4, \(step.title)\(setup.step == step ? ", current step" : "")")
            }
        }
    }

    private var chooseCapture: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Capture Task") {
                VStack(alignment: .leading, spacing: 12) {
                    if let plan = setup.appliedPlan {
                        Text(plan.title).font(.headline)
                        if let instructions = plan.instructions { Text(instructions).foregroundStyle(.secondary) }
                        Label("Engineer plan · Version \(plan.version)", systemImage: "doc.text")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Use Manual Capture") { setup.useManualCapture(store) }
                    } else {
                        Text("Open a plan from your engineer, or choose an app and capture sources below.")
                    }
                    Button(setup.appliedPlan == nil ? "Open Capture Plan…" : "Open Another Capture Plan…", systemImage: "doc.badge.plus") { setup.importPlan() }
                    if let plan = setup.pendingPlan { planReview(plan) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("Device and App") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Device", selection: Binding(get: { store.selectedDeviceID }, set: { store.selectDeviceForCapture($0) })) {
                        Text("Connect a device, then choose it…").tag("")
                        ForEach(store.devices, id: \.selectionID) { device in
                            Text("\(device.name) · \(device.platformName) · \(device.state)").tag(device.selectionID)
                                .selectionDisabled(!device.isReady)
                        }
                        if !store.selectedDeviceID.isEmpty, store.selectedDevice == nil {
                            Text("Selected device disconnected").tag(store.selectedDeviceID).selectionDisabled(true)
                        }
                    }
                    Text(connectionGuidance).font(.callout).foregroundStyle(.secondary)
                    if store.selectedDevice?.isReady == true {
                        TextField("Find an installed app by name or identifier", text: $setup.appSearch)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Find Installed App")
                        Picker("App", selection: $store.targetApp) {
                            Text("Choose the app to investigate…").tag("")
                            ForEach(filteredApplications) { app in
                                Text(app.name == app.id ? app.id : "\(app.name) · \(app.id)").tag(app.id)
                            }
                            if !store.targetApp.isEmpty, !filteredApplications.contains(where: { $0.id == store.targetApp }) {
                                Text(store.selectedApplication?.name ?? store.targetApp).tag(store.targetApp)
                            }
                        }
                        Button("Refresh Installed Apps", systemImage: "arrow.clockwise") { Task { await store.refreshApplications(); await setup.inspect(store) } }
                            .disabled(store.isLoadingApplications || store.isBusy)
                        if store.isLoadingApplications { ProgressView().controlSize(.small).accessibilityLabel("Loading installed apps") }
                        if let error = store.applicationDiscoveryError {
                            Text("Apps could not be loaded. \(error)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Button("Check Connection Again", systemImage: "arrow.clockwise") {
                        Task { await store.refreshDevices(); await setup.inspect(store) }
                    }.disabled(store.isBusy || store.hasActiveCapture)
                }.padding(8)
            }
            sourceChoices
            if let issue = selectionIssue { message(issue, symbol: "info.circle", color: .secondary) }
            HStack {
                Spacer()
                Button("Continue", systemImage: "arrow.right") { setup.step = .prepare; Task { await setup.inspect(store) } }
                    .buttonStyle(.borderedProminent).disabled(selectionIssue != nil || store.isBusy)
            }
        }.disabled(store.hasActiveCapture)
    }

    private var sourceChoices: some View {
        GroupBox("Evidence to Capture") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Device Logs\(requirementSuffix(logs: true))", isOn: $store.captureLogs)
                Toggle("Network Requests & Responses\(requirementSuffix(logs: false))", isOn: $store.captureNetwork)
                Text(store.logScopeMode == .app
                     ? "Logs are limited to the selected app. Network traffic may include other apps. Full captured request and response bodies are retained."
                     : "Whole-device logs are selected in Engineer Options and may contain other apps’ activity. Network traffic may also include other apps.")
                    .font(.callout).foregroundStyle(.secondary)
                if let limits = store.appliedSetupLoggingPolicy {
                    Text("Engineer log limits: \(ByteCountFormatter.string(fromByteCount: limits.max_bytes, countStyle: .file)), \(limits.max_records.formatted()) records or \(limits.max_duration_seconds.formatted()) seconds. Editing the limits in Engineer Options replaces these values.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let missing = excludedRequiredSources, !missing.isEmpty {
                    Label("Required by this task but turned off: \(missing.joined(separator: ", ")). The package will disclose the missing evidence.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                DisclosureGroup("Engineer Options", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        CaptureLogSettingsView(store: store)
                        if store.selectedDevice?.platform == "iphone" {
                            TextField("Mac Wi-Fi Address", text: $store.iphoneEndpointHost).textFieldStyle(.roundedBorder)
                        }
                        if store.selectedDevice?.platform == "simulator" {
                            Picker("Mac Network Service", selection: $store.networkService) {
                                Text("Choose service…").tag("")
                                ForEach(store.networkServices, id: \.self) { Text($0).tag($0) }
                            }
                            Toggle("Trust Capture CA in Selected Simulator", isOn: $store.trustSimulatorCA)
                            Text("This authorizes certificate import. Network capture temporarily changes this Mac service’s proxy and may include unrelated traffic.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 8)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var prepareDevice: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !setup.hasLiveCheck, let check = setup.report?.checks.first(where: { [.actionNeeded, .unavailable, .needsEngineerHelp].contains($0.state) }) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(check.title, systemImage: stateSymbol(check.state)).font(.headline)
                        Text(check.message)
                        Button("Check Again", systemImage: "arrow.clockwise") { Task { await store.refreshDevices(); await setup.inspect(store) } }
                            .disabled(store.isBusy || setup.isInspecting)
                        Button("Export Setup Report…", systemImage: "archivebox") { Task { await setup.exportReadinessReport() } }
                            .disabled(setup.isExportingReport)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            if store.selectedDevice?.platform == "iphone", store.captureNetwork {
                GroupBox("Prepare the iPhone Tunnel") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Keep the tunnel off for now. Connect this Mac and iPhone to a reachable Wi-Fi network.")
                        if store.iphoneTunnelConfiguration == nil {
                            Button("Prepare Device", systemImage: "iphone.and.arrow.forward") {
                                if store.prepareIPhoneSetup() { showTunnelImport = true; Task { await setup.inspect(store) } }
                            }.buttonStyle(.borderedProminent).disabled(store.isBusy || store.hasActiveCapture)
                        } else {
                            Label("Saved Capture Profile Available", systemImage: "doc.badge.gearshape").font(.headline)
                            Button(showTunnelImport ? "Hide Tunnel Import" : "Show Tunnel Import", systemImage: "qrcode") { showTunnelImport.toggle() }
                        }
                        if showTunnelImport, let configuration = store.iphoneTunnelConfiguration {
                            CaptureSetupQRCode(dataURL: configuration.clientProfile)
                            Text("In WireGuard on iPhone, choose Add Tunnel → Create from QR Code. Scan this private code and name the tunnel Mobile Capture. Leave it off until the check starts.")
                            Text("This profile contains a private key and stays outside evidence packages.").font(.callout).foregroundStyle(.secondary)
                        }
                        Text("The current iPhone route may need engineer-installed USB tools. Missing tools appear in Setup Details; this development build is not yet a proven fresh-Mac installer.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            } else if store.selectedDevice?.platform == "android" {
                GroupBox("Prepare Your Android App") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Use the test build from your engineer. USB debugging must be enabled and this computer authorized on the phone.")
                        if store.captureNetwork {
                            Text("For HTTPS bodies, the app must trust this capture’s certificate. Copy it to your phone first, then install it at your own pace.")
                            if setup.isPreparingCertificate {
                                ProgressView("Copying Certificate and Restoring Connection…").controlSize(.small)
                                Text("The Mac briefly prepares its capture connection, copies only the public certificate, then restores the connection before you install it.")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else if setup.isCertificatePreparation, setup.hasLiveCheck {
                                Label("Restore the Preparation Connection", systemImage: "network.slash").font(.headline)
                                Text("Finish restoring the connection before installing the certificate. Your capture choices and earlier session are preserved.")
                                Button("Restore Connection & Finish Preparation", systemImage: "arrow.clockwise") {
                                    Task { await setup.stopCheck() }
                                }.buttonStyle(.borderedProminent).disabled(setup.checkCapture?.isBusy == true)
                            } else {
                                Button(setup.certificateReadyForInstallation && setup.certificatePreparationDeviceID == store.selectedDeviceID
                                       ? "Copy Capture Certificate Again" : "Prepare & Copy Capture Certificate", systemImage: "certificate") {
                                    Task { await setup.prepareAndroidCertificate(store) }
                                }.disabled(store.isBusy || store.hasActiveCapture)
                                if setup.certificateReadyForInstallation, setup.certificatePreparationDeviceID == store.selectedDeviceID {
                                    Label("Certificate Copied · Connection Restored", systemImage: "doc.badge.checkmark").font(.headline)
                                    Text("On Android, open Settings and search Install a certificate. Choose CA certificate, then the newest mobile-capture-ca file in Downloads. Complete the phone’s confirmation.")
                                    Text("Take your time. No capture is running. When installation is complete, continue to a fresh capture check; copying the certificate does not verify trust.")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("An installed certificate alone does not make every app or ad SDK inspectable. Your engineer may need to adjust debug trust or certificate pinning.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            Text("Ready to try means the prerequisites are available. A check must observe fresh app logs and a decoded HTTPS response before those sources are verified.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Back") { setup.step = .choose }.disabled(setup.hasLiveCheck)
                Spacer()
                Button("Continue to Capture Check", systemImage: "arrow.right") { setup.step = .check }
                    .buttonStyle(.borderedProminent).disabled(setup.hasLiveCheck || !store.canStart || selectionIssue != nil)
            }
        }
    }

    private var checkCapture: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(setup.hasLiveCheck ? "Check in Progress" : setup.verificationCapture?.session == nil ? "Try a Short Capture" : "Review the Capture Check")
                        .font(.title2.weight(.semibold))
                    if setup.isLaunchingCheck {
                        ProgressView("Preparing Capture Check…").controlSize(.small)
                        Text("Wait for the connection to be ready before opening the phone check link.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if setup.hasLiveCheck, let check = setup.checkCapture {
                        if let started = setup.checkStartedAt, !setup.checkDeadlineReached {
                            let elapsed = min(45, max(0, Date().timeIntervalSince(started)))
                            ProgressView(value: elapsed, total: 45).accessibilityLabel("Capture check elapsed time")
                            Text("\(max(0, 45 - Int(elapsed))) seconds remaining in this short check")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if check.session?.platform == "iphone", check.captureNetwork {
                            Label("Turn On Mobile Capture in WireGuard on iPhone", systemImage: "iphone").font(.headline)
                        }
                        if check.captureLogs {
                            Text("Open \(store.selectedApplication?.name ?? store.targetApp) on your device and perform an action that produces debug logs. The check retains at most 10 MB, 10,000 log records or 45 seconds of logs.")
                        }
                        if check.captureNetwork { checkLink(check) }
                        if let error = check.error { message(error, symbol: "exclamationmark.triangle", color: .orange) }
                        if check.session?.caCertificatePath != nil {
                            Button("Show Public Capture Certificate…", systemImage: "certificate") { check.revealCaptureCertificate() }
                            if check.session?.platform == "android" {
                                Button(setup.isTransferringCertificate ? "Copying Certificate…" : "Copy Certificate to Phone Downloads", systemImage: "square.and.arrow.down") {
                                    Task { await setup.transferCertificate() }
                                }.disabled(setup.isTransferringCertificate || check.isBusy)
                            }
                            Text(certificateGuidance).font(.callout).foregroundStyle(.secondary)
                            if let identity = setup.report?.identity.caFingerprint {
                                Text("Current capture certificate: …\(identity.suffix(12)). The full fingerprint is in Setup Details.")
                                    .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Button(check.session?.needsRoutingRecovery == true ? "Restore Connection & Save Check" : "Stop Check & Save", systemImage: "stop.fill") {
                            Task { await setup.stopCheck(); await setup.inspect(store) }
                        }.buttonStyle(.borderedProminent).disabled(check.isBusy)
                        if check.isSaving { ProgressView(check.saveStageTitle).controlSize(.small) }
                    } else if let check = setup.verificationCapture, let session = check.session {
                        checkSummary(check)
                        if session.packagePath != nil {
                            HStack {
                                Button("Export Check ZIP…", systemImage: "archivebox") { check.exportPackage() }
                                Button("Show Check in Finder", systemImage: "folder") { check.revealPackage() }
                            }
                        }
                        if session.needsPackageRetry {
                            Button("Retry Save") { Task { await check.stop() } }.disabled(check.isBusy)
                        }
                        Button("Run a New Check", systemImage: "arrow.clockwise") { Task { await setup.startCheck(store) } }
                            .disabled(!store.canStart || selectionIssue != nil)
                    } else {
                        Text("The Mac will temporarily route the selected device’s traffic and capture app logs in a separate session. Your existing session stays open.")
                        if store.captureNetwork {
                            Text("On the device, open the check page and tap Verify HTTPS. The page sends synthetic text only to this Mac’s capture engine. This checks the device browser, not every app or SDK.")
                        }
                        Text("The check ends after 45 seconds. For an iPhone network check, the Mac keeps forwarding until you turn off the tunnel and confirm Stop Check & Save.")
                            .font(.callout).foregroundStyle(.secondary)
                        if store.selectedDevice?.platform == "iphone" {
                            Text("If certificate installation takes longer than the log check, finish the phone setup, turn the tunnel off, save this check and run a fresh check for app logs.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Button("Start Capture Check", systemImage: "checkmark.circle") { Task { await setup.startCheck(store) } }
                            .buttonStyle(.borderedProminent).disabled(!store.canStart || selectionIssue != nil)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if let check = setup.checkCapture, setup.hasLiveCheck { checkSummary(check) }
            HStack {
                Button("Back") { setup.step = .prepare }.disabled(setup.hasLiveCheck)
                Spacer()
                Button(setup.missingRequiredSources(store).isEmpty ? "Continue to Recording" : "Continue with Missing Evidence", systemImage: "arrow.right") {
                    setup.step = .record
                }.buttonStyle(.borderedProminent).disabled(setup.hasLiveCheck || setup.verificationCapture?.session == nil)
            }
        }
    }

    private func checkLink(_ check: CaptureStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = check.setupContext?.checkURL {
                Text("On the phone, open this address and tap Verify HTTPS.").font(.headline)
                Text(url.absoluteString).font(.callout.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Copy Phone Check Link", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Button(showCheckCode ? "Hide QR Code" : "Show QR Code", systemImage: "qrcode") { showCheckCode.toggle() }
                }
                if showCheckCode { CaptureSetupQRCode(text: url.absoluteString) }
                Text("A Mac browser visit does not prove the phone route. Use the connected phone. The HTTPS check does not certify your selected app’s trust settings or internet access.")
                    .font(.callout).foregroundStyle(.secondary)
                if setup.browserHTTPSObserved, !setup.phoneOriginConfirmed {
                    Label("Browser HTTPS Captured", systemImage: "checkmark.circle")
                    Button("I Opened This Check on the Phone", systemImage: "iphone") {
                        Task { await setup.confirmPhoneOrigin(store) }
                    }
                    Text("This records your confirmation of which device opened the page. HTTPS success comes from the captured response; phone origin is not independently verified.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func checkSummary(_ check: CaptureStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(setup.report?.checks.filter { ["device_routing", "https", "application_logs"].contains($0.id) } ?? [], id: \.id) { result in
                Label("\(result.title): \(stateTitle(result.state))", systemImage: stateSymbol(result.state))
                Text(result.message).font(.callout).foregroundStyle(.secondary)
            }
            Text("\(check.session?.counts["logs", default: 0] ?? 0) log events · \(check.session?.counts["network", default: 0] ?? 0) network events")
                .font(.callout).foregroundStyle(.secondary)
            if !setup.missingRequiredSources(store).isEmpty {
                Label("Required evidence still missing: \(setup.missingRequiredSources(store).joined(separator: ", ")). It remains disclosed in the engineer package.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }.accessibilityElement(children: .contain)
    }

    private var recordIssue: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Reproduce the Issue") {
                VStack(alignment: .leading, spacing: 12) {
                    if let plan = setup.appliedPlan {
                        Text(plan.title).font(.headline)
                        ForEach(Array(plan.reproductionSteps.enumerated()), id: \.offset) { index, step in Text("\(index + 1). \(step)") }
                        if let note = plan.engineerNote { Label(note, systemImage: "person.crop.circle.badge.questionmark").foregroundStyle(.secondary) }
                    } else { Text("Start recording, reproduce the issue in the selected app, then choose Stop & Save.") }
                    if store.hasOwnActiveCapture {
                        if store.selectedDevice?.platform == "iphone", store.captureNetwork {
                            Label("Turn on Mobile Capture in WireGuard while recording. Turn it off before Stop & Save.", systemImage: "iphone")
                        }
                        TextField("Optional note, such as Tapped the banner ad", text: $store.markerText)
                            .textFieldStyle(.roundedBorder).onSubmit { Task { await store.addMomentMarker() } }
                        Button("Mark This Moment", systemImage: "bookmark") { Task { await store.addMomentMarker() } }
                            .disabled(store.session?.phase != "recording" || store.isBusy || store.isAddingMarker)
                        if let receipt = store.markerReceipt { Text(receipt).font(.callout).foregroundStyle(.secondary) }
                        Button(store.session?.needsRoutingRecovery == true ? "Restore Connection & Save" : "Stop & Save", systemImage: "stop.fill") {
                            Task { await store.stop() }
                        }.buttonStyle(.borderedProminent).disabled(store.isBusy)
                        if store.isSaving { ProgressView(store.saveStageTitle).controlSize(.small) }
                        CaptureLogVolumeView(store: store)
                    } else if let session = store.session, session.packagePath != nil,
                              session.id == setup.recordingSessionID {
                        Label("Capture Saved", systemImage: "checkmark.circle.fill").font(.headline)
                        Text("Your ZIP is ready. Review the shared timeline, then export a copy for your engineer.")
                        CaptureTaskCoverageView(session: session)
                        HStack {
                            Button("Export ZIP…", systemImage: "archivebox") { store.exportPackage() }.buttonStyle(.borderedProminent)
                            Button("Show in Finder", systemImage: "folder") { store.revealPackage() }
                            Button("Review Timeline") { setup.dismiss(store) }
                        }
                        Button("Record Again", systemImage: "record.circle") { Task { await setup.startRecording(store) } }.disabled(!store.canStart)
                    } else {
                        if let missing = excludedRequiredSources, !missing.isEmpty {
                            message("This will be a diagnostic capture with missing required sources: \(missing.joined(separator: ", ")).", symbol: "exclamationmark.triangle", color: .orange)
                        }
                        Text("\(store.selectedDevice?.name ?? "Device") · \(store.selectedApplication?.name ?? store.targetApp)")
                        Button("Start Recording", systemImage: "record.circle") { Task { await setup.startRecording(store) } }
                            .buttonStyle(.borderedProminent).disabled(!store.canStart || selectionIssue != nil)
                        Text("Starting a new recording keeps the earlier session on disk. Its timeline is replaced here after capture starts.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if !store.hasOwnActiveCapture { Button("Back to Capture Check") { setup.step = .check } }
        }
    }

    private func planReview(_ plan: CapturePlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Label("Review Before Applying", systemImage: "doc.text.magnifyingglass").font(.headline)
            Text(plan.title).font(.headline)
            Text("\(plan.platform.rawValue) · \(plan.applicationID)")
            Text("Device logs: \(plan.sources.logs.rawValue) · Network: \(plan.sources.network.rawValue)")
            Text("Log limits: \(ByteCountFormatter.string(fromByteCount: plan.logLimits.maxBytes, countStyle: .file)), \(plan.logLimits.maxRecords.formatted()) records, \(Int(plan.logLimits.maxDurationSeconds)) seconds")
                .font(.callout).foregroundStyle(.secondary)
            if let note = plan.engineerNote { Text(note) }
            if let executable = plan.executableName { Text("Verified App Executable: \(executable)").font(.callout) }
            if !plan.helperProcessNames.isEmpty {
                Text("Additional App Processes: \(plan.helperProcessNames.joined(separator: ", "))").font(.callout)
            }
            if !plan.supportedBuilds.isEmpty { Text("Engineer-Supported Builds: \(plan.supportedBuilds.joined(separator: ", "))").font(.callout) }
            if let ticket = plan.ticket { Text("Engineer Reference: \(ticket)").font(.callout) }
            if let instructions = plan.instructions { Text(instructions) }
            ForEach(Array(plan.reproductionSteps.enumerated()), id: \.offset) { index, step in Text("\(index + 1). \(step)").font(.callout) }
            HStack {
                Button("Apply Capture Plan") { setup.applyPendingPlan(store) }.buttonStyle(.borderedProminent)
                Button("Cancel") { setup.discardPendingPlan() }
            }
        }
    }

    private var filteredApplications: [CaptureLogApplication] {
        let query = setup.appSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.applications.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    private var selectionIssue: String? {
        guard store.selectedDevice?.isReady == true else { return "Connect and authorize a device, then select it above." }
        if let issue = setup.configurationIssue(store) { return issue }
        if !store.captureLogs && !store.captureNetwork { return "Choose at least one evidence source." }
        if store.captureLogs { return store.logConfigurationIssue }
        return nil
    }

    private var connectionGuidance: String {
        if store.selectedDevice?.isReady == true { return "Connected. Device availability is rechecked automatically while setup is open." }
        if store.devices.contains(where: { $0.platform == "android" && !$0.isReady }) { return "Unlock Android and approve Allow USB Debugging for this Mac. The unavailable device becomes selectable after authorization." }
        return "Connect by USB and unlock the phone. Android needs USB debugging authorization. On iPhone, choose Trust This Computer and confirm with the phone’s passcode."
    }

    private var certificateGuidance: String {
        store.selectedDevice?.platform == "iphone"
            ? "On iPhone, open http://mitm.it with the tunnel on and install the Apple profile. Then enable its full trust in Settings → General → About → Certificate Trust Settings. Use this capture’s current certificate, not an older certificate with the same name."
            : "Install this capture’s public CA on the phone if needed. The engineer’s test app must also trust it. Certificate trust is verified only when the device HTTPS check succeeds."
    }

    private var excludedRequiredSources: [String]? {
        guard let plan = setup.appliedPlan else { return nil }
        return [("Device logs", plan.sources.logs == .required && !store.captureLogs),
                ("Network", plan.sources.network == .required && !store.captureNetwork)].compactMap { $0.1 ? $0.0 : nil }
    }

    private func requirementSuffix(logs: Bool) -> String {
        guard let plan = setup.appliedPlan else { return "" }
        let requirement = logs ? plan.sources.logs : plan.sources.network
        return " · \(requirement.rawValue.capitalized) by Plan"
    }

    private func message(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).foregroundStyle(color).font(.callout).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stateTitle(_ state: CaptureSetupState) -> String {
        switch state {
        case .checking: "Checking"
        case .actionNeeded: "Action Needed"
        case .readyToTry: "Ready to Try"
        case .verified: "Verified"
        case .unavailable: "Unavailable"
        case .needsEngineerHelp: "Needs Engineer Help"
        case .waitingForAppActivity: "Waiting for App Activity"
        case .unverified: "Unverified"
        case .notRequested: "Not Requested"
        }
    }

    private func stateSymbol(_ state: CaptureSetupState) -> String {
        switch state {
        case .verified: "checkmark.circle"
        case .readyToTry: "arrow.right.circle"
        case .checking, .waitingForAppActivity: "clock"
        case .actionNeeded, .needsEngineerHelp, .unavailable: "exclamationmark.triangle"
        case .unverified, .notRequested: "minus.circle"
        }
    }
}

/// Saved coverage comes from export validation; saving a ZIP does not itself satisfy a task.
struct CaptureTaskCoverageView: View {
    let session: CaptureSession

    var body: some View {
        if let assessment = session.taskAssessment {
            let required = hasRequiredSources(assessment)
            let met = assessment.value(for: "requirements_met")?.boolValue == true
            VStack(alignment: .leading, spacing: 5) {
                Label(required ? (met ? "Required Evidence Captured" : "Required Evidence Missing") : "Evidence Coverage",
                    systemImage: required && !met ? "exclamationmark.triangle" : "doc.text.magnifyingglass")
                    .font(.callout.weight(.semibold))
                if required, !met {
                    Text("Missing: \(missingSources(assessment).joined(separator: ", ")). The ZIP contains the available evidence and explains these gaps.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Review the engineer summary and timeline. Browser setup probes are excluded from task evidence, and request hosts do not prove which app or SDK sent them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.accessibilityElement(children: .combine)
        }
    }

    private func hasRequiredSources(_ assessment: CaptureJSON) -> Bool {
        guard case .array(let sources) = assessment.value(for: "sources") else { return false }
        return sources.contains { $0.value(for: "requirement")?.stringValue == "required" }
    }

    private func missingSources(_ assessment: CaptureJSON) -> [String] {
        guard case .array(let sources) = assessment.value(for: "missing_required_sources") else { return [] }
        return sources.compactMap(\.stringValue).map { $0 == "logs" ? "selected-app logs" : "decoded HTTPS requests and responses" }
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
