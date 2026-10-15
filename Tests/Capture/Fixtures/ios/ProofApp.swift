import CryptoKit
import Foundation
import UIKit
import os

/// A neutral Simulator or iPhone fixture. Launch environment supplies a public URL and proof nonce.
@main
@MainActor
final class ProofApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let logger = Logger(subsystem: "dev.mobilecapture.proof", category: "CaptureProof")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let controller = UIViewController()
        let label = UILabel()
        label.numberOfLines = 0
        label.text = "Mobile capture proof\nPreparing a neutral HTTPS POST…"
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.backgroundColor = .systemBackground
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)
        ])
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        Task { await prove(label: label) }
        return true
    }

    private func prove(label: UILabel) async {
        let environment = ProcessInfo.processInfo.environment
        let nonce = environment["CAPTURE_PROOF_NONCE"] ?? UUID().uuidString
        let endpoint = environment["CAPTURE_PROOF_URL"] ?? "https://httpbingo.org/anything"
        logger.notice("proof-start nonce=\(nonce, privacy: .public)")
        logger.debug("proof-debug nonce=\(nonce, privacy: .public) Unicode=café 東京 🚀")
        logger.info("proof-info nonce=\(nonce, privacy: .public)")
        do {
            guard let url = URL(string: endpoint), url.scheme == "https" else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: url, timeoutInterval: 25)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            #if targetEnvironment(simulator)
            let platform = "simulator"
            #else
            let platform = "iphone"
            #endif
            request.httpBody = try JSONSerialization.data(withJSONObject: ["capture_proof": nonce, "platform": platform], options: [.sortedKeys])
            let (data, response) = try await URLSession.shared.data(for: request)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let result = "proof-response nonce=\(nonce) status=\((response as? HTTPURLResponse)?.statusCode ?? 0) bytes=\(data.count) sha256=\(digest)"
            logger.notice("\(result, privacy: .public)")
            label.text = "Mobile capture proof\n" + result
        } catch {
            let result = "proof-error nonce=\(nonce) \(error.localizedDescription)"
            logger.error("\(result, privacy: .public)")
            label.text = result
        }
    }
}
