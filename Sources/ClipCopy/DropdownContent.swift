import AppKit

/// A view whose y axis runs top to bottom, for laying out rows in reading order.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The dropdown's contents from top to bottom: search, clips, a details line, and commands.
/// Kept apart from the panel so the render test can draw it without a menu bar.
@MainActor
final class DropdownContent {
    static let width: CGFloat = 360
    private static let padding: CGFloat = 5

    let view = FlippedView()
    let header = SearchHeaderView(width: DropdownContent.width)
    private(set) var rows: [ClipRowView] = []
    private let emptyField = NSTextField(labelWithString: "")
    private let detailsField = NSTextField(labelWithString: "")
    private var clearRow: CommandRowView!
    private var loginRow: CommandRowView!
    private var quitRow: CommandRowView!
    private let separators = [SeparatorView(width: DropdownContent.width), SeparatorView(width: DropdownContent.width),
                              SeparatorView(width: DropdownContent.width)]
    private var summaryText = ""

    var onCopy: ((Int64, ClipboardWriter.Style) -> Void)?
    var onDelete: ((Int64) -> Void)?
    var onClearHistory: (() -> Void)?
    var onToggleLogin: (() -> Void)?
    var onQuit: (() -> Void)?

    /// The clip highlighted by the pointer or the arrow keys.
    var selectedIndex: Int? {
        didSet { applySelection() }
    }

    init() {
        clearRow = CommandRowView(title: "Clear History…", width: Self.width) { [weak self] in self?.onClearHistory?() }
        loginRow = CommandRowView(title: "Open at Login", width: Self.width) { [weak self] in self?.onToggleLogin?() }
        quitRow = CommandRowView(title: "Quit ClipCopy", shortcut: "⌘Q", width: Self.width) { [weak self] in self?.onQuit?() }
        for field in [emptyField, detailsField] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
        }
        emptyField.font = .menuFont(ofSize: 0)
        emptyField.textColor = .disabledControlTextColor
        detailsField.font = .systemFont(ofSize: 11)
        detailsField.textColor = .secondaryLabelColor
        for commandRow in [clearRow!, loginRow!, quitRow!] {
            commandRow.onHover = { [weak self] in self?.selectedIndex = nil }
        }
    }

    func setLoginEnabled(_ enabled: Bool) {
        loginRow.checked = enabled
    }

    /// Shows `clips`, dropping rows from the bottom if they wouldn't fit in `maxHeight`.
    func setClips(_ clips: [ClipSummary], imagesDirectory: URL, query: String, totalCount: Int, maxHeight: CGFloat) {
        for row in rows {
            row.removeFromSuperview()
        }
        rows = []
        var used = fixedHeight
        for (index, clip) in clips.enumerated() {
            let row = ClipRowView(clip: clip, width: Self.width, imagesDirectory: imagesDirectory)
            guard used + row.frame.height <= maxHeight || index == 0 else { break }
            used += row.frame.height
            let id = clip.id
            row.onCopy = { [weak self] style in self?.onCopy?(id, style) }
            row.onDelete = { [weak self] in self?.onDelete?(id) }
            row.onHover = { [weak self] entered in
                guard let self else { return }
                if entered {
                    self.selectedIndex = index
                } else if self.selectedIndex == index {
                    self.selectedIndex = nil
                }
            }
            rows.append(row)
        }
        emptyField.stringValue = query.isEmpty ? "Nothing copied yet" : "No clips match “\(query)”"
        if query.isEmpty {
            summaryText = totalCount == 1 ? "1 clip saved" : "\(totalCount.formatted()) clips saved"
        } else {
            summaryText = rows.count == 1 ? "1 match" : "\(rows.count) matches"
        }
        selectedIndex = nil
        layout()
    }

    /// Everything except the clip rows: padding, search, separators, details line and commands.
    private var fixedHeight: CGFloat {
        Self.padding * 2 + header.frame.height + SeparatorView.height * 3 + 22 + CommandRowView.height * 3
    }

    /// Positions everything top to bottom. Only the clip rows come and go; the search box stays put,
    /// because taking it out of the window, even for a moment, would drop the keyboard focus.
    private func layout() {
        var y = Self.padding
        let fullWidth = Self.width
        func place(_ subview: NSView, height: CGFloat, x: CGFloat = 0, width: CGFloat? = nil) {
            subview.frame = NSRect(x: x, y: y, width: width ?? fullWidth, height: height)
            if subview.superview !== view {
                view.addSubview(subview)
            }
            y += height
        }

        place(header, height: header.frame.height)
        place(separators[0], height: SeparatorView.height)
        if rows.isEmpty {
            place(emptyField, height: 22, x: 14, width: Self.width - 28)
        } else {
            emptyField.removeFromSuperview()
        }
        for row in rows {
            place(row, height: row.frame.height)
        }
        place(detailsField, height: 22, x: 14, width: Self.width - 28)
        place(separators[1], height: SeparatorView.height)
        place(clearRow, height: CommandRowView.height)
        place(loginRow, height: CommandRowView.height)
        place(separators[2], height: SeparatorView.height)
        place(quitRow, height: CommandRowView.height)
        y += Self.padding
        view.frame = NSRect(x: 0, y: 0, width: Self.width, height: y)
        applySelection()
    }

    private func applySelection() {
        for (index, row) in rows.enumerated() {
            row.isHighlighted = index == selectedIndex
        }
        if let selectedIndex, selectedIndex < rows.count {
            detailsField.stringValue = ClipRowView.detailsLine(for: rows[selectedIndex].clip)
        } else {
            detailsField.stringValue = summaryText
        }
    }

    func moveSelection(by step: Int) {
        guard !rows.isEmpty else { return }
        guard let current = selectedIndex else {
            selectedIndex = step > 0 ? 0 : rows.count - 1
            return
        }
        selectedIndex = min(max(current + step, 0), rows.count - 1)
    }
}

/// A thin line between sections, like a menu separator.
final class SeparatorView: NSView {
    static let height: CGFloat = 11

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 14, y: floor(bounds.midY), width: bounds.width - 28, height: 1).fill()
    }
}

/// A plain command row, such as "Clear History…", that highlights under the pointer like a menu item.
final class CommandRowView: NSView {
    static let height: CGFloat = 22

    var onHover: (() -> Void)?
    var checked = false {
        didSet { checkView.isHidden = !checked }
    }
    private let action: () -> Void
    private let titleField: NSTextField
    private let shortcutField: NSTextField?
    private let checkView: NSImageView
    private var isHighlighted = false {
        didSet {
            titleField.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
            shortcutField?.textColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
            checkView.contentTintColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
            needsDisplay = true
        }
    }

    init(title: String, shortcut: String? = nil, width: CGFloat, action: @escaping () -> Void) {
        self.action = action
        titleField = NSTextField(labelWithString: title)
        titleField.font = .menuFont(ofSize: 0)
        shortcutField = shortcut.map { NSTextField(labelWithString: $0) }
        checkView = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: "On")
            ?? NSImage(size: NSSize(width: 12, height: 12)))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))

        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        titleField.frame = NSRect(x: 14, y: (Self.height - titleHeight) / 2, width: width - 80, height: titleHeight)
        addSubview(titleField)
        if let shortcutField {
            shortcutField.font = .menuFont(ofSize: 0)
            shortcutField.textColor = .secondaryLabelColor
            shortcutField.alignment = .right
            shortcutField.frame = NSRect(x: width - 74, y: titleField.frame.minY, width: 60, height: titleHeight)
            addSubview(shortcutField)
        }
        checkView.frame = NSRect(x: width - 30, y: (Self.height - 14) / 2, width: 14, height: 14)
        checkView.isHidden = true
        addSubview(checkView)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        onHover?()
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        isHighlighted = false
        action()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
}
