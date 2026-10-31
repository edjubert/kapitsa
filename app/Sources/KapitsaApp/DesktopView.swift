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
                Section("Kapitsa") {
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
        .onAppear {
            if chats.openingChat { section = .chat; chats.openingChat = false }
        }
        .sheet(item: $launchRequest) { request in
            NewInstanceForm(creating: Binding(
                get: { launchRequest != nil },
                set: { if !$0 { launchRequest = nil } }), initialModel: request.model)
                .padding(24).frame(width: 530)
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
            ContentUnavailableView("Aucune instance", systemImage: "cpu",
                description: Text("Démarre un modèle avec le bouton +. Les instances lancées depuis la CLI apparaissent aussi ici."))
        } else {
            HSplitView {
                List(selection: $store.selectedId) {
                    ForEach(store.rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(row.name).font(.headline).lineLimit(1)
                                Spacer()
                                Circle().fill(row.snapshot == nil ? .gray : .green).frame(width: 7, height: 7)
                            }
                            Text(row.snapshot?.model ?? row.profile?.model ?? "Instance injoignable")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(lifecycleLabel(row.snapshot?.state ?? "stopped"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(row.id)
                    }
                }.listStyle(.inset).frame(minWidth: 185, idealWidth: 220, maxWidth: 300)
                if let row = store.selected {
                    InstanceDetailView(row: row)
                        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Choisis une instance", systemImage: "cpu")
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
                        Label(lifecycleLabel(row.snapshot?.state ?? "stopped"),
                              systemImage: row.snapshot == nil ? "pause.circle" : "checkmark.circle.fill")
                            .foregroundStyle(row.snapshot == nil ? Color.secondary : Color.green)
                    }
                    Spacer()
                    if row.snapshot != nil {
                        Button("Arrêter", systemImage: "stop.fill", role: .destructive) { stopTarget = row }
                            .disabled(row.snapshot?.state == "stopping")
                    } else if let config = row.profile {
                        Button("Démarrer", systemImage: "play.fill") { Task { await store.start(config) } }
                            .buttonStyle(.borderedProminent)
                    }
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
                            LabeledContent("Modèle", value: state.model)
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
                    if row.record == nil {
                        Button("Oublier cette configuration", role: .destructive) { store.forget(row) }
                    }
                }
                Divider()
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
    default: return state
    }
}
