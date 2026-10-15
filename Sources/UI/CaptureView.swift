import AppKit
import SwiftUI

struct CaptureView: View {
    @Bindable var store: CaptureStore
    @State private var showRuntimeSettings = false

    var body: some View {
        VStack(spacing: 0) {
            setup
            Divider()
            sessionStatus
            if let error = store.error { notice(error, symbol: "exclamationmark.triangle.fill", color: .red) }
            if let session = store.session {
                ForEach(Array(session.warnings.enumerated()), id: \.offset) { _, warning in
                    notice(warning, symbol: "exclamationmark.triangle", color: .orange)
                }
                if session.platform == "android", session.caCertificatePath != nil {
                    HStack {
                        Button("Reveal Capture CA Certificate…") { store.revealCaptureCertificate() }
                        Text("Install this public CA on the device. The test app must also trust it.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                }
                if session.routingRestored == false {
                    notice("Network routing has not been restored. Follow the session warning before disconnecting.", symbol: "network.slash", color: .red)
                }
                if session.needsPackageRetry, !store.hasActiveCapture {
                    notice("The ZIP is not available. Use Retry Save to package the existing capture evidence.", symbol: "archivebox", color: .orange)
                }
            }
            Divider()
            timeline
            Divider()
            footer
        }
        .frame(minWidth: 960, minHeight: 680)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await store.openSession() } } label: { Label("Open Session…", systemImage: "folder") }
                    .disabled(store.hasActiveCapture || store.isBusy)
                if store.hasActiveCapture {
                    Button { Task { await store.stop() } } label: {
                        Label(store.session?.needsRoutingRecovery == true && store.session?.isActive == false ? "Retry Cleanup & Save" : "Stop & Save", systemImage: "stop.circle.fill")
                    }
                        .disabled(store.isBusy)
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    if store.session?.needsPackageRetry == true {
                        Button { Task { await store.stop() } } label: { Label("Retry Save", systemImage: "arrow.clockwise") }
                            .disabled(store.isBusy)
                    }
                    Button { Task { await store.start() } } label: { Label("Start Capture", systemImage: "record.circle") }
                        .disabled(!store.canStart)
                }
                Button { store.revealPackage() } label: { Label("Reveal ZIP", systemImage: "folder") }
                    .disabled(store.session?.packagePath == nil)
                Button { store.exportPackage() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .disabled(store.session?.packagePath == nil)
            }
            ToolbarItem(placement: .status) {
                if store.isBusy { ProgressView().controlSize(.small) }
            }
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
                Text(store.isStarting ? "Preparing capture…" : (store.session?.phase.capitalized ?? "Ready to prepare")).font(.headline)
                Text(store.activeTargetName).font(.caption).foregroundStyle(.secondary)
                if let session = store.session {
                    Text(session.directory).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help("Open this session folder to recover or inspect the capture after relaunching the app.")
                }
            }
            Spacer()
            sourceStatus("Logs", source: "logs")
            sourceStatus("Network", source: "network")
            if let session = store.session {
                Text("\(session.counts["markers", default: 0]) markers").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func sourceStatus(_ title: String, source: String) -> some View {
        let status = store.session?.sources[source] ?? "not_selected"
        let color: Color = status == "observed" ? .green : (["failed", "interrupted", "tls_failed"].contains(status) ? .red : (status == "started" ? .blue : .secondary))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text("\(title): \(status.replacingOccurrences(of: "_", with: " "))")
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
            HStack(spacing: 8) {
                Image(systemName: "bookmark")
                TextField("Mark an action, placement or reproduction step…", text: $store.markerText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.addMarker() } }
                Button("Add Marker") { Task { await store.addMarker() } }
                    .disabled(store.session?.isActive != true || store.isBusy || store.markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(store.session?.isActive != true)
            .padding(12)
        }
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
