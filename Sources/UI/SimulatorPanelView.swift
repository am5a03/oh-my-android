import AppKit
import SwiftUI

/// Only supported iOS capabilities are rendered; the Android feature grid remains Android-only.
struct SimulatorPanelView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var showSaved = false
    @State private var url = ""
    @State private var choosingBuild = false
    @FocusState private var linkFocused: Bool
    private var store: SimulatorStore { model.simulators }
    private var enabled: Bool { store.target != nil && !store.locksSelection && !choosingBuild }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let device = store.selected {
                        Text("iOS \(device.runtimeVersion) · \(device.state)").font(.caption2).foregroundStyle(.secondary)
                        if !device.isReady {
                            Text("Boot this Simulator to select an app.").font(.callout)
                            Button("Boot Simulator") { Task { await store.bootSelected() } }
                                .disabled(store.locksSelection || store.isLoading || !device.isAvailable)
                        } else {
                            appSection
                            if store.selectedApp != nil { linkSection }
                        }
                    } else if let id = store.selectedID {
                        Text("Selected Simulator unavailable").font(.headline)
                        Text("\(id)\nRefresh or choose another Simulator. No other device will be selected automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Choose an iOS Simulator").font(.headline)
                        Text("Select a device above. This panel requires full Xcode and an installed iOS runtime; it does not require an Android SDK.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.devices.isEmpty && !store.isLoading {
                        Text("No simulators listed? Add an iOS runtime and device in Xcode, then refresh.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = store.error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    } else if let notice = store.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let recovery = store.recoveryBuild {
                        Button("Show recovery build in Finder") { model.host.reveal(recovery) }
                            .font(.caption).help("A staged build was retained after a failed reinstall. Drag it onto the selected Simulator to retry installation.")
                    }
                    Divider()
                    Button("Show Simulator") { showSimulator() }
                        .disabled(store.simulatorApplication == nil)
                    Button("Reconnect Xcode tools") { Task { await store.refresh(reconnect: true) } }
                        .disabled(store.locksSelection || store.isLoading || choosingBuild)
                        .help("Re-read the Xcode selected in Xcode Settings → Locations → Command Line Tools.")
                    Text("Physical iPhones, UI automation, and Android-only settings are not included in this panel.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.scrollIndicators(.hidden)
        }
        .task(id: store.selectedID) { await store.refresh() }
        .onHover { inside in if inside { Task { await store.refreshIfStale() } } }
        .onChange(of: store.selectedID) { _, _ in resetEditor() }
        .onChange(of: store.selectedApp?.bundleID) { _, _ in resetEditor() }
        .sheet(item: Binding(get: { store.pending }, set: { if $0 == nil { store.cancelReinstall() } })) { request in
            reinstallConfirmation(request)
        }
        .onDisappear { store.cancelReinstall(); store.invalidateReads() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(store.devices) { device in
                    Button("\(device.title) — \(device.state)") { store.selectDevice(device.udid) }
                        .disabled(!device.isAvailable)
                }
                if store.devices.isEmpty { Text("No iOS Simulators") }
            } label: {
                Label(store.selected?.name ?? "Choose Simulator…", systemImage: "iphone")
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(store.locksSelection || choosingBuild)
            .help(store.selected?.title ?? "Select a specific Simulator")
            if store.isLoading || store.isBusy || choosingBuild {
                ProgressView().controlSize(.mini)
            } else {
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh simulators and apps").disabled(store.pending != nil)
            }
            Button { model.isPinned.toggle() } label: { Image(systemName: model.isPinned ? "pin.fill" : "pin.slash") }
                .help("Pin or unpin the companion panel")
        }.buttonStyle(.glass).controlSize(.small)
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SELECTED APP").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Button { showPicker = true } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.selectedApp?.name ?? "Choose an app…").font(.callout.weight(.medium)).lineLimit(1)
                    if let id = store.rememberedAppID { Text(id).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.glass).disabled(store.locksSelection || store.isLoading || choosingBuild)
            .popover(isPresented: $showPicker, arrowEdge: .trailing) { SimulatorAppPicker(isPresented: $showPicker) }
            if store.rememberedAppID != nil && store.selectedApp == nil && !store.isLoading {
                Text("The selected app is not installed. Install its Simulator build with Xcode or drag the .app onto Simulator, then refresh.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button("Launch") { Task { await store.perform(.launch) } }
                Button("Restart") { Task { await store.perform(.restart) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Stop") { Task { await store.perform(.forceStop) } }
            }.buttonStyle(.glass).controlSize(.small).disabled(!enabled)
            Menu("Reinstall app…") {
                Button("Choose .app and reinstall…", role: .destructive) { chooseBuild(launchAfter: false) }
                Button("Choose .app, reinstall and launch…", role: .destructive) { chooseBuild(launchAfter: true) }
                if let previous = store.previousBuild {
                    Divider()
                    Button("Reinstall from previous build…", role: .destructive) {
                        Task { await store.prepareReinstall(source: previous, launchAfter: false) }
                    }
                }
            }
            .disabled(!enabled || store.selectedApp?.isUserApp != true)
            .help("Validates and stages a Simulator build before asking to uninstall. System apps are excluded.")
            Text("Reinstall removes the app first. Keychain, shared containers, and server data may remain.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("DEEP LINK").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            TextField("myapp://path", text: $url)
                .textFieldStyle(.roundedBorder).font(.caption).focused($linkFocused)
                .onSubmit { send(stopFirst: false) }.disabled(!enabled)
            HStack {
                Button("Open") { send(stopFirst: false) }
                Menu {
                    Button("Stop selected app, then open") { send(stopFirst: true) }
                } label: { Image(systemName: "chevron.down") }
                Spacer(minLength: 0)
            }.controlSize(.small).disabled(!enabled || url.trimmed.isEmpty)
            Text("System routing: iOS chooses the receiver. Stopping the selected app does not force the URL into that app.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Saved…") { showSaved = true }
                Menu("Recent") {
                    if let app = store.selectedApp {
                        ForEach(model.links.recent(for: app.linkStorageKey)) { link in
                            Button(link.url) { url = link.url }
                        }
                        Divider()
                        Button("Clear history", role: .destructive) { model.links.clearRecent(for: app.linkStorageKey) }
                    }
                }
                Button("Focus deep link") { linkFocused = true }
                    .keyboardShortcut("l", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }.font(.caption).disabled(!enabled)
        }
        .popover(isPresented: $showSaved, arrowEdge: .trailing) {
            if let app = store.selectedApp {
                SimulatorSavedLinksView(app: app, currentURL: url) { link in url = link; showSaved = false }
            }
        }
    }

    private func reinstallConfirmation(_ request: PreparedSimulatorReinstall) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reinstall \(request.target.app.name)?").font(.headline)
            Text("\(request.target.app.bundleID)\n\(request.target.device.title)\n\(request.target.device.udid)")
                .font(.callout).textSelection(.enabled)
            Text("Build: \(request.source.path)").font(.caption).textSelection(.enabled)
            Text("A copy of this build has been staged. The app will be uninstalled, deleting its local app container, then installed again. This cannot be undone. Keychain, shared containers, and server data may remain.")
            if request.launchAfter { Text("The app will launch after installation.").font(.caption) }
            HStack {
                Button("Cancel", role: .cancel) { store.cancelReinstall() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Reinstall", role: .destructive) { Task { await store.confirmReinstall(request.id) } }
            }
        }.padding(20).frame(width: 400)
    }

    private func chooseBuild(launchAfter: Bool) {
        guard enabled, let target = store.target else { return }
        choosingBuild = true
        Task {
            defer { choosingBuild = false }
            guard let file = await model.host.chooseFile("app", "Choose a Simulator build of \(target.app.bundleID)"),
                  model.platform == .iosSimulator, store.target == target else { return }
            await store.prepareReinstall(source: file, launchAfter: launchAfter)
        }
    }

    private func showSimulator() {
        guard let app = store.simulatorApplication else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private func send(stopFirst: Bool) {
        guard enabled else { return }
        let value = url
        Task { await store.send(value, stopFirst: stopFirst, links: model.links) }
    }

    private func resetEditor() { url = ""; showSaved = false; showPicker = false }
}

private struct SimulatorAppPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    @State private var query = ""
    var body: some View {
        @Bindable var store = model.simulators
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose iOS app").font(.headline)
            TextField("Search app name or bundle identifier", text: $query).textFieldStyle(.roundedBorder)
            Toggle("Show system apps", isOn: $store.includeSystem).font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.listedApps(matching: query)) { app in
                        Button {
                            store.selectApp(app.bundleID)
                            isPresented = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(app.name)
                                    Text(app.bundleID).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if app.bundleID == store.selectedApp?.bundleID { Image(systemName: "checkmark") }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 250)
            Text("Recent selections appear first. App names come from Simulator metadata.").font(.caption2).foregroundStyle(.secondary)
        }.padding(14).frame(width: 360).disabled(store.locksSelection || store.isLoading)
    }
}

private struct SimulatorSavedLinksView: View {
    @Environment(AppModel.self) private var model
    let app: SimulatorApp
    let currentURL: String
    let choose: (String) -> Void
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        @Bindable var links = model.links
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved iOS links · \(app.name)").font(.headline)
            HStack {
                TextField("Name for current URL", text: $name).textFieldStyle(.roundedBorder)
                Button("Save") {
                    do {
                        try links.save(name: name, url: currentURL, routing: .system, for: app.linkStorageKey)
                        name = ""; error = nil
                    } catch { self.error = error.localizedDescription }
                }.disabled(name.trimmed.isEmpty || currentURL.trimmed.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(links.saved(for: app.linkStorageKey)) { link in
                        HStack {
                            Button { choose(link.url) } label: {
                                VStack(alignment: .leading) {
                                    Text(link.name)
                                    Text(link.url).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Button(role: .destructive) { links.remove(link.id, for: app.linkStorageKey) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                        }
                    }
                }
            }.frame(maxHeight: 200)
            Toggle("Remember successful links", isOn: $links.remembersHistory).font(.caption)
            Button("Clear recent history") { links.clearRecent(for: app.linkStorageKey) }.font(.caption)
            Text("Stored locally, not encrypted. Avoid saving tokens. Selecting a link fills the field; Open sends it.")
                .font(.caption2).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(14).frame(width: 360)
    }
}
