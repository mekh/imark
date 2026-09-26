import AppKit

/// A toolbar button built the way the appearance button is: a bordered button
/// with the glyph as a subview, rather than an image the toolbar makes a button
/// of by itself. The toolbar's own buttons gave nothing back under the pointer,
/// so Appearance was the one button in the row that lit up when you went to it.
/// Now every one does, and shows the hand, like everything else in the window
/// that can be pressed.
class ToolbarButton: NSButton {
    let glyph = NSImageView()

    init(symbol: String?, label: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        bezelStyle = .texturedRounded
        title = ""
        imagePosition = .noImage
        self.target = target
        self.action = action
        setAccessibilityLabel(label)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleNone
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 38),
            heightAnchor.constraint(equalToConstant: 24),
        ])

        if let symbol {
            show(NSImage(systemSymbolName: symbol, accessibilityDescription: label))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    static let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

    /// `tint` for a switch that is on: the glyph takes the accent colour. A
    /// glyph drawn rather than taken from SF Symbols is shown as it is.
    func show(_ image: NSImage?, tint: NSColor? = nil) {
        glyph.image = image?.withSymbolConfiguration(Self.configuration) ?? image
        glyph.contentTintColor = tint
    }

    /// The glyph is not the button's own image, so it does not grey out with the
    /// button by itself.
    override var isEnabled: Bool {
        didSet {
            glyph.alphaValue = isEnabled ? 1 : 0.35
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// An item whose view is a `ToolbarButton`. The toolbar validates the items it
/// draws an image for and leaves the ones with a view alone, so Save and Revert
/// would stay lit on a clean document and Comments on one with none. This asks
/// the same question those items were asked, of whoever takes the action.
final class ToolbarButtonItem: NSToolbarItem {
    override func validate() {
        guard let action, let button = view as? NSButton else { return }
        let taker = NSApp.target(forAction: action, to: button.target, from: self)
        let on = (taker as? NSToolbarItemValidation)?.validateToolbarItem(self) ?? true
        if button.isEnabled != on { button.isEnabled = on }
        isEnabled = on
    }
}
