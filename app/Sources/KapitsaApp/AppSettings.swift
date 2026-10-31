import Foundation
import Combine

struct LaunchDefaults: Codable, Equatable {
    var model = ""
    var context = ""
    var slots = 0
    var port = 8000
    var memory = ""
    var speculation = -1
    var diskCache = ""
    var prefillChunk = 0
    var useDrafter = true

    init() {}

    init(configuration: RuntimeConfiguration) {
        model = configuration.model
        context = configuration.context.map(String.init) ?? ""
        slots = configuration.slots ?? 0
        port = configuration.port
        memory = configuration.memBudgetGb.map { String($0) } ?? ""
        speculation = configuration.spec ?? -1
        diskCache = configuration.diskCache ?? ""
        prefillChunk = configuration.prefillChunk ?? 0
        useDrafter = configuration.dflash != "none"
    }

    func configuration(name: String, model: String, port: Int,
                       context: String, slots: Int,
                       editing original: RuntimeConfiguration? = nil) throws -> RuntimeConfiguration {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 128, !reference.isEmpty, reference.utf8.count <= 4096 else {
            throw RuntimeFailure.message("Renseigne un nom et un modèle.")
        }
        guard (1...65535).contains(port), (0...4).contains(slots),
              (-1...32).contains(speculation), (0...8192).contains(prefillChunk) else {
            throw RuntimeFailure.message("Vérifie le port et les limites des options.")
        }
        let budget: Double?
        if memory.trimmingCharacters(in: .whitespaces).isEmpty {
            budget = nil
        } else {
            guard let number = Double(memory.replacingOccurrences(of: ",", with: ".")),
                  number.isFinite, number > 0, number <= 4096 else {
                throw RuntimeFailure.message("Le budget mémoire doit être un nombre positif en GB.")
            }
            budget = number
        }
        let cache = diskCache.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.validCache(cache) else {
            throw RuntimeFailure.message("La taille du cache doit être de la forme 10g, 512m ou 0.")
        }
        return RuntimeConfiguration(instanceId: original?.instanceId ?? UUID().uuidString.lowercased(), name: title,
            model: (reference as NSString).expandingTildeInPath, port: port,
            context: try RuntimeConfiguration.contextTokens(context), slots: slots == 0 ? nil : slots,
            memBudgetGb: budget, spec: speculation == -1 ? nil : speculation,
            dflash: useDrafter ? (original?.dflash == "none" ? nil : original?.dflash) : "none",
            diskCache: cache.isEmpty ? nil : cache,
            prefillChunk: prefillChunk == 0 ? nil : prefillChunk)
    }

    static func validCache(_ cache: String) -> Bool {
        if ["", "auto", "off", "none", "no"].contains(cache) { return true }
        guard let expression = try? NSRegularExpression(pattern: #"^([0-9]+(?:\.[0-9]*)?|\.[0-9]+)([kmgt]?(?:ib|b)?)$"#),
              let match = expression.firstMatch(in: cache, range: NSRange(cache.startIndex..., in: cache)),
              let numberRange = Range(match.range(at: 1), in: cache),
              let unitRange = Range(match.range(at: 2), in: cache),
              let number = Double(cache[numberRange]) else { return false }
        let unit = cache[unitRange].first
        let powers: [String: Double] = ["k": 1, "m": 2, "g": 3, "t": 4]
        let power = powers[unit.map(String.init) ?? ""] ?? 0
        return number.isFinite && number * pow(1024, power) < 9e18
    }

    func validate() throws {
        _ = try configuration(name: "Validation", model: model.isEmpty ? "4b" : model,
                              port: port, context: context, slots: slots)
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var defaults: LaunchDefaults
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let saved = preferences.data(forKey: "launchDefaults")
            .flatMap { try? JSONDecoder().decode(LaunchDefaults.self, from: $0) } ?? LaunchDefaults()
        defaults = (try? saved.validate()) != nil ? saved : LaunchDefaults()
    }

    func save(_ value: LaunchDefaults) throws {
        try value.validate()
        let data = try JSONEncoder().encode(value)
        preferences.set(data, forKey: "launchDefaults")
        defaults = value
    }

    func useModel(_ reference: String) {
        var next = defaults
        next.model = reference
        try? save(next)
    }

    func availablePort(in rows: [InstanceRow]) -> Int {
        let used = Set(rows.compactMap { $0.snapshot.flatMap { URLComponents(string: $0.apiUrl)?.port } })
        return (defaults.port...65535).first { !used.contains($0) }
            ?? (1024..<defaults.port).first { !used.contains($0) } ?? defaults.port
    }
}
