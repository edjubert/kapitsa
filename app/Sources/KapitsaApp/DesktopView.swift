import SwiftUI
import AppKit

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NativeGlassCard())
    }
}

struct NativeGlassCard: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

struct DownloadActivity: View {
    @EnvironmentObject private var library: ModelLibrary
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.down.circle").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(library.downloadId ?? "").font(.callout.weight(.medium))
                if library.downloadTotal > 0 {
                    ProgressView(value: Double(library.downloaded), total: Double(library.downloadTotal))
                    Text("\(library.downloadPhase) · \(byteLabel(library.downloaded)) / \(byteLabel(library.downloadTotal))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack { ProgressView().controlSize(.small); Text(library.downloadPhase).font(.caption) }
                }
            }
            Button("Interrompre") { library.cancelDownload() }
        }.padding(16).background(.quaternary)
    }
}

func lifecycleLabel(_ state: String) -> String {
    switch state {
    case "starting", "preparing": return "Préparation"
    case "loading": return "Chargement"
    case "ready": return "Prête"
    case "stopping": return "Arrêt en cours"
    case "waiting": return "En attente"
    case "prefill": return "Lecture des messages"
    case "writing": return "Génération"
    case "done": return "Terminée"
    case "stopped": return "Arrêtée"
    default: return state
    }
}
