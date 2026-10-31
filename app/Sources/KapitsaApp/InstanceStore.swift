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
    var pendingEdit = false
    var requiresManualStop = false

    var lifecycle: String { snapshot?.state ?? (record == nil ? "stopped" : "unreachable") }

    var editableConfiguration: RuntimeConfiguration? {
        if let profile { return profile }
        if let config = snapshot?.configuration { return config.value }
        guard let state = snapshot, let port = URLComponents(string: state.apiUrl)?.port else { return nil }
        return RuntimeConfiguration(instanceId: id, name: name, model: state.model, port: port,
                                    context: state.context, slots: state.slots)
    }

    var canRestart: Bool {
        record != nil && !requiresManualStop &&
            (profile != nil || snapshot?.configuration != nil) &&
            (snapshot?.managed == true || (snapshot?.managed == nil && profile != nil))
    }

    var hasPendingChanges: Bool {
        guard let profile else { return false }
        guard let running = snapshot?.configuration?.value else { return pendingEdit }
        return profile != running
    }
}

@MainActor
final class InstanceStore: ObservableObject {
    @Published var rows: [InstanceRow] = []
    @Published var selectedId = ""
    @Published var history: [String: [RuntimeEvent]] = [:]
    @Published var lastError: String?
    @Published var editing: InstanceEditRequest?
    @Published var deletion: InstanceRow?
    @Published private(set) var startingIDs: Set<String> = []
    @Published private(set) var deletingIDs: Set<String> = []
    @Published private(set) var restartingIDs: Set<String> = []
    @Published var widgetOpenRequest = UUID()
    private let widgetPublisher: WidgetPublisher?
    private let client = RuntimeClient()
    private let preferences: UserDefaults
    private let runtimeHome: URL
    private let launcher: ((RuntimeConfiguration) throws -> Process)?
    private var cursors: [String: UInt64] = [:]
    private var profiles: [RuntimeConfiguration] = []
    private var pendingRuns: [String: String] = [:]
    private var incompleteProfiles: Set<String> = []
    private var children: [String: Process] = [:]
    private var refreshing = false
    private var polling: Task<Void, Never>?

    init(preferences: UserDefaults = .standard, home: URL = Registry.home,
         poll: Bool = true, launcher: ((RuntimeConfiguration) throws -> Process)? = nil) {
        self.preferences = preferences
        runtimeHome = home
        self.launcher = launcher
        widgetPublisher = home == Registry.home && preferences === UserDefaults.standard ?
            WidgetSharedStorage.shared.map { WidgetPublisher(storage: $0) } : nil
        if let data = preferences.data(forKey: "runtimeProfiles") {
            profiles = (try? JSONDecoder().decode([RuntimeConfiguration].self, from: data)) ?? []
        }
        pendingRuns = preferences.dictionary(forKey: "runtimePendingEdits") as? [String: String] ?? [:]
        incompleteProfiles = Set(preferences.stringArray(forKey: "runtimeIncompleteProfiles") ?? [])
        if poll { polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        } }
    }

    var selected: InstanceRow? { rows.first { $0.id == selectedId } }
    var activeRequests: Int { rows.reduce(0) { $0 + ($1.snapshot?.requests.count ?? 0) } }
    func isChanging(_ id: String) -> Bool {
        startingIDs.contains(id) || restartingIDs.contains(id) || deletingIDs.contains(id)
    }

    func refresh() async {
        // A cold-start AppIntent must wait for the app's initial discovery,
        // rather than looking for its target in an empty or outdated list.
        while refreshing {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        refreshing = true
        defer { refreshing = false }
        let records = records()
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
                                    profile: profiles.first { $0.instanceId == record.instanceId }, error: error,
                                    pendingEdit: pendingRuns[record.instanceId] == record.runId,
                                    requiresManualStop: incompleteProfiles.contains(record.instanceId) &&
                                        snapshot?.configuration == nil))
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
        widgetPublisher?.publish(rows)
    }

    func stop(_ row: InstanceRow) async {
        guard let record = row.record, !isChanging(row.id) else { return }
        do {
            guard records().first(where: { $0.instanceId == row.id })?.runId == record.runId else {
                throw RuntimeFailure.message("L’instance a changé depuis la confirmation. Actualise sa fiche.")
            }
            try preserveConfiguration(row)
            try await client.stop(record)
            lastError = nil
            await refresh()
        } catch { lastError = error.localizedDescription }
    }

    @discardableResult
    func start(_ config: RuntimeConfiguration) async -> Bool {
        guard !isChanging(config.instanceId) else {
            lastError = "Une opération est déjà en cours sur cette instance."
            return false
        }
        return await startRuntime(config)
    }

    private func startRuntime(_ config: RuntimeConfiguration) async -> Bool {
        startingIDs.insert(config.instanceId)
        defer { startingIDs.remove(config.instanceId) }
        do {
            try validate(config)
            guard !records().contains(where: { $0.instanceId == config.instanceId }),
                  children[config.instanceId]?.isRunning != true else {
                throw RuntimeFailure.message("Cette instance fonctionne déjà. Actualise sa fiche.")
            }
            let logURL = runtimeHome.appendingPathComponent("logs/instance-\(config.instanceId).log")
            let logOffset = (try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let process = try launcher?(config) ?? NativeHelper.launch(config, home: runtimeHome)
            children[config.instanceId] = process
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard self?.children[config.instanceId] === process else { return }
                    self?.children.removeValue(forKey: config.instanceId)
                    if process.terminationStatus != 0 &&
                        self?.startingIDs.contains(config.instanceId) != true &&
                        self?.deletingIDs.contains(config.instanceId) != true &&
                        self?.restartingIDs.contains(config.instanceId) != true &&
                        !(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM) {
                        self?.lastError = NativeHelper.failureMessage(config, process: process,
                            log: logURL, since: logOffset)
                    }
                    await self?.refresh()
                }
            }
            try persist(config)
            pendingRuns.removeValue(forKey: config.instanceId)
            preferences.set(pendingRuns, forKey: "runtimePendingEdits")
            incompleteProfiles.remove(config.instanceId)
            preferences.set(Array(incompleteProfiles), forKey: "runtimeIncompleteProfiles")
            selectedId = config.instanceId
            lastError = nil
            // Publishing the control endpoint precedes loading a model. Wait
            // for that acknowledgment so an immediate exit cannot look like a
            // successful start or lose its error behind the initial refresh.
            let deadline = ContinuousClock.now + .seconds(5)
            while !records().contains(where: {
                $0.instanceId == config.instanceId && $0.pid == Int(process.processIdentifier)
            }) {
                guard process.isRunning else {
                    throw RuntimeFailure.message(NativeHelper.failureMessage(config, process: process,
                        log: logURL, since: logOffset))
                }
                guard ContinuousClock.now < deadline else {
                    throw RuntimeFailure.message("Le runtime de « \(config.name) » n’a pas encore répondu. Consulte son journal avant de relancer.")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            await refresh()
            return false
        }
    }

    func save(_ config: RuntimeConfiguration, for target: InstanceRow, restart: Bool) async throws {
        guard config.instanceId == target.id, !isChanging(target.id) else {
            throw RuntimeFailure.message("Cette instance est déjà en cours de modification.")
        }
        try validate(config)
        let current = records().first { $0.instanceId == target.id }
        guard current?.runId == target.record?.runId else {
            throw RuntimeFailure.message("L’instance a changé depuis l’ouverture du formulaire. Rouvre sa fiche.")
        }
        if restart {
            guard let record = target.record, target.canRestart else {
                throw RuntimeFailure.message("Cette instance doit être arrêtée depuis sa fiche avant son prochain lancement.")
            }
            restartingIDs.insert(target.id)
            defer { restartingIDs.remove(target.id) }
            // Check ownership and current protocol capabilities before changing anything.
            let state = try await client.fetch(record)
            guard state.managed != false else {
                throw RuntimeFailure.message("Cette instance CLI ne peut pas être redémarrée avec les options de l’app.")
            }
            try await client.stop(record)
            // Retain the edit even if shutdown times out or the new model fails.
            try persist(config)
            pendingRuns[target.id] = record.runId
            preferences.set(pendingRuns, forKey: "runtimePendingEdits")
            let deadline = ContinuousClock.now + .seconds(30)
            while let owner = records().first(where: { $0.instanceId == target.id }) {
                guard owner.runId == record.runId else {
                    throw RuntimeFailure.message("Une autre exécution a démarré. Elle n’a pas été interrompue.")
                }
                guard ContinuousClock.now < deadline else {
                    throw RuntimeFailure.message("L’arrêt prend trop de temps. La configuration est enregistrée ; redémarre l’instance une fois arrêtée.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            // The owner removes its record just before releasing its file lock.
            try await Task.sleep(for: .milliseconds(100))
            if let child = children[target.id], !child.isRunning { children.removeValue(forKey: target.id) }
            guard await startRuntime(config) else {
                throw RuntimeFailure.message(lastError ?? "Impossible de redémarrer cette instance.")
            }
        } else {
            if target.record != nil && !target.canRestart {
                incompleteProfiles.insert(target.id)
                preferences.set(Array(incompleteProfiles), forKey: "runtimeIncompleteProfiles")
            }
            try persist(config)
            if let record = target.record, config != target.editableConfiguration {
                pendingRuns[target.id] = record.runId
                preferences.set(pendingRuns, forKey: "runtimePendingEdits")
            }
            lastError = nil
            await refresh()
        }
    }

    private func records() -> [RuntimeRecord] {
        let directory = runtimeHome.appendingPathComponent("instances")
        return Registry.records(in: directory).filter { !Registry.removeOrphan($0, in: directory) }
    }

    private func validate(_ config: RuntimeConfiguration) throws {
        guard RuntimeRecord.validId(config.instanceId), config.protocolVersion == 1,
              config.context.map({ (1...1_048_576).contains($0) }) ?? true,
              config.slots.map({ (1...4).contains($0) }) ?? true,
              config.prefillChunk.map({ (1...8192).contains($0) }) ?? true else {
            throw RuntimeFailure.message("Identifiant ou limites d’instance invalides.")
        }
        let draft = LaunchDefaults(configuration: config)
        _ = try draft.configuration(name: config.name, model: config.model, port: config.port,
                                    context: draft.context, slots: draft.slots, editing: config)
        guard try JSONEncoder().encode(config).count <= 16_384 else {
            throw RuntimeFailure.message("Configuration trop volumineuse.")
        }
        let conflict = rows.first { row in
            row.id != config.instanceId && row.record != nil &&
                (row.snapshot.flatMap { URLComponents(string: $0.apiUrl)?.port } ??
                 row.profile?.port ?? row.snapshot?.configuration?.port) == config.port
        }
        if let conflict {
            throw RuntimeFailure.message("Le port \(config.port) est utilisé par « \(conflict.name) ». Choisis un autre port.")
        }
    }

    private func persist(_ config: RuntimeConfiguration) throws {
        var next = profiles.filter { $0.instanceId != config.instanceId }
        next.append(config)
        preferences.set(try JSONEncoder().encode(next), forKey: "runtimeProfiles")
        profiles = next
    }

    func forget(_ row: InstanceRow) {
        guard row.record == nil, !isChanging(row.id),
              !records().contains(where: { $0.instanceId == row.id }) else { return }
        try? removeProfile(row.id)
    }

    private func removeProfile(_ id: String) throws {
        let next = profiles.filter { $0.instanceId != id }
        preferences.set(try JSONEncoder().encode(next), forKey: "runtimeProfiles")
        profiles = next
        pendingRuns.removeValue(forKey: id)
        preferences.set(pendingRuns, forKey: "runtimePendingEdits")
        incompleteProfiles.remove(id)
        preferences.set(Array(incompleteProfiles), forKey: "runtimeIncompleteProfiles")
        rows.removeAll { $0.id == id }
        if selectedId == id { selectedId = rows.first?.id ?? "" }
        if editing?.configuration.instanceId == id { editing = nil }
        widgetPublisher?.publish(rows)
    }

    @discardableResult
    func delete(_ target: InstanceRow) async -> Bool {
        guard !isChanging(target.id) else {
            lastError = "Une opération est déjà en cours sur cette instance."
            return false
        }
        deletingIDs.insert(target.id)
        defer { deletingIDs.remove(target.id) }
        do {
            let current = records().first { $0.instanceId == target.id }
            if let current {
                guard current.runId == target.record?.runId else {
                    throw RuntimeFailure.message("L’instance a redémarré depuis la confirmation. Sa nouvelle exécution a été conservée.")
                }
                do { try await client.stop(current) }
                catch {
                    throw RuntimeFailure.message("Impossible d’arrêter « \(target.name) » : \(error.localizedDescription) Sa configuration a été conservée.")
                }
                let deadline = ContinuousClock.now + .seconds(30)
                while let owner = records().first(where: { $0.instanceId == target.id }) {
                    guard owner.runId == current.runId else {
                        throw RuntimeFailure.message("Une autre exécution a démarré. Elle n’a pas été supprimée.")
                    }
                    guard ContinuousClock.now < deadline else {
                        throw RuntimeFailure.message("L’arrêt prend trop de temps. L’instance a été conservée ; réessaie après son arrêt.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            // Keep a concurrent CLI start from racing the final profile removal.
            try Registry.withIdleInstance(target.id, in: runtimeHome.appendingPathComponent("instances")) {
                guard !Registry.records(in: runtimeHome.appendingPathComponent("instances"))
                    .contains(where: { $0.instanceId == target.id }) else {
                    throw RuntimeFailure.message("Une autre exécution a démarré. Elle n’a pas été supprimée.")
                }
                try removeProfile(target.id)
            }
            lastError = nil
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            await refresh()
            return false
        }
    }

    private func preserveConfiguration(_ row: InstanceRow) throws {
        if row.profile == nil, row.snapshot?.managed == true,
           let configuration = row.snapshot?.configuration?.value {
            try persist(configuration)
        }
    }

    func handleWidget(_ command: WidgetCommand) async throws {
        let id: String
        switch command {
        case .start(let value), .stop(let value, _), .refresh(let value): id = value
        }
        guard RuntimeRecord.validId(id) else { throw RuntimeFailure.message("Instance invalide.") }
        await refresh()
        guard let row = rows.first(where: { $0.id == id }) else {
            throw RuntimeFailure.message("Cette instance n’existe plus. Modifie la cible du widget.")
        }
        selectedId = id
        widgetOpenRequest = UUID()
        if case .refresh = command { return }
        guard !isChanging(id) else {
            throw RuntimeFailure.message("Une opération est déjà en cours sur cette instance.")
        }
        switch command {
        case .start:
            guard row.record == nil, let config = row.profile else {
                throw RuntimeFailure.message("Cette instance est déjà active ou n’a pas de configuration enregistrée.")
            }
            guard await start(config) else {
                throw RuntimeFailure.message(lastError ?? "Le démarrage a échoué.")
            }
        case .stop(_, let run):
            guard RuntimeRecord.validId(run), let record = row.record, record.runId == run else {
                throw RuntimeFailure.message("L’instance a redémarré depuis l’affichage du widget. Actualise-le avant de l’arrêter.")
            }
            try preserveConfiguration(row)
            try await client.stop(record)
            await refresh()
        case .refresh: break
        }
    }
}
