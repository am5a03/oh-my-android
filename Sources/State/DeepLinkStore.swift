import Foundation
import Observation

/// Local-only preferences. URLs may contain secrets: history can be disabled or cleared per app.
@MainActor
@Observable
final class DeepLinkStore {
    private struct Archive: Codable {
        var saved: [String: [SavedDeepLink]] = [:]
        var recent: [String: [SavedDeepLink]] = [:]
        var remembersHistory = true
    }
    private var archive: Archive
    private let defaults: UserDefaults
    private static let key = "quickActions.links.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        archive = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Archive.self, from: $0) } ?? Archive()
    }

    var remembersHistory: Bool {
        get { archive.remembersHistory }
        set { archive.remembersHistory = newValue; persist() }
    }

    func saved(for package: String) -> [SavedDeepLink] { archive.saved[package] ?? [] }
    func recent(for package: String) -> [SavedDeepLink] { archive.recent[package] ?? [] }

    func save(name: String, url: String, routing: LinkRouting, for package: String) throws {
        let url = try AppInput.link(url)
        guard !name.trimmed.isEmpty else { throw AppError("Give this link a name.") }
        var links = saved(for: package)
        if let index = links.firstIndex(where: { $0.url == url && $0.routing == routing }) {
            links[index].name = name.trimmed
        } else {
            links.append(SavedDeepLink(name: name.trimmed, url: url, routing: routing))
        }
        archive.saved[package] = links
        persist()
    }

    func remove(_ id: UUID, for package: String) {
        archive.saved[package]?.removeAll { $0.id == id }
        persist()
    }

    func record(url: String, routing: LinkRouting, for package: String) {
        guard remembersHistory, let url = try? AppInput.link(url) else { return }
        var links = recent(for: package).filter { $0.url != url || $0.routing != routing }
        links.insert(SavedDeepLink(name: url, url: url, routing: routing), at: 0)
        archive.recent[package] = Array(links.prefix(10))
        persist()
    }

    func clearRecent(for package: String) { archive.recent[package] = []; persist() }

    private func persist() {
        if let data = try? JSONEncoder().encode(archive) { defaults.set(data, forKey: Self.key) }
    }
}
