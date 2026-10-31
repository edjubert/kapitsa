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


    func testInferenceEndpointsStayOnLoopback() throws {
        _ = try ChatClient.endpoint("http://127.0.0.1:8000")
        _ = try ChatClient.endpoint("http://[::1]:8001/")
        for invalid in ["http://example.com:8000", "https://127.0.0.1:8000", "http://127.0.0.1:8000/chat",
                        "http://key@127.0.0.1:8000", "http://127.0.0.1:8000?token=key", "http://127.0.0.1:0"] {
            XCTAssertThrowsError(try ChatClient.endpoint(invalid), invalid)
        }
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
