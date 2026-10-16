import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

/// A private, local setup guide. Tunnel keys never enter the timeline or evidence package.
struct IPhoneCaptureSetupView: View {
    let configuration: IPhoneTunnelConfiguration
    let isRecording: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: CGImage?
    @State private var qrUnavailable = false
    @State private var saveNotice: String?
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up iPhone Capture")
                    .font(.title2.weight(.semibold))
                Text("Keep iPhone connected by USB for logs. Network capture uses a Wi-Fi tunnel.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    step(1, title: "Add the Capture Tunnel") {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                tunnelQRCode
                                importInstructions.frame(minWidth: 250, maxWidth: .infinity, alignment: .leading)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                importInstructions
                                tunnelQRCode.frame(maxWidth: .infinity)
                            }
                        }
                    }

                    step(2, title: "Start Capture, Then Turn On the Tunnel") {
                        Text("Connect iPhone and this Mac to the same reachable Wi-Fi network.")
                        Text(isRecording
                             ? "The Mac is recording. Turn this tunnel on in WireGuard on iPhone."
                             : "Click Done, then Start Capture on the Mac. After recording starts, turn this tunnel on in WireGuard on iPhone.")
                        LabeledContent("Mac endpoint") {
                            Text(verbatim: "\(configuration.endpointHost):\(configuration.port)")
                                .monospacedDigit()
                                .textSelection(.enabled)
                        }
                        .foregroundStyle(.secondary)
                        Label(isRecording ? "Recording on Mac" : "Not Recording — Keep the Tunnel Off",
                              systemImage: isRecording ? "record.circle" : "pause.circle")
                            .font(.callout.weight(.medium))
                    }

                    step(3, title: "Trust the Capture Certificate Once") {
                        Text("With the tunnel on, open **http://mitm.it** in Safari on iPhone and download the **Apple** certificate profile.")
                        Text("Install it in **Settings → General → VPN & Device Management**. Then enable full trust in **Settings → General → About → Certificate Trust Settings**.")
                        Text("Previously installed certificates can also be named mitmproxy. Enable trust for the certificate you just downloaded through this capture.")
                            .foregroundStyle(.secondary)
                        Text("This allows the Mac to read HTTPS requests and responses during capture.")
                            .foregroundStyle(.secondary)
                    }

                    step(4, title: "Turn Off the Tunnel Before Stopping") {
                        Text("Turn this tunnel off in WireGuard on iPhone, then click **Stop & Save** on the Mac. The Mac asks you to confirm the tunnel is off.")
                    }

                    Divider()
                    Text("This version captures IPv4 traffic; IPv6 may bypass capture. Certificate pinning can prevent HTTPS decoding, and iOS may redact private log values.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .font(.body)
        .frame(minWidth: 560, idealWidth: 680, maxWidth: 760, minHeight: 480, idealHeight: 740, maxHeight: 840)
        .task { loadQRCode() }
    }

    private var importInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("In **WireGuard** on iPhone, choose **Add Tunnel → Create from QR Code**, scan this code, and name the tunnel **Mobile Capture**.")
            Button("Save Tunnel Profile…", systemImage: "square.and.arrow.down") { saveTunnelProfile() }
                .help("Save a private .conf file to import into WireGuard instead of scanning the QR code.")
            Text("Keep this QR code and saved profile private. They contain a key to the capture tunnel.")
                .foregroundStyle(.secondary)
            if let saveNotice {
                Label(saveNotice, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var tunnelQRCode: some View {
        Group {
            if let qrImage {
                Image(decorative: qrImage, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 192, height: 192)
                    .padding(12)
                    .background(.white)
                    .accessibilityLabel("Private capture tunnel QR code. Scan with WireGuard on iPhone.")
            } else if qrUnavailable {
                ContentUnavailableView("QR Code Unavailable", systemImage: "qrcode",
                    description: Text("Save the tunnel profile and import it in WireGuard on iPhone."))
                    .frame(width: 216, height: 216)
            } else {
                ProgressView("Preparing QR Code…")
                    .frame(width: 216, height: 216)
            }
        }
    }

    private func step<Content: View>(_ number: Int, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted())
                .font(.headline.monospacedDigit())
                .frame(width: 26, height: 26)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loadQRCode() {
        do {
            let data = try Data(contentsOf: configuration.clientProfile)
            guard !data.isEmpty, data.count <= 65_536 else { throw AppError("The tunnel profile is unavailable.") }
            let filter = CIFilter.qrCodeGenerator()
            filter.message = data
            filter.correctionLevel = "M"
            guard let output = filter.outputImage else { throw AppError("The tunnel QR code could not be created.") }
            let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
            guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else {
                throw AppError("The tunnel QR code could not be created.")
            }
            qrImage = image
            qrUnavailable = false
        } catch {
            qrImage = nil
            qrUnavailable = true
        }
    }

    private func saveTunnelProfile() {
        let panel = NSSavePanel()
        panel.title = "Save Tunnel Profile"
        panel.prompt = "Save Profile"
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .data]
        panel.nameFieldStringValue = "MobileCapture.conf"
        panel.message = "This profile contains a private tunnel key. Save it locally and share it only with the iPhone being captured."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try IPhoneCaptureSetup.exportClientProfile(configuration, to: destination)
            saveError = nil
            saveNotice = "Tunnel profile saved."
        } catch {
            saveNotice = nil
            saveError = "Could not save the tunnel profile. Choose another local folder and try again."
        }
    }
}
