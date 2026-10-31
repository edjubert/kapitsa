import Foundation
import Darwin

struct RuntimeRecord: Decodable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case instanceId, runId, name, state, apiUrl, model, modelDir, context, slots, quant
        case memoryUsedBytes, memoryBudgetBytes, requests, lastRequest, cursor, events, reset
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

    nonisolated static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    func fetch(_ record: RuntimeRecord, cursor: UInt64 = 0) async throws -> RuntimeSnapshot {
        try await request(record, path: "/v1/events?after=\(cursor)")
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

struct RuntimeConfiguration: Codable {
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
}
