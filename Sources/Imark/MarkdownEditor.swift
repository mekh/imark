import AppKit

/// The document as text, for the half of the app that writes.
///
/// Ported from Loadout, which had already worked out the two things that make a
/// programmatic `NSTextView` behave: the sizing dance without which the buffer
/// draws nothing, and a gutter that is a plain sibling view rather than an
/// `NSRulerView`. What changed on the way in is the palette — Loadout is dark
/// only and names its colours; Imark has a light face and six themes, so
/// everything here comes from the system's semantic colours and the app's accent,
/// and follows the window when the system switches.
final class MarkdownEditorView: NSView {
    /// Called on every keystroke, so the window can find out it has something
    /// unsaved without asking.
    var onEdit: (() -> Void)?
    /// ⌘S from inside the text view, which owns the keyboard while it has focus.
    var onSave: (() -> Void)?

    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let gutter = LineGutter()
    private var gutterWidth: NSLayoutConstraint!
    private var boundsObserver: NSObjectProtocol?

    /// The file as it was read. What the gutter's bars are measured against, and
    /// what tells "unsaved" from "saved".
    private var diskText = ""

    /// The buffer's size at the reader's default text size. ⌘+ and ⌘− scale it
    /// by the same share as the page, so the two keep the proportion they had.
    static let defaultFontSize: CGFloat = 12.5
    /// The reader's text size over its default, as last sent by the window.
    private var scale: CGFloat = 1
    private var fontSize: CGFloat { Self.defaultFontSize * scale }

    var text: String { textView.string }
    var isDirty: Bool { textView.string != diskText }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 12)
        // A document is not prose the system should be correcting: a smart quote
        // in Markdown is a smart quote in the file, and an em dash where somebody
        // typed two hyphens is an edit nobody asked for.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = self

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        gutter.textView = textView
        gutter.translatesAutoresizingMaskIntoConstraints = false

        addSubview(gutter)
        addSubview(scroll)
        gutterWidth = gutter.widthAnchor.constraint(equalToConstant: 46)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterWidth,
            scroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The gutter draws the slice of the document that is on screen, so it has
        // to be repainted by scrolling as well as by typing.
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak self] _ in self?.gutter.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    /// Puts a file in the editor. `text` is both the buffer and the copy on disk:
    /// a freshly opened document has nothing unsaved in it.
    func load(_ text: String) {
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        diskText = text
        textView.undoManager?.removeAllActions()
        refresh()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scroll(.zero)
    }

    /// After a save: the buffer has not changed, but the file has caught up with
    /// it, so the bars in the gutter go away.
    func markSaved() {
        diskText = textView.string
        refresh()
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    /// Typing is undone by the text view's own stack, not by the app's — the app's
    /// undo puts whole documents back, which is not what ⌘Z means while typing.
    var canUndo: Bool { textView.undoManager?.canUndo ?? false }
    var canRedo: Bool { textView.undoManager?.canRedo ?? false }

    func undo() {
        textView.undoManager?.undo()
        refresh()
        onEdit?()
    }

    func redo() {
        textView.undoManager?.redo()
        refresh()
        onEdit?()
    }

    /// The system's own find bar, from ⌘F — the text view owns it, and the menu
    /// item has no reference to the text view.
    func showFind() {
        window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }

    /// The reader's text size, in points, from the same menu items and slider as
    /// the page's. The buffer used to stay at one size, so ⌘+ in the editor only
    /// changed the page behind it, where nobody could see it until they went back
    /// to reading. Every window is sent the text size on any change in Settings:
    /// the size it already has does nothing, because highlighting a long file
    /// again is not free.
    func setTextScale(_ points: Double) {
        let scale = CGFloat(points / Settings.defaultTextScale)
        guard scale != self.scale else { return }
        self.scale = scale
        gutter.scale = scale
        // The numbers grow with the text, and a line in the thousands still has to
        // fit beside it.
        gutterWidth.constant = (46 * scale).rounded()
        // Behind the page the buffer still holds whatever was edited last, and
        // setting that again on every ⌘+ while reading is work nobody sees: `load`
        // sets the file in the new size when it is opened as text again.
        guard !isHidden else { return }
        let place = topPlace()
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // The buffer takes its new width now rather than on the next pass, which
        // would wrap the lines again under the place just kept.
        layoutSubtreeIfNeeded()
        refresh()
        keep(place)
    }

    /// Where the view starts: the character at its top edge, and how far down
    /// that character's line the edge falls, as a share of the line's height.
    /// The scroll offset is kept in pixels, and every line above it is a different
    /// height once the size changes, so without this each ⌘+ scrolled the buffer
    /// back and each ⌘− scrolled it on. Nil at the very top, which stays the top.
    private func topPlace() -> (character: Int, share: CGFloat)? {
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              layout.numberOfGlyphs > 0 else { return nil }
        let top = textView.visibleRect.minY - textView.textContainerOrigin.y
        guard top > 0 else { return nil }
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: top), in: container)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard line.height > 0 else { return nil }
        return (layout.characterIndexForGlyph(at: glyph), (top - line.minY) / line.height)
    }

    /// Puts a place from `topPlace` back at the top of the view.
    private func keep(_ place: (character: Int, share: CGFloat)?) {
        guard let place, let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        let glyph = layout.glyphIndexForCharacter(at: place.character)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let top = line.minY + line.height * place.share
        // The buffer grows to the new size only as far as it has been laid out,
        // and the rest is laid out later. A view's worth past the place has to be
        // there now, or a bigger size stopped the scroll short of it.
        let reach = NSRect(x: 0, y: top, width: container.size.width, height: textView.visibleRect.height)
        layout.ensureLayout(forBoundingRect: reach, in: container)
        textView.scroll(NSPoint(x: 0, y: top + textView.textContainerOrigin.y))
    }

    /// Re-highlights and repaints. Cheap enough per keystroke at the size Imark
    /// already caps documents to.
    private func refresh() {
        // Both of these read the whole buffer, which is fine at the size documents
        // actually are and a stall on a file that is mostly generated. Past the
        // ceiling the text is still editable — it just stops being coloured, which
        // is a cost worth paying to keep typing instant.
        guard textView.string.utf8.count <= Self.highlightLimit else {
            gutter.modifiedLines = []
            gutter.needsDisplay = true
            return
        }
        MarkdownHighlighter.apply(to: textView, size: fontSize)
        gutter.modifiedLines = Self.modifiedLines(current: textView.string, original: diskText)
        gutter.needsDisplay = true
    }

    /// Where colouring stops. Half a megabyte of Markdown is about 8,000 lines,
    /// well past anything written by hand.
    private static let highlightLimit = 512 * 1_024

    /// Which lines differ from the file on disk. A real diff, not a positional
    /// compare: one inserted line would otherwise flag everything below it and
    /// drown the signal the bars exist to give.
    static func modifiedLines(current: String, original: String) -> Set<Int> {
        // Opening a file and saving one both land here with the two sides equal,
        // and a diff is the slowest possible way to find that out.
        guard current != original else { return [] }
        let now = current.components(separatedBy: "\n")
        let disk = original.components(separatedBy: "\n")
        var changed: Set<Int> = []
        for case let .insert(offset, _, _) in now.difference(from: disk) {
            changed.insert(offset + 1)
        }
        return changed
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The attributes hold resolved colours, so a light/dark switch has to be
        // painted again rather than left to the system.
        refresh()
    }

    /// ⌘S while the caret is in the buffer. The menu carries it too, but a text
    /// view that has focus swallows key equivalents it recognises first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension MarkdownEditorView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        refresh()
        onEdit?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // The caret's own line number draws brighter than the rest.
        gutter.needsDisplay = true
    }
}

// MARK: - Highlighting

/// Markdown in colour, applied as attributes so the same buffer stays editable.
///
/// Every colour is a semantic one or the app's accent, which is what makes this
/// work on a light face as well as a dark one: the six themes only ever paint the
/// rendered page, and the editor is text on the system's own background.
enum MarkdownHighlighter {
    static func apply(to textView: NSTextView, size: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let source = textView.string as NSString
        let full = NSRange(location: 0, length: source.length)
        let heading = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)

        storage.beginEditing()
        storage.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ], range: full)

        var inFrontMatter = false
        var closedFrontMatter = false
        var inFence = false
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
            defer { location = NSMaxRange(lineRange) }

            // Front matter: only at the very top, and only until it closes.
            if line == "---", !inFence, !closedFrontMatter {
                if !inFrontMatter, lineRange.location == 0 {
                    inFrontMatter = true
                } else if inFrontMatter {
                    inFrontMatter = false
                    closedFrontMatter = true
                }
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: lineRange)
                storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.06), range: lineRange)
                continue
            }
            if inFrontMatter {
                storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.06), range: lineRange)
                if let colon = line.range(of: #"^[\w-]+:"#, options: .regularExpression) {
                    let keyLength = line.distance(from: line.startIndex, to: colon.upperBound) - 1
                    storage.addAttribute(
                        .foregroundColor, value: NSColor.imarkAccent,
                        range: NSRange(location: lineRange.location, length: keyLength)
                    )
                    storage.addAttribute(
                        .foregroundColor, value: NSColor.secondaryLabelColor,
                        range: NSRange(
                            location: lineRange.location + keyLength + 1,
                            length: max(0, lineRange.length - keyLength - 1)
                        )
                    )
                } else {
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: lineRange)
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: lineRange)
                continue
            }
            if inFence {
                storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: lineRange)
                continue
            }
            // A comment block is a note somebody wrote in the app. Dimmed as a
            // whole, because it is not the document — and it is still editable,
            // because in the editor the file is the file.
            if Comments.isNote(line) || line.trimmingCharacters(in: .whitespaces) == "-->" {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: lineRange)
                continue
            }
            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                storage.addAttribute(
                    .foregroundColor, value: NSColor.tertiaryLabelColor,
                    range: NSRange(location: lineRange.location, length: min(hashes + 1, lineRange.length))
                )
                let rest = NSRange(
                    location: lineRange.location + hashes + 1,
                    length: max(0, lineRange.length - hashes - 1)
                )
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: rest)
                storage.addAttribute(.font, value: heading, range: rest)
                continue
            }
            // List and quote markers, so the shape of a document is readable
            // down the left edge without reading the words.
            if let marker = line.range(of: #"^\s*([-*+>]|\d+\.)\s"#, options: .regularExpression) {
                let length = line.distance(from: line.startIndex, to: marker.upperBound)
                storage.addAttribute(
                    .foregroundColor, value: NSColor.imarkAccent,
                    range: NSRange(location: lineRange.location, length: min(length, lineRange.length))
                )
            }

            // Inline code, chip and backticks together.
            let lineText = source.substring(with: lineRange) as NSString
            var search = 0
            while true {
                let open = lineText.range(of: "`", range: NSRange(location: search, length: lineText.length - search))
                guard open.location != NSNotFound, open.location + 1 < lineText.length else { break }
                let after = open.location + 1
                let close = lineText.range(of: "`", range: NSRange(location: after, length: lineText.length - after))
                guard close.location != NSNotFound else { break }
                let span = NSRange(
                    location: lineRange.location + open.location,
                    length: close.location - open.location + 1
                )
                storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: span)
                storage.addAttribute(
                    .backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.10), range: span
                )
                search = close.location + 1
            }
        }
        storage.endEditing()
    }
}

// MARK: - Gutter

/// Line numbers, and a bar on every line that differs from the file on disk.
///
/// A plain view beside the scroll view rather than an `NSRulerView`: the ruler
/// draws under the text view's own inset and has to be fought for its width, and
/// this needs neither.
final class LineGutter: NSView {
    weak var textView: NSTextView?
    var modifiedLines: Set<Int> = []
    /// The editor's text size over its default, which the numbers follow so they
    /// stay the size of the lines they count.
    var scale: CGFloat = 1

    override var isFlipped: Bool { true }

    /// The 1-based line the caret sits on, which draws brighter than the rest.
    /// Counted with `lineRange`, the same way the numbers beside it are drawn.
    /// Counting `\n` characters instead looks equivalent and is not: on a file
    /// saved by a Windows editor, Swift reads `\r\n` as one character that is not
    /// a newline, so the caret lit a line further and further off the more line
    /// breaks it had passed.
    private var caretLine: Int {
        guard let textView else { return 0 }
        let source = textView.string as NSString
        return Self.lineNumber(at: textView.selectedRange().location, in: source)
    }

    /// Pulled out of the property so it can be tested on its own: the CRLF case
    /// is the whole reason it is written this way, and it is not reachable through
    /// a text view without one.
    static func lineNumber(at caret: Int, in source: NSString) -> Int {
        let caret = min(max(0, caret), source.length)
        var number = 1
        var location = 0
        while location < caret {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            guard NSMaxRange(line) <= caret, NSMaxRange(line) > location else { break }
            number += 1
            location = NSMaxRange(line)
        }
        return number
    }

    override func draw(_ rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer
        else { return }

        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.width - 0.5, y: 0, width: 0.5, height: bounds.height).fill()

        let source = textView.string as NSString
        // View coordinates to container coordinates: without taking the inset off,
        // the visible slice is computed one inset lower than what the eye sees.
        var visible = textView.visibleRect
        visible.origin.y -= textView.textContainerInset.height
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        // Counted from the start of the line holding the first visible character:
        // when the top of the viewport lands part-way through a wrapped line,
        // counting to the raw location includes that partial line and every
        // number comes out one too high.
        let firstLineStart = source.lineRange(for: NSRange(location: chars.location, length: 0)).location
        var number = 1
        source.enumerateSubstrings(
            in: NSRange(location: 0, length: firstLineStart),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in number += 1 }

        let current = caretLine
        var location = firstLineStart
        while location < NSMaxRange(chars) {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let glyphRange = layout.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var lineRect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            lineRect.origin.y += textView.textContainerInset.height
            // Both views are flipped, so the y converts one to one.
            let y = convert(NSPoint(x: 0, y: lineRect.minY), from: textView).y

            if modifiedLines.contains(number) {
                NSColor.imarkAccent.setFill()
                NSRect(x: 0, y: y + 2, width: 2, height: lineRect.height - 4).fill()
            }

            let label = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5 * scale, weight: .regular),
                .foregroundColor: number == current ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: bounds.width - size.width - 9, y: y + (lineRect.height - size.height) / 2),
                withAttributes: attributes
            )

            number += 1
            location = NSMaxRange(lineRange)
        }
    }
}
