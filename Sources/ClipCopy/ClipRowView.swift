import AppKit

/// One clip in the dropdown. Clicking the row copies it as plain text. Formatted clips also get
/// Aa (with formatting) and T (plain text) buttons, and the highlighted row shows × to delete it.
final class ClipRowView: NSView {
    static let textRowHeight: CGFloat = 24
    static let imageRowHeight: CGFloat = 44

    let clip: ClipSummary
    var onCopy: ((ClipboardWriter.Style) -> Void)?
    var onDelete: (() -> Void)?
    /// The pointer entered (true) or left (false) the row.
    var onHover: ((Bool) -> Void)?
    /// Highlighted by the pointer or the arrow keys.
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            refreshHighlight()
            needsDisplay = true
        }
    }

    private let titleField = NSTextField(labelWithString: "")
    private var iconView: NSImageView?
    private(set) var formattedButton: NSButton?
    private(set) var plainButton: NSButton?
    private let deleteButton: NSButton
    private let filesMissing: Bool

    init(clip: ClipSummary, width: CGFloat, imagesDirectory: URL) {
        self.clip = clip
        filesMissing = clip.kind == .files && clip.paths.contains { !FileManager.default.fileExists(atPath: $0) }
        let xmark = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete")
            ?? NSImage(size: NSSize(width: 12, height: 12))
        deleteButton = NSButton(image: xmark, target: nil, action: nil)
        let height = clip.kind == .image ? Self.imageRowHeight : Self.textRowHeight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

        var titleX: CGFloat = 14
        switch clip.kind {
        case .image:
            let box = NSRect(x: 14, y: 4, width: 52, height: 36)
            let view = NSImageView(frame: box)
            view.imageScaling = .scaleProportionallyDown
            view.imageAlignment = .alignLeft
            if let file = clip.thumbnailFile {
                view.image = NSImage(contentsOf: imagesDirectory.appendingPathComponent(file))
            }
            addSubview(view)
            iconView = view
            titleX = box.maxX + 8
        case .files:
            let view = NSImageView(frame: NSRect(x: 14, y: (height - 16) / 2, width: 16, height: 16))
            if let first = clip.paths.first {
                let icon = NSWorkspace.shared.icon(forFile: first)
                icon.size = NSSize(width: 16, height: 16)
                view.image = icon
            }
            view.alphaValue = filesMissing ? 0.45 : 1
            addSubview(view)
            iconView = view
            titleX = 36
        case .text, .rich:
            break
        }

        // Right-hand controls: [Aa][T] for formatted text, then × (shown only under the pointer).
        var right = width - 12
        let deleteSize: CGFloat = 16
        deleteButton.frame = NSRect(x: right - deleteSize, y: (height - deleteSize) / 2, width: deleteSize, height: deleteSize)
        deleteButton.isBordered = false
        deleteButton.imageScaling = .scaleProportionallyDown
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.toolTip = "Delete this clip"
        deleteButton.isHidden = true
        addSubview(deleteButton)
        right -= deleteSize + 6

        if clip.kind == .rich {
            let plain = Self.pillButton(title: "T", toolTip: "Copy as plain text")
            plain.frame = NSRect(x: right - 24, y: (height - 18) / 2, width: 24, height: 18)
            plain.target = self
            plain.action = #selector(plainClicked)
            addSubview(plain)
            plainButton = plain
            right -= 24 + 4

            let formatted = Self.pillButton(title: "Aa", toolTip: "Copy with formatting")
            formatted.frame = NSRect(x: right - 28, y: (height - 18) / 2, width: 28, height: 18)
            formatted.target = self
            formatted.action = #selector(formattedClicked)
            addSubview(formatted)
            formattedButton = formatted
            right -= 28 + 6
        }

        titleField.stringValue = Self.title(for: clip)
        titleField.font = .menuFont(ofSize: 0)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.truncatesLastVisibleLine = true
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        titleField.frame = NSRect(x: titleX, y: (height - titleHeight) / 2, width: max(20, right - titleX), height: titleHeight)
        addSubview(titleField)

        toolTip = Self.details(for: clip, filesMissing: filesMissing)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(titleField.stringValue)
        refreshHighlight()
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    // MARK: - Drawing

    /// Matches the text and controls to the row's highlight.
    private func refreshHighlight() {
        let highlighted = isHighlighted
        if highlighted {
            titleField.textColor = .selectedMenuItemTextColor
        } else {
            titleField.textColor = filesMissing ? .disabledControlTextColor : .labelColor
        }
        deleteButton.isHidden = !highlighted
        deleteButton.contentTintColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
    }

    // MARK: - Clicks

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    /// ClipCopy is never the active app, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onCopy?(.plain)
    }

    @objc private func formattedClicked() {
        onCopy?(.asCopied)
    }

    @objc private func plainClicked() {
        onCopy?(.plain)
    }

    @objc private func deleteClicked() {
        onDelete?()
    }

    // MARK: - Text

    private static func pillButton(title: String, toolTip: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 10, weight: .semibold)
        button.toolTip = toolTip
        return button
    }

    static func title(for clip: ClipSummary) -> String {
        switch clip.kind {
        case .text, .rich:
            let words = clip.preview.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            return words.isEmpty ? "(spaces only)" : words
        case .image:
            return clip.pixelWidth > 0 ? "Image  \(clip.pixelWidth) × \(clip.pixelHeight)" : "Image"
        case .files:
            let first = clip.paths.first.map { ($0 as NSString).lastPathComponent } ?? "File"
            return clip.paths.count > 1 ? "\(first) + \(clip.paths.count - 1) more" : first
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// The one-line details shown under the clips for the highlighted one.
    static func detailsLine(for clip: ClipSummary) -> String {
        let source = clip.sourceApp ?? "Unknown app"
        let time = dateFormatter.string(from: clip.copiedAt)
        let characters = clip.characterCount == 1 ? "1 character" : "\(clip.characterCount.formatted()) characters"
        let kind: String
        switch clip.kind {
        case .text:
            kind = "Plain · \(characters)"
        case .rich:
            kind = "Formatted · \(characters)"
        case .image:
            kind = "\(clip.pixelWidth) × \(clip.pixelHeight)"
        case .files:
            let missing = clip.paths.filter { !FileManager.default.fileExists(atPath: $0) }.count
            kind = (clip.paths.count == 1 ? "1 file" : "\(clip.paths.count) files")
                + (missing == 0 ? "" : " · \(missing) missing")
        }
        return "\(source) · \(time) · \(kind)"
    }

    /// The hover tooltip: where the clip came from, when, and what kind it is.
    static func details(for clip: ClipSummary, filesMissing: Bool) -> String {
        var lines: [String] = []
        lines.append("Copied from \(clip.sourceApp ?? "an unknown app")")
        lines.append(dateFormatter.string(from: clip.copiedAt))
        let characters = clip.characterCount.formatted()
        switch clip.kind {
        case .text:
            lines.append("Plain text · \(characters) characters")
        case .rich:
            lines.append("Formatted text · \(characters) characters")
        case .image:
            lines.append("Image · \(clip.pixelWidth) × \(clip.pixelHeight) pixels")
        case .files:
            lines.append(clip.paths.count == 1 ? "File" : "\(clip.paths.count) files")
            for path in clip.paths.prefix(5) {
                let missing = FileManager.default.fileExists(atPath: path) ? "" : " (missing)"
                lines.append((path as NSString).abbreviatingWithTildeInPath + missing)
            }
            if clip.paths.count > 5 {
                lines.append("…")
            }
            if filesMissing {
                lines.append("Missing files can't be pasted.")
            }
        }
        return lines.joined(separator: "\n")
    }
}
