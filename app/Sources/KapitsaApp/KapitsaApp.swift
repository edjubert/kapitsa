import SwiftUI
import AppKit

@main
struct KapitsaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: InstanceStore
    @StateObject private var library = ModelLibrary()
    @StateObject private var settings = AppSettings()
    @StateObject private var chats = ChatStore()

    init() {
        let instances = InstanceStore()
        _store = StateObject(wrappedValue: instances)
        WidgetActionRouter.perform = { [weak instances] command in
            guard let instances else { throw RuntimeFailure.message("Kapitsa se ferme.") }
            do {
                try await instances.handleWidget(command)
                instances.lastError = nil
            }
            catch { instances.lastError = error.localizedDescription; throw error }
        }
    }

    var body: some Scene {
        Window("Kapitsa", id: "desktop") {
            DesktopView()
                .environmentObject(store)
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(chats)
                .onAppear { delegate.cancelActivities = { library.cancelDownload(); chats.stopAll() } }
                .onOpenURL { url in
                    guard url.scheme == "kapitsa", url.host == "instance",
                          url.pathComponents.count == 2 else { return }
                    let id = url.lastPathComponent
                    Task {
                        do { try await store.handleWidget(.refresh(id)) }
                        catch { store.lastError = error.localizedDescription }
                        DesktopWindowFocus.activate()
                    }
                }
        }
        .defaultSize(width: 1120, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenDesktopCommand()
            }
        }
        MenuBarExtra {
            InstanceMenu().environmentObject(store).environmentObject(settings).environmentObject(chats)
        } label: {
            RuntimeBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
        Settings {
            PreferencesView().environmentObject(settings).environmentObject(library)
                .frame(width: 620, height: 580)
        }
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
    var cancelActivities: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        cancelActivities?()
    }
}

struct OpenDesktopCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Ouvrir Kapitsa") {
            openWindow(id: "desktop")
            DesktopWindowFocus.activate()
        }.keyboardShortcut("0", modifiers: .command)
    }
}

struct InstanceMenu: View {
    @EnvironmentObject private var store: InstanceStore
    @EnvironmentObject private var chats: ChatStore
    @Environment(\.openWindow) private var openWindow
    @State private var creating = false
    @State private var stopTarget: InstanceRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Kapitsa").font(.headline)
                Spacer()
                Button("Ouvrir l’app", systemImage: "macwindow") {
                    openWindow(id: "desktop")
                    DesktopWindowFocus.activate()
                }.labelStyle(.iconOnly).help("Ouvrir la fenêtre Kapitsa")
                Text("\(store.rows.filter { $0.snapshot != nil }.count) instance(s)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let target = stopTarget {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Arrêter « \(target.name) » ?").font(.headline)
                    Text("Les requêtes en cours seront interrompues.").font(.caption)
                    HStack {
                        Button("Annuler") { stopTarget = nil }
                        Spacer()
                        Button("Confirmer l’arrêt", role: .destructive) {
                            stopTarget = nil
                            Task { await store.stop(target) }
                        }
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Divider()
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
                    chats.open(row.id)
                    openWindow(id: "desktop")
                    DesktopWindowFocus.activate()
                }.disabled(state.state != "ready")
                Spacer()
                Button("Arrêter", role: .destructive) {
                    stopTarget = row
                }
                    .disabled(state.state == "stopping" || store.restartingIDs.contains(row.id))
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
                    .disabled(row.record != nil || store.restartingIDs.contains(row.id))
            }
        }
        if row.editableConfiguration != nil {
            Button("Modifier l’instance…", systemImage: "pencil") {
                store.editing = InstanceEditRequest(row)
                openWindow(id: "desktop")
                DesktopWindowFocus.activate()
            }.disabled(store.restartingIDs.contains(row.id) || row.snapshot?.state == "stopping")
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
    @EnvironmentObject private var settings: AppSettings
    @Binding var creating: Bool
    var initialModel = ""
    @State private var name = ""
    @State private var model = ""
    @State private var context = ""
    @State private var port = "8000"
    @State private var slots = 0
    @State private var error: String?
    @State private var launching = false
    @State private var advanced = LaunchDefaults()

    private var capacityQuery: CapacityQuery {
        var options = advanced
        options.context = context
        options.slots = slots
        return CapacityQuery(model: model, defaults: options)
    }

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
            DisclosureGroup("Options du moteur") {
                EngineOptionsFields(value: $advanced)
            }
            ModelCapacityBanner(query: capacityQuery).id(capacityQuery)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Annuler") { creating = false }
                Spacer()
                Button("Démarrer") {
                    do {
                        guard let number = Int(port), (1...65535).contains(number) else {
                            throw RuntimeFailure.message("Le port doit être compris entre 1 et 65535.")
                        }
                        let config = try advanced.configuration(name: name, model: model,
                            port: number, context: context, slots: slots)
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
            advanced = settings.defaults
            model = initialModel.isEmpty ? settings.defaults.model : initialModel
            context = settings.defaults.context
            slots = settings.defaults.slots
            port = String(settings.availablePort(in: store.rows))
        }
    }
}
