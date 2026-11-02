import SwiftUI
import AppKit

enum DesktopSection: String, CaseIterable, Identifiable {
    case instances, chat, downloaded, catalog, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .instances: return "Instances"
        case .chat: return "Chat"
        case .downloaded: return "Modèles téléchargés"
        case .catalog: return "Catalogue"
        case .settings: return "Réglages"
        }
    }
    var symbol: String {
        switch self {
        case .instances: return "cpu"
        case .chat: return "bubble.left.and.bubble.right"
        case .downloaded: return "internaldrive"
        case .catalog: return "square.grid.2x2"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct DesktopView: View {
    private struct LaunchRequest: Identifiable {
        let id = UUID()
        let model: String
    }

    @EnvironmentObject private var store: InstanceStore
    @EnvironmentObject private var library: ModelLibrary
    @EnvironmentObject private var chats: ChatStore
    @State private var section: DesktopSection? = .instances
    @State private var launchRequest: LaunchRequest?

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("Espace de travail") {
                    ForEach([DesktopSection.instances, .chat, .downloaded, .catalog], id: \.self) { item in
                        Button {
                            section = item
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain).badge(count(for: item)).tag(Optional(item))
                    }
                }
                Section {
                    Button {
                        section = .settings
                    } label: {
                        Label(DesktopSection.settings.title, systemImage: DesktopSection.settings.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain).tag(Optional(DesktopSection.settings))
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
            .safeAreaInset(edge: .top) {
                KapitsaWordmark(width: 168)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 16)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("\(store.rows.filter { $0.snapshot != nil }.count) instance(s) active(s)",
                          systemImage: "circle.fill").font(.caption).foregroundStyle(.secondary)
                    Text("\(byteLabel(library.bytes)) de modèles")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        } detail: {
            VStack(spacing: 0) {
                if let error = store.lastError ?? library.error {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .textSelection(.enabled)
                        Spacer()
                        Button("Fermer", systemImage: "xmark") {
                            store.lastError = nil
                            library.error = nil
                        }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    }.frame(maxWidth: .infinity)
                    .font(.callout).padding(12)
                    .background(.orange.opacity(0.12))
                }
                if library.downloadId != nil { DownloadActivity() }
                content
            }
            .navigationTitle((section ?? .instances).title)
            .toolbar {
                ToolbarItemGroup {
                    Button("Actualiser", systemImage: "arrow.clockwise") {
                        Task { await store.refresh(); await library.refresh() }
                    }.help("Actualiser les instances et les modèles")
                    Button("Nouvelle instance", systemImage: "plus") {
                        launchRequest = LaunchRequest(model: "")
                    }
                    .help("Démarrer une nouvelle instance")
                }
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .background(DesktopWindowMarker())
        .task { await library.refresh() }
        .onChange(of: chats.openRequest) { _, _ in section = .chat; chats.openingChat = false }
        .onChange(of: store.editing?.id) { _, value in if value != nil { section = .instances } }
        .onChange(of: store.widgetOpenRequest) { _, _ in section = .instances }
        .onAppear {
            if chats.openingChat { section = .chat; chats.openingChat = false }
            if store.editing != nil { section = .instances }
        }
        .sheet(item: $launchRequest) { request in
            NewInstanceForm(creating: Binding(
                get: { launchRequest != nil },
                set: { if !$0 { launchRequest = nil } }), initialModel: request.model)
                .padding(24).frame(width: 530)
        }
        .sheet(item: $store.editing) { request in EditInstanceView(request: request) }
        .alert("Supprimer « \(store.deletion?.name ?? "") » ?", isPresented: Binding(
            get: { store.deletion != nil }, set: { if !$0 { store.deletion = nil } })) {
                Button("Annuler", role: .cancel) { store.deletion = nil }
                Button("Supprimer", role: .destructive) {
                    if let target = store.deletion { Task { await store.delete(target) } }
                    store.deletion = nil
                }
            } message: {
                Text("L’instance sera arrêtée si elle fonctionne encore, puis sa configuration sera supprimée. Ses modèles téléchargés et son historique de chat seront conservés.")
            }
    }

    @ViewBuilder private var content: some View {
        switch section ?? .instances {
        case .instances: InstancesWorkspace()
        case .chat: ChatWorkspace()
        case .downloaded:
            DownloadedModelsView { model in launchRequest = LaunchRequest(model: model) }
        case .catalog:
            CatalogView { model in launchRequest = LaunchRequest(model: model) }
        case .settings: PreferencesView()
        }
    }

    private func count(for item: DesktopSection) -> Int {
        switch item {
        case .instances: return store.rows.filter { $0.snapshot != nil }.count
        case .downloaded: return library.installed.count
        default: return 0
        }
    }
}

enum DesktopWindowFocus {
    static let identifier = NSUserInterfaceItemIdentifier("kapitsa-desktop")

    @MainActor static func activate() {
        // Opening an existing SwiftUI scene need not make its NSWindow key
        // while a status-item panel has focus. Bring the desktop forward after
        // openWindow has had a chance to create/reveal it.
        DispatchQueue.main.async {
            NSApplication.shared.windows.first { $0.identifier == identifier }?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

struct DesktopWindowMarker: NSViewRepresentable {
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = DesktopWindowFocus.identifier
        }
    }
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ nsView: Anchor, context: Context) {}
}

struct InstancesWorkspace: View {
    @EnvironmentObject private var store: InstanceStore
    var body: some View {
        if store.rows.isEmpty {
            KapitsaEmptyState(title: "Aucune instance",
                description: "Démarre un modèle avec le bouton +. Les instances lancées depuis la CLI apparaissent aussi ici.")
        } else {
            HSplitView {
                List(selection: $store.selectedId) {
                    ForEach(store.rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(row.name).font(.headline).lineLimit(1)
                                Spacer()
                                Circle().fill(row.lifecycle == "unreachable" ? .red :
                                    row.snapshot == nil ? .gray : row.lifecycle == "ready" ? .green : .orange)
                                    .frame(width: 7, height: 7)
                            }
                            Text(abbreviatedHomePath(row.snapshot?.model ?? row.profile?.model ?? "Instance injoignable"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(lifecycleLabel(row.lifecycle))
                                .font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(row.id)
                        .contextMenu {
                            Button("Supprimer l’instance…", systemImage: "trash", role: .destructive) {
                                store.deletion = row
                            }.disabled(store.isChanging(row.id))
                        }
                    }
                }.listStyle(.inset).frame(minWidth: 185, idealWidth: 220, maxWidth: 300)
                if let row = store.selected {
                    InstanceDetailView(row: row)
                        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    KapitsaEmptyState(title: "Choisis une instance")
                }
            }
        }
    }
}

struct InstanceDetailView: View {
    @EnvironmentObject private var store: InstanceStore
    @EnvironmentObject private var chats: ChatStore
    let row: InstanceRow
    @State private var stopTarget: InstanceRow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.name).font(.largeTitle.weight(.semibold))
                        Label(lifecycleLabel(row.lifecycle),
                              systemImage: row.lifecycle == "unreachable" ? "exclamationmark.circle" :
                                row.snapshot == nil ? "pause.circle" : "checkmark.circle.fill")
                            .foregroundStyle(row.lifecycle == "unreachable" ? Color.red :
                                row.snapshot == nil ? Color.secondary : row.lifecycle == "ready" ? Color.green : Color.orange)
                    }
                    Spacer()
                    if row.editableConfiguration != nil {
                        Button("Modifier", systemImage: "pencil") { store.editing = InstanceEditRequest(row) }
                            .disabled(store.isChanging(row.id) || row.snapshot?.state == "stopping")
                            .accessibilityIdentifier("instance-edit")
                    }
                    if row.snapshot != nil {
                        Button("Arrêter", systemImage: "stop.fill", role: .destructive) { stopTarget = row }
                            .disabled(row.snapshot?.state == "stopping" || store.isChanging(row.id))
                    } else if let config = row.profile {
                        Button("Démarrer", systemImage: "play.fill") { Task { await store.start(config) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(row.record != nil || store.isChanging(row.id))
                    }
                    Button("Supprimer", systemImage: "trash", role: .destructive) { store.deletion = row }
                        .disabled(store.isChanging(row.id))
                        .accessibilityIdentifier("instance-delete")
                }
                if store.deletingIDs.contains(row.id) {
                    Label("Arrêt et suppression en cours…", systemImage: "trash").foregroundStyle(.secondary)
                } else if store.startingIDs.contains(row.id) {
                    Label("Démarrage en cours…", systemImage: "play.circle").foregroundStyle(.secondary)
                } else if store.restartingIDs.contains(row.id) {
                    Label("Redémarrage en cours…", systemImage: "arrow.clockwise").foregroundStyle(.secondary)
                }
                if row.hasPendingChanges {
                    Label("Modifications enregistrées : elles seront appliquées au prochain lancement.",
                          systemImage: "clock.arrow.circlepath")
                        .font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                if let profile = row.profile, row.record == nil || row.hasPendingChanges {
                    InstanceConfigurationSummary(configuration: profile)
                }
                if let state = row.snapshot {
                    HStack(spacing: 14) {
                        MetricCard(title: "Conversations", value: "\(state.requests.count)",
                                   subtitle: "\(state.slots ?? 0) simultanées", symbol: "bubble.left.and.bubble.right")
                        MetricCard(title: "Contexte", value: state.context?.formatted() ?? "Auto",
                                   subtitle: "tokens par conversation", symbol: "text.alignleft")
                    }
                    GroupBox("Modèle et serveur") {
                        VStack(spacing: 10) {
                            LabeledContent("Modèle", value: abbreviatedHomePath(state.model))
                            if let quant = state.quant { LabeledContent("Précision", value: quant) }
                            if let used = state.memoryUsedBytes, let budget = state.memoryBudgetBytes {
                                LabeledContent("Mémoire", value: "\(byteLabel(used)) / \(byteLabel(budget))")
                                ProgressView(value: Double(used), total: Double(max(1, budget)))
                            }
                            LabeledContent("API") { Text(state.apiUrl).textSelection(.enabled) }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity)
                    HStack {
                        Button("Ouvrir le chat", systemImage: "bubble.left") {
                            chats.open(row.id)
                        }.disabled(state.state != "ready")
                        Button("Copier l’URL", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(state.apiUrl, forType: .string)
                        }
                    }
                    if !state.requests.isEmpty {
                        Text("Activité").font(.title2.weight(.semibold))
                        ForEach(state.requests) { request in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label(request.client.isEmpty ? "Requête" : request.client,
                                              systemImage: "waveform")
                                        Spacer()
                                        Text(lifecycleLabel(request.phase)).foregroundStyle(.secondary)
                                    }
                                    Text("\(request.completionTokens) tokens · \(request.tokensPerSecond, specifier: "%.1f") tok/s")
                                        .font(.title3.monospacedDigit())
                                    Text("\(request.promptTokens) tokens d’entrée · \(request.cachedTokens) en cache")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if request.phase == "prefill" {
                                        ProgressView(value: Double(request.readTokens),
                                                     total: Double(max(1, request.promptTokens)))
                                    }
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else if let last = state.lastRequest {
                        GroupBox("Dernière requête") {
                            LabeledContent("\(last.completionTokens) tokens générés",
                                value: String(format: "%.1f tok/s", last.tokensPerSecond)).padding(8)
                        }
                    }
                    if let events = store.history[state.runId], !events.isEmpty {
                        DisclosureGroup("Événements récents") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(events.suffix(30))) { event in
                                    if let message = event.data.message {
                                        Text(message).font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .foregroundStyle(event.data.level == 0 ? Color.red : Color.secondary)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }
                    }
                } else {
                    Text(row.error ?? "Cette configuration est enregistrée. Démarre-la pour charger son modèle.")
                        .foregroundStyle(.secondary)
                    if row.record != nil {
                        Text("Le runtime détient encore le verrou de cette instance. Son démarrage restera indisponible tant qu’il ne sera pas arrêté.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Button("Voir le journal", systemImage: "doc.text") {
                    NSWorkspace.shared.open(Registry.home.appendingPathComponent("logs/instance-\(row.id).log"))
                }
                Text("Fermer Kapitsa laisse les instances actives. Leur arrêt est une action explicite.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .alert("Arrêter « \(stopTarget?.name ?? "") » ?", isPresented: Binding(
            get: { stopTarget != nil }, set: { if !$0 { stopTarget = nil } })) {
                Button("Annuler", role: .cancel) { stopTarget = nil }
                Button("Arrêter", role: .destructive) {
                    if let target = stopTarget { Task { await store.stop(target) } }
                    stopTarget = nil
                }
            } message: { Text("Les requêtes en cours seront interrompues.") }
    }
}

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
    case "unreachable": return "Injoignable"
    default: return state
    }
}
