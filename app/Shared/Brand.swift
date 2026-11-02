import SwiftUI
import AppKit

// The press-kit files are the source of truth. The native build copies them
// into both bundles; Swift Package development uses those same source files.
enum KapitsaBrand {
    static let green = Color(red: 63.0 / 255, green: 181.0 / 255, blue: 90.0 / 255)
    static let icon = image("kapitsa-icon-1024.png")
    private static let darkMark = image("kapitsa-mark-1024.png")
    private static let lightMark = image("kapitsa-mark-light-1024.png")
    private static let darkMenuBarMark = menuBarImage(darkMark)
    private static let lightMenuBarMark = menuBarImage(lightMark)
    private static let darkWordmark = image("kapitsa-logo-dark-1024.png")
    private static let lightWordmark = image("kapitsa-logo-light-1024.png")

    static func mark(for scheme: ColorScheme) -> NSImage { scheme == .dark ? darkMark : lightMark }
    static func menuBarMark(for scheme: ColorScheme) -> NSImage {
        scheme == .dark ? darkMenuBarMark : lightMenuBarMark
    }
    static func wordmark(for scheme: ColorScheme) -> NSImage { scheme == .dark ? darkWordmark : lightWordmark }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Développement"
    }

    private static func menuBarImage(_ source: NSImage) -> NSImage {
        // MenuBarExtra uses NSImage's native size, not the SwiftUI frame modifiers.
        // Resize a copy so the full-size artwork stays available to the app and widgets.
        let image = source.copy() as! NSImage
        let scale = min(24 / source.size.width, 18 / source.size.height)
        image.size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        return image
    }

    private static func image(_ name: String) -> NSImage {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Brand").appendingPathComponent(name),
           let image = NSImage(contentsOf: url) { return image }
        #if SWIFT_PACKAGE
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if let image = NSImage(contentsOf: root.appendingPathComponent("docs/assets/brand/" + name)) { return image }
        #endif
        preconditionFailure("Missing Kapitsa brand asset: \(name)")
    }
}

struct KapitsaMark: View {
    @Environment(\.colorScheme) private var scheme
    var height: CGFloat = 24

    var body: some View {
        Image(nsImage: KapitsaBrand.mark(for: scheme))
            .resizable().scaledToFit().frame(width: height * 144 / 104, height: height)
            .accessibilityHidden(true)
    }
}

struct KapitsaWordmark: View {
    @Environment(\.colorScheme) private var scheme
    var width: CGFloat = 160

    var body: some View {
        Image(nsImage: KapitsaBrand.wordmark(for: scheme))
            .resizable().scaledToFit().frame(width: width, height: width * 184 / 1024)
            .accessibilityLabel("Kapitsa")
    }
}

struct KapitsaEmptyState: View {
    let title: String
    var description = ""

    var body: some View {
        VStack(spacing: 12) {
            KapitsaMark(height: 48).padding(.bottom, 12)
            Text(title).font(.title2.bold())
            if !description.isEmpty {
                Text(description).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
