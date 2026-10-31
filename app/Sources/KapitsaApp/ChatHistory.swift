import AppKit
import ImageIO
import Security
import LocalAuthentication
import UniformTypeIdentifiers

struct ChatImage: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let name: String
    let dataURL: String
    var bytes: Data? {
        guard let separator = dataURL.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: separator)...]))
    }

    static func importData(_ data: Data, name: String) throws -> ChatImage {
        guard data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source),
              let mime = UTType(identifier as String)?.preferredMIMEType, mime.hasPrefix("image/"),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 40_000_000 / height else {
            throw ChatFailure.message("Image illisible ou trop grande (20 MB et 40 mégapixels maximum).")
        }
        return ChatImage(name: name, dataURL: "data:\(mime);base64," + data.base64EncodedString())
    }

    static func importFile(_ url: URL) throws -> ChatImage {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20 * 1024 * 1024 else { throw ChatFailure.message("Cette image dépasse 20 MB.") }
        return try importData(Data(contentsOf: url), name: url.lastPathComponent)
    }
}

struct ChatStats: Codable, Equatable, Sendable {
    var tokens: Int?
    var tokensPerSecond: Double?
    var firstTokenSeconds: Double?
    var thinkingSeconds: Double?
    var cachedTokens: Int?
    var prefillTokensPerSecond: Double?
    var freshTokens: Int?
    var finish: String?
    var stopped = false
}

struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let role: String
    var content = ""
    var images: [ChatImage] = []
    var reasoning = ""
    var stats = ChatStats()
    var error: String?
}

struct ChatHistory: Codable {
    var protocolVersion = 1
    var thinking = true
    var messages: [ChatMessage] = []

    static func load(instance: String, directory: URL) throws -> ChatHistory {
        let url = try path(instance: instance, directory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return ChatHistory() }
        guard Registry.privatePath(directory, directory: true), Registry.privatePath(url, directory: false),
              (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 128 * 1024 * 1024 else {
            throw ChatFailure.message("L’historique de chat n’est pas un fichier privé valide.")
        }
        let history = try JSONDecoder().decode(ChatHistory.self, from: Data(contentsOf: url))
        guard history.protocolVersion == 1, history.messages.allSatisfy({ ["user", "assistant"].contains($0.role) }) else {
            throw ChatFailure.message("Format d’historique de chat incompatible.")
        }
        return history
    }

    func save(instance: String, directory: URL) throws {
        let destination = try Self.path(instance: instance, directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        guard Registry.privatePath(directory, directory: true) else {
            throw ChatFailure.message("Le dossier d’historique doit être privé.")
        }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 128 * 1024 * 1024 else { throw ChatFailure.message("L’historique dépasse 128 MB.") }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ChatFailure.message("Impossible d’enregistrer la conversation.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        do { try file.write(contentsOf: data); try file.close() }
        catch { try? file.close(); throw error }
        guard rename(temporary.path, destination.path) == 0 else {
            throw ChatFailure.message("Impossible de remplacer l’historique de chat.")
        }
    }

    private static func path(instance: String, directory: URL) throws -> URL {
        guard RuntimeRecord.validId(instance) else { throw ChatFailure.message("Identifiant de conversation invalide.") }
        return directory.appendingPathComponent(instance + ".json")
    }
}

enum ChatKeychain {
    private static func query(_ instance: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.edjubert.kapitsa.chat",
         kSecAttrAccount as String: instance]
    }

    static func read(_ instance: String) -> String {
        var request = query(instance)
        request[kSecReturnData as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ key: String, instance: String) throws {
        let request = query(instance)
        if key.isEmpty {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let value = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(request as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(value) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }

    private static func failure(_ status: OSStatus) -> ChatFailure {
        .message("La clé reste disponible pour cette session, mais le trousseau n’a pas pu l’enregistrer (\(status)).")
    }
}
