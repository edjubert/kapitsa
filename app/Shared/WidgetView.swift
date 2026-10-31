import SwiftUI
import WidgetKit

struct KapitsaWidgetEntry: TimelineEntry {
    let date: Date
    let instance: WidgetInstance?
    var configured = true
}

extension WidgetState {
    var color: Color {
        switch self {
        case .ready: return .green
        case .busy: return .blue
        case .preparing, .loading, .stopping: return .orange
        case .unreachable, .missing: return .red
        case .stopped: return .secondary
        }
    }
}

struct KapitsaWidgetView: View {
    let entry: KapitsaWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let instance = entry.instance { content(instance) }
            else {
                VStack(alignment: .leading, spacing: 8) {
                    KapitsaWordmark(width: 128)
                    Spacer()
                    Text(entry.configured ? "Instance indisponible" : "Choisir une instance")
                        .font(.headline)
                        .foregroundStyle(entry.configured ? Color.red : Color.primary)
                    Text(entry.configured ?
                        "Ouvre Kapitsa ou modifie la cible du widget." :
                        "Modifie ce widget pour sélectionner une instance.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [(entry.instance?.state.color ??
                    (entry.configured ? .red : .secondary)).opacity(0.16), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .widgetURL(entry.instance?.deepLink)
    }

    private func content(_ value: WidgetInstance) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 7 : 12) {
            HStack {
                Label { Text(value.name) } icon: { KapitsaMark() }
                    .font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                if family != .systemSmall {
                    Button(intent: RefreshKapitsaInstanceIntent(id: value.id)) {
                        Image(systemName: "arrow.clockwise")
                    }.buttonStyle(.plain).accessibilityLabel("Actualiser cette instance")
                }
            }
            Label(value.state.title, systemImage: value.state.symbol)
                .font(.subheadline.weight(.semibold)).foregroundStyle(value.state.color)
            Text(value.model.isEmpty ? "Kapitsa" : value.model)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if family == .systemLarge { details(value) }
            else if family == .systemMedium {
                HStack(spacing: 24) {
                    metric("Requêtes", value.state == .unreachable ? "—" : "\(value.activeRequests)",
                           "arrow.triangle.2.circlepath")
                    if let rate = value.tokensPerSecond {
                        metric("Débit", "\(rate.formatted(.number.precision(.fractionLength(1)))) tok/s", "speedometer")
                    }
                    if let used = value.memoryUsedBytes { metric("Mémoire", bytes(used), "memorychip") }
                }
            }
            Spacer(minLength: 0)
            HStack {
                if value.canStop, let run = value.runId {
                    Button(intent: StopKapitsaInstanceIntent(id: value.id, run: run)) {
                        Label("Arrêter", systemImage: "stop.fill")
                    }.tint(.red).accessibilityHint("Interrompt les requêtes de cette instance.")
                } else if value.canLaunch {
                    Button(intent: StartKapitsaInstanceIntent(id: value.id)) {
                        Label("Démarrer", systemImage: "play.fill")
                    }.tint(.green)
                } else {
                    Text(value.state == .stopped ? "Configurer dans l’app" : "Ouvrir dans l’app")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if family != .systemSmall {
                    Spacer()
                    Text(entry.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel("Âge de la dernière vérification")
                }
            }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func details(_ value: WidgetInstance) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let used = value.memoryUsedBytes, let budget = value.memoryBudgetBytes, budget > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Mémoire", systemImage: "memorychip")
                        Spacer()
                        Text("\(bytes(used)) / \(bytes(budget))")
                    }.font(.caption)
                    ProgressView(value: min(Double(used) / Double(budget), 1))
                        .tint(used > budget ? .orange : value.state.color)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                GridRow {
                    metric("Contexte", value.context.map { "\($0.formatted()) tokens" } ?? "Automatique", "text.alignleft")
                    metric("Conversations", value.slots.map(String.init) ?? "Automatique", "bubble.left.and.bubble.right")
                }
                GridRow {
                    metric("Requêtes", value.state == .unreachable ? "—" : "\(value.activeRequests) en cours",
                           "arrow.triangle.2.circlepath")
                    metric("Débit", value.tokensPerSecond.map {
                        "\($0.formatted(.number.precision(.fractionLength(1)))) tok/s"
                    } ?? "—", "speedometer")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let quant = value.quant { Text(quant).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let tokens = value.completionTokens {
                Text("\(tokens.formatted()) tokens · \(value.activeRequests == 0 ? "dernière requête" : "génération en cours")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let api = value.apiUrl {
                Label(api, systemImage: "network").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func bytes(_ value: UInt64) -> String {
        "\((Double(value) / 1e9).formatted(.number.precision(.fractionLength(1)))) GB"
    }
}
