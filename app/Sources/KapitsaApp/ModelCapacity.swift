import Foundation
import Metal
import SwiftUI

struct ModelCapacity: Decodable, Sendable {
    let status: String
    let budgetBytes: UInt64
    let startupBytes: UInt64?
    let conversationBytes: UInt64?
    let context: Int?
    let slots: Int?

    enum Warning: Equatable {
        case model, context, instances
    }

    func warning(physicalBytes: UInt64, sharedBudgetBytes: UInt64? = nil,
                 occupiedBytes: UInt64 = 0) -> Warning? {
        guard status == "known", let startupBytes else { return nil }
        let limit = min(budgetBytes, physicalBytes)
        if startupBytes > limit { return .model }
        if let conversationBytes, conversationBytes > limit { return .context }
        let sharedLimit = min(sharedBudgetBytes ?? physicalBytes, physicalBytes)
        if startupBytes > sharedLimit - min(sharedLimit, occupiedBytes) { return .instances }
        return nil
    }
}

// Hash only options that affect planning. Instance names, UUIDs and API ports
// must not restart a request each time SwiftUI evaluates the form.
struct CapacityQuery: Hashable {
    let model: String
    let context: String
    let slots: Int
    let memory: String
    let speculation: Int
    let useDrafter: Bool
    let prefillChunk: Int
    let drafter: String?

    init(model: String, defaults: LaunchDefaults, drafter: String? = nil) {
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        context = defaults.context
        slots = defaults.slots
        memory = defaults.memory
        speculation = defaults.speculation
        useDrafter = defaults.useDrafter
        prefillChunk = defaults.prefillChunk
        self.drafter = defaults.useDrafter && drafter != "none" ? drafter : nil
    }

    func configuration() throws -> RuntimeConfiguration {
        var defaults = LaunchDefaults()
        defaults.memory = memory
        defaults.speculation = speculation
        defaults.useDrafter = useDrafter
        defaults.prefillChunk = prefillChunk
        let config = try defaults.configuration(name: "Capacity", model: model, port: 8000,
                                                context: context, slots: slots)
        return RuntimeConfiguration(instanceId: "capacity", name: config.name, model: config.model,
            port: config.port, context: config.context, slots: config.slots, memBudgetGb: config.memBudgetGb,
            spec: config.spec, dflash: config.dflash ?? drafter, prefillChunk: config.prefillChunk)
    }
}

enum MachineMemory {
    static let physicalBytes = ProcessInfo.processInfo.physicalMemory
    // Hardware metadata only: no engine, buffers, kernels or command queue.
    static let recommendedBudget: UInt64? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let workingSet = device.recommendedMaxWorkingSetSize
        let margin = max(UInt64(512) << 20, workingSet / 25)
        return workingSet > margin ? workingSet - margin : nil
    }()

    static func budget(for config: RuntimeConfiguration) -> UInt64? {
        if let gb = config.memBudgetGb { return UInt64(gb * 1e9) }
        if let value = ProcessInfo.processInfo.environment["NI_MEM_BUDGET"],
           let gb = Double(value), gb.isFinite, gb > 0, gb <= 4096 {
            return UInt64(gb * 1e9)
        }
        return recommendedBudget
    }
}

struct ModelCapacityBanner: View {
    private struct RequestID: Hashable {
        let query: CapacityQuery
        let revision: Int
    }

    @EnvironmentObject private var store: InstanceStore
    let query: CapacityQuery
    // In the downloaded-model detail, its own running instances already
    // demonstrate a successful start; warn about an additional copy in the form.
    var alreadyRunning = false
    var replacingInstanceId: String?
    var refreshID = 0
    @State private var capacity: ModelCapacity?
    @State private var checking = true

    private var occupiedBytes: UInt64 {
        store.rows.filter { $0.id != replacingInstanceId }.reduce(0) { $0 + ($1.snapshot?.memoryUsedBytes ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let capacity, let warning = capacity.warning(
                physicalBytes: MachineMemory.physicalBytes,
                sharedBudgetBytes: MachineMemory.recommendedBudget,
                occupiedBytes: alreadyRunning ? 0 : occupiedBytes) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .font(.title3).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title(warning)).font(.callout.weight(.semibold))
                        Text(detail(warning, capacity)).font(.caption)
                        Text(warning == .model
                             ? "Choisis un modèle plus petit ou une variante plus quantifiée."
                             : warning == .context
                             ? "Réduis le contexte ou choisis une variante plus légère."
                             : "Arrête une autre instance ou choisis un modèle plus léger.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3)))
            } else if checking {
                Label("Estimation de la mémoire…", systemImage: "ellipsis.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if capacity?.status != "known", !query.model.isEmpty {
                Label("Estimation indisponible. La mémoire sera vérifiée au démarrage.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: RequestID(query: query, revision: refreshID)) {
            capacity = nil
            checking = !query.model.isEmpty
            guard !query.model.isEmpty else { return }
            do {
                // Debounce edits and cancel requests when the selection changes.
                try await Task.sleep(for: .milliseconds(350))
                let config = try query.configuration()
                guard let budget = MachineMemory.budget(for: config) else {
                    checking = false
                    return
                }
                let job = try NativeModelJob(action: "capacity", configuration: config, budgetBytes: budget)
                let reply = try await withTaskCancellationHandler {
                    try await job.read { _ in }
                } onCancel: {
                    job.interrupt()
                }
                guard !Task.isCancelled else { return }
                capacity = reply.capacity
                checking = false
            } catch {
                if !Task.isCancelled { checking = false }
            }
        }
    }

    private func title(_ warning: ModelCapacity.Warning) -> String {
        switch warning {
        case .model: return "Mémoire insuffisante pour ce modèle"
        case .context: return "Le contexte choisi dépasse le budget mémoire"
        case .instances: return "Les instances actives laissent trop peu de mémoire"
        }
    }

    private func detail(_ warning: ModelCapacity.Warning, _ capacity: ModelCapacity) -> String {
        let limit = min(warning == .instances
            ? MachineMemory.recommendedBudget ?? MachineMemory.physicalBytes
            : capacity.budgetBytes, MachineMemory.physicalBytes)
        let needed = warning == .context ? capacity.conversationBytes : capacity.startupBytes
        let amount = String(format: "%.1f GB", Double(needed ?? 0) / 1e9)
        let budget = String(format: "%.1f GB", Double(limit) / 1e9)
        if warning == .instances {
            let occupied = String(format: "%.1f GB", Double(occupiedBytes) / 1e9)
            return "Environ \(amount) au démarrage, avec \(occupied) déjà utilisés par Kapitsa, pour un budget de \(budget)."
        }
        if warning == .context {
            return "Environ \(amount) pour une conversation de \(capacity.context ?? 0) tokens, pour un budget de \(budget)."
        }
        return "Environ \(amount) nécessaires au démarrage, pour un budget de \(budget) sur ce Mac."
    }
}
