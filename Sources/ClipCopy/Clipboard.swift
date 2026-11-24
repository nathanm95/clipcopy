import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Reads what's on a pasteboard into a clip that can be saved.
enum ClipboardReader {
    /// Text clips bigger than this are skipped, and formatting bigger than this is dropped.
    static let maxTextBytes = 20_000_000
    static let maxFormattingBytes = 10_000_000
    static let maxImageBytes = 50_000_000
    /// Longest edge of the saved thumbnail, in pixels (the menu shows it at about half that, on Retina).
    static let thumbnailPixels = 112

    static func capture(from pasteboard: NSPasteboard) -> CapturedClip? {
        let types = pasteboard.types ?? []

        // Finder copies: file URLs, plus an icon picture and the names as text, which are ignored.
        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            var clip = CapturedClip(kind: .files)
            clip.paths = urls.map(\.path)
            clip.plain = urls.map(\.lastPathComponent).joined(separator: "\n")
            return clip
        }

        let hasImage = types.contains(.png) || types.contains(.tiff)
        let string = types.contains(.string) ? pasteboard.string(forType: .string) : nil
        let rtf = types.contains(.rtf) ? pasteboard.data(forType: .rtf) : nil
        let html = types.contains(.html) ? pasteboard.data(forType: .html) : nil

        // "Copy Image" in a browser can put the image's address alongside the picture; the picture
        // is what was meant. Text with formatting (a spreadsheet range, say) is kept as text.
        if hasImage, string == nil || (rtf == nil && html == nil && looksLikeLink(string!)) {
            return captureImage(from: pasteboard)
        }

        if let string, !string.isEmpty {
            guard string.utf8.count <= maxTextBytes else { return nil }
            var clip = CapturedClip(kind: .text, plain: string)
            clip.rtf = rtf.flatMap { $0.count <= maxFormattingBytes ? $0 : nil }
            clip.html = html.flatMap { $0.count <= maxFormattingBytes ? $0 : nil }
            if clip.rtf != nil || clip.html != nil {
                clip.kind = .rich
            }
            return clip
        }

        return hasImage ? captureImage(from: pasteboard) : nil
    }

    private static func captureImage(from pasteboard: NSPasteboard) -> CapturedClip? {
        let types = pasteboard.types ?? []
        if types.contains(.png), let png = pasteboard.data(forType: .png) {
            return imageClip(from: png)
        }
        if let tiff = pasteboard.data(forType: .tiff) {
            return imageClip(from: tiff)
        }
        return nil
    }

    /// Makes an image clip from PNG or TIFF data, storing it as PNG with a small thumbnail.
    static func imageClip(from data: Data) -> CapturedClip? {
        guard data.count <= maxImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let isPNG = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
        let png: Data
        if isPNG {
            png = data
        } else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let encoded = encodePNG(image)
            else { return nil }
            png = encoded
        }

        var clip = CapturedClip(kind: .image)
        clip.imagePNG = png
        clip.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        clip.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            clip.thumbnailPNG = encodePNG(thumbnail)
        }
        return clip
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func looksLikeLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace) else { return false }
        return ["http://", "https://", "file://", "data:"].contains { trimmed.lowercased().hasPrefix($0) }
    }
}

/// Puts a saved clip back on a pasteboard.
enum ClipboardWriter {
    enum Style {
        /// Exactly as it was copied, formatting and all.
        case asCopied
        /// Text only, tidied by `TextTidy`.
        case plain
    }

    @discardableResult
    static func write(_ clip: StoredClip, style: Style, to pasteboard: NSPasteboard) -> Bool {
        switch clip.kind {
        case .text:
            pasteboard.clearContents()
            return pasteboard.setString(style == .plain ? TextTidy.plain(clip.plain) : clip.plain, forType: .string)

        case .rich:
            if style == .plain {
                pasteboard.clearContents()
                return pasteboard.setString(TextTidy.plain(clip.plain), forType: .string)
            }
            var types: [NSPasteboard.PasteboardType] = []
            if clip.rtf != nil { types.append(.rtf) }
            if clip.html != nil { types.append(.html) }
            types.append(.string)
            pasteboard.declareTypes(types, owner: nil)
            if let rtf = clip.rtf { pasteboard.setData(rtf, forType: .rtf) }
            if let html = clip.html { pasteboard.setData(html, forType: .html) }
            return pasteboard.setString(clip.plain, forType: .string)

        case .image:
            guard let url = clip.imageURL, let png = try? Data(contentsOf: url) else { return false }
            pasteboard.declareTypes([.png, .tiff], owner: nil)
            pasteboard.setData(png, forType: .png)
            // Some older apps only read TIFF.
            if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
            return true

        case .files:
            pasteboard.clearContents()
            return pasteboard.writeObjects(clip.paths.map { URL(fileURLWithPath: $0) as NSURL })
        }
    }
}

/// Watches the system clipboard and saves each new copy. macOS has no "clipboard changed" event,
/// so this checks the clipboard's change counter twice a second, which costs next to nothing.
@MainActor
final class ClipboardWatcher {
    private let pasteboard = NSPasteboard.general
    private let store: ClipStore
    private var lastChangeCount = -1
    private var timer: Timer?

    init(store: ClipStore) {
        self.store = store
    }

    func start() {
        check()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Call after ClipCopy writes to the clipboard itself, so that write isn't saved as a new copy.
    func ignoreCurrentContents() {
        lastChangeCount = pasteboard.changeCount
    }

    private func check() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard var clip = ClipboardReader.capture(from: pasteboard) else { return }
        clip.sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        store.save(clip)
    }
}
