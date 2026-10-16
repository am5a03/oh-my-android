import AppKit
import SwiftUI

struct CaptureView: View {
    @Bindable var store: CaptureStore
    @State private var showCaptureDetails = true
    @State private var showRuntimeSettings = false
    @State private var showCaptureWarnings = false
    private let minimumEventPaneHeight: CGFloat = 180

    var body: some View {
        Group {
            if store.isDoctorPresented {
                CaptureDoctorView(store: store, doctor: store.doctor)
            } else if store.isSetupPresented {
                CaptureSetupView(store: store, setup: store.setup)
            } else {
                CaptureWorkspaceLayout(detailsExpanded: showCaptureDetails) {
                    captureHeader
                    captureDetails
                    timeline
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 0) {
                        Divider()
                        footer
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(minWidth: 960, minHeight: 680)
        .task(id: store.setup.configurationKey(store)) {
            if !store.isSetupPresented, !store.isDoctorPresented { await store.setup.inspect(store) }
        }
        .onChange(of: store.session?.id) { showCaptureWarnings = false }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { Task { await store.openSession() } } label: {
                    toolbarLabel("Open Session…", symbol: "folder")
                }
                    .disabled(store.hasActiveCapture || store.isBusy || store.doctor.isRepairing)
                    .help(openSessionHelp)
                    .accessibilityLabel("Open Session")
                    .accessibilityHint(openSessionHelp)
            }
            ToolbarItemGroup(placement: .automatic) {
                if !store.isSetupPresented && !store.isDoctorPresented {
                    Button { store.exportPackage() } label: {
                        toolbarLabel("Export ZIP…", symbol: "archivebox")
                    }
                        .disabled(store.session?.packagePath == nil)
                        .help(exportHelp)
                        .accessibilityHint(exportHelp)
                    Menu {
                        Button("Show ZIP in Finder", systemImage: "folder") { store.revealPackage() }
                            .disabled(store.session?.packagePath == nil)
                            .help(store.session?.packagePath == nil ? "Stop and save a capture to create its ZIP." : "Select the saved ZIP in Finder.")
                        if store.session?.caCertificatePath != nil {
                            Button("Show Capture Certificate in Finder…", systemImage: "certificate") { store.revealCaptureCertificate() }
                                .help("Locate the public capture certificate to install on the device. This file contains no private key.")
                        }
                    } label: {
                        toolbarLabel("Session", symbol: "ellipsis")
                    }
                    .help("Show the saved ZIP or capture certificate in Finder.")
                }
            }
            ToolbarItem(placement: .status) {
                if store.isBusy || store.isSaving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(operationTitle).font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                    if store.canCancelSave || store.isCancellingSave {
                        Button(store.isCancellingSave ? "Cancelling…" : "Cancel Save") { Task { await store.cancelSave() } }
                            .disabled(!store.canCancelSave)
                            .help("Cancel packaging after collectors stop. Original evidence and any prior ZIP are retained; Retry Save remains available.")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if store.isSetupPresented || store.isDoctorPresented {
                    EmptyView()
                } else if store.hasActiveCapture || store.session?.needsPackageRetry == true {
                    Button { Task { await store.stop() } } label: {
                        toolbarLabel(stopTitle, symbol: store.hasActiveCapture ? "stop.fill" : "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)
                    .keyboardShortcut(".", modifiers: .command)
                    .help(stopHelp)
                    .accessibilityHint(stopHelp)
                } else {
                    Button { Task { await store.start() } } label: {
                        toolbarLabel("Start Capture", symbol: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canStart)
                    .help(startHelp)
                    .accessibilityHint(startHelp)
                }
            }
        }
    }

    private var savedSession: CaptureSession? {
        guard !store.isStarting, !store.isStopping, let session = store.session,
              !session.isActive, !session.needsRoutingRecovery, session.packagePath != nil else { return nil }
        return session
    }

    private func savedCaptureNotice(_ session: CaptureSession) -> some View {
        let hasWarnings = session.phase != "saved" || !session.warnings.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    savedCaptureMessage(session, hasWarnings: hasWarnings)
                    Spacer(minLength: 8)
                    savedCaptureActions
                }
                VStack(alignment: .leading, spacing: 10) {
                    savedCaptureMessage(session, hasWarnings: hasWarnings)
                    savedCaptureActions
                }
            }
            if hasWarnings {
                captureWarnings(session)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    private func savedCaptureMessage(_ session: CaptureSession, hasWarnings: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hasWarnings ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.title2).foregroundStyle(hasWarnings ? Color.orange : Color.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.phase == "failed" ? "Evidence Saved after Capture Failure" : hasWarnings ? "Capture Saved with Warnings" : "Capture Saved")
                    .font(.headline)
                Text(hasWarnings
                     ? "The ZIP is ready. Review capture warnings and the timeline before sharing."
                     : "The ZIP is ready. Review the timeline below, export a copy, or start another capture.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var savedCaptureActions: some View {
        HStack(spacing: 8) {
            Button("Export ZIP…", systemImage: "archivebox") { store.exportPackage() }
                .buttonStyle(.borderedProminent)
                .help("Save a copy of the evidence ZIP to a location you choose.")
            Button("Show in Finder", systemImage: "folder") { store.revealPackage() }
                .help("Select the saved evidence ZIP in Finder.")
        }
    }

    private var captureHeader: some View {
        VStack(spacing: 0) {
            DisclosureGroup(isExpanded: captureDetailsBinding) {
                EmptyView()
            } label: {
                HStack(spacing: 12) {
                    Text("Capture Details").font(.headline).fixedSize()
                    Text(captureDetailsSummary)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if store.error != nil || !(store.session?.warnings.isEmpty ?? true) {
                        Label(captureAttentionSummary, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(store.error == nil ? Color.orange : Color.red)
                            .fixedSize()
                    }
                }
                .help(showCaptureDetails
                      ? "Hide capture settings, notices and session details to give the timeline more room."
                      : "Show capture settings, notices and session details. \(captureDetailsSummary)")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            if store.session?.routingRestored == false {
                notice("Connection needs recovery. Choose Restore Connection & Save before disconnecting the device.", symbol: "network.slash", color: .red)
                ForEach(Array((store.session?.warnings ?? []).filter { $0.hasPrefix("Routing recovery still required:") }.enumerated()), id: \.offset) { _, warning in
                    notice(warning, symbol: "exclamationmark.triangle.fill", color: .red)
                }
            }
            if store.selectedDevice?.platform == "iphone", store.captureNetwork {
                Text(store.session?.isActive == true
                     ? "Recording on Mac. Turn on Mobile Capture in WireGuard on iPhone. Turn it off before Stop & Save."
                     : "Start Capture on Mac, then turn on Mobile Capture in WireGuard on iPhone. Turn the tunnel off before Stop & Save.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
        }
        .background(.bar)
    }

    private var captureDetails: some View {
        ScrollView(.vertical) {
            headerContent
        }
        .scrollIndicators(.visible)
        .scrollBounceBehavior(.basedOnSize)
        .frame(minHeight: 0, maxHeight: .infinity)
        .clipped()
        .disabled(!showCaptureDetails)
        .allowsHitTesting(showCaptureDetails)
        .accessibilityHidden(!showCaptureDetails)
        .accessibilityLabel("Capture settings, notices and session details")
        .background(.bar)
    }

    private var captureDetailsBinding: Binding<Bool> {
        Binding(get: { showCaptureDetails }, set: { expanded in
            // Resize the workspace once. Animating a disclosure's descendants repeatedly reflows
            // the native table and inspector; an immediate change also respects Reduce Motion.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { showCaptureDetails = expanded }
        })
    }

    private var captureDetailsSummary: String {
        guard let session = store.session else { return "\(phaseTitle) · \(captureSettingsSummary)" }
        var parts = [phaseTitle, session.deviceName]
        if let app = session.context?.value(for: "log_scope")?.value(for: "application_id")?.stringValue, !app.isEmpty {
            parts.append(app)
        }
        let sources = [("logs", "Device Logs"), ("network", "Network")].compactMap { source, title in
            session.sources[source].flatMap { $0 == "not_selected" ? nil : title }
        }
        if !sources.isEmpty { parts.append(sources.joined(separator: " + ")) }
        return parts.joined(separator: " · ")
    }

    private var captureAttentionSummary: String {
        if store.error != nil { return "Needs Attention" }
        let warningCount = store.session?.warnings.count ?? 0
        return "\(warningCount) \(warningCount == 1 ? "Warning" : "Warnings")"
    }

    private var headerContent: some View {
        VStack(spacing: 0) {
            if let notice = store.externalRequestNotice {
                HStack(alignment: .top, spacing: 12) {
                    Label(notice, systemImage: "info.circle").frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { store.dismissExternalRequestNotice() }
                }
                .font(.callout).padding(12)
                Divider()
            }
            if let session = savedSession {
                savedCaptureNotice(session)
                Divider()
            }
            setup.padding(16)
            Divider()
            sessionStatus
            if let error = store.error { notice(error, symbol: "exclamationmark.triangle.fill", color: .red) }
            if let session = store.session {
                if session.needsPackageRetry, !store.hasActiveCapture {
                    notice("The ZIP is not available. Use Retry Save to package the existing capture evidence.", symbol: "archivebox", color: .orange)
                }
                if savedSession == nil { captureWarnings(session) }
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// An explicit HStack keeps these action names visible in an icon-only toolbar configuration.
    private func toolbarLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(title)
        }
    }

    private var openSessionHelp: String {
        if store.doctor.isRepairing { return "Finish or cancel the Doctor installation before opening another session." }
        if store.hasActiveCapture { return "Stop and save the current capture before opening another session." }
        if store.isBusy { return "Wait for the current operation to finish, then open a saved capture folder." }
        return "Open a saved capture folder to inspect its timeline or recover an interrupted capture."
    }

    private var startHelp: String {
        if store.isBusy { return "Wait for the current operation to finish." }
        if store.hasActiveCapture { return "Stop and save the current capture before starting another." }
        guard let device = store.selectedDevice else { return "Choose a connected device to start capturing." }
        if !device.isReady { return "The selected device is not ready. Unlock it, authorize the computer, then refresh devices." }
        if device.platform == "iphone", store.captureLogs, store.toolPath("idevicesyslog") == nil { return "Open Doctor to check the iPhone logging component. Network capture can run without device logs." }
        if store.captureLogs, let issue = store.logConfigurationIssue { return issue }
        if store.captureNetwork && device.platform == "iphone" && store.iphoneTunnelConfiguration == nil { return "Choose Device Setup to prepare the private capture connection, then start recording." }
        if !store.captureLogs && !store.captureNetwork { return "Select Device Logs, Network Requests & Responses, or both." }
        if store.captureNetwork && device.platform == "simulator" && store.networkService.isEmpty {
            return "Choose the Mac network service used by the Simulator before starting network capture."
        }
        return "Record the selected sources from \(device.name). Stop & Save restores the connection and creates one evidence ZIP."
    }

    private var exportHelp: String {
        store.session?.packagePath == nil
            ? "Stop and save a capture to create a ZIP, then export a copy."
            : "Save a copy of the complete evidence ZIP to a location you choose."
    }

    private var stopTitle: String {
        if store.session?.needsRoutingRecovery == true { return "Restore Connection & Save" }
        if !store.hasActiveCapture && store.session?.needsPackageRetry == true { return "Retry Save" }
        return "Stop & Save"
    }

    private var stopHelp: String {
        if store.isBusy { return "Wait for the current operation to finish. The capture remains available here." }
        if store.session?.needsRoutingRecovery == true { return "Restore the original connection settings, stop collectors, and save the evidence ZIP." }
        if store.session?.needsPackageRetry == true && !store.hasActiveCapture { return "Create a ZIP from the evidence already saved in this session." }
        return "Stop recording, restore the original connection settings, and create one evidence ZIP."
    }

    private var operationTitle: String {
        if store.isStarting { return "Preparing capture…" }
        if store.isSaving { return store.saveStageTitle }
        return "Updating session…"
    }

    @ViewBuilder
    private func captureWarnings(_ session: CaptureSession) -> some View {
        let warnings = session.warnings.filter { session.routingRestored != false || !$0.hasPrefix("Routing recovery still required:") }
        if !warnings.isEmpty {
            DisclosureGroup(isExpanded: $showCaptureWarnings) {
                captureWarningDetails(session, warnings: warnings).padding(.top, 8)
            } label: {
                Label("\(warnings.count) Capture \(warnings.count == 1 ? "Warning" : "Warnings")", systemImage: "exclamationmark.triangle")
            }
            .font(.caption)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.quaternary)
        }
    }

    private func captureWarningDetails(_ session: CaptureSession, warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            if session.platform == "android", session.caCertificatePath != nil {
                Button("Show Capture Certificate in Finder…") { store.revealCaptureCertificate() }
                Text("Install this public certificate on the device. The test app must also trust it.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var captureSettingsSummary: String {
        var parts = [store.selectedDevice?.name ?? (store.selectedDeviceID.isEmpty ? "No device selected" : "Device unavailable")]
        if store.captureLogs, store.logScopeMode == .app, !store.targetApp.isEmpty {
            parts.append(store.selectedApplication?.name ?? store.targetApp)
        }
        var sources: [String] = []
        if store.captureLogs { sources.append(store.logScopeMode == .wholeDevice ? "Whole-device logs" : "App logs") }
        if store.captureNetwork { sources.append("Network") }
        parts.append(sources.isEmpty ? "No sources selected" : sources.joined(separator: " + "))
        return parts.joined(separator: " · ")
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("Device", selection: Binding(get: { store.selectedDeviceID }, set: { store.selectDeviceForCapture($0) })) {
                    Text("Choose a connected device…").tag("")
                    ForEach(store.devices, id: \.selectionID) { device in
                        Text("\(device.name) · \(device.platformName) · \(device.state)").tag(device.selectionID)
                            .selectionDisabled(!device.isReady)
                    }
                    if !store.selectedDeviceID.isEmpty, store.selectedDevice == nil {
                        Text("Selected device unavailable").tag(store.selectedDeviceID)
                            .selectionDisabled(true)
                    }
                }
                .frame(maxWidth: 560)
                Button { Task { await store.refreshDevices() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Spacer()
                Text("Android · iPhone · iOS Simulator").font(.caption).foregroundStyle(.secondary)
            }
            .disabled(store.hasActiveCapture || store.isBusy)
            HStack(spacing: 20) {
                Toggle("Device logs", isOn: $store.captureLogs)
                Toggle("Network requests & responses", isOn: $store.captureNetwork)
                Spacer()
            }
            .disabled(store.hasActiveCapture || store.isBusy)
            if !store.hasActiveCapture, let prompt = store.setup.setupPrompt(store) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label(prompt, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    Button("Finish Setup…") { store.showSetup() }.disabled(store.isBusy || store.doctor.isRepairing)
                }
            }
            if store.captureLogs { CaptureLogSettingsView(store: store) }
            if store.selectedDevice?.platform == "iphone" {
                Text("iPhone logs use USB. Network traffic uses the private WireGuard tunnel over Wi-Fi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.selectedDevice?.platform == "iphone" {
                if store.captureLogs, store.toolPath("idevicesyslog") == nil {
                    HStack {
                        Text("The iPhone log component needs attention. Doctor can check it and offer a repair.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Doctor…") { store.showDoctor() }.disabled(store.hasActiveCapture || store.isBusy)
                    }
                }
            } else if store.captureNetwork, store.selectedDevice?.platform == "simulator" {
                HStack(spacing: 16) {
                    Picker("Mac network service", selection: $store.networkService) {
                        Text("Choose service…").tag("")
                        ForEach(store.networkServices, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 320)
                    Toggle("Trust capture CA in selected Simulator", isOn: $store.trustSimulatorCA)
                    Spacer()
                }
                .disabled(store.hasActiveCapture || store.isBusy)
                Text("Simulator capture temporarily changes this Mac service’s proxy and can include unrelated Mac or Simulator traffic. The CA checkbox authorizes importing the public capture certificate into the selected Simulator.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if store.captureNetwork, store.selectedDevice?.platform == "android" {
                Text("Use an engineer-prepared test app that trusts the capture certificate. Device Setup can guide the phone certificate installation.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Runtime settings & prerequisites", isExpanded: $showRuntimeSettings) {
                runtimeSettings.padding(.top, 6)
            }
            .font(.caption)
            .disabled(store.hasActiveCapture || store.isBusy)
        }
    }

    private var runtimeSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.selectedDevice?.platform == "iphone" {
                TextField("Mac Wi-Fi Address", text: $store.iphoneEndpointHost).textFieldStyle(.roundedBorder)
                    .help("A Mac address reachable from iPhone. After changing it, use Device Setup to update the phone’s capture profile.")
            }
            HStack {
                runtimeField("ADB", value: $store.adbPath, placeholder: store.toolPath("adb") ?? "Not detected")
                runtimeField("mitmdump", value: $store.mitmdumpPath, placeholder: store.toolPath("mitmdump") ?? "Not detected")
            }
            HStack(spacing: 12) {
                Label("ADB: \(store.toolPath("adb") == nil ? "missing" : "available")", systemImage: "cable.connector")
                Label("simctl: \(store.toolPath("simctl") == nil ? "missing" : "available")", systemImage: "iphone")
                Label("mitmdump: \(store.toolPath("mitmdump") == nil ? "missing" : "available")", systemImage: "network")
            }
            .foregroundStyle(.secondary)
            HStack {
                Text("Local captures: \(store.outputRoot.path)").textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button("Choose folder…") { store.chooseOutputRoot() }
            }
            Text("Capture is managed by the app’s compiled Swift service. Android needs platform tools, iOS Simulator needs Xcode tools, and network capture uses mitmproxy. Use absolute paths for tool overrides, then refresh devices.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runtimeField(_ title: String, value: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextField(placeholder, text: value).textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }

    private var sessionStatus: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(phaseTitle).font(.headline)
                Text(store.activeTargetName).font(.caption).foregroundStyle(.secondary)
                if savedSession == nil && !store.canStart && !store.hasActiveCapture && !store.isBusy && store.session?.needsPackageRetry != true {
                    Text(startHelp).font(.caption).foregroundStyle(.secondary)
                } else if store.session?.isActive == true {
                    Text("Stop & Save creates the ZIP for export. Closing this window keeps recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let session = store.session {
                    Text(session.directory).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help("Open this session folder to recover or inspect the capture after relaunching the app.")
                }
            }
            Spacer()
            sourceStatus("Device Logs", source: "logs")
            sourceStatus("Network", source: "network")
            if let session = store.session {
                Text("\(session.counts["markers", default: 0]) markers").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        CaptureLogVolumeView(store: store)
        }
    }

    private var phaseTitle: String {
        if store.isStarting { return "Preparing Capture…" }
        if store.isSaving { return store.saveStageTitle }
        guard let session = store.session else { return "Ready to Capture" }
        if session.needsRoutingRecovery { return "Connection Needs Recovery" }
        return switch session.phase {
        case "preparing": "Preparing Capture…"
        case "recording": "Recording"
        case "stopping": "Stopping & Saving…"
        case "saved": "Saved"
        case "partial": session.packagePath == nil ? "Capture Needs Saving" : "Saved with Warnings"
        case "failed": session.packagePath == nil ? "Capture Failed · Evidence May Be Available" : "Saved after Capture Failure"
        default: "Capture Session"
        }
    }

    private func sourceStatus(_ title: String, source: String) -> some View {
        let status = store.session?.sources[source] ?? "not_selected"
        let logReason = source == "logs" ? store.deviceLogProgress?.completion_reason : nil
        let color: Color = logReason?.isLimit == true ? .orange : status == "observed" ? .green : (["failed", "interrupted", "tls_failed"].contains(status) ? .red : (status == "started" ? .blue : .secondary))
        let statusTitle: String
        if let logReason { statusTitle = logReason.isLimit ? "Limit Reached" : "Stopped" }
        else { statusTitle = switch status {
        case "observed": store.session?.isActive == true ? "Receiving" : "Captured"
        case "started": store.session?.isActive == true ? "Waiting for Events" : "No Events Captured"
        case "preparing": "Preparing"
        case "failed": "Capture Failed"
        case "interrupted": "Interrupted"
        case "tls_failed": "Check Certificate Trust"
        case "not_selected": "Not Selected"
        default: "Status Unavailable"
        }
        }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text("\(title): \(statusTitle)")
            }
            Text("\(store.session?.counts[source] ?? 0) events").foregroundStyle(.secondary)
        }
        .font(.caption)
        .help(status == "tls_failed" ? "Traffic reached the proxy, but TLS failed before a request could be decoded. Check CA trust and the error details." : (status == "started" ? "Collector started; fresh evidence has not yet been observed." : "Status reported by the capture source."))
    }

    private var timelineHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Shared timeline").font(.headline)
                Picker("Source", selection: $store.sourceFilter) {
                    Text("All sources").tag("all")
                    Text("Logs").tag("logs")
                    Text("Network").tag("network")
                    Text("Markers").tag("marker")
                    Text("Capture Status").tag("status")
                }
                .labelsHidden().frame(width: 140)
                TextField("Filter URL, message, kind or detail…", text: $store.search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 350)
                    .accessibilityLabel("Filter timeline events")
                    .help("Search event text and details within the current source and view boundaries. All evidence remains in the saved session.")
                if !store.search.isEmpty || store.sourceFilter != "all" {
                    Button("Clear filters") { store.search = ""; store.sourceFilter = "all" }
                }
                Spacer()
                Picker("Order", selection: $store.newestFirst) {
                    Text("Oldest first").tag(false)
                    Text("Newest first").tag(true)
                }
                .labelsHidden().frame(width: 130)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            timelineControls
                .padding(.horizontal, 16).padding(.bottom, 8)
            HStack(spacing: 10) {
                Text(store.timelineCountText).monospacedDigit()
                if store.isLoadingTimeline { ProgressView().controlSize(.small) }
                if store.pendingTimelineBytes > 0, store.session?.isActive != true {
                    Button(store.isIndexingPaused ? "Resume Indexing" : "Pause Indexing") { store.toggleBackgroundIndexing() }
                        .help("Pause rebuilding the disposable timeline cache. Original evidence is retained; remaining records become searchable when indexing resumes.")
                }
                if store.hasOlderEvents {
                    Button("Load Older") { Task { await store.loadOlderEvents() } }
                        .disabled(store.isBusy || store.isLoadingTimeline)
                        .help("Load the previous page of matching events while holding your reading position.")
                }
                if store.hasNewerEvents {
                    Button("Load Newer") { Task { await store.loadNewerEvents() } }
                        .disabled(store.isBusy || store.isLoadingTimeline)
                        .help("Load the next page of matching events while keeping Follow Latest off.")
                }
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.bottom, 8)
            if let hint = store.presentationHint {
                Label(hint, systemImage: store.isViewPaused ? "pause.circle" : "hand.raised")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            timelineHeader
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { pane in
                HSplitView {
                    eventList.frame(minWidth: 460, maxHeight: .infinity)
                    eventDetail.frame(minWidth: 290, idealWidth: 350, maxHeight: .infinity)
                }
                // The AppKit-backed split view otherwise keeps its intrinsic minimum height inside
                // an expanding outer frame. Give it the actual remaining pane size instead.
                .frame(width: pane.size.width, height: pane.size.height)
            }
            .frame(minHeight: minimumEventPaneHeight, maxHeight: .infinity)
            .layoutPriority(1)
            VStack(alignment: .leading, spacing: 5) {
                Text(store.session?.phase == "recording" ? "Add a note at the current time. Selecting a row only opens its details." : "Start recording to add a time marker.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "bookmark").accessibilityHidden(true)
                    TextField("For example: Tapped the banner ad", text: $store.markerText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Marker note at the current time")
                        .help("Type a note while recording, then choose Add Marker or press Return. The marker uses the current time, not the selected row’s time.")
                        .onSubmit { Task { await store.addMarker() } }
                    Button(store.isAddingMarker ? "Saving Marker…" : "Add Marker") { Task { await store.addMarker() } }
                        .disabled(store.session?.phase != "recording" || store.isBusy || store.isAddingMarker || store.markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(markerHelp)
                        .accessibilityHint(markerHelp)
                }
                .disabled(store.session?.phase != "recording")
                if let receipt = store.markerReceipt {
                    Label(receipt, systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var timelineControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                playbackControls
                Divider().frame(height: 20)
                viewControls
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { playbackControls; Spacer(minLength: 0) }
                HStack(spacing: 8) { viewControls; Spacer(minLength: 0) }
            }
        }
        .disabled(store.session == nil || store.isBusy)
    }

    @ViewBuilder
    private var playbackControls: some View {
        Button { Task { await store.togglePauseView() } } label: {
            Label(store.isViewPaused ? "Resume Display" : "Pause Display", systemImage: store.isViewPaused ? "play.fill" : "pause.fill")
        }
        .disabled(store.session?.isActive != true && !store.isViewPaused)
        .help(store.isViewPaused ? "Show events captured while the display was paused." : "Freeze this timeline for inspection. Device logs and network capture continue to be saved.")
        Toggle(isOn: Binding(get: { store.followLatest }, set: { enabled in Task { await store.setFollowLatest(enabled) } })) {
            Label("Follow Latest", systemImage: store.newestFirst ? "arrow.up.to.line" : "arrow.down.to.line")
        }
        .toggleStyle(.button)
        .help(store.isViewPaused ? "This following preference takes effect when the display resumes." : "Keep the newest matching event in view. Scrolling or selecting an event turns this off.")
        Button { Task { await store.jumpToLatest() } } label: {
            Label("Jump to Latest", systemImage: "forward.end")
        }
        .help("Resume the display and show the newest matching event once. This does not turn on Follow Latest.")
    }

    @ViewBuilder
    private var viewControls: some View {
        Button { Task { await store.clearView() } } label: {
            Label("Clear View", systemImage: "eraser")
        }
        .help("Hide events captured so far from this view. The device log buffer, saved evidence and export are preserved.")
        if store.hiddenThroughSequence != nil {
            Button("Show Full Session") { Task { await store.showFullSession() } }
                .help("Restore events hidden by Clear View. Source, search and pause settings still apply.")
        }
        Toggle(isOn: $store.wrapLines) { Label("Wrap Lines", systemImage: "text.word.spacing") }
            .toggleStyle(.button)
            .help("Wrap long event previews in the list. Select an event to inspect its complete text and bodies.")
    }

    private var markerHelp: String {
        if store.session?.phase != "recording" { return "Start recording to add a marker at the current time." }
        if store.isAddingMarker { return "Saving your marker…" }
        if store.isBusy { return "Wait for the current operation to finish, then add your note." }
        if store.markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Type a note first, such as Tapped the banner ad." }
        return "Add your note at the current time. Choose All Sources or Markers to see it in the timeline."
    }

    private var eventList: some View {
        let rows = store.retainedTimelineRows
        let showsOverlay = !store.timelineMatchesFilters || rows.isEmpty
        return ZStack {
            CaptureTimelineList(rows: rows, selectedEventID: $store.selectedEventID,
                followLatest: store.followLatest && !store.isViewPaused, newestFirst: store.newestFirst, wrapLines: store.wrapLines,
                jumpToLatestToken: store.jumpToLatestToken, onInteraction: { store.userDidInteractWithTimeline() })
                .disabled(showsOverlay)
                .allowsHitTesting(!showsOverlay)
                .accessibilityHidden(showsOverlay)
            if showsOverlay {
                ContentUnavailableView(emptyTimelineTitle, systemImage: "list.bullet.rectangle", description: Text(emptyTimelineHelp))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private var emptyTimelineTitle: String {
        if store.isLoadingTimeline || !store.timelineMatchesFilters && store.session != nil { return "Loading Timeline…" }
        if store.hiddenThroughSequence != nil { return "No Events in This View" }
        if store.isViewPaused { return "Display Paused" }
        if (store.timeline?.totalCount ?? 0) > 0 { return "No Matching Events" }
        return store.session == nil ? "No Capture Open" : "No Events Captured Yet"
    }

    private var emptyTimelineHelp: String {
        if store.isViewPaused { return "Resume Display to see new events. Recorded evidence is retained while this view is paused." }
        if store.hiddenThroughSequence != nil { return "Clear View hides earlier events. Show Full Session restores them; saved evidence stays intact." }
        if !store.search.isEmpty || store.sourceFilter != "all" { return "Try another source or search term, or clear the filters to see other events." }
        return store.hasActiveCapture
            ? "Use the selected device and add markers while recording. Events appear here as they are captured."
            : "Select a device and capture sources, then start recording. Choose Open Session to inspect an existing capture."
    }

    @ViewBuilder
    private var eventDetail: some View {
        if let event = store.selectedEvent {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !store.visibleEvents.contains(where: { $0.id == event.id }) {
                        Label("Selected event is outside the current view.", systemImage: "pin")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(event.kind).font(.headline)
                    Text(event.summary).font(.system(.body, design: .monospaced))
                    Divider()
                    detailField("UTC timestamp", event.timestamp)
                    if let original = event.originalTimestamp { detailField("Original timestamp", original) }
                    if let received = event.receivedAt { detailField("Received at", received) }
                    detailField("Clock alignment", event.clockUncertaintyMs.map { "Uncertainty: ±\($0.formatted()) ms" } ?? "Uncalibrated; uncertainty unknown")
                    detailField("Raw evidence", event.rawRef)
                    Button("Reveal evidence file") { store.revealRawEvidence(event) }
                    ForEach(event.bodies) { body in
                        Divider()
                        DisclosureGroup(body.title) {
                            Text(body.content)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }
                    }
                    Divider()
                    Text("Headers & event details").font(.headline)
                    Text(event.metadata).font(.system(.caption, design: .monospaced))
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        } else if store.isLoadingSelectedEvent {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading Selected Event…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.selectedEventID != nil {
            ContentUnavailableView("Event Unavailable", systemImage: "doc.text.magnifyingglass",
                description: Text("Select another event or reopen the session to retry loading its details."))
        } else {
            ContentUnavailableView("Inspect an event", systemImage: "sidebar.right", description: Text("Select a log, request or marker to inspect details and its raw evidence reference."))
        }
    }

    private func detailField(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced))
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("All captured evidence is retained in the session and ZIP. Time proximity is inferred.")
            Spacer()
            Text("Saved locally. No automatic uploads. Review private evidence before sharing.")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .help(store.hasActiveCapture ? "Capture continues when this window is closed. Use Stop & Save to finalize it." : "A ZIP contains raw evidence and the normalized shared timeline.")
    }

    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(color.opacity(0.08))
    }
}

/// Allocates the upper details and the evidence workspace together, without publishing measured
/// heights back into view state. Long details scroll while the timeline keeps its minimum pane size.
private struct CaptureWorkspaceLayout: Layout {
    let detailsExpanded: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 960, height: 680))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let width = bounds.width
        let minimumProposal = ProposedViewSize(width: width, height: 0)
        let headerHeight = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let timelineMinimum = subviews[2].sizeThatFits(minimumProposal).height
        let footerHeight = subviews[3].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let availableForDetails = max(0, bounds.height - headerHeight - timelineMinimum - footerHeight)
        let preferredDetailsHeight = max(0, min(360, bounds.height * 0.4) - headerHeight)
        // Deliberately never measure the scrolling details. Expanding a warning or runtime
        // disclosure changes its document height, not the timeline's allocated position.
        let detailsHeight = detailsExpanded ? min(preferredDetailsHeight, availableForDetails) : 0
        let timelineHeight = max(timelineMinimum, bounds.height - headerHeight - detailsHeight - footerHeight)

        subviews[0].place(at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: headerHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + headerHeight), anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: detailsHeight))
        subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + headerHeight + detailsHeight), anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: timelineHeight))
        subviews[3].place(at: CGPoint(x: bounds.minX, y: bounds.minY + headerHeight + detailsHeight + timelineHeight), anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: footerHeight))
    }
}
