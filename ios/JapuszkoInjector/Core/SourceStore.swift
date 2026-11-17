import Foundation
import Observation

struct SourceApp: Codable, Identifiable, Hashable {
    var name: String
    var bundleIdentifier: String
    var version: String
    var versionDate: String?
    var size: UInt64?
    var downloadURL: String
    var iconURL: String?
    var localizedDescription: String?
    var developerName: String?

    var id: String { "\(bundleIdentifier).\(version)" }
}

struct Source: Codable, Identifiable, Hashable {
    var name: String
    var identifier: String
    var apps: [SourceApp]
    var sourceURL: String

    var id: String { identifier }

    private enum CodingKeys: String, CodingKey {
        case name, identifier, apps, sourceURL
    }
}

private struct SourceJSON: Codable {
    var name: String
    var identifier: String
    var apps: [SourceApp]
}

@MainActor
@Observable
final class SourceStore {
    static let shared = SourceStore()

    var sources: [Source] = []
    var loading = false
    var error: String?

    private let key = "japuszko_sources"

    init() {
        load()
    }

    func addSource(url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let parsed = URL(string: trimmed) else {
            error = "Invalid URL."
            return
        }
        if sources.contains(where: { $0.sourceURL == trimmed }) {
            error = "Source already added."
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: parsed)
            let decoded = try JSONDecoder().decode(SourceJSON.self, from: data)
            let source = Source(name: decoded.name,
                                identifier: decoded.identifier,
                                apps: decoded.apps,
                                sourceURL: trimmed)
            if sources.contains(where: { $0.identifier == source.identifier }) {
                sources.removeAll { $0.identifier == source.identifier }
            }
            sources.append(source)
            save()
        } catch {
            self.error = "Failed to load source: \(error.localizedDescription)"
        }
    }

    func removeSource(id: String) {
        sources.removeAll { $0.id == id }
        save()
    }

    func refreshSources() async {
        loading = true
        error = nil
        defer { loading = false }
        var updated: [Source] = []
        for source in sources {
            guard let url = URL(string: source.sourceURL) else {
                updated.append(source)
                continue
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(SourceJSON.self, from: data)
                updated.append(Source(name: decoded.name,
                                      identifier: decoded.identifier,
                                      apps: decoded.apps,
                                      sourceURL: source.sourceURL))
            } catch {
                updated.append(source)
            }
        }
        sources = updated
        save()
    }

    func refreshSource(id: String) async {
        guard let idx = sources.firstIndex(where: { $0.id == id }),
              let url = URL(string: sources[idx].sourceURL) else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(SourceJSON.self, from: data)
            sources[idx] = Source(name: decoded.name,
                                  identifier: decoded.identifier,
                                  apps: decoded.apps,
                                  sourceURL: sources[idx].sourceURL)
            save()
        } catch {
            self.error = "Refresh failed: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Source].self, from: data) else { return }
        sources = decoded
    }
}
