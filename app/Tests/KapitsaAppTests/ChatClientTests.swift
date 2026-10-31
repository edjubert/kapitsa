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
}
