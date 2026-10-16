import SwiftUI

struct MobileCaptureSettingsView: View {
    @Bindable var store: CaptureStore
    var showCapture: () -> Void
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"

    private let isDevelopment = Bundle.main.object(forInfoDictionaryKey: "MobileCaptureDevelopmentIdentity") as? Bool ?? true

    var body: some View {
        Form {
            Section("Devices") {
                Text("Set up a new phone once, or check the components used by this Mac.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Device Setup…", systemImage: "iphone") { store.showSetup(); showCapture() }
                    Button("Doctor…", systemImage: "stethoscope") { store.showDoctor(); showCapture() }
                }.disabled(store.hasActiveCapture || store.isBusy || store.doctor.isRepairing)
                Text("Phone certificate approval and iPhone full trust are completed on the phone. Setup includes a separate HTTPS connection check.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Saved Captures") {
                LabeledContent("Session Folder") {
                    Text(store.outputRoot.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                Button("Choose Folder…") { store.chooseOutputRoot() }
                    .disabled(store.hasActiveCapture || store.isBusy || store.doctor.isRepairing)
                Text("Existing sessions, certificates and iPhone tunnel profiles stay in their current locations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(isDevelopment ? "Development Build" : "Updates") {
                LabeledContent("Version", value: version)
                Text(isDevelopment ? "Automatic updates are disabled. This app uses a provisional local development identity." : "Automatic updates are disabled. Install reviewed builds from the project’s distribution instructions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 430)
    }
}
