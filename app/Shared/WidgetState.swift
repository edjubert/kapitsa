import Foundation
import Darwin

enum WidgetState: String, Codable, Sendable {
    case stopped, preparing, loading, ready, busy, stopping, unreachable, missing

    var title: String {
        switch self {
        case .stopped: return "Arrêtée"
        case .preparing: return "Préparation"
        case .loading: return "Chargement"
        case .ready: return "Prête"
        case .busy: return "En activité"
        case .stopping: return "Arrêt en cours"
        case .unreachable: return "Injoignable"
        case .missing: return "Instance indisponible"
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .busy: return "waveform"
        case .loading, .preparing: return "hourglass"
        case .stopping: return "stop.circle"
        case .unreachable, .missing: return "exclamationmark.triangle.fill"
        case .stopped: return "power"
        }
    }
}

// Display data only: no prompt, generated text, API key or control credential.
struct WidgetInstance: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var model: String
    var state: WidgetState
    var runId: String?
    var canStart: Bool
    var context: Int?
    var slots: Int?
    var quant: String?
    var apiUrl: String?
    var memoryUsedBytes: UInt64?
    var memoryBudgetBytes: UInt64?
    var activeRequests = 0
    var completionTokens: Int?
    var tokensPerSecond: Double?

    static func live(_ snapshot: RuntimeSnapshot, canStart: Bool) -> Self {
        let state = WidgetState(rawValue: snapshot.state) ?? .preparing
        return Self(id: snapshot.instanceId, name: snapshot.name, model: snapshot.model,
            state: state == .ready && !snapshot.requests.isEmpty ? .busy : state,
            runId: snapshot.runId, canStart: canStart, context: snapshot.context,
            slots: snapshot.slots, quant: snapshot.quant, apiUrl: snapshot.apiUrl,
            memoryUsedBytes: snapshot.memoryUsedBytes, memoryBudgetBytes: snapshot.memoryBudgetBytes,
            activeRequests: snapshot.requests.count,
            completionTokens: snapshot.requests.isEmpty ? snapshot.lastRequest?.completionTokens :
                snapshot.requests.reduce(0) { $0 + $1.completionTokens },
            tokensPerSecond: snapshot.requests.isEmpty ? snapshot.lastRequest?.tokensPerSecond :
                snapshot.requests.reduce(0) { $0 + $1.tokensPerSecond })
    }

    var canStop: Bool {
        runId != nil && [.ready, .busy, .preparing, .loading].contains(state)
    }

    var canLaunch: Bool { state == .stopped && canStart }

    var deepLink: URL? {
        guard RuntimeRecord.validId(id) else { return nil }
        return URL(string: "kapitsa://instance/\(id)")
    }

    static let example = Self(id: "example", name: "Code", model: "qwen3.8-27b",
        state: .busy, runId: "example-run", canStart: true, context: 92160, slots: 4,
        quant: "MLX affine 4-bit", apiUrl: "http://127.0.0.1:8000",
        memoryUsedBytes: 21_500_000_000, memoryBudgetBytes: 30_200_000_000,
        activeRequests: 1, completionTokens: 163, tokensPerSecond: 40)
}

struct WidgetInventory: Codable, Equatable, Sendable {
    var protocolVersion = 1
    var updatedAt: Date
    var instances: [WidgetInstance]
}

enum WidgetCommand: Equatable, Sendable {
    case start(String)
    case stop(String, runId: String)
    case refresh(String)
}

enum WidgetActionRouter {
    // Foreground AppIntents execute in the containing app, never spawn a
    // runtime from the sandboxed WidgetKit extension.
    @MainActor static var perform: ((WidgetCommand) async throws -> Void)?
}

struct WidgetSharedStorage: Sendable {
    static let kind = "KapitsaInstance"
    let directory: URL

    static var shared: Self? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "KapitsaAppGroup") as? String,
              !group.isEmpty, !group.contains("$("),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group) else { return nil }
        return Self(directory: container.appendingPathComponent("KapitsaWidgets", isDirectory: true))
    }

    func inventory() -> WidgetInventory? {
        guard let value: WidgetInventory = read("instances.json"),
              value.protocolVersion == 1,
              value.instances.allSatisfy({ RuntimeRecord.validId($0.id) }) else { return nil }
        return value
    }

    func connections() -> [RuntimeRecord] {
        // Private App Group file, accessible only to the signed app and its
        // extension. Credentials never enter timeline entries or entity labels.
        let records: [RuntimeRecord] = read("connections.json") ?? []
        return records.filter(\.valid)
    }

    func publish(_ inventory: WidgetInventory, connections: [RuntimeRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        guard Registry.privatePath(directory, directory: true) else {
            throw RuntimeFailure.message("Le dossier partagé du widget est invalide.")
        }
        try write(inventory, name: "instances.json")
        try write(connections, name: "connections.json")
    }

    private func read<T: Decodable>(_ name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard Registry.privatePath(directory, directory: true),
              Registry.privatePath(url, directory: false),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_048_576, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        let data = try JSONEncoder().encode(value)
        let destination = directory.appendingPathComponent(name)
        if (try? Data(contentsOf: destination)) == data { return }
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
            attributes: [.posixPermissions: 0o600]) else {
            throw RuntimeFailure.message("Impossible de publier l’état du widget.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, destination.path) == 0 else {
            throw RuntimeFailure.message("Impossible de remplacer l’état du widget.")
        }
    }
}

enum WidgetStatusReader {
    static func read(id: String, storage: WidgetSharedStorage) async -> WidgetInstance? {
        guard RuntimeRecord.validId(id),
              var value = storage.inventory()?.instances.first(where: { $0.id == id }) else { return nil }
        if let record = storage.connections().first(where: { $0.instanceId == id }) {
            do {
                let snapshot = try await RuntimeClient().status(record)
                return .live(snapshot, canStart: value.canStart)
            } catch {
                value.state = .unreachable
                value.activeRequests = 0
                value.tokensPerSecond = nil
            }
        } else if value.state != .stopped {
            value.state = .unreachable
        }
        return value
    }
}
