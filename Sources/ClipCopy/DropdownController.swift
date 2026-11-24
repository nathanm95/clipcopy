import AppKit

/// A borderless panel that can take the keyboard without making ClipCopy the active app,
/// so the app you were using stays in front.
final class DropdownPanel: NSPanel {
    var onCommandKey: ((String) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(), onCommandKey?(key) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The paperclip in the menu bar and the dropdown it opens. The dropdown looks like a menu, but it
/// is a panel, so the search box can keep the keyboard and rows can have their own buttons.
@MainActor
final class DropdownController: NSObject, NSWindowDelegate {
    static let visibleCount = 20

    let store: ClipStore
    let statusItem: NSStatusItem
    /// Where copies go. Only the menu test changes this, to keep away from the real clipboard.
    var pasteboard = NSPasteboard.general
    let content = DropdownContent()
    private let watcher: ClipboardWatcher?
    private let panel: DropdownPanel
    private let background = NSVisualEffectView()
    private var outsideClickMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private var closedAt = Date.distantPast
    private(set) var query = ""

    var isOpen: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    var visibleClipCount: Int { content.rows.count }

    init(store: ClipStore, watcher: ClipboardWatcher?) {
        self.store = store
        self.watcher = watcher
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = DropdownPanel(contentRect: NSRect(x: 0, y: 0, width: DropdownContent.width, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()

        statusItem.autosaveName = "ClipCopy"
        if let button = statusItem.button {
            button.image = Paperclip.menuBarImage()
            button.toolTip = "ClipCopy"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        panel.onCommandKey = { [weak self] key in
            MainActor.assumeIsolated { self?.commandKey(key) ?? false }
        }

        // The same frosted material and rounded corners as a menu.
        background.material = .menu
        background.state = .active
        background.blendingMode = .behindWindow
        background.maskImage = Self.roundedMask(radius: 10)
        panel.contentView = background
        background.addSubview(content.view)

        content.header.onChange = { [weak self] text in
            MainActor.assumeIsolated { self?.searchChanged(text) }
        }
        content.header.onCommand = { [weak self] command in
            MainActor.assumeIsolated { self?.keyCommand(command) ?? false }
        }
        content.onCopy = { [weak self] id, style in self?.copy(id, style: style) }
        content.onDelete = { [weak self] id in self?.delete(id) }
        content.onClearHistory = { [weak self] in self?.clearHistory() }
        content.onToggleLogin = { [weak self] in
            self?.close()
            LoginItem.setEnabled(!LoginItem.isEnabled)
        }
        content.onQuit = { NSApp.terminate(nil) }
    }

    // MARK: - Opening and closing

    @objc private func statusItemClicked() {
        if isOpen {
            close()
        } else if Date().timeIntervalSince(closedAt) > 0.25 {
            // A click on the paperclip also takes the keyboard away from the panel, which closes it
            // just before this runs; don't reopen it straight away.
            open()
        }
    }

    func open() {
        query = ""
        content.header.query = ""
        content.setLoginEnabled(LoginItem.isEnabled)
        reload()
        panel.makeKeyAndOrderFront(nil)
        content.header.focus()
        statusItem.button?.highlight(true)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        closedAt = Date()
        statusItem.button?.highlight(false)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
        }
        appSwitchObserver = nil
        // Let the rows (and their thumbnails) go while the dropdown is closed.
        content.setClips([], imagesDirectory: store.imagesDirectory, query: "", totalCount: 0, maxHeight: .greatestFiniteMagnitude)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: - Contents

    private func reload() {
        let clips = query.isEmpty
            ? store.recent(limit: Self.visibleCount)
            : store.search(query, limit: Self.visibleCount)
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let maxHeight = (screen?.visibleFrame.height ?? 800) - 20
        content.setClips(clips, imagesDirectory: store.imagesDirectory, query: query, totalCount: store.count(),
                         maxHeight: maxHeight)
        if !query.isEmpty, !content.rows.isEmpty {
            content.selectedIndex = 0
        }
        position()
    }

    /// Puts the dropdown under the paperclip, kept on screen, growing downwards.
    private func position() {
        let size = content.view.frame.size
        guard let button = statusItem.button, let buttonWindow = button.window else {
            panel.setContentSize(size)
            return
        }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? buttonRect
        var x = buttonRect.minX - 6
        x = min(x, visible.maxX - size.width - 6)
        x = max(x, visible.minX + 6)
        let top = min(buttonRect.minY - 1, visible.maxY)
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        content.view.frame = background.bounds
    }

    private func searchChanged(_ text: String) {
        query = text
        reload()
    }

    // MARK: - Keyboard

    private func keyCommand(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveDown(_:)):
            content.moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            content.moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            // Return does what clicking the row does: plain text.
            let index = content.selectedIndex ?? 0
            if index < content.rows.count {
                copy(content.rows[index].clip.id, style: .plain)
            }
        case #selector(NSResponder.cancelOperation(_:)):
            if query.isEmpty {
                close()
            } else {
                content.header.query = ""
                searchChanged("")
            }
        default:
            return false
        }
        return true
    }

    private func commandKey(_ key: String) -> Bool {
        switch key {
        case "q":
            NSApp.terminate(nil)
        case "w":
            close()
        default:
            return false
        }
        return true
    }

    // MARK: - Actions

    private func copy(_ id: Int64, style: ClipboardWriter.Style) {
        close()
        guard let clip = store.load(id), ClipboardWriter.write(clip, style: style, to: pasteboard) else {
            NSSound.beep()
            return
        }
        if pasteboard == .general {
            watcher?.ignoreCurrentContents()
        }
        store.touch(id)
    }

    private func delete(_ id: Int64) {
        let selected = content.selectedIndex
        store.delete(id)
        reload()
        if let selected, !content.rows.isEmpty {
            content.selectedIndex = min(selected, content.rows.count - 1)
        }
    }

    private func clearHistory() {
        close()
        let count = store.count()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Clear 1 clip?" : "Clear all \(count.formatted()) clips?"
        alert.informativeText = "This deletes your whole ClipCopy history, including saved images. It can't be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearAll()
        }
    }

    /// A stretchable rounded-rectangle mask, so the frosted background gets rounded corners.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
