import Foundation
import WidgetKit

@MainActor
final class WidgetPublisher {
    private let storage: WidgetSharedStorage
    private var previous: [String] = []
    private var lastReload = Date.distantPast
    var error: String?

    init(storage: WidgetSharedStorage) { self.storage = storage }

    func publish(_ rows: [InstanceRow]) {
        let values = rows.map { row -> WidgetInstance in
            if let snapshot = row.snapshot {
                return .live(snapshot, canStart: row.profile != nil ||
                    (snapshot.managed == true && snapshot.configuration != nil))
            }
            let config = row.profile
            return WidgetInstance(id: row.id, name: row.name,
                model: config.map { URL(fileURLWithPath: $0.model).lastPathComponent } ?? "",
                state: row.record == nil ? .stopped : .unreachable, runId: row.record?.runId,
                canStart: config != nil, context: config?.context, slots: config?.slots,
                apiUrl: config.map { "http://127.0.0.1:\($0.port)" })
        }
        do {
            try storage.publish(WidgetInventory(updatedAt: Date(), instances: values),
                                connections: rows.compactMap(\.record))
            error = nil
            let signatures = values.map {
                "\($0.id)|\($0.runId ?? "")|\($0.name)|\($0.model)|\($0.state)|\($0.canStart)"
            }
            if signatures != previous || Date().timeIntervalSince(lastReload) >= 60 {
                previous = signatures
                lastReload = Date()
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStorage.kind)
            }
        } catch { self.error = error.localizedDescription }
    }
}
