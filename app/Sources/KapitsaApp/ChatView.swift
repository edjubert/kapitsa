import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatWorkspace: View {
    @EnvironmentObject private var store: InstanceStore
    @EnvironmentObject private var chats: ChatStore

    var body: some View {
        VStack(spacing: 0) {
            if store.rows.isEmpty {
                KapitsaEmptyState(title: "Aucune instance",
                    description: "Démarre une instance dans la section Instances pour commencer une conversation.")
            } else {
                HStack {
                    Picker("Instance", selection: $chats.selectedInstanceID) {
                        ForEach(store.rows) { row in
                            Text("\(row.name) · \(row.snapshot?.model ?? row.profile?.model ?? "arrêtée")").tag(row.id)
                        }
                    }.frame(maxWidth: 430)
                    Spacer()
                    if let row = selected {
                        Label(lifecycleLabel(row.snapshot?.state ?? "stopped"), systemImage: "circle.fill")
                            .font(.caption).foregroundStyle(row.snapshot?.state == "ready" ? .green : .secondary)
                    }
                }.padding(.horizontal, 24).padding(.vertical, 12)
                Divider()
                if let row = selected {
                    ChatConversation(session: chats.session(row.id), row: row).id(row.id)
                }
            }
        }
        .task { selectInitial() }
        .onChange(of: store.rows.map(\.id)) { _, _ in selectInitial() }
    }

    private var selected: InstanceRow? { store.rows.first { $0.id == chats.selectedInstanceID } }
    private func selectInitial() {
        if selected == nil {
            chats.selectedInstanceID = store.rows.first { $0.id == store.selectedId }?.id ?? store.rows.first?.id ?? ""
        }
    }
}

private struct ChatConversation: View {
    @ObservedObject var session: ChatSession
    let row: InstanceRow
    @State private var nearBottom = true
    @State private var dropping = false
    @State private var confirmClear = false

    private var connection: String {
        "\(row.snapshot?.runId ?? "")/\(row.snapshot?.state ?? "")/\(row.snapshot?.model ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = session.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                    Spacer()
                    Button("Fermer", systemImage: "xmark") { session.error = nil }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }.font(.callout).padding(12).background(.orange.opacity(0.12))
            }
            transcript
            composer
        }
        .task(id: connection) {
            await session.connect(address: row.snapshot?.apiUrl, run: row.snapshot?.runId ?? "",
                                  ready: row.snapshot?.state == "ready")
        }
        .sheet(isPresented: $session.needsKey) { ChatKeySheet(session: session) }
        .confirmationDialog("Effacer la conversation de « \(row.name) » ?", isPresented: $confirmClear) {
            Button("Nouvelle conversation", role: .destructive) { session.newChat(); nearBottom = true }
        } message: {
            Text("L’historique de cette instance sera effacé. Les autres conversations sont conservées.")
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { ChatAttachments.dropped($0, into: session) }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 16).stroke(.tint, lineWidth: 3).padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Picker("Modèle", selection: Binding(get: { session.modelID }, set: { id in
                Task { await session.switchModel(id) }
            })) {
                if session.models.isEmpty { Text(row.snapshot?.model ?? "Indisponible").tag("") }
                ForEach(session.models.filter { $0.downloaded == true }) { model in
                    Text(model.title).tag(model.id)
                }
                if session.models.contains(where: { $0.downloaded != true }) {
                    Divider()
                    ForEach(session.models.filter { $0.downloaded != true }) { model in
                        Text("\(model.title) · à télécharger").tag(model.id)
                    }
                }
            }
            .disabled(!session.connected || !session.allowSwitch || session.busy || session.switching)
            .help(session.allowSwitch ? "Changer le modèle de cette instance" : "Le changement de modèle est désactivé sur ce serveur")
            .frame(maxWidth: 320)
            Toggle("Thinking", isOn: $session.thinking).toggleStyle(.checkbox)
                .help("Activer le raisonnement du modèle").disabled(session.busy)
            Spacer()
            if session.switching { ProgressView().controlSize(.small) }
            Button("Clé API", systemImage: "key") { session.needsKey = true }
                .labelStyle(.iconOnly).accessibilityLabel("Clé API").help("Configurer la clé API de cette instance")
            Button("Nouvelle conversation", systemImage: "square.and.pencil") {
                if session.messages.isEmpty { session.newChat() } else { confirmClear = true }
            }.labelStyle(.iconOnly).accessibilityLabel("Nouvelle conversation").help("Nouvelle conversation")
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if session.messages.isEmpty {
                            KapitsaEmptyState(title: "Parlons avec \(row.name)",
                                description: session.connected
                                    ? "Écris un message ou ajoute des images. La conversation reste sur ce Mac."
                                    : "Cette instance doit être prête pour recevoir des messages.")
                                .frame(minHeight: max(160, viewport.size.height - 48))
                        }
                        ForEach(session.messages) { message in
                            ChatMessageView(message: message, streaming: session.busy && message.id == session.messages.last?.id,
                                            timing: session.timing).equatable()
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }.padding(24).frame(maxWidth: 920).frame(maxWidth: .infinity)
                        .background(ChatScrollObserver { nearBottom = $0 })
                }
                .onChange(of: session.streamRevision) { _, _ in
                    if nearBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .onChange(of: session.messages.count) { _, _ in
                    if nearBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                .overlay(alignment: .bottomTrailing) {
                    if !nearBottom {
                        Button("Dernier message", systemImage: "arrow.down") {
                            nearBottom = true
                            withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                        }.buttonStyle(.bordered).padding(16)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.pending.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(session.pending) { image in
                            ChatImageView(image: image, height: 68)
                                .overlay(alignment: .topTrailing) {
                                    Button("Retirer \(image.name)", systemImage: "xmark.circle.fill") {
                                        session.pending.removeAll { $0.id == image.id }
                                    }.labelStyle(.iconOnly).buttonStyle(.borderless).padding(4)
                                }
                        }
                    }.padding(4)
                }
            }
            ZStack(alignment: .topLeading) {
                if session.draft.isEmpty {
                    Text(session.connected ? "Message à \(row.name)…" : "Instance indisponible")
                        .foregroundStyle(.tertiary).padding(.horizontal, 15).padding(.top, 10)
                        .allowsHitTesting(false)
                }
                ChatComposer(text: $session.draft, send: { session.send(); nearBottom = true },
                             images: session.addImages, failure: { session.error = $0 })
                    .frame(height: 84)
            }
            HStack {
                Button("Ajouter des images", systemImage: "photo.badge.plus") { ChatAttachments.choose(session) }
                    .labelStyle(.iconOnly).accessibilityLabel("Ajouter des images").help("Ajouter des images, ou les coller et les déposer ici")
                Text("Entrée pour envoyer · ⇧ Entrée pour une nouvelle ligne")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if session.busy {
                    ProgressView().controlSize(.small)
                    Button("Arrêter", systemImage: "stop.fill") { session.stop() }
                        .help("Arrêter cette réponse ; l’instance reste active")
                } else {
                    Button("Envoyer", systemImage: "arrow.up") { session.send(); nearBottom = true }
                        .buttonStyle(.borderedProminent).disabled(!session.canSend)
                }
            }.padding(.horizontal, 12).padding(.bottom, 10)
        }
        .modifier(NativeGlassCard())
        .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 8)
    }
}

private struct ChatScrollObserver: NSViewRepresentable {
    var changed: (Bool) -> Void
    final class Anchor: NSView {
        var changed: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.observe() }
        }
        private func observe() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let scroll = enclosingScrollView else { return }
            // Content growth and programmatic scrolling must not disable
            // follow mode. Only live user scrolling changes that preference.
            observer = NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification,
                object: scroll, queue: .main) { [weak self, weak scroll] _ in
                    guard let scroll, let document = scroll.documentView else { return }
                    let visible = scroll.documentVisibleRect
                    let remaining = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
                    self?.changed?(remaining < 110)
                }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.changed = changed
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) { view.changed = changed }
}

private struct ChatMessageView: View, Equatable {
    let message: ChatMessage
    let streaming: Bool
    let timing: String
    @State private var reasoningOpen = false
    @State private var manualReasoning = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.streaming == rhs.streaming && lhs.timing == rhs.timing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if message.role == "user" {
                    Label("Vous", systemImage: "person.crop.circle")
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    Label { Text("Kapitsa") } icon: { KapitsaMark() }
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                if !message.content.isEmpty {
                    Button("Copier le message", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                    }.labelStyle(.iconOnly).accessibilityLabel("Copier le message")
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            if !message.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack { ForEach(message.images) { ChatImageView(image: $0, height: 180) } }
                }
            }
            if !message.reasoning.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { reasoningOpen }, set: {
                    reasoningOpen = $0; manualReasoning = true
                })) {
                    ChatMarkdown(text: message.reasoning).font(.callout).foregroundStyle(.secondary)
                        .padding(.top, 8)
                } label: {
                    Label(streaming && message.content.isEmpty ? "Réflexion en cours…" : "Raisonnement",
                          systemImage: "brain").font(.callout).foregroundStyle(.secondary)
                }
                .onAppear { reasoningOpen = streaming && message.content.isEmpty }
                .onChange(of: message.content.isEmpty) { _, empty in
                    if !manualReasoning { reasoningOpen = streaming && empty }
                }
            }
            if !message.content.isEmpty {
                if message.role == "user" { Text(message.content).textSelection(.enabled) }
                else { ChatMarkdown(text: message.content) }
            } else if streaming && message.reasoning.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Préparation de la réponse…").foregroundStyle(.secondary) }
            }
            if let error = message.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if !streaming && message.role == "assistant" {
                ChatStatistics(stats: message.stats, timing: timing)
            }
        }
        .padding(message.role == "user" ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if message.role == "user" { RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)) }
        }
    }
}

private struct ChatImageView: View {
    let image: ChatImage
    let height: CGFloat
    var body: some View {
        if let data = image.bytes, let native = NSImage(data: data) {
            Image(nsImage: native).resizable().scaledToFit().frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(image.name)
        }
    }
}

private struct ChatStatistics: View {
    let stats: ChatStats
    let timing: String
    var body: some View {
        let parts: [String] = [
            stats.tokens.map { "\($0) tokens" },
            stats.tokensPerSecond.map { String(format: "%.1f tok/s", $0) },
            timing == "ttft" || timing == "both" ? stats.firstTokenSeconds.map { String(format: "Premier token : %.2f s", $0) } : nil,
            stats.thinkingSeconds.map { String(format: "Réflexion : %.1f s", $0) },
            timing == "prefill" || timing == "both" ? stats.prefillTokensPerSecond.map { String(format: "Lecture : %.0f tok/s", $0) } : nil,
            (stats.cachedTokens ?? 0) > 0 ? "\(stats.cachedTokens!) tokens en cache" : nil,
            stats.stopped ? "Arrêtée" : nil,
            stats.finish == "length" ? "Limite de contexte atteinte" : nil
        ].compactMap { $0 }
        if !parts.isEmpty { Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
    }
}

private struct ChatKeySheet: View {
    @ObservedObject var session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Clé API de cette instance", systemImage: "key").font(.title2)
            Text("Si le serveur est protégé, sa clé est nécessaire pour le chat. Elle sera conservée dans le trousseau macOS.")
                .foregroundStyle(.secondary)
            SecureField("Clé API", text: $key)
            Text("Un champ vide retire la clé enregistrée.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Enregistrer") {
                    dismiss()
                    Task { await session.setKey(key) }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 450)
    }
}
