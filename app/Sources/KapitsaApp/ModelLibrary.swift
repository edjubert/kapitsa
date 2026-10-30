import Foundation
import AppKit
import Combine
import Darwin

struct CatalogVariant: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let quant: String
    let repo: String
    let downloadGb: Double
    let dir: String
}

struct CatalogModel: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let about: String
    let aliases: [String]
    let defaultVariant: String
    let variants: [CatalogVariant]
}

struct InstalledModel: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let variant: String
    let dir: String
    let repo: String
    let complete: Bool
    let managed: Bool
    let bytes: UInt64
    let total: UInt64
    let includes: [String]

    var runnable: Bool { complete || !managed }

    func used(by rows: [InstanceRow], catalog: [CatalogModel] = []) -> Bool {
        rows.contains { row in
            guard let state = row.snapshot else { return false }
            if let path = state.modelDir {
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                    == URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
            }
            if state.model == name || state.model == dir ||
                state.model == name.components(separatedBy: ":").first { return true }
            // Preparation can still name an alias (27b); the effective model
            // directory is published only after resolve/download.
            let reference = state.model.components(separatedBy: ":").first ?? state.model
            return catalog.contains { model in
                model.variants.contains { $0.dir == dir } &&
                    ([model.id] + model.aliases).contains { $0.caseInsensitiveCompare(reference) == .orderedSame }
            }
        }
    }

    static func trashCandidate(_ path: String, root: URL) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let base = root.standardizedFileURL
        var info = stat()
        guard url.deletingLastPathComponent() == base,
              url.lastPathComponent.first != ".", lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              url.resolvingSymlinksInPath().deletingLastPathComponent() == base.resolvingSymlinksInPath() else {
            throw RuntimeFailure.message("Seuls les dossiers de modèles de la bibliothèque peuvent être mis à la corbeille.")
        }
        return url
    }
}

struct ModelMessage: Decodable, Sendable {
    let protocolVersion: Int
    let type: String
    let modelsDir: String?
    let catalog: [CatalogModel]?
    let installed: [InstalledModel]?
    let done: UInt64?
    let total: UInt64?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case type, modelsDir, catalog, installed, done, total, message
    }
}

// The helper is an engine API adapter, with a JSON-lines contract. Never run
// terminal commands or interpret terminal logs as engine state.
final class NativeModelJob: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let diagnostics: FileHandle

    init(action: String, model: String? = nil) throws {
        process.executableURL = try NativeHelper.executableURL()
        process.arguments = ["--model-request"]
        let input = Pipe()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = output
        let logs = Registry.home.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("model-manager.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil,
                                          attributes: [.posixPermissions: 0o600])
        }
        diagnostics = try FileHandle(forWritingTo: log)
        try diagnostics.seekToEnd()
        process.standardError = diagnostics
        var request: [String: Any] = ["protocol": 1, "action": action]
        if let model { request["model"] = model }
        let data = try JSONSerialization.data(withJSONObject: request)
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        try diagnostics.close()
    }

    func interrupt() {
        if process.isRunning { process.interrupt() }
    }

    func read(onMessage: @escaping @Sendable (ModelMessage) async -> Void) async throws -> ModelMessage {
        try await Task.detached { [self] in
            var pending = Data()
            var last: ModelMessage?
            do {
                while let bytes = try output.fileHandleForReading.read(upToCount: 8192), !bytes.isEmpty {
                    pending.append(bytes)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        let message = try RuntimeClient.decode(ModelMessage.self, from: line)
                        guard message.protocolVersion == 1 else {
                            throw RuntimeFailure.message("Version du gestionnaire de modèles incompatible.")
                        }
                        last = message
                        await onMessage(message)
                    }
                    guard pending.count <= 4 * 1024 * 1024 else {
                        throw RuntimeFailure.message("Réponse du gestionnaire de modèles trop volumineuse.")
                    }
                }
                process.waitUntilExit()
                try output.fileHandleForReading.close()
                guard let message = last else {
                    throw RuntimeFailure.message("Le gestionnaire de modèles n’a pas répondu. Consulte son journal.")
                }
                guard pending.isEmpty, process.terminationStatus == 0,
                      ["complete", "library"].contains(message.type) else {
                    throw RuntimeFailure.message(message.message ?? "Le téléchargement a été interrompu. Ses fichiers partiels sont conservés.")
                }
                return message
            } catch {
                interrupt()
                // Close the read end before waiting so a malformed producer
                // cannot deadlock on a full stdout pipe.
                try? output.fileHandleForReading.close()
                process.waitUntilExit()
                throw error
            }
        }.value
    }
}

@MainActor
final class ModelLibrary: ObservableObject {
    @Published private(set) var catalog: [CatalogModel] = []
    @Published private(set) var installed: [InstalledModel] = []
    @Published private(set) var modelsDirectory = Registry.home.appendingPathComponent("models")
    @Published private(set) var refreshing = false
    @Published private(set) var downloadId: String?
    @Published private(set) var downloaded: UInt64 = 0
    @Published private(set) var downloadTotal: UInt64 = 0
    @Published private(set) var downloadPhase = ""
    @Published var error: String?
    private var downloadJob: NativeModelJob?

    var bytes: UInt64 { installed.reduce(0) { $0 + $1.bytes } }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let job = try NativeModelJob(action: "list")
            let reply = try await job.read { _ in }
            guard let path = reply.modelsDir, let catalog = reply.catalog, let installed = reply.installed else {
                throw RuntimeFailure.message("Réponse de bibliothèque incomplète.")
            }
            modelsDirectory = URL(fileURLWithPath: path, isDirectory: true)
            self.catalog = catalog
            self.installed = installed
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func download(_ reference: String) async {
        guard downloadJob == nil else { return }
        downloadId = reference
        downloaded = 0
        downloadTotal = 0
        downloadPhase = "Préparation et vérification des fichiers…"
        error = nil
        defer { downloadJob = nil; downloadId = nil }
        do {
            let job = try NativeModelJob(action: "download", model: reference)
            downloadJob = job
            _ = try await job.read { [weak self] message in
                await self?.receive(message)
            }
            await refresh()
        } catch {
            let reason = error.localizedDescription
            await refresh()
            self.error = reason
        }
    }

    private func receive(_ message: ModelMessage) {
        if message.type == "progress" {
            downloaded = message.done ?? 0
            downloadTotal = message.total ?? 0
            downloadPhase = downloaded == downloadTotal ? "Vérification et finalisation…" : "Téléchargement"
        }
    }

    func cancelDownload() {
        downloadPhase = "Interruption en cours…"
        downloadJob?.interrupt()
    }

    func trash(_ model: InstalledModel, instances: InstanceStore) async {
        await instances.refresh()
        guard downloadId == nil, !model.used(by: instances.rows, catalog: catalog),
              !instances.rows.contains(where: { $0.record != nil && $0.snapshot == nil }) else {
            error = "Arrête les instances qui utilisent ce modèle et termine le téléchargement avant de le retirer. Une instance injoignable doit aussi être vérifiée."
            return
        }
        do {
            let url = try InstalledModel.trashCandidate(model.dir, root: modelsDirectory)
            // Coordinate with the native downloader's existing per-folder lock.
            let metadata = url.appendingPathComponent(".kapitsa")
            var info = stat()
            var descriptor: Int32 = -1
            if lstat(metadata.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw RuntimeFailure.message("Le dossier de métadonnées n’est pas un dossier normal.")
                }
                descriptor = open(metadata.appendingPathComponent("lock").path,
                                  O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw RuntimeFailure.message("Impossible de vérifier le verrou du modèle.") }
            }
            defer { if descriptor >= 0 { close(descriptor) } }
            if descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                throw RuntimeFailure.message("Un autre processus télécharge ce modèle.")
            }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
}

func byteLabel(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}
