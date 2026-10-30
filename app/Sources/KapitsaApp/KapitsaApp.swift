import SwiftUI
import AppKit

@main
struct KapitsaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = InstanceStore()

    var body: some Scene {
        MenuBarExtra {
            InstanceMenu().environmentObject(store)
        } label: {
            RuntimeBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct RuntimeBarLabel: View {
    @ObservedObject var store: InstanceStore
    var body: some View {
        Label(store.activeRequests > 0 ? "Kapitsa · \(store.activeRequests)" : "Kapitsa",
              systemImage: "cpu")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

struct InstanceMenu: View {
    @EnvironmentObject private var store: InstanceStore
    @State private var creating = false
    @State private var confirmStop = false
    @State private var stopTarget: InstanceRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Kapitsa").font(.headline)
                Spacer()
                Text("\(store.rows.filter { $0.snapshot != nil }.count) instance(s)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if !store.rows.isEmpty {
                Picker("Instance", selection: $store.selectedId) {
                    ForEach(store.rows) { row in
                        Text("\(row.name) · \(row.snapshot == nil ? "arrêtée" : "active")").tag(row.id)
                    }
                }
                if let row = store.selected { instance(row) }
            } else {
                Text("Démarre une instance ici, ou retrouve celles lancées depuis la CLI.")
                    .foregroundStyle(.secondary)
            }
            Divider()
            if creating {
                NewInstanceForm(creating: $creating).environmentObject(store)
            } else {
                Button("Nouvelle instance…", systemImage: "plus") { creating = true }
            }
            Divider()
            HStack {
                Button("Actualiser") { Task { await store.refresh() } }
                Spacer()
                Button("Quitter l’app") { NSApplication.shared.terminate(nil) }
            }
            Text("Les instances continuent à fonctionner quand l’app se ferme.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 440)
        .alert("Arrêter cette instance ?", isPresented: $confirmStop) {
            Button("Annuler", role: .cancel) { stopTarget = nil }
            Button("Arrêter", role: .destructive) {
                if let row = stopTarget { Task { await store.stop(row) } }
                stopTarget = nil
            }
        } message: {
            Text("Les requêtes en cours de « \(stopTarget?.name ?? "") » seront interrompues.")
        }
    }

    @ViewBuilder
    private func instance(_ row: InstanceRow) -> some View {
        if let state = row.snapshot {
            HStack {
                Circle().fill(state.state == "ready" ? .green : .orange).frame(width: 8, height: 8)
                Text(stateLabel(state.state))
                Spacer()
                Text(state.model).font(.caption).lineLimit(1)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                if let context = state.context {
                    GridRow { Text("Contexte"); Text("\(context.formatted()) tokens × \(state.slots ?? 0)") }
                }
                if let quant = state.quant, !quant.isEmpty {
                    GridRow { Text("Précision"); Text(quant).lineLimit(2) }
                }
                if let used = state.memoryUsedBytes, let budget = state.memoryBudgetBytes {
                    GridRow {
                        Text("Mémoire")
                        Text("\(Double(used) / 1e9, specifier: "%.1f") / \(Double(budget) / 1e9, specifier: "%.1f") GB")
                    }
                }
                GridRow {
                    Text("API")
                    Text(state.apiUrl).textSelection(.enabled)
                }
            }
            .font(.caption)
            ForEach(state.requests) { request in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(request.client.isEmpty ? "Requête" : request.client)
                        Spacer()
                        Text(stateLabel(request.phase)).foregroundStyle(.secondary)
                    }
                    Text("\(request.completionTokens) tokens · \(request.tokensPerSecond, specifier: "%.1f") tok/s · \(request.tokensPerStep, specifier: "%.1f") tokens/étape")
                    if request.promptTokens > 0 {
                        Text("\(request.promptTokens) tokens d’entrée · \(request.cachedTokens) en cache")
                            .foregroundStyle(.secondary)
                        if request.phase == "prefill" {
                            ProgressView(value: Double(request.readTokens),
                                         total: Double(max(1, request.promptTokens)))
                        }
                    }
                }
                .font(.caption)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            if state.requests.isEmpty, let last = state.lastRequest {
                Text("Dernière requête : \(last.completionTokens) tokens · \(last.tokensPerSecond, specifier: "%.1f") tok/s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Ouvrir le chat") {
                    if let url = URL(string: state.apiUrl) { NSWorkspace.shared.open(url) }
                }.disabled(state.state != "ready")
                Spacer()
                Button("Arrêter", role: .destructive) {
                    stopTarget = row
                    confirmStop = true
                }
                    .disabled(state.state == "stopping")
            }
            if let events = store.history[state.runId], !events.isEmpty {
                DisclosureGroup("Événements récents") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(events.suffix(20))) { event in
                                if let message = event.data.message {
                                    Text(message).textSelection(.enabled)
                                        .foregroundStyle(event.data.level == 0 ? .red : .secondary)
                                } else if event.type == "request_finished" {
                                    Text("Requête terminée · \(event.data.completionTokens ?? 0) tokens")
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 130).font(.caption2)
                }.font(.caption)
            }
        } else {
            Text(row.error == nil ? "Instance arrêtée" : "Instance injoignable").foregroundStyle(.secondary)
            if let profile = row.profile {
                Button("Démarrer « \(row.name) »") { Task { await store.start(profile) } }
            }
        }
        Button("Voir le journal") {
            NSWorkspace.shared.open(Registry.home.appendingPathComponent("logs/instance-\(row.id).log"))
        }.font(.caption)
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "starting", "preparing": return "Préparation"
        case "loading": return "Chargement"
        case "ready": return "Prête"
        case "stopping": return "Arrêt en cours"
        case "waiting": return "En attente"
        case "prefill": return "Lecture du prompt"
        case "writing": return "Génération"
        case "done": return "Terminée"
        default: return state
        }
    }
}

struct NewInstanceForm: View {
    @EnvironmentObject private var store: InstanceStore
    @Binding var creating: Bool
    @State private var name = ""
    @State private var model = ""
    @State private var context = ""
    @State private var port = "8000"
    @State private var slots = 0
    @State private var error: String?
    @State private var launching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nouvelle instance").font(.subheadline)
            TextField("Nom de l’instance", text: $name)
            HStack {
                TextField("Modèle : 27b, 4b, ou dossier", text: $model)
                Button("Parcourir…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { model = url.path }
                }
            }
            HStack {
                TextField("Contexte automatique, ou 90k", text: $context)
                TextField("Port", text: $port).frame(width: 70)
            }
            Picker("Conversations simultanées", selection: $slots) {
                Text("Automatique").tag(0)
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Annuler") { creating = false }
                Spacer()
                Button("Démarrer") {
                    do {
                        guard let number = Int(port), (1...65535).contains(number) else {
                            throw RuntimeFailure.message("Le port doit être compris entre 1 et 65535.")
                        }
                        let config = RuntimeConfiguration(instanceId: UUID().uuidString.lowercased(),
                            name: name.trimmingCharacters(in: .whitespaces),
                            model: (model as NSString).expandingTildeInPath,
                            port: number, context: try RuntimeConfiguration.contextTokens(context),
                            slots: slots == 0 ? nil : slots)
                        guard !config.name.isEmpty, config.name.utf8.count <= 128,
                              !config.model.isEmpty else {
                            throw RuntimeFailure.message("Renseigne un nom et un modèle.")
                        }
                        launching = true
                        Task {
                            await store.start(config)
                            launching = false
                            if store.lastError == nil { creating = false }
                        }
                    } catch { self.error = error.localizedDescription }
                }.disabled(launching)
            }
        }
        .onAppear {
            let used = Set(store.rows.compactMap { $0.snapshot.flatMap { URLComponents(string: $0.apiUrl)?.port } })
            port = String((8000...65535).first { !used.contains($0) } ?? 8000)
        }
    }
}
