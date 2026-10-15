import SwiftUI

struct CaptureCompanionSettingsSection: View {
    private var launcher = CaptureAppLauncher.shared

    var body: some View {
        Section {
            LabeledContent("Mobile Capture") {
                Text(launcher.selectedAppPath ?? "No companion found")
                    .lineLimit(2).truncationMode(.middle).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("Choose App…") { launcher.chooseApplication() }
                if launcher.hasExplicitSelection {
                    Button("Use Automatic Discovery") { launcher.useAutomaticDiscovery() }
                }
                Button("Refresh") { launcher.refreshAvailability() }
            }
            if let error = launcher.configurationError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: { Text("Capture Companion") }
        footer: {
            Text("Mobile Capture is optional and runs independently. Opening it can preselect the current device and app; recording starts only in the companion.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { launcher.refreshAvailability() }
    }
}
