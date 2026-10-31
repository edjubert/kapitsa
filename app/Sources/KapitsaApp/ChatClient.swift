import Foundation

struct ChatModel: Decodable, Identifiable, Sendable {
    let id: String
    let displayName: String?
    let active: Bool?
    let downloaded: Bool?
    let contextFit: Int?
    let contextLength: Int?
    var title: String { displayName ?? id }
}

struct ChatModels: Decodable, Sendable {
    let data: [ChatModel]
    let allowSwitch: Bool?
    let timing: String?
}

struct ChatChunk: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Delta: Decodable, Sendable {
            let content: String?
            let reasoningContent: String?
        }
        let delta: Delta?
        let finishReason: String?
    }
    struct Usage: Decodable, Sendable {
        struct PromptDetails: Decodable, Sendable { let cachedTokens: Int? }
        struct Kapitsa: Decodable, Sendable { let prefillMs: Double? }
        let completionTokens: Int?
        let promptTokens: Int?
        let promptTokensDetails: PromptDetails?
        let kapitsa: Kapitsa?
    }
    struct APIError: Decodable, Sendable { let message: String? }
    let choices: [Choice]?
    let usage: Usage?
    let error: APIError?
}

enum ChatFailure: Error, LocalizedError, Equatable {
    case unauthorized, message(String)
    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Cette instance demande une clé API."
        case .message(let text): return text
        }
    }
}

// Parse bytes before decoding UTF-8: neither transport chunks nor lines need
// coincide with character boundaries. SSE permits CRLF, comments and multiline data.
struct ChatEventDecoder {
    private var line = Data()
    private var data: [String] = []
    private var size = 0

    mutating func append(_ byte: UInt8) throws -> String? {
        size += 1
        guard size <= 4 * 1024 * 1024 else { throw ChatFailure.message("Événement de chat trop volumineux.") }
        if byte != 10 { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        guard let text = String(data: line, encoding: .utf8) else {
            throw ChatFailure.message("Le serveur a envoyé un texte UTF-8 invalide.")
        }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            let event = data.isEmpty ? nil : data.joined(separator: "\n")
            data.removeAll(keepingCapacity: true)
            size = 0
            return event
        }
        if text.hasPrefix("data:") {
            let value = text.dropFirst(5)
            data.append(String(value.first == " " ? value.dropFirst() : value))
        }
        return nil
    }
}

private final class ChatSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class ChatClient: @unchecked Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: ChatSessionDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    static func endpoint(_ address: String) throws -> URL {
        guard let parts = URLComponents(string: address), parts.scheme == "http",
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(parts.host ?? ""),
              let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let url = parts.url else {
            throw ChatFailure.message("L’adresse de chat doit désigner une instance locale Kapitsa.")
        }
        return url
    }

    private func request(_ endpoint: URL, path: String, key: String, body: Data? = nil) throws -> URLRequest {
        _ = try Self.endpoint(endpoint.absoluteString)
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("KapitsaApp/1", forHTTPHeaderField: "User-Agent")
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        return request
    }

    private func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ChatFailure.message("Réponse HTTP invalide.") }
        if http.statusCode == 401 { throw ChatFailure.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? RuntimeClient.decode(ChatChunk.self, from: body).error?.message
            throw ChatFailure.message(error ?? "Le serveur a répondu HTTP \(http.statusCode).")
        }
    }

    func models(_ endpoint: URL, key: String) async throws -> ChatModels {
        let (data, response) = try await session.data(for: request(endpoint, path: "v1/models", key: key))
        try check(response, body: data)
        return try RuntimeClient.decode(ChatModels.self, from: data)
    }

    func switchModel(_ model: String, endpoint: URL, key: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["model": model])
        var loading = try request(endpoint, path: "v1/models/switch", key: key, body: body)
        loading.timeoutInterval = 3600 // Switching may download a catalog model.
        let (data, response) = try await session.data(for: loading)
        try check(response, body: data)
        guard (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String == "ok" else {
            throw ChatFailure.message("Le changement de modèle n’a pas été confirmé.")
        }
    }

    static func body(messages: [ChatMessage], model: String, thinking: Bool, context: Int) throws -> Data {
        var body: [String: Any] = [
            "model": model.isEmpty ? "default" : model,
            "messages": messages.map { message -> [String: Any] in
                if message.images.isEmpty { return ["role": message.role, "content": message.content] }
                var content: [[String: Any]] = message.images.map {
                    ["type": "image_url", "image_url": ["url": $0.dataURL]]
                }
                if !message.content.isEmpty { content.append(["type": "text", "text": message.content]) }
                return ["role": message.role, "content": content]
            },
            "stream": true, "stream_options": ["include_usage": true],
            "chat_template_kwargs": ["enable_thinking": thinking]
        ]
        if context > 0 { body["max_tokens"] = context }
        return try JSONSerialization.data(withJSONObject: body)
    }

    func reply(_ endpoint: URL, key: String, body: Data,
               onChunk: @escaping @Sendable (ChatChunk) async -> Void) async throws {
        var streaming = try request(endpoint, path: "v1/chat/completions", key: key, body: body)
        streaming.timeoutInterval = 3600
        let (bytes, response) = try await session.bytes(for: streaming)
        guard let http = response as? HTTPURLResponse else { throw ChatFailure.message("Réponse HTTP invalide.") }
        if !(200..<300).contains(http.statusCode) {
            var error = Data()
            for try await byte in bytes {
                error.append(byte)
                if error.count >= 64 * 1024 { break }
            }
            try check(response, body: error)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
            throw ChatFailure.message("Le serveur n’a pas renvoyé de flux de chat.")
        }
        var decoder = ChatEventDecoder()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let event = try decoder.append(byte) else { continue }
            if event == "[DONE]" { return }
            let chunk = try RuntimeClient.decode(ChatChunk.self, from: Data(event.utf8))
            if let error = chunk.error { throw ChatFailure.message(error.message ?? "Erreur de génération.") }
            await onChunk(chunk)
        }
        throw ChatFailure.message("La connexion a été interrompue avant la fin de la réponse.")
    }
}
