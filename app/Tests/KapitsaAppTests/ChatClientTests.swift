import XCTest
import AppKit
@testable import KapitsaApp

final class ChatClientTests: XCTestCase {
    func testSSEByteFramingUnicodeCommentsAndMultiline() throws {
        var parser = ChatEventDecoder()
        let wire = ": ping\r\ndata: {\"content\":\r\ndata: \"café ☕\"}\r\n\r\ndata:[DONE]\n\n"
        var events: [String] = []
        for byte in wire.utf8 { if let event = try parser.append(byte) { events.append(event) } }
        XCTAssertEqual(events, ["{\"content\":\n\"café ☕\"}", "[DONE]"])
        XCTAssertThrowsError(try [UInt8(255), 10].forEach { _ = try parser.append($0) })
        var oversized = ChatEventDecoder()
        XCTAssertThrowsError(try (0...4 * 1024 * 1024).forEach { _ in _ = try oversized.append(65) })
    }

    func testRequestMatchesWebWithoutReplayingReasoningOrStatistics() throws {
        var bot = ChatMessage(role: "assistant", content: "answer", reasoning: "private reasoning")
        bot.stats.tokens = 5
        bot.error = "failure"
        let image = try tinyImage()
        let data = try ChatClient.body(messages: [bot, ChatMessage(role: "user", content: "question", images: [image])],
                                       model: "model", thinking: false, context: 90 * 1024)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 90 * 1024)
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0].count, 2)
        XCTAssertEqual(messages[0]["content"] as? String, "answer")
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual((content[0]["image_url"] as? [String: String])?["url"], image.dataURL)
        XCTAssertEqual(content[1]["text"] as? String, "question")
        XCTAssertThrowsError(try ChatImage.importData(Data("not an image".utf8), name: "invalid"))
    }

    @MainActor func testHistoryIsolationPrivacyAndTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = ChatHistory(thinking: false, messages: [ChatMessage(role: "user", content: "saved", images: [try tinyImage()])])
        try history.save(instance: "alpha", directory: root)
        XCTAssertTrue(Registry.privatePath(root, directory: true))
        XCTAssertTrue(Registry.privatePath(root.appendingPathComponent("alpha.json"), directory: false))
        XCTAssertEqual(try ChatHistory.load(instance: "alpha", directory: root).messages.first?.content, "saved")
        XCTAssertFalse(try ChatHistory.load(instance: "alpha", directory: root).thinking)
        XCTAssertTrue(try ChatHistory.load(instance: "beta", directory: root).messages.isEmpty)
        XCTAssertThrowsError(try history.save(instance: "../escape", directory: root))
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("alpha.json"))
        XCTAssertThrowsError(try ChatHistory.load(instance: "link", directory: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("alpha.json").path)
        XCTAssertThrowsError(try ChatHistory.load(instance: "alpha", directory: root))
        var incompatible = history
        incompatible.protocolVersion = 2
        try incompatible.save(instance: "broken", directory: root)
        let bytes = try Data(contentsOf: root.appendingPathComponent("broken.json"))
        let session = ChatSession(instanceID: "broken", directory: root, credentials: false)
        session.thinking.toggle()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("broken.json")), bytes)
        session.newChat()
        XCTAssertTrue(try ChatHistory.load(instance: "broken", directory: root).messages.isEmpty)
    }

    func testInferenceEndpointsStayOnLoopback() throws {
        _ = try ChatClient.endpoint("http://127.0.0.1:8000")
        _ = try ChatClient.endpoint("http://[::1]:8001/")
        for invalid in ["http://example.com:8000", "https://127.0.0.1:8000", "http://127.0.0.1:8000/chat",
                        "http://key@127.0.0.1:8000", "http://127.0.0.1:8000?token=key", "http://127.0.0.1:0"] {
            XCTAssertThrowsError(try ChatClient.endpoint(invalid), invalid)
        }
    }

    @MainActor
    func testHTTPStreamingCancellationAuthenticationAndMultipleInstances() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("tests/fixtures/native_chat_server.py").path, "--home", home.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: home)
        }
        var records: [RuntimeRecord] = []
        for _ in 0..<100 {
            records = Registry.records(in: home.appendingPathComponent("instances"))
            if records.count == 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let alpha = try XCTUnwrap(records.first { $0.instanceId == "chat-alpha" })
        let beta = try XCTUnwrap(records.first { $0.instanceId == "chat-beta" })
        let directory = home.appendingPathComponent("chats")
        let a = ChatSession(instanceID: alpha.instanceId, directory: directory, credentials: false)
        let b = ChatSession(instanceID: beta.instanceId, directory: directory, credentials: false)
        await a.connect(address: alpha.controlUrl, run: alpha.runId, ready: true)
        await b.connect(address: beta.controlUrl, run: beta.runId, ready: true)
        XCTAssertEqual(a.context, 4096)
        XCTAssertTrue(a.allowSwitch)
        XCTAssertFalse(b.allowSwitch)
        a.draft = "image"; a.pending = [try tinyImage()]; a.thinking = false; a.send()
        b.draft = "slow"; b.send()
        try await wait { !a.busy && (b.messages.last?.content.count ?? 0) > 0 }
        XCTAssertTrue(b.busy)
        XCTAssertTrue(a.messages.last?.content.contains("café ☕") == true)
        XCTAssertTrue(a.messages.last?.reasoning.contains("café") == true)
        XCTAssertEqual(a.messages.last?.stats.tokens, 80)
        XCTAssertEqual(a.messages.last?.stats.prefillTokensPerSecond, 1500)
        b.stop()
        let stopped = b.messages.last?.content
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(b.messages.last?.content, stopped)
        XCTAssertTrue(b.messages.last?.stats.stopped == true)
        XCTAssertFalse(a.messages.last?.stats.stopped == true)
        let saved = ChatSession(instanceID: alpha.instanceId, directory: directory, credentials: false)
        XCTAssertEqual(saved.messages.last?.content, a.messages.last?.content)
        XCTAssertFalse(saved.thinking)
        b.newChat(); b.draft = "waiting"; b.send(); b.newChat()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(b.messages.isEmpty, "A stale stream must not resurrect a cleared conversation")
        b.draft = "error"; b.send(); b.draft = "next message"
        try await wait { !b.busy }
        XCTAssertEqual(b.draft, "next message", "An HTTP failure must not overwrite a new draft")
        XCTAssertEqual(b.messages.last?.content, "error")
        XCTAssertNotNil(b.messages.last?.error)
        b.newChat()
        for failure in ["error", "redirect"] {
            a.draft = failure; a.send(); try await wait { !a.busy }
            XCTAssertEqual(a.draft, failure)
            XCTAssertEqual(a.messages.count, 2)
            XCTAssertNotNil(a.error)
        }
        a.draft = "unauthorized"; a.send(); try await wait { !a.busy }
        XCTAssertTrue(a.needsKey)
        await a.setKey("fixture-key")
        try await wait { !a.busy }
        XCTAssertEqual(a.messages.count, 4, "The failed auth turn is retried after providing a key")
        XCTAssertNil(a.error)
        await a.switchModel("fixture-other")
        XCTAssertEqual(a.modelID, "fixture-other")
        for failure in ["truncated", "stream-error"] {
            a.draft = failure; a.send(); try await wait { !a.busy }
            XCTAssertNotNil(a.messages.last?.error)
            XCTAssertFalse(a.messages.last!.content.isEmpty)
        }
        b.draft = "length"; b.send(); try await wait { !b.busy }
        XCTAssertEqual(b.messages.last?.stats.finish, "length")
        let captured = try await capture(alpha.controlUrl)
        XCTAssertEqual(captured["control_leaked"] as? Bool, false)
        let bodies = try XCTUnwrap(captured["bodies"] as? [[String: Any]])
        XCTAssertEqual(bodies[0]["max_tokens"] as? Int, 4096)
        XCTAssertEqual((bodies[0]["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        let betaCapture = try await capture(beta.controlUrl)
        XCTAssertGreaterThanOrEqual(betaCapture["disconnected"] as? Int ?? 0, 1, "Stopping must close the HTTP stream")
        b.draft = "slow"; b.send()
        try await wait { (b.messages.last?.content.count ?? 0) > 0 }
        await b.connect(address: beta.controlUrl, run: "new-run", ready: true)
        let before = b.messages.last?.content
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(b.busy)
        XCTAssertEqual(b.messages.last?.content, before, "A restarted runtime must detach the former stream")
        a.newChat()
        XCTAssertTrue(try ChatHistory.load(instance: alpha.instanceId, directory: directory).messages.isEmpty)
        XCTAssertFalse(try ChatHistory.load(instance: beta.instanceId, directory: directory).messages.isEmpty)
        let protected = try XCTUnwrap(records.first { $0.instanceId == "chat-protected" })
        let p = ChatSession(instanceID: protected.instanceId, directory: directory, credentials: false)
        await p.connect(address: protected.controlUrl, run: protected.runId, ready: true)
        XCTAssertTrue(p.needsKey)
        XCTAssertTrue(p.models.isEmpty)
        await p.setKey("fixture-key")
        XCTAssertFalse(p.needsKey)
        XCTAssertFalse(p.models.isEmpty)
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the synthetic chat")
        throw ChatFailure.message("Test timeout")
    }

    private func capture(_ address: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: address + "/capture")!)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func tinyImage() throws -> ChatImage {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        image.setColor(NSColor(calibratedRed: 0, green: 0.5, blue: 1, alpha: 1), atX: 0, y: 0)
        return try ChatImage.importData(XCTUnwrap(image.representation(using: .png, properties: [:])), name: "tiny.png")
    }
}
