import SwiftUI

/// Collection intent is separate from timeline display filters and network scope.
struct CaptureLogSettingsView: View {
    @Bindable var store: CaptureStore
    @State private var showAdvanced = false
    @State private var appSearch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.logScopeMode == .app {
                TextField("Find an installed app", text: $appSearch)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 560)
                    .accessibilityLabel("Find Installed App by Name or Identifier")
                HStack(spacing: 12) {
                    Picker("Application", selection: $store.targetApp) {
                        Text("Choose an installed app…").tag("")
                        ForEach(filteredApplications) { app in
                            Text(app.name == app.id ? app.id : "\(app.name) · \(app.id)").tag(app.id)
                        }
                        if !store.targetApp.isEmpty, !filteredApplications.contains(where: { $0.id == store.targetApp }) {
                            Text(store.selectedApplication?.name ?? store.targetApp).tag(store.targetApp)
                        }
                    }
                    .frame(maxWidth: 560)
                    Button("Refresh Apps", systemImage: "arrow.clockwise") {
                        Task { await store.refreshApplications() }
                    }
                    .disabled(store.isLoadingApplications)
                    if store.isLoadingApplications { ProgressView().controlSize(.small).accessibilityLabel("Loading installed apps") }
                    Spacer()
                }
                Text("Capture this app’s emitted logs, including SDK debug and info messages. Network capture can include other apps.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Whole-device logs can grow quickly and include activity from other apps.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let issue = store.logConfigurationIssue {
                Text(issue).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Advanced Logging", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    if store.logScopeMode == .app {
                        TextField("App identifier (manual)", text: $store.targetApp).textFieldStyle(.roundedBorder)
                        TextField("Related process names, separated by commas", text: $store.logHelpers).textFieldStyle(.roundedBorder)
                        TextField("Executable name (engineer override)", text: $store.logExecutableOverride).textFieldStyle(.roundedBorder)
                        Text("Only add verified process names. Shared system processes may include unrelated activity; missing helpers are disclosed in the package.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 16) {
                        limit("MB", value: $store.logLimitMB)
                        limit("records", value: $store.logLimitRecords)
                        limit("minutes", value: $store.logLimitMinutes)
                        Spacer()
                    }
                    Text("Logs stop at the first limit: up to 200 MB, 250,000 nonblank raw lines or 10 minutes. Network capture continues until Stop & Save. No captured log history is discarded.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Capture whole-device logs for the next recording", isOn: Binding(
                        get: { store.logScopeMode == .wholeDevice },
                        set: { store.logScopeMode = $0 ? .wholeDevice : .app }))
                    if let error = store.applicationDiscoveryError {
                        Text("Installed apps could not be loaded: \(error) You can enter a verified identifier above, or capture network only.")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.padding(.top, 8)
            }
            .font(.caption)
        }
        .disabled(store.hasActiveCapture || store.isBusy)
    }

    private var filteredApplications: [CaptureLogApplication] {
        let query = appSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.applications.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func limit(_ unit: String, value: Binding<Int>) -> some View {
        HStack(spacing: 5) {
            TextField(unit, value: value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: unit == "records" ? 100 : 60)
                .accessibilityLabel("Log limit in \(unit)")
            Text(unit).foregroundStyle(.secondary)
        }
    }
}

struct CaptureLogVolumeView: View {
    let store: CaptureStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let progress = store.deviceLogProgress {
                Text("Device logs: \(bytes(progress.persisted_bytes)) · \(progress.persisted_records.formatted()) records · \(Int(progress.elapsed_seconds)) seconds · \(bytes(Int64(Double(progress.persisted_bytes) / max(1, progress.elapsed_seconds))))/s average")
                if let reason = progress.completion_reason {
                    Label(reasonText(reason), systemImage: reason.isLimit ? "pause.circle" : "info.circle")
                        .foregroundStyle(reason.isLimit ? .orange : .secondary)
                } else if progress.persisted_records == 0, store.session?.isActive == true {
                    Text(store.session?.context?.value(for: "log_scope")?.value(for: "mode")?.stringValue == "whole_device"
                         ? "Waiting for device logs."
                         : "Waiting for app logs. Open the selected app to reproduce the issue.").foregroundStyle(.secondary)
                }
                if !progress.threshold_warnings.isEmpty, progress.completion_reason == nil {
                    Label("Approaching the device log limit. Network capture can continue after logs stop.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if store.session != nil {
                Text("Raw evidence: \(bytes(store.rawEvidenceBytes)) · Network files: \(bytes(store.networkEvidenceBytes)) · Timeline cache: \(bytes(store.timelineCacheBytes)) · Waiting to index: \(bytes(store.pendingTimelineBytes))")
                    .foregroundStyle(.secondary)
                if let available = store.availableDiskBytes {
                    Text("Available disk space: \(bytes(available)). Network bodies can grow beyond the device log limits.").foregroundStyle(.secondary)
                }
            }
            if let progress = store.saveProgress, store.isSaving, progress.stage == "finish_timeline",
               let indexed = progress.indexed_bytes, let remaining = progress.pending_bytes, indexed + remaining > 0 {
                ProgressView(value: Double(indexed), total: Double(indexed + remaining))
                    .frame(maxWidth: 350).accessibilityLabel("Finishing the saved timeline")
                Text("\(bytes(remaining)) left to index").foregroundStyle(.secondary)
            }
        }
        .font(.caption).textSelection(.enabled)
        .padding(.horizontal, 16).padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    private func reasonText(_ reason: CaptureLogCompletionReason) -> String {
        let stopped = switch reason {
        case .byteLimit: "Logs stopped at the byte limit."
        case .recordLimit: "Logs stopped at the record limit."
        case .durationLimit: "Logs stopped at the time limit."
        case .identityLost: "Log capture stopped because the app’s identity could no longer be verified."
        case .collectorFailure: "The log collector failed. Captured evidence is retained."
        case .writeFailure: "Logs stopped because evidence could not be written."
        case .collectorExit: "The log collector ended."
        case .userStop: "Device logs saved."
        }
        return stopped + (reason.isLimit && store.session?.isActive == true && store.session?.sources["network"] != "not_selected"
            ? " Network is still recording; choose Stop & Save when finished." : "")
    }
}
