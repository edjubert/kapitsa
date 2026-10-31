import SwiftUI
import AppKit

struct PreferencesView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: ModelLibrary
    @State private var draft = LaunchDefaults()
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                TextField("Modèle par défaut", text: $draft.model, prompt: Text("À choisir au lancement"))
                if !library.installed.isEmpty {
                    Menu("Choisir un modèle téléchargé") {
                        ForEach(library.installed.filter(\.runnable)) { model in
                            Button(model.name) { draft.model = model.dir }
                        }
                    }
                }
                TextField("Contexte (tokens)", text: $draft.context, prompt: Text("Automatique, ou 90k"))
                Picker("Conversations simultanées", selection: $draft.slots) {
                    Text("Automatique").tag(0)
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                TextField("Premier port API", value: $draft.port, format: .number.grouping(.never))
            } header: { Text("Nouvelles instances") } footer: {
                Text("Ces valeurs préremplissent le lancement. Le prochain port libre est proposé. Les instances déjà actives conservent leurs options.")
            }
            Section("Moteur") {
                EngineOptionsFields(value: $draft)
            }
            Section("Stockage") {
                LabeledContent("Dossier des modèles") {
                    Text(library.modelsDirectory.path).font(.caption).textSelection(.enabled)
                }
                Button("Ouvrir dans le Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(library.modelsDirectory)
                }
            }
            Section {
                HStack {
                    Button("Valeurs d’origine") { draft = LaunchDefaults(); saved = false }
                    Spacer()
                    if saved { Label("Enregistré", systemImage: "checkmark").foregroundStyle(.secondary) }
                    Button("Enregistrer") {
                        do { try settings.save(draft); error = nil; saved = true }
                        catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(draft == settings.defaults)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }.formStyle(.grouped)
            .onAppear { draft = settings.defaults }
            .onChange(of: draft) { _, _ in saved = false }
            .onChange(of: settings.defaults) { _, value in draft = value }
    }
}

struct EngineOptionsFields: View {
    @Binding var value: LaunchDefaults
    var body: some View {
        TextField("Budget mémoire (GB)", text: $value.memory, prompt: Text("Automatique"))
        Picker("Spéculation (tokens par étape)", selection: $value.speculation) {
            Text("Automatique").tag(-1)
            Text("Désactivée").tag(0)
            ForEach(1...32, id: \.self) { Text("\($0)").tag($0) }
        }
        Toggle("Utiliser le modèle brouillon disponible", isOn: $value.useDrafter)
        TextField("Cache disque", text: $value.diskCache, prompt: Text("Automatique, 10g ou 0"))
        TextField("Lecture par blocs (tokens)", value: $value.prefillChunk, format: .number.grouping(.never))
        Text("0 laisse le moteur choisir la taille des blocs. Le budget mémoire est une limite de l’instance ; il ne réserve pas la RAM du Mac.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
