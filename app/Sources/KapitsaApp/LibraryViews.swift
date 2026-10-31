import SwiftUI
import AppKit

struct DownloadedModelsView: View {
    @EnvironmentObject private var library: ModelLibrary
    @EnvironmentObject private var store: InstanceStore
    @EnvironmentObject private var settings: AppSettings
    var launch: (String) -> Void
    @State private var search = ""
    @State private var selection: String?
    @State private var trashTarget: InstalledModel?

    private var models: [InstalledModel] {
        library.installed.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var selected: InstalledModel? { library.installed.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                MetricCard(title: "Bibliothèque", value: "\(library.installed.count)",
                           subtitle: "modèles et variantes", symbol: "internaldrive")
                MetricCard(title: "Taille des fichiers", value: byteLabel(library.bytes),
                           subtitle: "les clones APFS peuvent partager leur espace", symbol: "externaldrive")
            }.padding(24)
            if library.installed.isEmpty {
                ContentUnavailableView("Aucun modèle téléchargé", systemImage: "internaldrive",
                    description: Text("Ouvre le catalogue pour télécharger un modèle, ou utilise un dossier local au lancement."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(models, selection: $selection) {
                    TableColumn("Modèle") { model in
                        Label(model.name, systemImage: "cube")
                            .fontWeight(.medium)
                    }.width(min: 200, ideal: 310)
                    TableColumn("Variante") { model in Text(model.variant.isEmpty ? "Locale" : model.variant) }
                    TableColumn("Taille") { model in Text(byteLabel(model.bytes)).monospacedDigit() }
                    TableColumn("État") { model in
                        if model.used(by: store.rows, catalog: library.catalog) {
                            Label("En cours d’utilisation", systemImage: "play.circle.fill").foregroundStyle(.green)
                        } else {
                            Label(model.complete ? "Téléchargé" : model.managed ? "Incomplet" : "Dossier local",
                                  systemImage: model.runnable ? "checkmark.circle" : "arrow.down.circle")
                                .foregroundStyle(model.runnable ? Color.secondary : Color.orange)
                        }
                    }.width(min: 150, ideal: 190)
                }
                if let model = selected {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.name).font(.title3.weight(.semibold))
                                if !model.includes.isEmpty {
                                    Text(model.includes.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Dans le Finder", systemImage: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.dir)])
                            }
                            Button("Par défaut", systemImage: "star") { settings.useModel(model.dir) }
                            Button("Démarrer", systemImage: "play.fill") { launch(model.dir) }
                                .buttonStyle(.borderedProminent).disabled(!model.runnable)
                        }
                        Text(model.dir).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if model.runnable {
                            ModelCapacityBanner(query: CapacityQuery(model: model.dir, defaults: settings.defaults),
                                alreadyRunning: model.used(by: store.rows, catalog: library.catalog),
                                refreshID: library.revision)
                                .id(CapacityQuery(model: model.dir, defaults: settings.defaults))
                        }
                        HStack {
                            if !model.complete, let variant = catalogVariant(for: model) {
                                Button("Reprendre le téléchargement", systemImage: "arrow.down.circle") {
                                    Task { await library.download(variant.id) }
                                }.disabled(library.downloadId != nil)
                            }
                            Spacer()
                            Button("Mettre à la corbeille", systemImage: "trash", role: .destructive) {
                                trashTarget = model
                            }.disabled(model.used(by: store.rows, catalog: library.catalog) || library.downloadId != nil)
                        }
                    }.padding(20)
                }
            }
        }
        .searchable(text: $search, prompt: "Rechercher un modèle téléchargé")
        .alert("Mettre ce modèle à la corbeille ?", isPresented: Binding(
            get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } })) {
                Button("Annuler", role: .cancel) { trashTarget = nil }
                Button("Mettre à la corbeille", role: .destructive) {
                    if let target = trashTarget { Task { await library.trash(target, instances: store) } }
                    trashTarget = nil
                }
            } message: {
                Text("« \(trashTarget?.name ?? "") » pourra être restauré depuis la corbeille du Finder. L’espace sera libéré lorsque tu la videras.")
            }
    }

    private func catalogVariant(for model: InstalledModel) -> CatalogVariant? {
        library.catalog.flatMap(\.variants).first { $0.dir == model.dir }
    }
}

struct CatalogView: View {
    @EnvironmentObject private var library: ModelLibrary
    @EnvironmentObject private var store: InstanceStore
    @EnvironmentObject private var settings: AppSettings
    var launch: (String) -> Void
    @State private var search = ""
    @State private var selection: String?
    @State private var variantId = ""
    private var models: [CatalogModel] {
        library.catalog.filter { model in
            search.isEmpty || ([model.title, model.about] + model.aliases).contains {
                $0.localizedCaseInsensitiveContains(search)
            }
        }
    }
    private var selected: CatalogModel? {
        models.first { $0.id == selection } ?? models.first
    }

    var body: some View {
        HSplitView {
            List(models, selection: $selection) { model in
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.title, systemImage: "cube").font(.headline)
                    Text(model.about).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text("\(model.variants.count) variante(s)").font(.caption2).foregroundStyle(.tertiary)
                }.padding(.vertical, 6).tag(model.id)
            }.listStyle(.inset).frame(minWidth: 230, idealWidth: 300, maxWidth: 400)
            if let model = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Image(systemName: "cube.transparent").font(.system(size: 52, weight: .light))
                            .foregroundStyle(.tint).accessibilityHidden(true)
                        Text(model.title).font(.largeTitle.weight(.semibold))
                        Text(model.about).foregroundStyle(.secondary)
                        GroupBox("Précision et téléchargement") {
                            VStack(alignment: .leading, spacing: 16) {
                                Picker("Variante", selection: $variantId) {
                                    ForEach(model.variants) { variant in
                                        Text("\(variant.name) · \(variant.downloadGb, specifier: "%.1f") GB")
                                            .tag(variant.id)
                                    }
                                }
                                if let variant = model.variants.first(where: { $0.id == variantId }) {
                                    Text(variant.quant).font(.callout)
                                    LabeledContent("Téléchargement estimé",
                                        value: String(format: "%.1f GB", variant.downloadGb))
                                    Text(variant.repo).font(.caption).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    ModelCapacityBanner(query: CapacityQuery(model: variant.id, defaults: settings.defaults),
                                        alreadyRunning: library.installed.first { $0.dir == variant.dir }?
                                            .used(by: store.rows, catalog: library.catalog) ?? false,
                                        refreshID: library.revision)
                                        .id(CapacityQuery(model: variant.id, defaults: settings.defaults))
                                    if let installed = library.installed.first(where: { $0.dir == variant.dir && $0.complete }) {
                                        Label("Déjà téléchargé", systemImage: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                        Button("Démarrer ce modèle", systemImage: "play.fill") { launch(installed.dir) }
                                            .buttonStyle(.borderedProminent)
                                    } else {
                                        Button("Télécharger", systemImage: "arrow.down") {
                                            Task { await library.download(variant.id) }
                                        }.buttonStyle(.borderedProminent)
                                            .disabled(library.downloadId != nil)
                                    }
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Label("Le téléchargement ne démarre pas le modèle.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("La taille téléchargée et la mémoire nécessaire à l’exécution sont différentes. Plusieurs instances partagent la mémoire du Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(28)
                }.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: model.id, initial: true) { _, _ in
                        variantId = model.variants.first { $0.name == model.defaultVariant }?.id
                            ?? model.variants.first?.id ?? ""
                    }
            } else {
                ContentUnavailableView(search.isEmpty ? "Chargement du catalogue" : "Aucun résultat",
                                       systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $search, prompt: "Rechercher dans le catalogue")
    }
}
