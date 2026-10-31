import SwiftUI
import WidgetKit

struct KapitsaWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> KapitsaWidgetEntry {
        KapitsaWidgetEntry(date: Date(), instance: .example)
    }

    func snapshot(for configuration: SelectKapitsaInstanceIntent, in context: Context) async -> KapitsaWidgetEntry {
        if context.isPreview { return placeholder(in: context) }
        return await entry(configuration)
    }

    func timeline(for configuration: SelectKapitsaInstanceIntent, in context: Context) async -> Timeline<KapitsaWidgetEntry> {
        let value = await entry(configuration)
        // WidgetKit owns the refresh budget; this is not continuous monitoring.
        return Timeline(entries: [value], policy: .after(Date().addingTimeInterval(60)))
    }

    private func entry(_ configuration: SelectKapitsaInstanceIntent) async -> KapitsaWidgetEntry {
        guard let id = configuration.instance?.id else {
            return KapitsaWidgetEntry(date: Date(), instance: nil, configured: false)
        }
        let value: WidgetInstance?
        if let storage = WidgetSharedStorage.shared {
            value = await WidgetStatusReader.read(id: id, storage: storage)
        } else { value = nil }
        return KapitsaWidgetEntry(date: Date(), instance: value)
    }
}

@main
struct KapitsaWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetSharedStorage.kind,
            intent: SelectKapitsaInstanceIntent.self, provider: KapitsaWidgetProvider()) { entry in
            KapitsaWidgetView(entry: entry)
        }
        .configurationDisplayName("Instance Kapitsa")
        .description("Une instance, son activité et ses commandes de démarrage et d’arrêt.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
