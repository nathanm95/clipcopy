import AppKit

/// The search box at the top of the dropdown. It has the keyboard while the dropdown is open:
/// typing filters the clips, and the arrow keys, Return and Escape are passed to `onCommand`.
final class SearchHeaderView: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    var onChange: ((String) -> Void)?
    /// Arrow keys, Return and Escape; return true if handled.
    var onCommand: ((Selector) -> Bool)?

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 34))
        field.frame = NSRect(x: 12, y: 6, width: width - 24, height: 22)
        field.placeholderString = "Type to search"
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.delegate = self
        addSubview(field)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    func focus() {
        window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        onCommand?(commandSelector) ?? false
    }
}
