import SwiftUI
import UniformTypeIdentifiers

struct InstanceEditRequest: Identifiable {
    let id = UUID()
    let row: InstanceRow
    let configuration: RuntimeConfiguration

    init?(_ row: InstanceRow) {
        guard let configuration = row.editableConfiguration else { return nil }
        self.row = row
        self.configuration = configuration
    }
}

struct EditInstanceView: View {
    @EnvironmentObject private var store: InstanceStore
    @EnvironmentObject private var library: ModelLibrary
    @Environment(\.dismiss) private var dismiss
    let request: InstanceEditRequest
    @State private var name: String
    @State private var draft: LaunchDefaults
    @State private var error: String?
    @State private var saving = false
    @State private var choosingFolder = false
    @State private var restartConfiguration: RuntimeConfiguration?

    init(request: InstanceEditRequest) {
        self.request = request
        _name = State(initialValue: request.configuration.name)
        _draft = State(initialValue: LaunchDefaults(configuration: request.configuration))
    }

    private var capacityQuery: CapacityQuery {
        CapacityQuery(model: draft.model, defaults: draft, drafter: request.configuration.dflash)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    KapitsaMark()
                    Text("Modifier l’instance").font(.title2.weight(.semibold))
                }
                Text(request.row.record == nil || !request.row.canRestart
                     ? "Les changements seront utilisés au prochain lancement."
                     : "Enregistre les changements pour plus tard, ou redémarre l’instance pour les appliquer.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Form {
                Section("Instance") {
                    TextField("Nom", text: $name).accessibilityIdentifier("instance-edit-name")
                    LabeledContent("Identifiant") {
                        Text(request.configuration.instanceId).font(.caption).textSelection(.enabled)
                    }
                }
                Section("Modèle et serveur") {
                    TextField("Modèle", text: $draft.model).accessibilityIdentifier("instance-edit-model")
                    HStack {
                        if !library.installed.filter(\.runnable).isEmpty {
                            Menu("Modèles téléchargés") {
                                ForEach(library.installed.filter(\.runnable)) { model in
                                    Button(model.name) { draft.model = model.dir }
                                }
                            }
                        }
                        Button("Choisir un dossier…", systemImage: "folder") { choosingFolder = true }
                    }
                    TextField("Port API", value: $draft.port, format: .number.grouping(.never))
                        .accessibilityIdentifier("instance-edit-port")
                    TextField("Contexte (tokens)", text: $draft.context, prompt: Text("Automatique, ou 90k"))
                    Picker("Conversations simultanées", selection: $draft.slots) {
                        Text("Automatique").tag(0)
                        ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                    }
                    ModelCapacityBanner(query: capacityQuery, replacingInstanceId: request.row.id)
                        .id(capacityQuery)
                }
                Section("Options du moteur") { EngineOptionsFields(value: $draft) }
                if request.row.record != nil && !request.row.canRestart {
                    Section {
                        Label("La configuration d’origine complète n’est pas disponible. Les champs connus préremplissent une configuration pour l’app ; les autres options ne sont pas reprises. Arrête l’instance avant de la relancer depuis l’app.",
                              systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if saving { ProgressView().controlSize(.small) }
                    Button("Enregistrer") { submit(restart: false) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("instance-edit-save")
                    if request.row.canRestart {
                        Button("Enregistrer et redémarrer…") { submit(restart: true) }
                            .accessibilityIdentifier("instance-edit-restart")
                    }
                }
            }.padding(20)
        }
        .frame(width: 620, height: 710)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            do { draft.model = try result.get().path }
            catch { self.error = error.localizedDescription }
        }
        .alert("Redémarrer « \(request.row.name) » ?", isPresented: Binding(
            get: { restartConfiguration != nil }, set: { if !$0 { restartConfiguration = nil } })) {
                Button("Annuler", role: .cancel) { restartConfiguration = nil }
                Button("Redémarrer", role: .destructive) {
                    if let config = restartConfiguration { save(config, restart: true) }
                    restartConfiguration = nil
                }
            } message: {
                Text("Les requêtes en cours seront interrompues et le modèle sera rechargé. L’identifiant et l’historique du chat seront conservés.")
            }
    }

    private func submit(restart: Bool) {
        do {
            let config = try draft.configuration(name: name, model: draft.model, port: draft.port,
                context: draft.context, slots: draft.slots, editing: request.configuration)
            if restart { restartConfiguration = config } else { save(config, restart: false) }
        } catch { self.error = error.localizedDescription }
    }

    private func save(_ config: RuntimeConfiguration, restart: Bool) {
        saving = true
        error = nil
        Task {
            do {
                try await store.save(config, for: request.row, restart: restart)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                await store.refresh()
            }
            saving = false
        }
    }
}

struct InstanceConfigurationSummary: View {
    let configuration: RuntimeConfiguration
    var body: some View {
        GroupBox("Configuration enregistrée") {
            VStack(spacing: 10) {
                LabeledContent("Nom", value: configuration.name)
                LabeledContent("Modèle", value: configuration.model)
                LabeledContent("Port API", value: String(configuration.port))
                LabeledContent("Contexte", value: configuration.context.map { "\($0.formatted()) tokens" } ?? "Automatique")
                LabeledContent("Conversations simultanées", value: configuration.slots.map(String.init) ?? "Automatique")
                LabeledContent("Budget mémoire", value: configuration.memBudgetGb.map { "\($0) GB" } ?? "Automatique")
                LabeledContent("Spéculation", value: configuration.spec.map(String.init) ?? "Automatique")
                LabeledContent("Modèle brouillon", value: configuration.dflash ?? "Automatique")
                LabeledContent("Cache disque", value: configuration.diskCache ?? "Automatique")
                LabeledContent("Lecture par blocs", value: configuration.prefillChunk.map(String.init) ?? "Automatique")
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity)
    }
}
