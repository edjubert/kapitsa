import AppIntents
import OSLog
import WidgetKit

#if KAPITSA_WIDGET || DEBUG
// Configuration/entity lookup belongs to the widget extension. The containing
// app declares only its foreground control intents. DEBUG also compiles the
// picker into the engine-free Swift Package test executable.
struct KapitsaInstanceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Instance Kapitsa"
    static var defaultQuery = KapitsaInstanceQuery()
    let id: String
    let name: String
    let model: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(abbreviatedHomePath(model)) · \(id)")
    }
}

struct KapitsaInstanceQuery: EntityQuery {
    private let storage: WidgetSharedStorage?

    init() { storage = .shared }
    init(storage: WidgetSharedStorage) { self.storage = storage }

    func entities(for identifiers: [String]) async throws -> [KapitsaInstanceEntity] {
        let candidates = values
        return identifiers.filter(RuntimeRecord.validId).map { id in
            // Keep a deleted selection resolvable so WidgetKit can render the
            // missing-target state instead of clearing the user's selection.
            candidates.first(where: { $0.id == id }) ??
                KapitsaInstanceEntity(id: id, name: "Instance indisponible", model: "")
        }
    }

    func suggestedEntities() async throws -> [KapitsaInstanceEntity] { values }

    func defaultResult() async -> KapitsaInstanceEntity? {
        let candidates = values
        return candidates.count == 1 ? candidates.first : nil
    }

    private var values: [KapitsaInstanceEntity] {
        (storage?.inventory()?.instances ?? []).map {
            KapitsaInstanceEntity(id: $0.id, name: $0.name, model: $0.model)
        }
    }
}

struct SelectKapitsaInstanceIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Instance Kapitsa"
    static var description = IntentDescription("Choisis l’instance à afficher et à contrôler.")
    @Parameter(title: "Instance") var instance: KapitsaInstanceEntity?
}
#endif

struct StartKapitsaInstanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Démarrer l’instance Kapitsa"
    static var openAppWhenRun = true
    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    #endif
    @Parameter(title: "Identifiant de l’instance") var instanceId: String

    init() {}
    init(id: String) { instanceId = id }

    @MainActor func perform() async throws -> some IntentResult {
        try await performWidgetCommand(.start(instanceId))
        return .result()
    }
}

struct StopKapitsaInstanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Arrêter l’instance Kapitsa"
    static var openAppWhenRun = true
    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    #endif
    @Parameter(title: "Identifiant de l’instance") var instanceId: String
    @Parameter(title: "Exécution affichée") var runId: String

    init() {}
    init(id: String, run: String) { instanceId = id; runId = run }

    @MainActor func perform() async throws -> some IntentResult {
        try await performWidgetCommand(.stop(instanceId, runId: runId))
        return .result()
    }
}

struct RefreshKapitsaInstanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Actualiser l’instance Kapitsa"
    static var openAppWhenRun = true
    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    #endif
    @Parameter(title: "Identifiant de l’instance") var instanceId: String

    init() {}
    init(id: String) { instanceId = id }

    @MainActor func perform() async throws -> some IntentResult {
        try await performWidgetCommand(.refresh(instanceId))
        return .result()
    }
}

#if !KAPITSA_WIDGET
// These intents need the containing app's runtime launcher. Declaring the
// foreground protocol here keeps execution out of the sandboxed extension.
extension StartKapitsaInstanceIntent: ForegroundContinuableIntent {}
extension StopKapitsaInstanceIntent: ForegroundContinuableIntent {}
extension RefreshKapitsaInstanceIntent: ForegroundContinuableIntent {}
#endif

@MainActor
private func performWidgetCommand(_ command: WidgetCommand) async throws {
    let logger = Logger(subsystem: "io.github.edjubert.kapitsa", category: "WidgetControl")
    let action: String
    switch command {
    case .start: action = "start"
    case .stop: action = "stop"
    case .refresh: action = "refresh"
    }
    logger.notice("Received widget command: \(action, privacy: .public)")
    guard let perform = WidgetActionRouter.perform else {
        logger.error("Widget command handler is unavailable.")
        throw RuntimeFailure.message("Ouvre Kapitsa pour contrôler cette instance.")
    }
    try await perform(command)
    logger.notice("Completed widget command: \(action, privacy: .public)")
    WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStorage.kind)
}
