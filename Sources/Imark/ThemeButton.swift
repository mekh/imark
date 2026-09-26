import AppKit

/// One button for three states, in place of the three-segment control that used
/// to sit here. Three segments is a lot of a reading app's chrome to spend on
/// something most people set once — and the appearance now also has a home in
/// the preferences, where the palettes are chosen.
///
/// The glyph is a subview rather than the button's own image so it can be
/// swapped with a symbol transition: an icon that changes without moving reads
/// as a redraw, and one that slides reads as an answer to the press.
final class ThemeButton: ToolbarButton {
    private var showing: Settings.Theme?

    init(target: AnyObject, action: Selector) {
        super.init(symbol: nil, label: "Appearance", target: target, action: action)
        show(Settings.theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Animates only when the state actually moved. Every setting announces
    /// itself, so without this the glyph would jump each time somebody nudged
    /// the text size.
    func show(_ theme: Settings.Theme) {
        let moved = showing != nil && showing != theme
        showing = theme

        toolTip = "Appearance: \(theme.label)"
        setAccessibilityLabel("Appearance: \(theme.label)")

        guard let image = NSImage(systemSymbolName: theme.symbol, accessibilityDescription: theme.label)?
            .withSymbolConfiguration(Self.configuration)
        else { return }

        if moved, #available(macOS 15.0, *) {
            glyph.setSymbolImage(image, contentTransition: .replace.downUp)
        } else {
            glyph.image = image
        }
    }
}
