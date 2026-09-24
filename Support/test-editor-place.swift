// Editing mode opens on the line the page was showing, through a real window.
//
//   TEST_BIN="$(swift build --show-bin-path)"
//   mkdir -p /tmp/imark-test-editor-place && swiftc -parse-as-library \
//     -I "$TEST_BIN" -I "$TEST_BIN/Modules" -F "$TEST_BIN" \
//     -Xlinker -rpath -Xlinker "$TEST_BIN" \
//     $(find Sources/Imark -name '*.swift' ! -name main.swift) \
//     $(find Sources/ImarkRender -name '*.swift') \
//     Support/test-editor-place.swift -o /tmp/imark-test-editor-place/run \
//     && /tmp/imark-test-editor-place/run
//
// A folder of its own, because the renderer is put beside the executable to be
// served from there.
//
// ⌘E put the file in the editor at its first line, whatever the page had been
// showing, so a typo spotted forty screens down had to be found again in the
// source. The page knows which lines of the file each block came from; the
// window asks it which one is under the toolbar, and the editor opens there.

import AppKit
import WebKit

@main
enum EditorPlaceTest {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("OK   \(name)")
        } else {
            failures += 1
            print("FAIL \(name)  \(detail())")
        }
    }

    static let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("imark-editor-place-\(UUID().uuidString)")

    /// Lets the run loop turn: the web view and the answers coming back from
    /// the page all arrive on the main queue.
    static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The page is served from the executable's own resources, which for the
    /// app is its Resources folder and for this test is wherever swiftc put it.
    /// So the renderer goes there first — built, as the other web-view suites
    /// expect, by `(cd renderer && node build.mjs)`.
    static func stageRenderer() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let built = repo.appendingPathComponent("Resources")
        guard let beside = Bundle.main.resourceURL else { return }
        for name in ["index.html", "bundle.js", "bundle.css"] {
            let target = beside.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: built.appendingPathComponent(name), to: target)
        }
    }

    static func main() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try stageRenderer()
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        try theEditorOpensWhereThePageWas()

        try? FileManager.default.removeItem(at: folder)
        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }

    /// The document, and the lines of it the cases scroll to, counted from zero
    /// the way the page counts them.
    struct Fixture {
        var lines: [String] = []
        var headings: [Int: Int] = [:]
        var paragraphs: [Int: Int] = [:]
        var tableRow = 0

        init() {
            // Front matter first: the page parses the body without it, and its
            // lines still count in the file.
            lines += ["---", "title: A long document", "tags: [one, two]", "---", "# A long document", ""]
            for section in 0..<24 {
                headings[section] = lines.count
                lines += ["## Section \(section)", ""]
                for paragraph in 0..<4 {
                    if paragraph == 2 { paragraphs[section] = lines.count }
                    // One paragraph on the page, written over four lines of the file.
                    lines += [
                        "Paragraph \(section).\(paragraph) begins on this line of the file",
                        "and goes on over a second one, the way prose is often wrapped",
                        "by hand in a text editor, so that one block on the page is",
                        "several lines in the source, and this is the fourth of them.",
                        "",
                    ]
                }
                if section == 14 {
                    lines += ["| Column | Other |", "|---|---|"]
                    for row in 0..<12 {
                        if row == 7 { tableRow = lines.count }
                        lines.append("| row \(row) | value \(row) |")
                    }
                    lines.append("")
                }
            }
        }
    }

    static func theEditorOpensWhereThePageWas() throws {
        print("▸ the editor opens on the line the page was showing")
        let fixture = Fixture()
        let url = folder.appendingPathComponent("long.md")
        try fixture.lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let window = DocumentWindowController(url: url)
        window.window?.setFrameOrigin(NSPoint(x: -6_000, y: 0))
        window.showWindow(nil)
        spin(1.5)

        guard let page = window.content.renderer.subviews.compactMap({ $0 as? WKWebView }).first else {
            return check("the renderer has a web view", false)
        }

        /// Runs a line of script in the page and waits for what it returns.
        func evaluate(_ script: String) -> Any? {
            var result: Any?
            var done = false
            page.evaluateJavaScript(script) { value, _ in
                result = value
                done = true
            }
            let deadline = Date().addingTimeInterval(5)
            while !done, Date() < deadline { spin(0.02) }
            return result
        }

        /// Scrolls the page so the top of the view, under the toolbar, is `share`
        /// of the way into the block that starts on `line` — or, with `gap`, half
        /// way between its end and whatever comes next. Returns whether the
        /// block is really there afterwards, so a case cannot pass on a page that
        /// never reached it.
        func scrollPage(toLine line: Int, share: Double = 0, gap: Bool = false) -> Bool {
            let script = """
            (() => {
              const inset = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--top-inset')) || 0
              const block = document.querySelector('#content [data-line^="\(line),"]')
              if (!block) return false
              const at = () => {
                const box = block.getBoundingClientRect()
                if (!\(gap)) return box.top + \(share) * box.height
                const next = block.nextElementSibling.getBoundingClientRect().top
                return (box.bottom + next) / 2
              }
              window.scrollBy(0, at() - inset)
              return Math.abs(at() - inset) < 1
            })()
            """
            return (evaluate(script) as? Bool) ?? false
        }

        func buffer() -> NSTextView? {
            func find(_ view: NSView) -> NSTextView? {
                if let text = view as? NSTextView, text.isEditable { return text }
                for child in view.subviews { if let hit = find(child) { return hit } }
                return nil
            }
            return window.window?.contentView.flatMap(find)
        }

        /// The line at the top of the editor, numbered as the gutter numbers it.
        func editorTop() -> Int {
            guard let view = buffer(), let layout = view.layoutManager, let container = view.textContainer
            else { return -1 }
            let y = max(0, view.visibleRect.minY - view.textContainerOrigin.y + 1)
            let glyph = layout.glyphIndex(for: NSPoint(x: 1, y: y), in: container)
            let character = layout.characterIndexForGlyph(at: glyph)
            return LineGutter.lineNumber(at: character, in: view.string as NSString)
        }

        /// The line the caret is on, and whether it is at the start of it.
        func caret() -> (line: Int, atStart: Bool) {
            guard let view = buffer() else { return (-1, false) }
            let source = view.string as NSString
            let location = view.selectedRange().location
            let start = source.lineRange(for: NSRange(location: location, length: 0)).location
            return (LineGutter.lineNumber(at: location, in: source), start == location)
        }

        func enter() {
            window.toggleEditMode(nil)
            spin(0.5)
        }

        func leave() {
            window.toggleEditMode(nil)
            spin(0.8)
        }

        // 1. At the top of the document the editor opens at the top, as before.
        _ = evaluate("window.scrollTo(0, 0)")
        spin(0.3)
        enter()
        check("the editor is open", window.editMode && buffer() != nil)
        check("from the top of the page, the first line", editorTop() == 1, "\(editorTop())")
        check("with the caret on it", caret().line == 1 && caret().atStart, "\(caret())")
        leave()

        // 2. A heading far down, where the outline puts it: just under the
        //    toolbar. The front matter above is counted.
        let heading = fixture.headings[9]!
        check("the page reached section 9", scrollPage(toLine: heading))
        spin(0.3)
        enter()
        check("the heading is at the top of the editor", editorTop() == heading + 1,
              "line \(editorTop()), expected \(heading + 1)")
        check("with the caret at its start", caret().line == heading + 1 && caret().atStart, "\(caret())")
        leave()

        // 3. Part way into a paragraph written over four lines of the file: the
        //    line at about the same height, not the first of the four. Asked
        //    again, too: the place is not the one from the last time.
        let paragraph = fixture.paragraphs[11]!
        check("the page reached the paragraph", scrollPage(toLine: paragraph, share: 0.6))
        spin(0.3)
        enter()
        check("the third of its four lines is at the top", editorTop() == paragraph + 3,
              "line \(editorTop()), expected \(paragraph + 3)")
        leave()

        // 4. In the gap between two paragraphs: the line after the first one.
        check("the page reached the gap", scrollPage(toLine: paragraph, gap: true))
        spin(0.3)
        enter()
        check("the line after the paragraph is at the top", editorTop() == paragraph + 5,
              "line \(editorTop()), expected \(paragraph + 5)")
        leave()

        // 5. A row of a table: that row, not the top of the table.
        let row = fixture.tableRow
        check("the page reached the table row", scrollPage(toLine: row))
        spin(0.3)
        enter()
        check("the row is at the top of the editor", editorTop() == row + 1,
              "line \(editorTop()), expected \(row + 1)")

        // 6. The first keystroke goes into the line on screen. With the caret
        //    left on the first line, typing scrolled the buffer back up to it.
        guard let view = buffer() else { return check("found the buffer", false) }
        view.insertText("Typed ", replacementRange: view.selectedRange())
        spin(0.3)
        let source = view.string as NSString
        let typedLine = source.substring(with: source.lineRange(for: NSRange(location: view.selectedRange().location, length: 0)))
        check("the typing landed on the row", typedLine.hasPrefix("Typed | row 7 |"), typedLine)
        check("and the editor did not move", editorTop() == row + 1, "line \(editorTop())")
        window.content.editor.undo()
        spin(0.2)
        check("nothing is left unsaved", !window.content.editor.isDirty)

        window.close()
        spin(0.3)
    }
}
