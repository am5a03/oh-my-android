import Foundation

/// Small shared contract. Platform-specific reset semantics deliberately remain outside it.
protocol AppControlling: Sendable {
    associatedtype Target: Sendable
    func perform(_ action: AppAction, target: Target) async throws -> String
}


enum CompanionPlatform: String, CaseIterable, Identifiable {
    case android, iosSimulator
    var id: String { rawValue }
    var title: String { self == .android ? "Android" : "iOS Simulator" }
}
