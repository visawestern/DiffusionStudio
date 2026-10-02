import Foundation

@MainActor
final class PresetStore: ObservableObject {
    @Published var names: [String] = []
    @Published var selected: String?

    private let key = "DiffusionStudio.presets.v1"

    init() {
        loadIndex()
    }

    private func loadIndex() {
        let raw = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        names = raw.keys.sorted()
        if let first = names.first { selected = first }
    }

    private func readAll() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
    }

    private func writeAll(_ dict: [String: Data]) {
        UserDefaults.standard.set(dict, forKey: key)
    }

    func save(name: String, settings: GenerationSettings) {
        var all = readAll()
        guard let data = try? JSONEncoder().encode(settings) else { return }
        all[name] = data
        writeAll(all)
        loadIndex()
        selected = name
    }

    func named(_ name: String) -> GenerationSettings? {
        guard let data = readAll()[name] else { return nil }
        return try? JSONDecoder().decode(GenerationSettings.self, from: data)
    }

    func load() -> GenerationSettings? {
        guard let name = selected else { return nil }
        return named(name)
    }

    func delete(_ name: String) {
        var all = readAll()
        all.removeValue(forKey: name)
        writeAll(all)
        loadIndex()
        if selected == name { selected = names.first }
    }
}