import AppKit

/// The list under a text field that offers what to type in it, the way
/// Safari's address field does: opened by a click in the field, narrowed as
/// one types, walked with the arrows or the pointer, taken with Return or a
/// click. The field keeps the keyboard throughout.
///
/// Not NSComboBox: its list opens through `popUp:`, which runs an event loop of
/// its own until the list is closed, so opening it from code blocks whoever
/// asked — the first build of the model field hung inside a keystroke that way.
final class SuggestionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Item: Equatable {
        /// What goes into the field.
        var value: String
        var title: String
        /// Grey, on the right.
        var detail: String
    }

    var items: [Item] = [] {
        didSet { reload() }
    }

    /// A row taken with Return or a click.
    var onPick: ((Item) -> Void)?
    /// The line at the foot of the list for the row marked. Whatever sits
    /// under the field is behind the list while it is open, so what it would
    /// say about the row goes here.
    var describe: ((Item) -> String?)?
    /// The foot's line while no row is marked.
    var summary = "" {
        didSet { showFoot() }
    }

    /// Rows shown at once; the rest scroll.
    static let visibleRows = 10
    static let rowHeight: CGFloat = 22
    /// Wider than the field when it can be: a model's name and its provider
    /// do not fit in a field sized for the form.
    static let width: CGFloat = 440
    static let footHeight: CGFloat = 26

    static func height(rows: Int) -> CGFloat { CGFloat(rows) * rowHeight + 8 + footHeight }

    private let panel: NSPanel
    private let table = PointedTable()
    private let scroll = NSScrollView()
    private let foot = NSTextField(labelWithString: "")
    private weak var field: NSTextField?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        // Never key: the field it serves has to keep the keyboard.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        background.layer?.masksToBounds = true

        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onPoint = { [weak self] row in self?.highlight(row, scrolling: false) }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        foot.font = .systemFont(ofSize: 11)
        foot.textColor = .secondaryLabelColor
        foot.lineBreakMode = .byTruncatingTail
        let line = NSBox()
        line.boxType = .separator

        for view in [scroll, line, foot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -(4 + Self.footHeight)),
            line.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            line.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 3),
            foot.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            foot.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            foot.centerYAnchor.constraint(equalTo: background.bottomAnchor, constant: -(Self.footHeight / 2 + 1)),
        ])
        panel.contentView = background
    }

    var isOpen: Bool { panel.parent != nil }
    var frame: NSRect { panel.frame }
    var highlighted: Int? { table.selectedRow >= 0 ? table.selectedRow : nil }
    var footText: String { foot.stringValue }
    /// Whether there is more than the rows shown; for the tests.
    var scrolls: Bool { table.frame.height > scroll.contentView.bounds.height + 1 }

    /// Opens the list under the field, with the row holding `value` shown and
    /// marked. An empty list stays shut.
    func open(under field: NSTextField, marking value: String? = nil) {
        guard !items.isEmpty, let window = field.window else { return close() }
        self.field = field
        place()
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        if let value, let index = items.firstIndex(where: { $0.value == value }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
            table.scrollRowToVisible(0)
        }
        showFoot()
    }

    func close() {
        guard isOpen else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Under the field, or over it when the screen ends below.
    private func place() {
        guard let field, let window = field.window else { return }
        let rect = window.convertToScreen(field.convert(field.bounds, to: nil))
        let height = Self.height(rows: min(items.count, Self.visibleRows))
        let width = max(rect.width, Self.width)
        var frame = NSRect(x: rect.minX, y: rect.minY - height - 3, width: width, height: height)
        if let screen = window.screen?.visibleFrame {
            if frame.minY < screen.minY { frame.origin.y = rect.maxY + 3 }
            if frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - width) }
        }
        panel.setFrame(frame, display: isOpen)
    }

    private func reload() {
        table.reloadData()
        showFoot()
        guard isOpen else { return }
        if items.isEmpty || field?.window == nil { close() } else { place() }
    }

    /// Keys from the field's editor, through its delegate's
    /// `control(_:textView:doCommandBy:)`. True when the list took the key.
    func handle(_ selector: Selector, in field: NSTextField) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            guard !items.isEmpty else { return false }
            // Opened by the arrow, the list starts at what the field holds.
            if !isOpen || self.field !== field {
                open(under: field, marking: field.stringValue.trimmingCharacters(in: .whitespaces))
                if highlighted != nil { return true }
            }
            highlight(min((highlighted ?? -1) + 1, items.count - 1))
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard isOpen else { return false }
            highlight(max((highlighted ?? items.count) - 1, 0))
            return true
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            guard isOpen else { return false }
            highlight(min((highlighted ?? -1) + Self.visibleRows, items.count - 1))
            return true
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            guard isOpen else { return false }
            highlight(max((highlighted ?? 0) - Self.visibleRows, 0))
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard isOpen, let index = highlighted else {
                close()
                return false
            }
            pick(index)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            guard isOpen else { return false }
            close()
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            close()
            return false
        default:
            return false
        }
    }

    private func highlight(_ index: Int, scrolling: Bool = true) {
        guard items.indices.contains(index) else { return }
        table.selectRowIndexes([index], byExtendingSelection: false)
        if scrolling { table.scrollRowToVisible(index) }
        showFoot()
    }

    private func showFoot() {
        let marked = highlighted.flatMap { items.indices.contains($0) ? items[$0] : nil }
        foot.stringValue = marked.flatMap { describe?($0) } ?? summary
    }

    @objc private func clicked() {
        guard items.indices.contains(table.clickedRow) else { return }
        pick(table.clickedRow)
    }

    private func pick(_ index: Int) {
        let item = items[index]
        close()
        onPick?(item)
    }

    // MARK: - Rows

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { MenuRow() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SuggestionCell.identifier, owner: nil) as? SuggestionCell ?? SuggestionCell()
        cell.show(items[row])
        return cell
    }
}

/// Marks the row under the pointer, as a menu does.
private final class PointedTable: NSTableView {
    var onPoint: ((Int) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        // Always: the list's window is never key.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, row != selectedRow { onPoint?(row) }
    }
}

/// Marked the way a menu marks the item under the pointer, though the list's
/// window is never key.
private final class MenuRow: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}

private final class SuggestionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("suggestion")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.font = .systemFont(ofSize: 11)
        detail.lineBreakMode = .byTruncatingHead
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField = title
        for label in [title, detail] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detail.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(_ item: SuggestionList.Item) {
        title.stringValue = item.title
        detail.stringValue = item.detail
        toolTip = item.value
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { paint() }
    }

    private func paint() {
        let marked = backgroundStyle == .emphasized
        title.textColor = marked ? .alternateSelectedControlTextColor : .labelColor
        detail.textColor = marked ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
    }
}
