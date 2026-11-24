import AppKit
import Carbon

// Test modes, run from the command line. None of them touch your real history:
//   --self-test               checks the store, the plain-text tidy and clipboard reads and writes
//   --render-test <dir>       draws the menu rows and icons to PNGs
//   --data-dir <dir> --fill N fills a separate history with N sample clips
//   --data-dir <dir> --menu-test  opens the menu, types into its search, and reports memory

// MARK: - Self-test

@MainActor
enum SelfTest {
    private final class Checker {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print((condition ? "PASS  " : "FAIL  ") + name)
            if !condition { failures += 1 }
        }
    }

    static func run() -> Bool {
        _ = NSApplication.shared
        let checker = Checker()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipCopy-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        checkTidy(checker)
        do {
            try checkStore(checker, directory: root.appendingPathComponent("store"))
            try checkLimit(checker, directory: root.appendingPathComponent("limit"))
            try checkFullHistory(checker, directory: root.appendingPathComponent("full"))
        } catch {
            checker.check(false, "store opens (\(error))")
        }
        checkPasteboard(checker, directory: root.appendingPathComponent("pasteboard"))

        print(checker.failures == 0 ? "\nAll checks passed." : "\n\(checker.failures) check(s) failed.")
        return checker.failures == 0
    }

    private static func checkTidy(_ c: Checker) {
        c.check(TextTidy.plain("a\u{00A0}b\u{202F}c\u{2009}d") == "a b c d", "tidy: odd spaces become normal spaces")
        c.check(TextTidy.plain("x\u{200B}y\u{FEFF}z\u{00AD}w\u{2060}v") == "xyzwv", "tidy: invisible characters removed")
        c.check(TextTidy.plain("one\u{2028}two\u{2029}three") == "one\ntwo\nthree", "tidy: line separators become line breaks")
        c.check(TextTidy.plain("👨‍👩‍👧 family") == "👨‍👩‍👧 family", "tidy: emoji joiners kept")
        let untouched = "“Quoted” — dash\ttab\r\nnext line"
        c.check(TextTidy.plain(untouched) == untouched, "tidy: quotes, tabs and line breaks kept")
    }

    private static func checkStore(_ c: Checker, directory: URL) throws {
        let store = try ClipStore(directory: directory)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let first = store.save(CapturedClip(kind: .text, plain: "hello world"), at: start)
        var rich = CapturedClip(kind: .rich, plain: "hello world")
        rich.rtf = sampleRTF("hello world")
        let second = store.save(rich, at: start.addingTimeInterval(1))
        c.check(first != nil && first == second, "dedupe: same words with formatting reuse the clip")
        c.check(store.load(first!)?.kind == .rich && store.load(first!)?.rtf != nil, "dedupe: formatting added to the clip")
        let third = store.save(CapturedClip(kind: .text, plain: "hello world"), at: start.addingTimeInterval(2))
        c.check(third == first && store.load(first!)?.kind == .rich, "dedupe: copying as plain keeps the formatting")
        c.check(store.count() == 1, "dedupe: one clip, not three")

        store.save(CapturedClip(kind: .text, plain: "second clip"), at: start.addingTimeInterval(3))
        store.save(CapturedClip(kind: .text, plain: "hello world"), at: start.addingTimeInterval(4))
        c.check(store.recent(limit: 5).first?.preview == "hello world", "dedupe: copying again moves the clip to the top")

        store.save(CapturedClip(kind: .text, plain: "100% sure"), at: start.addingTimeInterval(5))
        c.check(store.search("WORLD", limit: 20).map(\.preview) == ["hello world"], "search: ignores case")
        c.check(store.search("%", limit: 20).map(\.preview) == ["100% sure"], "search: % is matched literally")
        c.check(store.search("_", limit: 20).isEmpty, "search: _ is matched literally")
        c.check(store.search("nothing like this", limit: 20).isEmpty, "search: no false matches")

        guard let image = ClipboardReader.imageClip(from: samplePNG(width: 640, height: 400, hue: 0.3)) else {
            c.check(false, "image: sample image reads")
            return
        }
        let imageID = store.save(image, at: start.addingTimeInterval(6))
        let imageFiles = { (try? FileManager.default.contentsOfDirectory(atPath: store.imagesDirectory.path)) ?? [] }
        c.check(imageFiles().count == 2, "image: picture and thumbnail saved")
        let summary = store.recent(limit: 1).first
        c.check(summary?.kind == .image && summary?.pixelWidth == 640 && summary?.pixelHeight == 400, "image: size recorded")
        store.delete(imageID!)
        c.check(imageFiles().isEmpty, "delete: image files removed with the clip")
        c.check(store.count() == 3, "delete: one clip removed")

        store.clearAll()
        c.check(store.count() == 0, "clear: history empty")
    }

    private static func checkLimit(_ c: Checker, directory: URL) throws {
        let store = try ClipStore(directory: directory, limit: 5)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<3 {
            if let image = ClipboardReader.imageClip(from: samplePNG(width: 200, height: 100, hue: Double(index) / 10)) {
                store.save(image, at: start.addingTimeInterval(Double(index)))
            }
        }
        for index in 0..<5 {
            store.save(CapturedClip(kind: .text, plain: "text \(index)"), at: start.addingTimeInterval(Double(10 + index)))
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: store.imagesDirectory.path)) ?? []
        c.check(store.count() == 5, "limit: oldest clips dropped beyond the limit")
        c.check(files.isEmpty, "limit: dropped images deleted from disk")
        c.check(store.recent(limit: 10).last?.preview == "text 0", "limit: newest clips kept")
    }

    private static func checkFullHistory(_ c: Checker, directory: URL) throws {
        let store = try ClipStore(directory: directory)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let began = Date()
        for index in 0..<1005 {
            store.save(CapturedClip(kind: .text, plain: "sample clip number \(index)"), at: start.addingTimeInterval(Double(index)))
        }
        let saveTime = Date().timeIntervalSince(began)
        c.check(store.count() == 1000, "limit: 1,005 copies leave the newest 1,000")
        c.check(store.search("number 4", limit: 20).allSatisfy { $0.preview != "sample clip number 4" },
                "limit: the 5 oldest are gone")
        let searchStart = Date()
        let found = store.search("number 99", limit: 20)
        let searchTime = Date().timeIntervalSince(searchStart)
        c.check(found.count == 11, "search: finds matches across all 1,000")
        print(String(format: "      1,005 saves took %.2f s; one search took %.1f ms", saveTime, searchTime * 1000))
    }

    private static func checkPasteboard(_ c: Checker, directory: URL) {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("just words", forType: .string)
        c.check(ClipboardReader.capture(from: pasteboard)?.kind == .text, "read: plain text")

        pasteboard.declareTypes([.rtf, .string], owner: nil)
        pasteboard.setData(sampleRTF("bold words"), forType: .rtf)
        pasteboard.setString("bold words", forType: .string)
        c.check(ClipboardReader.capture(from: pasteboard)?.kind == .rich, "read: RTF text is formatted")

        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setData(Data("<b>web</b> words".utf8), forType: .html)
        pasteboard.setString("web words", forType: .string)
        c.check(ClipboardReader.capture(from: pasteboard)?.kind == .rich, "read: HTML text is formatted")

        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/System/Applications/Calculator.app") as NSURL])
        let files = ClipboardReader.capture(from: pasteboard)
        c.check(files?.kind == .files && files?.plain == "Calculator.app", "read: Finder files")

        pasteboard.clearContents()
        pasteboard.setData(samplePNG(width: 1440, height: 900, hue: 0.6), forType: .png)
        let image = ClipboardReader.capture(from: pasteboard)
        c.check(image?.kind == .image && image?.pixelWidth == 1440, "read: PNG image")
        if let thumbnail = image?.thumbnailPNG, let rep = NSBitmapImageRep(data: thumbnail) {
            c.check(max(rep.pixelsWide, rep.pixelsHigh) <= ClipboardReader.thumbnailPixels, "read: thumbnail is small")
        } else {
            c.check(false, "read: thumbnail made")
        }

        let tiff = NSBitmapImageRep(data: samplePNG(width: 300, height: 200, hue: 0.1))!.tiffRepresentation!
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        let fromTIFF = ClipboardReader.capture(from: pasteboard)
        c.check(fromTIFF?.kind == .image && fromTIFF?.imagePNG?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true,
                "read: TIFF image stored as PNG")

        pasteboard.declareTypes([.tiff, .string], owner: nil)
        pasteboard.setData(tiff, forType: .tiff)
        pasteboard.setString("https://example.com/picture.png", forType: .string)
        c.check(ClipboardReader.capture(from: pasteboard)?.kind == .image, "read: browser Copy Image keeps the picture")

        pasteboard.declareTypes([.tiff, .html, .string], owner: nil)
        pasteboard.setData(tiff, forType: .tiff)
        pasteboard.setData(Data("<table><tr><td>1</td><td>2</td></tr></table>".utf8), forType: .html)
        pasteboard.setString("1\t2", forType: .string)
        c.check(ClipboardReader.capture(from: pasteboard)?.kind == .rich, "read: spreadsheet cells stay text")

        // Writing back.
        let rich = StoredClip(id: 1, kind: .rich, plain: "Hello\u{00A0}there\u{200B}", rtf: sampleRTF("Hello there"),
                              html: Data("<b>Hello</b> there".utf8), paths: [], imageURL: nil)
        ClipboardWriter.write(rich, style: .asCopied, to: pasteboard)
        let types = pasteboard.types ?? []
        c.check(types.contains(.rtf) && types.contains(.html) && types.contains(.string), "write: with formatting keeps RTF and HTML")
        ClipboardWriter.write(rich, style: .plain, to: pasteboard)
        let plainTypes = pasteboard.types ?? []
        c.check(!plainTypes.contains(.rtf) && !plainTypes.contains(.html) && pasteboard.string(forType: .string) == "Hello there",
                "write: plain text only, tidied")

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pngURL = directory.appendingPathComponent("image.png")
        try? samplePNG(width: 120, height: 80, hue: 0.8).write(to: pngURL)
        let storedImage = StoredClip(id: 2, kind: .image, plain: "", rtf: nil, html: nil, paths: [], imageURL: pngURL)
        ClipboardWriter.write(storedImage, style: .asCopied, to: pasteboard)
        c.check(pasteboard.data(forType: .png) != nil && pasteboard.data(forType: .tiff) != nil, "write: image as PNG and TIFF")

        let storedFiles = StoredClip(id: 3, kind: .files, plain: "Calculator.app", rtf: nil, html: nil,
                                     paths: ["/System/Applications/Calculator.app"], imageURL: nil)
        ClipboardWriter.write(storedFiles, style: .asCopied, to: pasteboard)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        c.check(urls?.first?.path == "/System/Applications/Calculator.app", "write: files")
    }

    static func sampleRTF(_ text: String) -> Data {
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        return (try? string.data(from: NSRange(location: 0, length: string.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])) ?? Data()
    }

    /// A gradient picture, so tests never need a real image.
    static func samplePNG(width: Int, height: Int, hue: Double) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let gradient = NSGradient(starting: NSColor(hue: hue, saturation: 0.6, brightness: 0.95, alpha: 1),
                                  ending: NSColor(hue: hue + 0.15, saturation: 0.7, brightness: 0.6, alpha: 1))
        gradient?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 35)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

// MARK: - Sample history

@MainActor
enum TestData {
    private static let phrases = [
        "Quarterly update – draft for review",
        "hello@example.com",
        "Meeting moved to Thursday at 10:00",
        "https://example.com/docs/getting-started",
        "The quick brown fox jumps over the lazy dog",
        "Order reference ABC-12345",
        "Please find the agenda attached",
        "let total = items.reduce(0, +)",
        "221B Example Street, Sampletown",
        "Thanks, that works for me"
    ]

    static func fill(directory: URL, count: Int) -> Bool {
        _ = NSApplication.shared
        guard let store = try? ClipStore(directory: directory) else {
            print("Couldn't open \(directory.path)")
            return false
        }
        let start = Date().addingTimeInterval(-Double(count) * 60)
        for index in 0..<count {
            let date = start.addingTimeInterval(Double(index) * 60)
            let phrase = phrases[index % phrases.count] + " #\(index)"
            var clip: CapturedClip
            switch index % 20 {
            case 0, 10:
                guard let image = ClipboardReader.imageClip(
                    from: SelfTest.samplePNG(width: 1440, height: 900, hue: Double(index % 97) / 97)) else { continue }
                clip = image
            case 5:
                clip = CapturedClip(kind: .files, plain: "Calculator.app", paths: ["/System/Applications/Calculator.app"])
                clip.paths.append("/tmp/clipcopy-sample-\(index).txt")
                clip.plain += "\nclipcopy-sample-\(index).txt"
            case 1, 3, 7, 13, 17:
                clip = CapturedClip(kind: .rich, plain: phrase)
                clip.rtf = SelfTest.sampleRTF(phrase)
                clip.html = Data("<b>\(phrase)</b>".utf8)
            default:
                clip = CapturedClip(kind: .text, plain: phrase)
            }
            clip.sourceApp = ["TextEdit", "Safari", "Mail", "Notes"][index % 4]
            store.save(clip, at: date)
        }
        print("Filled \(directory.path) with \(store.count()) clips")
        return true
    }
}

// MARK: - Render test

@MainActor
enum RenderTest {
    static func run(into directory: URL) -> Bool {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let images = directory.appendingPathComponent("sample-images")
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var thumbnailName: String?
        if let image = ClipboardReader.imageClip(from: SelfTest.samplePNG(width: 1440, height: 900, hue: 0.55)),
           let thumbnail = image.thumbnailPNG {
            thumbnailName = "thumb.png"
            try? thumbnail.write(to: images.appendingPathComponent("thumb.png"))
        }

        let now = Date()
        func summary(_ kind: ClipKind, _ preview: String, paths: [String] = [], thumbnail: String? = nil,
                     size: (Int, Int) = (0, 0)) -> ClipSummary {
            ClipSummary(id: 0, kind: kind, preview: preview, characterCount: preview.count, paths: paths,
                        thumbnailFile: thumbnail, pixelWidth: size.0, pixelHeight: size.1, sourceApp: "TextEdit",
                        copiedAt: now)
        }
        let clips = [
            summary(.rich, "Quarterly update – draft for review"),
            summary(.text, "hello@example.com"),
            summary(.image, "", thumbnail: thumbnailName, size: (1440, 900)),
            summary(.files, "Calculator.app", paths: ["/System/Applications/Calculator.app"]),
            summary(.files, "notes.txt", paths: ["/tmp/clipcopy-missing/notes.txt", "/tmp/a.txt", "/tmp/b.txt"]),
            summary(.rich, "Please find the agenda attached for Thursday's meeting at 10:00 in the main room"),
            summary(.text, "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog.")
        ]

        var ok = true
        for (name, appearance) in [("menu-light.png", NSAppearance.Name.aqua), ("menu-dark.png", .darkAqua)] {
            let menu = fakeMenu(clips: clips, imagesDirectory: images, highlightIndex: 0)
            menu.appearance = NSAppearance(named: appearance)
            ok = write(menu, to: directory.appendingPathComponent(name)) && ok
        }
        ok = writeMenuBarPreview(to: directory.appendingPathComponent("menubar-icon.png")) && ok
        if let icon = Paperclip.appIconPNG(pixels: 512) {
            try? icon.write(to: directory.appendingPathComponent("app-icon.png"))
        } else {
            ok = false
        }
        print(ok ? "Wrote renders to \(directory.path)" : "Some renders failed")
        return ok
    }

    /// The real dropdown contents on a plain background (the frosted material doesn't render offscreen).
    private static func fakeMenu(clips: [ClipSummary], imagesDirectory: URL, highlightIndex: Int) -> NSView {
        let content = DropdownContent()
        content.setLoginEnabled(true)
        content.setClips(clips, imagesDirectory: imagesDirectory, query: "", totalCount: 1000, maxHeight: 5000)
        content.selectedIndex = highlightIndex
        let container = BackgroundView(frame: content.view.frame)
        container.addSubview(content.view)
        return container
    }

    private final class BackgroundView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
    }

    private static func write(_ view: NSView, to url: URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// The menu bar icon at real size on light and dark bars, plus a large copy to judge the shape.
    private static func writeMenuBarPreview(to url: URL) -> Bool {
        let glyph = Paperclip.menuBarImage()
        let scale: CGFloat = 2
        let size = NSSize(width: 300, height: 120)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                   pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                   bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        // Light and dark menu bars with the icon at its real size.
        let bars: [(NSColor, NSColor)] = [(NSColor(white: 0.93, alpha: 1), .black), (NSColor(white: 0.16, alpha: 1), .white)]
        for (index, (bar, ink)) in bars.enumerated() {
            let barRect = NSRect(x: 10, y: 80 - CGFloat(index) * 30, width: 120, height: 24)
            bar.setFill()
            barRect.fill()
            tinted(glyph, ink).draw(in: NSRect(x: barRect.midX - glyph.size.width / 2, y: barRect.minY + 3,
                                               width: glyph.size.width, height: glyph.size.height))
        }
        // A large copy.
        tinted(glyph, .black).draw(in: NSRect(x: 170, y: 6, width: glyph.size.width * 6, height: glyph.size.height * 6))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

// MARK: - Menu test

/// Opens the real dropdown and drives it with real key presses: search, Delete, arrows, Return,
/// Escape, the Aa and T buttons and ×, then opens and closes it ten more times from the paperclip.
/// Copies go to a private pasteboard, never the real clipboard. Keys are only pressed while the
/// dropdown has the keyboard, so they can't reach another app.
@MainActor
enum MenuTest {
    static func run(_ dropdown: DropdownController) {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ text: String) {
            lines.append((ok ? "PASS  " : "FAIL  ") + text)
            if !ok { failures += 1 }
        }
        let pasteboard = NSPasteboard.withUniqueName()
        dropdown.pasteboard = pasteboard
        func press(_ keys: [(Character, Int)]) {
            guard dropdown.isKey else {
                lines.append("      (dropdown didn't have the keyboard; keys not pressed)")
                return
            }
            for (character, code) in keys {
                pressKey(character, keyCode: code)
            }
        }
        let fox: [(Character, Int)] = [("f", kVK_ANSI_F), ("o", kVK_ANSI_O), ("x", kVK_ANSI_X)]
        let content = dropdown.content
        var expected = ""

        var schedule: [(TimeInterval, () -> Void)] = [
            (1.0, { lines.append("      idle, closed: \(Memory.describe())") }),
            (1.2, { dropdown.statusItem.button?.performClick(nil) }),
            (2.0, {
                check(dropdown.isOpen && dropdown.isKey, "clicking the paperclip opens the dropdown with the keyboard")
                check(dropdown.visibleClipCount == DropdownController.visibleCount, "\(dropdown.visibleClipCount) clips shown")
                lines.append("      open: \(Memory.describe())")
                press(fox)
            }),
            (2.5, {
                check(dropdown.query == "fox", "typing goes into the search (got '\(dropdown.query)')")
                check(dropdown.visibleClipCount > 0 && content.selectedIndex == 0, "search shows matches, first one highlighted")
                press([("\u{7F}", kVK_Delete)])
            }),
            (2.9, {
                check(dropdown.query == "fo", "Delete removes a letter (got '\(dropdown.query)')")
                press([("\u{F701}", kVK_DownArrow)])
            }),
            (3.3, {
                check(content.selectedIndex == 1, "Down arrow moves the highlight (index \(content.selectedIndex.map(String.init) ?? "none"))")
                expected = content.rows.count > 1 ? content.rows[1].clip.preview : ""
                pasteboard.clearContents()
                press([("\r", kVK_Return)])
            }),
            (3.7, {
                check(!dropdown.isOpen, "Return closes the dropdown")
                check(!expected.isEmpty && pasteboard.string(forType: .string) == expected, "Return copies the highlighted clip")
                lines.append("      closed: \(Memory.describe())")
                dropdown.open()
            }),
            (4.3, { press(fox) }),
            (4.7, { press([("\u{1B}", kVK_Escape)]) }),
            (5.0, {
                check(dropdown.isOpen && dropdown.query.isEmpty, "Escape clears the search first")
                press([("\u{1B}", kVK_Escape)])
            }),
            (5.3, {
                check(!dropdown.isOpen, "Escape again closes the dropdown")
                dropdown.open()
            }),
            (5.8, {
                guard let rich = content.rows.first(where: { $0.clip.kind == .rich }) else {
                    check(false, "a formatted clip is shown")
                    return
                }
                rich.plainButton?.performClick(nil)
                let types = pasteboard.types ?? []
                check(!types.contains(.rtf) && !types.contains(.html) && pasteboard.string(forType: .string) == rich.clip.preview,
                      "T copies plain text only")
                dropdown.open()
            }),
            (6.2, {
                guard let rich = content.rows.first(where: { $0.clip.kind == .rich }) else { return }
                rich.formattedButton?.performClick(nil)
                let types = pasteboard.types ?? []
                check(types.contains(.rtf) && types.contains(.html), "Aa copies with formatting")
                dropdown.open()
            }),
            (6.6, {
                let before = dropdown.store.count()
                let first = content.rows.first?.clip.id
                content.rows.first?.onDelete?()
                check(dropdown.isOpen && dropdown.store.count() == before - 1 && content.rows.first?.clip.id != first,
                      "× deletes the clip and leaves the dropdown open")
                dropdown.close()
            })
        ]
        var time: TimeInterval = 7.0
        for _ in 0..<10 {
            schedule.append((time, { dropdown.statusItem.button?.performClick(nil) }))
            schedule.append((time + 0.4, { dropdown.statusItem.button?.performClick(nil) }))
            time += 0.8
        }
        schedule.append((time + 0.5, {
            check(!dropdown.isOpen, "clicking the paperclip again closes it")
            lines.append("      after 10 more opens: \(Memory.describe())")
            lines.append(failures == 0 ? "\nAll dropdown checks passed." : "\n\(failures) dropdown check(s) failed.")
            print(lines.joined(separator: "\n"))
            pasteboard.releaseGlobally()
            exit(failures == 0 ? 0 : 1)
        }))

        let start = Date()
        for (delay, action) in schedule {
            let timer = Timer(fire: start.addingTimeInterval(delay), interval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { action() }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Presses a key system-wide. Only call while ClipCopy's menu is open, so the menu gets it.
    private static func pressKey(_ character: Character, keyCode: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let code = CGKeyCode(keyCode)
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            var utf16 = Array(String(character).utf16)
            event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event?.post(tap: .cghidEventTap)
        }
    }
}

enum Memory {
    /// Resident memory and the footprint figure Activity Monitor shows, in MB.
    static func current() -> (resident: Double, footprint: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.resident_size) / 1_048_576, Double(info.phys_footprint) / 1_048_576)
    }

    static func describe() -> String {
        let memory = current()
        return String(format: "%.1f MB resident, %.1f MB footprint", memory.resident, memory.footprint)
    }
}
