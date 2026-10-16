import Foundation

/// Explicit collection intent. A missing app scope never means permission to collect the whole device.
nonisolated struct CaptureLogScope: Codable, Sendable, Equatable {
    enum Mode: String, Codable, Sendable { case app; case wholeDevice = "whole_device" }
    var mode: Mode = .app
    var applicationID: String? = nil
    var helperProcessNames: [String] = []
    /// Engineer-provided executable identity, used when installed tooling cannot expose it.
    var executableOverride: String? = nil

    enum CodingKeys: String, CodingKey {
        case mode
        case applicationID = "application_id"
        case helperProcessNames = "helper_process_names"
        case executableOverride = "executable_override"
    }
}

extension CaptureLogScope {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .app
        applicationID = try values.decodeIfPresent(String.self, forKey: .applicationID)
        helperProcessNames = try values.decodeIfPresent([String].self, forKey: .helperProcessNames) ?? []
        executableOverride = try values.decodeIfPresent(String.self, forKey: .executableOverride)
    }
}

nonisolated struct CaptureLogApplication: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let platform: String
    var executable: String? = nil
    var relatedProcessNames: [String] = []
    var resolution: String = "installed application metadata"
    var executableIsAmbiguous = false
}

/// Private worker configuration; contains executable paths and identity, never captured messages.
nonisolated struct CaptureLogFilterConfiguration: Codable, Sendable, Equatable {
    enum Strategy: String, Codable, Sendable { case androidUID = "android_uid"; case androidProcessMap = "android_process_map" }
    let strategy: Strategy
    let deviceID: String
    let applicationID: String
    let adbPath: String
    let androidUserID: Int
    let androidUID: Int
    let installIdentity: String
    var helperProcessNames: [String] = []
}

nonisolated struct CaptureResolvedLogScope: Sendable {
    let command: [String]
    /// Portable JSON for context.log_scope, separate from runtime-only filter configuration.
    let contextJSON: Data
    let filter: CaptureLogFilterConfiguration?
}
