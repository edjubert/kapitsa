import Foundation
import Darwin

struct RuntimeRecord: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let instanceId: String
    let runId: String
    let name: String
    let pid: Int
    let controlUrl: String
    let token: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case instanceId, runId, name, pid, controlUrl, token
    }

    static func validId(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    var valid: Bool {
        guard protocolVersion == 1, Self.validId(instanceId), Self.validId(runId),
              Self.validId(token), let url = URLComponents(string: controlUrl),
              url.scheme == "http", url.host == "127.0.0.1", let port = url.port,
              (1...65535).contains(port), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty else { return false }
        return true
    }
}

struct LiveRequest: Decodable, Identifiable, Sendable {
    let requestId: String
    let client: String
    let phase: String
    let promptTokens: Int
    let cachedTokens: Int
    let readTokens: Int
    let completionTokens: Int
    let elapsedMs: Double
    let tokensPerSecond: Double
    let tokensPerStep: Double
    let spec: Int
    var id: String { requestId }
}

struct RequestSummary: Decodable, Sendable {
    let requestId: String
    let finishReason: String
    let error: String?
    let promptTokens: Int
    let cachedTokens: Int
    let completionTokens: Int
    let prefillMs: Double
    let decodeMs: Double
    let tokensPerSecond: Double
}

struct RuntimeEvent: Decodable, Identifiable, Sendable {
    struct Payload: Decodable, Sendable {
        let message: String?
        let level: Int?
        let finishReason: String?
        let completionTokens: Int?
    }
    let seq: UInt64
    let type: String
    let data: Payload
    var id: UInt64 { seq }
}

struct RuntimeSnapshot: Decodable, Sendable {
    let protocolVersion: Int
    let instanceId: String
    let runId: String
    let name: String
    let state: String
    let apiUrl: String
    let model: String
    let modelDir: String?
    let context: Int?
    let slots: Int?
    let quant: String?
    let memoryUsedBytes: UInt64?
    let memoryBudgetBytes: UInt64?
    let requests: [LiveRequest]
    let lastRequest: RequestSummary?
    let cursor: UInt64
    let events: [RuntimeEvent]?
    let reset: Bool?
    let managed: Bool?
    let configuration: RuntimeLaunchConfiguration?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case instanceId, runId, name, state, apiUrl, model, modelDir, context, slots, quant
        case memoryUsedBytes, memoryBudgetBytes, requests, lastRequest, cursor, events, reset
        case managed, configuration
    }
}

enum RuntimeFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

enum Registry {
    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["KAPITSA_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/kapitsa")
    }

    static func privatePath(_ url: URL, directory: Bool) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return false }
        return info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG)
    }

    static func records(in directory: URL = home.appendingPathComponent("instances")) -> [RuntimeRecord] {
        guard privatePath(directory, directory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: directory,
                  includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return files.compactMap { file in
            guard file.pathExtension == "json", privatePath(file, directory: false),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 16_384, let data = try? Data(contentsOf: file),
                  let record = try? RuntimeClient.decode(RuntimeRecord.self, from: data),
                  record.valid else { return nil }
            return record
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // A PID is only informational: it can be reused, and an unreachable
    // endpoint can still belong to a running engine. Only its file lock proves
    // that an execution has ended. Never unlink the lock file itself.
    static func withIdleInstance<T>(_ id: String, in directory: URL,
                                    _ operation: () throws -> T) throws -> T {
        guard RuntimeRecord.validId(id) else { throw RuntimeFailure.message("Instance invalide.") }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard privatePath(directory, directory: true) else {
            throw RuntimeFailure.message("Le registre d’instances n’est pas accessible.")
        }
        let path = directory.appendingPathComponent(id + ".lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RuntimeFailure.message("Le verrou de l’instance n’est pas accessible.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == S_IFREG else {
            throw RuntimeFailure.message("Le verrou de l’instance est invalide.")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw RuntimeFailure.message("Cette instance est encore active. Elle doit être arrêtée avant sa suppression.")
        }
        return try operation()
    }

    @discardableResult
    static func removeOrphan(_ record: RuntimeRecord, in directory: URL) -> Bool {
        // A missing/invalid lock is not evidence that a known owner has ended.
        let lock = directory.appendingPathComponent(record.instanceId + ".lock")
        guard record.valid, privatePath(lock, directory: false) else { return false }
        return (try? withIdleInstance(record.instanceId, in: directory) {
            let file = directory.appendingPathComponent(record.instanceId + ".json")
            guard privatePath(file, directory: false),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_384,
                  let data = try? Data(contentsOf: file), data.count <= 16_384,
                  let current = try? RuntimeClient.decode(RuntimeRecord.self, from: data),
                  current == record else { return false }
            // The lock excludes native starts; the run comparison excludes an
            // outdated observer deleting a replacement execution's record.
            try FileManager.default.removeItem(at: file)
            return true
        }) ?? false
    }
}

private final class LocalOnlySession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor RuntimeClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: LocalOnlySession(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    nonisolated static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    func fetch(_ record: RuntimeRecord, cursor: UInt64 = 0) async throws -> RuntimeSnapshot {
        try await request(record, path: "/v1/events?after=\(cursor)")
    }

    func status(_ record: RuntimeRecord) async throws -> RuntimeSnapshot {
        try await request(record, path: "/v1/status")
    }

    func stop(_ record: RuntimeRecord) async throws {
        _ = try await request(record, path: "/v1/stop", method: "POST")
    }

    private func request(_ record: RuntimeRecord, path: String, method: String = "GET") async throws -> RuntimeSnapshot {
        guard record.valid, let url = URL(string: record.controlUrl + path) else {
            throw RuntimeFailure.message("Registre d’instance invalide.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + record.token, forHTTPHeaderField: "Authorization")
        request.setValue(record.runId, forHTTPHeaderField: "X-Kapitsa-Run-ID")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RuntimeFailure.message("L’instance ne répond plus à cette connexion.")
        }
        let state = try Self.decode(RuntimeSnapshot.self, from: data)
        guard state.protocolVersion == 1, state.instanceId == record.instanceId, state.runId == record.runId else {
            throw RuntimeFailure.message("L’instance a redémarré. La connexion sera renouvelée.")
        }
        return state
    }
}

// Control replies use snake-case decoding, whereas the launch/persistence
// protocol has explicit snake-case coding keys. Keep the boundary typed.
struct RuntimeLaunchConfiguration: Decodable, Sendable {
    let instanceId, name, model: String
    let port: Int
    let context, slots, spec, prefillChunk: Int?
    let memBudgetGb: Double?
    let dflash, diskCache: String?

    var value: RuntimeConfiguration {
        RuntimeConfiguration(instanceId: instanceId, name: name, model: model, port: port,
            context: context, slots: slots, memBudgetGb: memBudgetGb, spec: spec,
            dflash: dflash, diskCache: diskCache, prefillChunk: prefillChunk)
    }
}

struct RuntimeConfiguration: Codable, Equatable, Sendable {
    let instanceId: String
    let name: String
    let model: String
    let port: Int
    let context: Int?
    let slots: Int?
    var memBudgetGb: Double? = nil
    var spec: Int? = nil
    var dflash: String? = nil
    var diskCache: String? = nil
    var prefillChunk: Int? = nil
    var protocolVersion = 1

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case instanceId = "instance_id"
        case name, model, port, context, slots
        case memBudgetGb = "mem_budget_gb"
        case spec, dflash
        case diskCache = "disk_cache"
        case prefillChunk = "prefill_chunk"
    }

    static func contextTokens(_ text: String) throws -> Int? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.isEmpty { return nil }
        let unit = value.hasSuffix("k") ? 1024 : value.hasSuffix("m") ? 1_048_576 : 1
        let digits = unit == 1 ? value : String(value.dropLast())
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(digits), count > 0, count <= 1_048_576 / unit else {
            throw RuntimeFailure.message("Le contexte doit être un nombre de tokens, par exemple 90k.")
        }
        return count * unit
    }
}

enum NativeHelper {
    static func executableURL() throws -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/kapitsa-runtime")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/kapitsa-runtime")
        for url in [bundled, development] where FileManager.default.isExecutableFile(atPath: url.path) { return url }
        throw RuntimeFailure.message("Le runtime Kapitsa est absent. Reconstruis le bundle de l’app.")
    }

    #if !KAPITSA_WIDGET
    static func launch(_ config: RuntimeConfiguration, home: URL, arguments: [String] = []) throws -> Process {
        guard RuntimeRecord.validId(config.instanceId) else { throw RuntimeFailure.message("Instance invalide.") }
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = arguments
        let input = Pipe()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        let logs = home.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let logURL = logs.appendingPathComponent("instance-\(config.instanceId).log")
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RuntimeFailure.message("Impossible d’ouvrir le journal de l’instance.") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0 else {
            throw RuntimeFailure.message("Le journal de l’instance doit être un fichier privé.")
        }
        process.standardOutput = output
        process.standardError = output
        // Keep the runtime and its observer in the same registry even when
        // KAPITSA_HOME has been supplied by an embedding frontend.
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["KAPITSA_HOME": home.path], uniquingKeysWith: { _, value in value })
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(config))
            try input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            throw error
        }
        return process
    }

    static func failureMessage(_ config: RuntimeConfiguration, process: Process,
                               log: URL, since offset: Int) -> String {
        let cause = process.terminationReason == .uncaughtSignal ?
            "signal \(process.terminationStatus)" : "code \(process.terminationStatus)"
        var message = "L’instance « \(config.name) » s’est arrêtée (\(cause))."
        if Registry.privatePath(log, directory: false), let input = try? FileHandle(forReadingFrom: log) {
            defer { try? input.close() }
            let end = (try? input.seekToEnd()) ?? 0
            try? input.seek(toOffset: max(UInt64(max(0, offset)), end > 16_384 ? end - 16_384 : 0))
            if let data = try? input.read(upToCount: 16_384) {
                // Startup diagnostics only, bounded to this launch; never use
                // engine output as the state or activity protocol.
                let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
                if let reason = lines.last(where: { $0.hasPrefix("kapitsa-runtime:") || $0.hasPrefix("kapitsa:") }) {
                    message += "\n" + String(reason.prefix(600))
                }
            }
        }
        return message + "\nConsulte le journal de l’instance pour les détails."
    }
    #endif
}
