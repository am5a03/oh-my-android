import AppKit
import SwiftUI

struct CaptureView: View {
    @Bindable var store: CaptureStore
    @State private var showRuntimeSettings = false
    @State private var showCaptureWarnings = false
    @State private var isStopping = false

    var body: some View {
        VStack(spacing: 0) {
            setup
            Divider()
            sessionStatus
            if let error = store.error { notice(error, symbol: "exclamationmark.triangle.fill", color: .red) }
            if let session = store.session {
                if session.routingRestored == false {
                    notice("Connection needs recovery. Choose Restore Connection & Save before disconnecting the device.", symbol: "network.slash", color: .red)
                    ForEach(Array(session.warnings.filter { $0.hasPrefix("Routing recovery still required:") }.enumerated()), id: \.offset) { _, warning in
                        notice(warning, symbol: "exclamationmark.triangle.fill", color: .red)
                    }
                }
                if session.needsPackageRetry, !store.hasActiveCapture {
                    notice("The ZIP is not available. Use Retry Save to package the existing capture evidence.", symbol: "archivebox", color: .orange)
                }
                captureWarnings(session)
            }
            Divider()
            timeline
            Divider()
            footer
        }
        .frame(minWidth: 960, minHeight: 680)
        .onChange(of: store.session?.id) { showCaptureWarnings = false }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { Task { await store.openSession() } } label: {
                    toolbarLabel("Open Session…", symbol: "folder")
                }
                    .disabled(store.hasActiveCapture || store.isBusy)
                    .help(openSessionHelp)
                    .accessibilityLabel("Open Session")
                    .accessibilityHint(openSessionHelp)
            }
            ToolbarItemGroup(placement: .automatic) {
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
            ToolbarItem(placement: .status) {
                if store.isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(operationTitle).font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if store.hasActiveCapture || store.session?.needsPackageRetry == true {
                    Button { Task { await stopCapture() } } label: {
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

    /// An explicit HStack keeps these action names visible in an icon-only toolbar configuration.
    private func toolbarLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(title)
        }
    }

    private var openSessionHelp: String {
        if store.hasActiveCapture { return "Stop and save the current capture before opening another session." }
        if store.isBusy { return "Wait for the current operation to finish, then open a saved capture folder." }
        return "Open a saved capture folder to inspect its timeline or recover an interrupted capture."
    }

    private var startHelp: String {
        if store.isBusy { return "Wait for the current operation to finish." }
        if store.hasActiveCapture { return "Stop and save the current capture before starting another." }
        guard let device = store.selectedDevice else { return "Choose a connected device to start capturing." }
        if !device.isReady { return "The selected device is not ready. Unlock it, authorize the computer, then refresh devices." }
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
        if isStopping { return store.session?.needsRoutingRecovery == true ? "Restoring connection and saving…" : "Stopping and saving…" }
        return "Updating session…"
    }

    private func stopCapture() async {
        isStopping = true
        defer { isStopping = false }
        await store.stop()
    }

    @ViewBuilder
    private func captureWarnings(_ session: CaptureSession) -> some View {
        let warnings = session.warnings.filter { session.routingRestored != false || !$0.hasPrefix("Routing recovery still required:") }
        if !warnings.isEmpty {
            DisclosureGroup(isExpanded: $showCaptureWarnings) {
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
                .padding(.top, 8)
            } label: {
                Label("\(warnings.count) Capture \(warnings.count == 1 ? "Warning" : "Warnings")", systemImage: "exclamationmark.triangle")
            }
            .font(.caption)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.quaternary)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("Device", selection: $store.selectedDeviceID) {
                    Text("Choose a connected device…").tag("")
                    ForEach(store.devices, id: \.selectionID) { device in
                        Text("\(device.name) · \(device.platformName) · \(device.state)").tag(device.selectionID)
                    }
                    if !store.selectedDeviceID.isEmpty, store.selectedDevice == nil {
                        Text("Selected device unavailable").tag(store.selectedDeviceID)
                    }
                }
                .frame(maxWidth: 560)
                Button { Task { await store.refreshDevices() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Spacer()
                Text("Physical iPhone: next phase").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                Toggle("Device logs", isOn: $store.captureLogs)
                Toggle("Network requests & responses", isOn: $store.captureNetwork)
                TextField("Optional app bundle identifier", text: $store.targetApp)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 350)
                    .help("On Simulator, limits logs to the installed app’s process across restarts. On Android, records investigation context while retaining all device logs.")
                Spacer()
            }
            Text(store.selectedDevice?.platform == "simulator"
                 ? "Enter an installed app’s bundle identifier to focus Simulator logs. An empty field captures all processes. Network capture can include other apps; some SDK traffic may remain unreadable."
                 : "Android retains all device logs; app context is metadata. Network capture can include other apps; some SDK traffic may remain unreadable.")
                .font(.caption).foregroundStyle(.secondary)
            if store.captureNetwork, store.selectedDevice?.platform == "simulator" {
                HStack(spacing: 16) {
                    Picker("Mac network service", selection: $store.networkService) {
                        Text("Choose service…").tag("")
                        ForEach(store.networkServices, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 320)
                    Toggle("Trust capture CA in selected Simulator", isOn: $store.trustSimulatorCA)
                    Spacer()
                }
                Text("Simulator capture temporarily changes this Mac service’s proxy and can include unrelated Mac or Simulator traffic. The CA checkbox authorizes importing the public capture certificate into the selected Simulator.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if store.captureNetwork, store.selectedDevice?.platform == "android" {
                Text("Android needs USB debugging and a test app that trusts the capture CA. Install and trust the public certificate on the device for HTTPS bodies; pinning or apps that ignore the proxy can prevent capture.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Runtime settings & prerequisites", isExpanded: $showRuntimeSettings) {
                runtimeSettings.padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(16)
        .disabled(store.hasActiveCapture || store.isBusy)
        .background(.bar)
    }

    private var runtimeSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                runtimeField("Python 3", value: $store.pythonPath, placeholder: "Automatic discovery")
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
            Text("Prototype dependencies: Python 3, Android platform tools for Android, Xcode Simulator tools for iOS, and mitmproxy for network capture. Use absolute paths for overrides, then refresh devices.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runtimeField(_ title: String, value: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextField(placeholder, text: value).textFieldStyle(.roundedBorder)
        }
    }

    private var sessionStatus: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(phaseTitle).font(.headline)
                Text(store.activeTargetName).font(.caption).foregroundStyle(.secondary)
                if !store.canStart && !store.hasActiveCapture && !store.isBusy && store.session?.needsPackageRetry != true {
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
    }

    private var phaseTitle: String {
        if store.isStarting { return "Preparing Capture…" }
        if isStopping { return store.session?.needsRoutingRecovery == true ? "Restoring Connection & Saving…" : "Stopping & Saving…" }
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
        let color: Color = status == "observed" ? .green : (["failed", "interrupted", "tls_failed"].contains(status) ? .red : (status == "started" ? .blue : .secondary))
        let statusTitle = switch status {
        case "observed": store.session?.isActive == true ? "Receiving" : "Captured"
        case "started": store.session?.isActive == true ? "Waiting for Events" : "No Events Captured"
        case "preparing": "Preparing"
        case "failed": "Capture Failed"
        case "interrupted": "Interrupted"
        case "tls_failed": "Check Certificate Trust"
        case "not_selected": "Not Selected"
        default: "Status Unavailable"
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

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Shared timeline").font(.headline)
                Picker("Source", selection: $store.sourceFilter) {
                    Text("All sources").tag("all")
                    Text("Logs").tag("logs")
                    Text("Network").tag("network")
                    Text("Markers").tag("marker")
                }
                .labelsHidden().frame(width: 140)
                TextField("Filter URL, message, kind or detail…", text: $store.search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 350)
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
            HStack(spacing: 10) {
                Text(store.timelineCountText).monospacedDigit()
                if store.isLoadingTimeline { ProgressView().controlSize(.small) }
                if store.hasOlderEvents {
                    Button("Load 400 older matches") { Task { await store.loadOlderEvents() } }
                        .disabled(store.isBusy || store.isLoadingTimeline)
                }
                Spacer()
                Text("Filters search the full session. Displayed history stays while recording.")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.bottom, 8)
            HSplitView {
                eventList.frame(minWidth: 460)
                eventDetail.frame(minWidth: 290, idealWidth: 350)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(store.session?.isActive == true ? "Add a note at the current time. Selecting a row only opens its details." : "Start recording to add a time marker.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "bookmark").accessibilityHidden(true)
                    TextField("For example: Tapped the banner ad", text: $store.markerText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Marker note at the current time")
                        .help("Type a note while recording, then choose Add Marker or press Return. The marker uses the current time, not the selected row’s time.")
                        .onSubmit { Task { await store.addMarker() } }
                    Button("Add Marker") { Task { await store.addMarker() } }
                        .disabled(store.session?.isActive != true || store.isBusy || store.markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(markerHelp)
                        .accessibilityHint(markerHelp)
                }
                .disabled(store.session?.isActive != true)
            }
            .padding(12)
        }
    }

    private var markerHelp: String {
        if store.session?.isActive != true { return "Start recording to add a marker at the current time." }
        if store.isBusy { return "Wait for the current operation to finish, then add your note." }
        if store.markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Type a note first, such as Tapped the banner ad." }
        return "Add your note at the current time. Choose All Sources or Markers to see it in the timeline."
    }

    @ViewBuilder
    private var eventList: some View {
        if store.visibleEvents.isEmpty {
            ContentUnavailableView(store.isLoadingTimeline || !store.timelineMatchesFilters && store.session != nil ? "Loading timeline…" : (store.timeline?.totalCount ?? 0) > 0 ? "No matching events" : "No evidence yet", systemImage: "list.bullet.rectangle",
                description: Text(!store.search.isEmpty || store.sourceFilter != "all" ? "Filters search all captured events. Clear the filters to see other evidence." : (store.hasActiveCapture ? "Use the selected device and add markers while recording. A started collector is not proof of captured traffic." : "Select a device and capture sources, then start a session.")))
        } else {
            List(selection: $store.selectedEventID) {
                ForEach(store.visibleEvents) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: event.source == "network" ? "network" : (event.source == "marker" ? "bookmark.fill" : "text.alignleft"))
                            .foregroundStyle(event.source == "marker" ? Color.orange : Color.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(event.timestamp).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(event.source.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Text(event.summary).font(.system(.body, design: .monospaced)).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(event.id)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var eventDetail: some View {
        if let event = store.selectedEvent {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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
