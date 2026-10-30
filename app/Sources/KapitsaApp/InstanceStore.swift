import Foundation
import Combine
import Darwin

struct InstanceRow: Identifiable {
    let id: String
    let name: String
    let record: RuntimeRecord?
    let snapshot: RuntimeSnapshot?
    let profile: RuntimeConfiguration?
    let error: String?
}

@MainActor
final class InstanceStore: ObservableObject {
    @Published var rows: [InstanceRow] = []
    @Published var selectedId = ""
    @Published var history: [String: [RuntimeEvent]] = [:]
    @Published var lastError: String?
    private let client = RuntimeClient()
    private var cursors: [String: UInt64] = [:]
    private var profiles: [RuntimeConfiguration] = []
    private var children: [String: Process] = [:]
    private var refreshing = false
    private var polling: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: "runtimeProfiles") {
            profiles = (try? JSONDecoder().decode([RuntimeConfiguration].self, from: data)) ?? []
        }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    var selected: InstanceRow? { rows.first { $0.id == selectedId } }
    var activeRequests: Int { rows.reduce(0) { $0 + ($1.snapshot?.requests.count ?? 0) } }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let records = Registry.records()
        let client = self.client
        let cursors = self.cursors
        let results = await withTaskGroup(of: (RuntimeRecord, RuntimeSnapshot?, String?).self) { group in
            for record in records {
                group.addTask {
                    do {
                        let snapshot = try await client.fetch(record, cursor: cursors[record.runId] ?? 0)
                        return (record, snapshot, nil)
                    } catch {
                        return (record, nil, error.localizedDescription)
                    }
                }
            }
            var result: [(RuntimeRecord, RuntimeSnapshot?, String?)] = []
            for await row in group { result.append(row) }
            return result
        }
        var next: [InstanceRow] = []
        for (record, snapshot, error) in results {
            if let snapshot {
                self.cursors[record.runId] = snapshot.cursor
                var events = snapshot.reset == true ? [] : history[record.runId] ?? []
                events.append(contentsOf: snapshot.events ?? [])
                history[record.runId] = Array(events.suffix(100))
            }
            next.append(InstanceRow(id: record.instanceId, name: record.name, record: record, snapshot: snapshot,
                                    profile: profiles.first { $0.instanceId == record.instanceId }, error: error))
        }
        for profile in profiles where !next.contains(where: { $0.id == profile.instanceId }) {
            next.append(InstanceRow(id: profile.instanceId, name: profile.name, record: nil, snapshot: nil,
                                    profile: profile, error: nil))
        }
        rows = next.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !rows.contains(where: { $0.id == selectedId }) { selectedId = rows.first?.id ?? "" }
        let runs = Set(records.map(\.runId))
        self.cursors = self.cursors.filter { runs.contains($0.key) }
        history = history.filter { runs.contains($0.key) }
    }

    func stop(_ row: InstanceRow) async {
        guard let record = row.record else { return }
        do {
            try await client.stop(record)
            lastError = nil
            await refresh()
        } catch { lastError = error.localizedDescription }
    }

    func start(_ config: RuntimeConfiguration) async {
        do {
            guard RuntimeRecord.validId(config.instanceId) else {
                throw RuntimeFailure.message("Identifiant d’instance invalide.")
            }
            let process = Process()
            process.executableURL = try NativeHelper.executableURL()
            let input = Pipe()
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.standardInput = input
            let logs = Registry.home.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let logURL = logs.appendingPathComponent("instance-\(config.instanceId).log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]) else {
                    throw RuntimeFailure.message("Impossible de créer le journal de l’instance.")
                }
            }
            let output = try FileHandle(forWritingTo: logURL)
            try output.seekToEnd()
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    self?.children.removeValue(forKey: config.instanceId)
                    if process.terminationStatus != 0 && process.terminationReason == .exit {
                        self?.lastError = "L’instance « \(config.name) » s’est arrêtée (code \(process.terminationStatus)). Consulte son journal."
                    }
                    await self?.refresh()
                }
            }
            let bytes = try JSONEncoder().encode(config)
            guard bytes.count <= 16_384 else { throw RuntimeFailure.message("Configuration trop volumineuse.") }
            try process.run()
            children[config.instanceId] = process
            try input.fileHandleForWriting.write(contentsOf: bytes)
            try input.fileHandleForWriting.close()
            try output.close()
            if let index = profiles.firstIndex(where: { $0.instanceId == config.instanceId }) {
                profiles[index] = config
            } else {
                profiles.append(config)
            }
            if let data = try? JSONEncoder().encode(profiles) {
                UserDefaults.standard.set(data, forKey: "runtimeProfiles")
            }
            selectedId = config.instanceId
            lastError = nil
            await refresh()
        } catch { lastError = error.localizedDescription }
    }

    func forget(_ row: InstanceRow) {
        guard row.record == nil else { return }
        profiles.removeAll { $0.instanceId == row.id }
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "runtimeProfiles")
        }
        rows.removeAll { $0.id == row.id }
        if selectedId == row.id { selectedId = rows.first?.id ?? "" }
    }
}
