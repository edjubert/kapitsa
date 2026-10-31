import Foundation
import Combine

@MainActor
final class ChatSession: ObservableObject {
    let instanceID: String
    @Published var draft = ""
    @Published var pending: [ChatImage] = []
    @Published var thinking = true { didSet { save() } }
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var models: [ChatModel] = []
    @Published private(set) var modelID = ""
    @Published private(set) var context = 0
    @Published private(set) var allowSwitch = false
    @Published private(set) var timing = "both"
    @Published private(set) var busy = false
    @Published private(set) var switching = false
    @Published private(set) var connected = false
    @Published private(set) var streamRevision = 0
    @Published var error: String?
    @Published var needsKey = false
    private var apiKey = ""
    private var endpoint: URL?
    private var runID = ""
    private var generation: UUID?
    private var task: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var responseBuffer: ChatMessage?
    private var firstToken: Double?
    private var thinkingEnded: Double?
    private var started: Double = 0
    private let client: ChatClient
    private let directory: URL
    private let credentials: Bool
    private var retryAfterKey = false
    private var historyWritable = true

    init(instanceID: String, directory: URL = Registry.home.appendingPathComponent("chats"),
         client: ChatClient = ChatClient(), credentials: Bool = true) {
        self.instanceID = instanceID
        self.directory = directory
        self.client = client
        self.credentials = credentials
        do {
            let history = try ChatHistory.load(instance: instanceID, directory: directory)
            messages = history.messages
            thinking = history.thinking
        } catch { self.error = error.localizedDescription; historyWritable = false }
        if credentials { apiKey = ChatKeychain.read(instanceID) }
    }

    var canSend: Bool {
        connected && !modelID.isEmpty && !busy && !switching &&
            (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty)
    }

    func connect(address: String?, run: String, ready: Bool) async {
        let url = address.flatMap { try? ChatClient.endpoint($0) }
        if endpoint != url || runID != run || !ready {
            stop()
            endpoint = url
            runID = run
            models = []
            modelID = ""
            context = 0
        }
        connected = ready && url != nil
        if connected { await refreshModels() }
    }

    func refreshModels() async {
        guard let endpoint, connected else { return }
        let capturedRun = runID
        do {
            let reply = try await client.models(endpoint, key: apiKey)
            guard capturedRun == runID, !Task.isCancelled else { return }
            models = reply.data
            let model = models.first { $0.active == true } ?? models.first
            modelID = model?.id ?? ""
            context = model?.contextFit ?? model?.contextLength ?? 0
            allowSwitch = reply.allowSwitch ?? true // compatibility with earlier servers
            timing = reply.timing ?? "both"
            error = nil
        } catch {
            if capturedRun == runID, !Task.isCancelled { report(error) }
        }
    }

    func setKey(_ key: String) async {
        apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        needsKey = false
        var keychainError: String?
        if credentials {
            do { try ChatKeychain.save(apiKey, instance: instanceID) }
            catch { keychainError = error.localizedDescription }
        }
        await refreshModels()
        if error == nil, retryAfterKey, canSend { retryAfterKey = false; send() }
        if let keychainError { error = keychainError }
    }

    func switchModel(_ id: String) async {
        guard let endpoint, allowSwitch, !busy, !switching, !id.isEmpty, id != modelID else { return }
        switching = true
        defer { switching = false }
        let capturedRun = runID
        do {
            try await client.switchModel(id, endpoint: endpoint, key: apiKey)
            if capturedRun == runID { await refreshModels() }
        } catch {
            if capturedRun == runID { report(error) }
        }
    }

    func send() {
        guard canSend, let endpoint else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pending
        let history = messages + [ChatMessage(role: "user", content: text, images: images)]
        do {
            let body = try ChatClient.body(messages: history, model: modelID, thinking: thinking, context: context)
            draft = ""
            pending = []
            messages = history + [ChatMessage(role: "assistant")]
            responseBuffer = messages.last
            started = ProcessInfo.processInfo.systemUptime
            firstToken = nil
            thinkingEnded = nil
            error = nil
            busy = true
            let id = UUID()
            generation = id
            let key = apiKey
            task = Task {
                var failure: Error?
                do {
                    try await client.reply(endpoint, key: key, body: body) { [weak self] chunk in
                        await self?.receive(chunk, generation: id)
                    }
                } catch { failure = error }
                guard generation == id else { return }
                flush()
                responseBuffer = nil
                busy = false
                task = nil
                generation = nil
                guard let index = messages.indices.last else { return }
                finishStats(index)
                if Task.isCancelled || (failure as? URLError)?.code == .cancelled {
                    messages[index].stats.stopped = true
                } else if let failure {
                    messages[index].error = failure.localizedDescription
                    report(failure)
                    // A failed turn with no output must not poison the next
                    // prompt. Restore its text/images for retry after fixing auth.
                    if messages[index].content.isEmpty && messages[index].reasoning.isEmpty {
                        messages.removeLast()
                        if draft.isEmpty && pending.isEmpty {
                            messages.removeLast()
                            draft = text
                            pending = images
                            retryAfterKey = (failure as? ChatFailure) == .unauthorized
                        } else {
                            // The user may already be composing the next turn.
                            // Preserve both that draft and the failed user input.
                            messages[messages.count - 1].error = failure.localizedDescription
                        }
                    }
                }
                save()
            }
        } catch { report(error) }
    }

    private func receive(_ chunk: ChatChunk, generation id: UUID) {
        guard generation == id, var message = responseBuffer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = chunk.choices?.first?.delta
        if !(delta?.content ?? "").isEmpty || !(delta?.reasoningContent ?? "").isEmpty {
            if firstToken == nil { firstToken = now }
            if !(delta?.content ?? "").isEmpty, !message.reasoning.isEmpty, thinkingEnded == nil { thinkingEnded = now }
        }
        message.content += delta?.content ?? ""
        message.reasoning += delta?.reasoningContent ?? ""
        if let finish = chunk.choices?.first?.finishReason { message.stats.finish = finish }
        if let usage = chunk.usage {
            let seconds = now - (firstToken ?? started)
            message.stats.tokens = usage.completionTokens
            if let tokens = usage.completionTokens, tokens > 1, seconds > 0 {
                message.stats.tokensPerSecond = Double(tokens - 1) / seconds
            }
            let cached = usage.promptTokensDetails?.cachedTokens ?? 0
            message.stats.cachedTokens = cached
            if let ms = usage.kapitsa?.prefillMs, ms > 0, let prompt = usage.promptTokens, prompt > cached {
                message.stats.prefillTokensPerSecond = Double(prompt - cached) / (ms / 1000)
                message.stats.freshTokens = prompt - cached
            }
        }
        responseBuffer = message
        if flushTask == nil {
            // Coalesce fast deltas rather than reparsing Markdown per token.
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        if let responseBuffer, let index = messages.indices.last, messages[index].id == responseBuffer.id {
            messages[index] = responseBuffer
            streamRevision += 1
        }
    }

    private func finishStats(_ index: Int) {
        if let firstToken {
            messages[index].stats.firstTokenSeconds = firstToken - started
            if !messages[index].reasoning.isEmpty {
                messages[index].stats.thinkingSeconds = (thinkingEnded ?? ProcessInfo.processInfo.systemUptime) - firstToken
            }
        }
    }

    func stop() {
        let wasBusy = busy
        flush()
        responseBuffer = nil
        task?.cancel()
        task = nil
        generation = nil
        if busy, let index = messages.indices.last {
            finishStats(index)
            messages[index].stats.stopped = true
        }
        busy = false
        if wasBusy {
            // No empty assistant turn in the next prompt when stopped before
            // the first token. Keep the user's input available for retry.
            if let last = messages.last, last.content.isEmpty && last.reasoning.isEmpty,
               messages.count >= 2 {
                let user = messages[messages.count - 2]
                messages.removeLast()
                if draft.isEmpty && pending.isEmpty {
                    draft = user.content; pending = user.images
                    messages.removeLast()
                }
            }
            save()
        }
    }

    func newChat() {
        stop()
        messages = []
        pending = []
        draft = ""
        error = nil
        retryAfterKey = false
        historyWritable = true
        save()
    }

    func addImages(_ images: [ChatImage]) {
        guard pending.count + images.count <= 16 else { error = "Ajoute au maximum 16 images par message."; return }
        pending.append(contentsOf: images)
    }

    private func report(_ failure: Error) {
        error = failure.localizedDescription
        if (failure as? ChatFailure) == .unauthorized { needsKey = true }
    }

    private func save() {
        guard historyWritable else {
            error = "L’ancien historique est illisible. Commence une nouvelle conversation pour le remplacer."
            return
        }
        do { try ChatHistory(thinking: thinking, messages: messages).save(instance: instanceID, directory: directory) }
        catch { self.error = error.localizedDescription }
    }
}
