import SwiftUI

/// The everyday workflow stays above the original feature grid, inside its existing scroll view.
struct AppQuickActionsView: View {
    let context: DeviceContext
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var showSaved = false
    @State private var url = ""
    @State private var routing = LinkRouting.selectedApp
    @FocusState private var linkFocused: Bool

    private var apps: AppSelectionStore { model.apps }
    private var enabled: Bool { apps.target(on: context.device) != nil && !apps.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SELECTED APP").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if apps.isLoading || apps.isBusy { ProgressView().controlSize(.mini) }
                Button { Task { await apps.refresh(on: context.device) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(apps.isLoading || apps.isBusy)
                .help("Refresh installed apps")
            }
            Button { showPicker = true } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(apps.selected?.displayName ?? "Choose an app…").font(.callout.weight(.medium)).lineLimit(1)
                        if let app = apps.selected, app.name != "" {
                            Text(app.package).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.glass)
            .disabled(apps.isBusy)
            .popover(isPresented: $showPicker, arrowEdge: .trailing) {
                AppPickerView(device: context.device, isPresented: $showPicker)
            }
            if apps.selected != nil && !apps.selectedIsInstalled && !apps.isLoading {
                Text("Selected app is missing or hidden by the system-app filter.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            HStack(spacing: 5) {
                Button("Launch") { apps.request(.launch, on: context.device) }
                Button("Restart") { apps.request(.restart, on: context.device) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Menu("Clear…") {
                    Button("Clear data…", role: .destructive) { apps.request(.clearData, on: context.device) }
                    Button("Clear data and launch…", role: .destructive) { apps.request(.clearAndLaunch, on: context.device) }
                }
                .help("Clear only the selected app's data")
            }
            .font(.caption)
            .controlSize(.small)
            .buttonStyle(.glass)
            .disabled(!enabled)

            Divider()
            Text("DEEP LINK").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            TextField("myapp://path", text: $url)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($linkFocused)
                .onSubmit { send(stopFirst: false) }
                .disabled(!enabled)
            HStack(spacing: 4) {
                Picker("Routing", selection: $routing) {
                    ForEach(LinkRouting.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                Menu {
                    Button("Stop app, then open") { send(stopFirst: true) }
                } label: {
                    Text("Open")
                } primaryAction: {
                    send(stopFirst: false)
                }
            }
            .controlSize(.small)
            .disabled(!enabled || url.trimmed.isEmpty)
            HStack {
                Button("Saved…") { showSaved = true }
                    .popover(isPresented: $showSaved, arrowEdge: .trailing) {
                        if let app = apps.selected {
                            SavedLinksView(package: app.package, currentURL: url, routing: routing) { link in
                                url = link.url
                                routing = link.routing
                                showSaved = false
                            }
                        }
                    }
                Menu("Recent") {
                    if let app = apps.selected {
                        ForEach(model.links.recent(for: app.package)) { link in
                            Button("\(link.routing.title): \(link.url)") { url = link.url; routing = link.routing }
                        }
                        Divider()
                        Button("Clear history", role: .destructive) { model.links.clearRecent(for: app.package) }
                    }
                }
                Spacer(minLength: 0)
                // A hidden command button provides a panel-local shortcut, not a global hotkey.
                Button("Focus deep link") { linkFocused = true }
                    .keyboardShortcut("l", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
            .font(.caption).buttonStyle(.borderless).disabled(!enabled)
            if let error = apps.error {
                Text(error).font(.caption2).foregroundStyle(.red).textSelection(.enabled)
            } else if let notice = apps.notice {
                Text(notice).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .onChange(of: apps.selected?.package) { _, _ in
            url = ""; routing = .selectedApp; showSaved = false
        }
    }

    private func send(stopFirst: Bool) {
        guard enabled else { return }
        apps.send(url, routing: routing, stopFirst: stopFirst, on: context.device, links: model.links)
    }
}

private struct AppPickerView: View {
    let device: Device
    @Binding var isPresented: Bool
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var name = ""

    var body: some View {
        @Bindable var apps = model.apps
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose app").font(.headline)
            TextField("Search package or local display name", text: $query).textFieldStyle(.roundedBorder)
            HStack {
                Toggle("Show system apps", isOn: $apps.includeSystem)
                    .onChange(of: apps.includeSystem) { _, _ in Task { await apps.refresh(on: device) } }
                Spacer()
                Button("Use foreground") {
                    Task { await apps.useForeground(on: device); name = apps.selected?.name ?? "" }
                }
                .disabled(apps.isLoading)
            }.font(.caption)
            if let user = apps.userID {
                Text("Android user \(user) · Recently selected apps appear first.").font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(apps.listedApps(matching: query)) { app in
                        Button {
                            apps.select(app.package)
                            isPresented = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.displayName).lineLimit(1)
                                    if !app.name.isEmpty { Text(app.package).font(.caption2).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if app.package == apps.selected?.package { Image(systemName: "checkmark") }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 250)
            if apps.selected != nil {
                Divider()
                Text("Local display name for selected app").font(.caption)
                HStack {
                    TextField("Optional friendly name", text: $name).textFieldStyle(.roundedBorder)
                        .onSubmit { apps.renameSelected(name) }
                    Button("Save") { apps.renameSelected(name) }
                }
            }
            Text("Names are optional local aliases. No APK download or extra Android helper app is required.")
                .font(.caption2).foregroundStyle(.secondary)
            if let error = apps.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(14).frame(width: 360)
        .onAppear { name = apps.selected?.name ?? "" }
        .disabled(apps.isBusy)
    }
}

private struct SavedLinksView: View {
    let package: String
    let currentURL: String
    let routing: LinkRouting
    let choose: (SavedDeepLink) -> Void
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        @Bindable var links = model.links
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved links").font(.headline)
            Text(package).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Name for current URL", text: $name).textFieldStyle(.roundedBorder)
                Button("Save") {
                    do { try links.save(name: name, url: currentURL, routing: routing, for: package); name = ""; error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(currentURL.trimmed.isEmpty || name.trimmed.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(links.saved(for: package)) { link in
                        HStack {
                            Button { choose(link) } label: {
                                VStack(alignment: .leading) {
                                    Text(link.name)
                                    Text("\(link.routing.title) · \(link.url)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Button(role: .destructive) { links.remove(link.id, for: package) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless).help("Delete saved link")
                        }
                    }
                }
            }.frame(maxHeight: 200)
            Toggle("Remember successful links in recent history", isOn: $links.remembersHistory).font(.caption)
            Button("Clear recent history for this app") { links.clearRecent(for: package) }.font(.caption)
            Text("Stored locally in preferences, not encrypted. Avoid saving URLs containing tokens. Choosing a saved link fills the field; Open sends it.")
                .font(.caption2).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(14).frame(width: 360)
    }
}

/// Attach to the non-lazy scroll container so confirmations also work from lower grid rows.
struct AppActionConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onChange(of: model.apps.pending?.id) { _, id in isPresented = id != nil }
            .confirmationDialog("Confirm app action", isPresented: $isPresented, titleVisibility: .visible, presenting: model.apps.pending) { request in
                Button(request.action.title, role: .destructive) {
                    guard let selected = model.devices?.selected,
                          selected.serial == request.target.device.serial,
                          selected.appSelectionKey == request.target.device.appSelectionKey else {
                        model.apps.pending = nil
                        return
                    }
                    model.apps.confirm(request)
                }
                Button("Cancel", role: .cancel) { model.apps.pending = nil }
            } message: { request in
                Text("\(request.action.title) for \(request.target.app.displayName)?\n\(request.target.app.package)\nDevice: \(request.target.device.displayName)\nAndroid user: \(request.target.userID)\n\n\(request.action.warning)")
            }
            .onDisappear { model.apps.pending = nil }
    }
}
