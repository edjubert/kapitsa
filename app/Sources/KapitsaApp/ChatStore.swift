import Foundation
import Combine

@MainActor
final class ChatStore: ObservableObject {
    @Published var selectedInstanceID = ""
    @Published private(set) var openRequest = UUID()
    var openingChat = false
    private var sessions: [String: ChatSession] = [:]

    func session(_ instanceID: String) -> ChatSession {
        if let session = sessions[instanceID] { return session }
        let session = ChatSession(instanceID: instanceID)
        sessions[instanceID] = session
        return session
    }

    func open(_ instanceID: String) {
        selectedInstanceID = instanceID
        openingChat = true
        openRequest = UUID()
    }

    func stopAll() { sessions.values.forEach { $0.stop() } }
}
