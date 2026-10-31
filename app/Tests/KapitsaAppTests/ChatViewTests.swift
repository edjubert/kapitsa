import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import KapitsaApp

final class ChatViewTests: XCTestCase {
    func testMarkdownTablesFencesListsAndQuotes() {
        let blocks = ChatMarkdownBlock.parse("# Title\n\n| A | B |\n| --- | :---: |\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\n\n> quote\n\n- one\n- two\n\n---")
        XCTAssertEqual(blocks.map(\.kind), [.heading(1), .table, .code("swift"), .quote, .list, .rule])
        XCTAssertEqual(blocks[2].lines, ["let x = 1"])
        XCTAssertEqual(ChatMarkdownBlock.parse("~~~\nunfinished").last?.lines, ["unfinished"])
    }

    @MainActor
    func testPlainTextComposerAcceptsImagePasteboardData() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let data = try imageData()
        board.setData(data, forType: .png)
        let editor = ChatComposer.Editor()
        editor.isRichText = false
        var attached: [ChatImage] = []
        editor.attach = { attached += $0 }
        editor.failure = { XCTFail($0) }
        XCTAssertTrue(editor.readablePasteboardTypes.contains(.png),
                      "Otherwise AppKit disables Paste before invoking the editor")
        XCTAssertTrue(editor.readSelection(from: board, type: .png))
        XCTAssertEqual(attached.count, 1)
        XCTAssertEqual(attached[0].bytes, data)
        XCTAssertTrue(editor.string.isEmpty, "Image bytes must not enter the text composer")
    }

    @MainActor
    func testDroppedImageProviderLoadsIntoComposer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = ChatSession(instanceID: "drop", directory: directory, credentials: false)
        let provider = NSItemProvider()
        let data = try imageData()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) {
            $0(data, nil)
            return nil
        }
        XCTAssertTrue(ChatAttachments.dropped([provider], into: session))
        for _ in 0..<100 where session.pending.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.pending.count, 1)
        XCTAssertEqual(session.pending.first?.bytes, data)
        XCTAssertNil(session.error)
    }

    private func imageData() throws -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }
}
