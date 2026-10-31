import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatComposer: NSViewRepresentable {
    @Binding var text: String
    var send: () -> Void
    var images: ([ChatImage]) -> Void
    var failure: (String) -> Void

    final class Editor: NSTextView {
        var submit: (() -> Void)?
        var attach: (([ChatImage]) -> Void)?
        var failure: ((String) -> Void)?
        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            [.png, .tiff, .fileURL] + super.readablePasteboardTypes
        }
        override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            if [.png, .tiff, .fileURL].contains(type) { return pasteImage(from: pboard) }
            return super.readSelection(from: pboard, type: type)
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76 {
                if !event.modifierFlags.contains(.shift), !hasMarkedText() {
                    submit?()
                    return
                }
            }
            super.keyDown(with: event)
        }
        override func paste(_ sender: Any?) {
            if !pasteImage(from: .general) { super.paste(sender) }
        }
        override func pasteAsPlainText(_ sender: Any?) {
            // AppKit routes Cmd+V through this action for a plain-text editor.
            if !pasteImage(from: .general) { super.pasteAsPlainText(sender) }
        }
        private func pasteImage(from board: NSPasteboard) -> Bool {
            let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            if !urls.isEmpty {
                do { attach?(try urls.map(ChatImage.importFile)) }
                catch { failure?(error.localizedDescription) }
                return true
            }
            if let data = board.data(forType: .png) {
                do { attach?([try ChatImage.importData(data, name: "Image collée.png")]) }
                catch { failure?(error.localizedDescription) }
                return true
            }
            if let data = board.data(forType: .tiff),
               let image = NSBitmapImageRep(data: data),
               let png = image.representation(using: .png, properties: [:]) {
                do { attach?([try ChatImage.importData(png, name: "Image collée.png")]) }
                catch { failure?(error.localizedDescription) }
                return true
            }
            return false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: ChatComposer
        init(_ owner: ChatComposer) { self.owner = owner }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { owner.text = editor.string }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = Editor()
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Message")
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        guard let editor = scroll.documentView as? Editor else { return }
        if editor.string != text { editor.string = text }
        editor.submit = send
        editor.attach = images
        editor.failure = failure
    }
}

enum ChatAttachments {
    @MainActor static func choose(_ session: ChatSession) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            do { session.addImages(try panel.urls.map(ChatImage.importFile)) }
            catch { session.error = error.localizedDescription }
        }
    }

    static func dropped(_ providers: [NSItemProvider], into session: ChatSession) -> Bool {
        let supported = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        for provider in supported {
            let file = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            provider.loadDataRepresentation(forTypeIdentifier: file ? UTType.fileURL.identifier : UTType.image.identifier) { data, error in
                let result: Result<ChatImage, Error> = Result {
                    if let error { throw error }
                    guard let data else { throw ChatFailure.message("Impossible de lire cette image.") }
                    if file, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                        return try ChatImage.importFile(url)
                    }
                    return try ChatImage.importData(data, name: provider.suggestedName ?? "Image déposée")
                }
                Task { @MainActor in
                    switch result {
                    case .success(let image): session.addImages([image])
                    case .failure(let error): session.error = error.localizedDescription
                    }
                }
            }
        }
        return !supported.isEmpty
    }
}
