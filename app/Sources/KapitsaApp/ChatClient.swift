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
