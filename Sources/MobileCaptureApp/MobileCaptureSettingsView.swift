import SwiftUI

struct MobileCaptureSettingsView: View {
    @Bindable var store: CaptureStore
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"

    var body: some View {
        Form {
            Section("Saved Captures") {
                LabeledContent("Session Folder") {
                    Text(store.outputRoot.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                Button("Choose Folder…") { store.chooseOutputRoot() }
                    .disabled(store.hasActiveCapture || store.isBusy)
                Text("Existing sessions, certificates and iPhone tunnel profiles stay in their current locations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Development Build") {
                LabeledContent("Version", value: version)
                Text("Automatic updates are disabled. This app uses a provisional local development identity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 260)
    }
}
