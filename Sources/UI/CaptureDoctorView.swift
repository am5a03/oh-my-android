import AppKit
import SwiftUI

/// Component checks remain read only. Installing Mac software always has a separate preview.
struct CaptureDoctorView: View {
    @Bindable var store: CaptureStore
    @Bindable var doctor: CaptureDoctorStore
    @State private var showDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Doctor").font(.largeTitle.weight(.semibold))
                        Text("Check the components this Mac needs to capture from your device.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Back to Capture", systemImage: "list.bullet.rectangle") { store.dismissDoctor() }
                        .disabled(doctor.isRepairing)
                }
                HStack(spacing: 12) {
                    Text(store.selectedDevice.map { "\($0.name) · \($0.platformName)" } ?? "Connect a device to check its capture components.")
                    Spacer()
                    Button("Check Again", systemImage: "arrow.clockwise") {
                        Task {
                            await store.refreshDevices(includeApplications: false)
                            store.setup.selectOnlyReadyDevice(store)
                            await doctor.refresh(store, force: true)
                            await store.setup.inspect(store)
                        }
                    }.disabled(doctor.hasOperation || store.isBusy)
                }
                if store.selectedDevice == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Device Type", selection: Binding(get: { doctor.deviceType }, set: { doctor.selectDeviceType($0, owner: store) })) {
                            ForEach(CaptureDoctorStore.DeviceType.allCases) { type in Text(type.title).tag(type) }
                        }.frame(maxWidth: 320)
                            .disabled(doctor.hasOperation || store.hasActiveCapture || store.isBusy)
                        Text("Check tools for a phone that is not detected yet. This does not select or connect a capture device.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if doctor.isChecking || doctor.isPreparingPreview {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(doctor.isChecking ? "Checking Components…" : "Preparing Repair Details…")
                    }.accessibilityElement(children: .combine)
                }
                if let error = doctor.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                }
                if let notice = doctor.notice { Label(notice, systemImage: "info.circle").foregroundStyle(.secondary) }
                if doctor.isRepairing {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(doctor.progressMessage ?? "Installing Components…").font(.headline)
                            }
                            Text("Keep Mobile Capture open until installation finishes or cancellation completes.")
                                .foregroundStyle(.secondary)
                            Button(doctor.isCancelling ? "Cancelling…" : "Cancel Installation", role: .cancel) { doctor.cancelRepair() }
                                .disabled(doctor.isCancelling)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                } else if let preview = doctor.preview {
                    repairPreview(preview)
                }
                if let report = doctor.report {
                    VStack(spacing: 0) {
                        ForEach(Array(report.rows.enumerated()), id: \.element.id) { index, row in
                            if index != 0 { Divider() }
                            component(row)
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    Text("Checked \(report.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup("Technical Details", isExpanded: $showDetails) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(report.rows) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.title).font(.callout.weight(.semibold))
                                    if let version = row.version { Text("Version: \(version)") }
                                    Text("Source: \(row.source.rawValue)")
                                    if let path = row.path { Text(path).font(.callout.monospaced()).textSelection(.enabled) }
                                }
                            }
                            if !doctor.output.isEmpty {
                                Text("Latest Installation Output").font(.callout.weight(.semibold))
                                ScrollView { Text(doctor.output).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                    .frame(maxHeight: 180)
                            }
                        }.padding(.top, 10)
                    }
                }
                GroupBox("Phone Setup") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(store.selectedDevice?.isReady == true ? "Device Available" : "Connect and Unlock Your Device",
                              systemImage: store.selectedDevice?.isReady == true ? "checkmark.circle" : "cable.connector")
                        Text("Component checks cannot inspect the phone’s certificate-trust switch. Device Setup guides installation and runs a separate HTTPS connection check.")
                            .foregroundStyle(.secondary)
                        ForEach(phoneChecks) { check in
                            VStack(alignment: .leading, spacing: 4) {
                                Label("\(check.title) · \(phoneStateTitle(check.state))", systemImage: check.state == .verified || check.state == .readyToTry ? "checkmark.circle" : "info.circle")
                                    .font(.callout.weight(.medium))
                                Text(check.message).font(.callout).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                        }
                        Button("Device Setup…", systemImage: "iphone") { store.dismissDoctor(); store.showSetup() }
                            .disabled(doctor.isRepairing || store.hasActiveCapture || store.isBusy)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                Text("Checking does not install software or change your phone connection. Bundled tools are preferred; Homebrew is an optional repair route for supported external tools.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 820, alignment: .leading).padding(28)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task { await doctor.refresh(store); await store.setup.inspect(store) }
        .onChange(of: doctor.configurationKey(store)) {
            doctor.dismissPreview()
            Task { await doctor.refresh(store); await store.setup.inspect(store) }
        }
    }

    private func component(_ row: CaptureDoctorCheck) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: statusSymbol(row.status)).foregroundStyle(statusColor(row.status))
                .font(.title3).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.title).font(.headline)
                Text(statusTitle(row.status)).font(.callout.weight(.medium)).foregroundStyle(statusColor(row.status))
                Text(row.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if let version = row.version { Text("Version \(version)").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let repair = row.repair {
                Button(repair == .chooseOutputFolder ? "Choose Folder…" : "Fix…") {
                    if repair == .chooseOutputFolder {
                        store.chooseOutputRoot()
                        Task { await doctor.refresh(store) }
                    } else { Task { await doctor.prepareRepair(repair, owner: store) } }
                }.disabled(doctor.hasOperation || store.hasActiveCapture || store.isBusy)
                    .accessibilityLabel("Fix \(row.title)")
            }
        }.padding(.vertical, 16).accessibilityElement(children: .contain)
    }

    private func repairPreview(_ preview: CaptureDoctorRepairPreview) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(preview.title).font(.title3.weight(.semibold))
                Text(preview.message)
                if !preview.packages.isEmpty {
                    Text("Mac software to install: \(preview.packages.joined(separator: ", ")).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    if preview.canRun {
                        Button("Install with Homebrew", systemImage: "arrow.down.circle") { doctor.beginRepair(store) }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.hasActiveCapture || store.isBusy)
                    }
                    if let url = preview.instructionsURL { Link("Open Official Instructions", destination: url) }
                    Button("Cancel", role: .cancel) { doctor.dismissPreview() }
                }
                if !preview.canRun {
                    Text("Complete the official steps, return here, then choose Check Again. Mobile Capture will not request your password or change macOS security settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func statusTitle(_ status: CaptureDoctorStatus) -> String {
        switch status {
        case .ready: "Ready"
        case .needsAction: "Needs Action"
        case .missing: "Missing"
        case .incompatible: "Incompatible"
        }
    }

    private var phoneChecks: [CaptureSetupCheck] {
        let ids = store.captureNetwork
            ? ["device", "certificate", "iphone_profile", "routing_owner", "device_routing", "https"]
            : ["device", "routing_owner"]
        return store.setup.report?.checks.filter { ids.contains($0.id) } ?? []
    }

    private func phoneStateTitle(_ state: CaptureSetupState) -> String {
        switch state {
        case .checking: "Checking"
        case .actionNeeded: "Needs Action"
        case .readyToTry: "Ready to Try"
        case .verified: "Verified"
        case .unavailable: "Unavailable"
        case .needsEngineerHelp: "Needs Engineer Help"
        case .waitingForAppActivity: "Waiting for App Activity"
        case .unverified: "Not Verified"
        case .notRequested: "Not Requested"
        }
    }

    private func statusSymbol(_ status: CaptureDoctorStatus) -> String {
        switch status {
        case .ready: "checkmark.circle"
        case .needsAction: "hand.point.up.left"
        case .missing, .incompatible: "exclamationmark.triangle"
        }
    }

    private func statusColor(_ status: CaptureDoctorStatus) -> Color {
        status == .ready ? .green : status == .needsAction ? .secondary : .orange
    }
}
