// Tests for opening a document where it was being read, through real windows.
//
//   swift build && TEST_BIN="$(swift build --show-bin-path)"
//   mkdir -p /tmp/imark-test-reading-place && swiftc -parse-as-library \
//     -I "$TEST_BIN" -I "$TEST_BIN/Modules" -F "$TEST_BIN" -Xlinker -rpath -Xlinker "$TEST_BIN" \
//     $(find Sources/Imark -name '*.swift' ! -name main.swift) \
//     $(find Sources/ImarkRender -name '*.swift') \
//     Support/test-reading-place.swift -o /tmp/imark-test-reading-place/run \
//     && /tmp/imark-test-reading-place/run
//
// A folder of its own, because the renderer is put beside the executable to be
// served from there.
//
// A document used to open at the top every time, however far down it had been
// read. Now it opens on the block that was under the toolbar when it was put
// down, unless its text has changed since. What is checked is what the reader
// sees: a window closed on a paragraph and a new window on the same file, with
// the page measured, not the list the place is kept in.

import AppKit
import WebKit

@main
enum ReadingPlaceTest {
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
        .appendingPathComponent("imark-reading-place-\(UUID().uuidString)")

    static func fixture(_ text: String, named name: String) -> URL {
        let url = folder.appendingPathComponent(name)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Lets the run loop turn: the web view and the messages coming back from
    /// the page all answer on the main queue.
    static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The page is served from the executable's own resources, which for the
    /// app is its Resources folder and for this test is wherever swiftc put it.
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

    /// Paragraphs of different lengths, so a bigger text size moves each one by
    /// a different amount and an offset in pixels lands somewhere else.
    static let filler = (0..<60).map { index in
        "Paragraph \(index). " + String(repeating: "Some words to read through. ", count: 3 + index % 7 * 4)
    }.joined(separator: "\n\n")

    static func main() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try stageRenderer()
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let textScale = Settings.textScale
        UserDefaults.standard.removeObject(forKey: "readingPlaces")

        theList()
        openingAgain()
        links()
        anImageAbove()
        writingItDown()
        puttingDown()
        // Last, because it ends the process the way the app ends: `finish`
        // runs when the app says it is going.
        quitting(then: {
            Settings.textScale = textScale
            UserDefaults.standard.removeObject(forKey: "readingPlaces")
            try? FileManager.default.removeItem(at: folder)
            print(failures == 0 ? "\nall good" : "\n\(failures) failing")
            exit(failures == 0 ? 0 : 1)
        })
    }

    // MARK: - A document in a window

    /// A window on one document, off screen, and ways to look at its page.
    final class Page {
        let controller: DocumentWindowController
        let web: WKWebView?

        convenience init(_ url: URL) {
            self.init(DocumentWindowController(url: url))
        }

        init(_ controller: DocumentWindowController) {
            self.controller = controller
            controller.window?.setFrameOrigin(NSPoint(x: -6_000, y: 0))
            controller.showWindow(nil)
            web = controller.content.renderer.subviews.compactMap { $0 as? WKWebView }.first
            // The first render, its diagrams and images, and a moment besides.
            spin(1.5)
        }

        /// Runs a line of script in the page and waits for what it returns.
        func evaluate(_ script: String) -> Any? {
            guard let web else { return nil }
            var result: Any?
            var done = false
            web.evaluateJavaScript(script) { value, _ in
                result = value
                done = true
            }
            let deadline = Date().addingTimeInterval(5)
            while !done, Date() < deadline { spin(0.02) }
            return result
        }

        var scrollY: Double { (evaluate("window.scrollY") as? Double) ?? -1 }

        static let inset = "(parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--top-inset')) || 0)"

        /// Scrolls the page so that the `index`th paragraph starts `share` of its
        /// height above the toolbar's edge, and says which lines it came from.
        /// Then waits for the page to tell the window, or, with `telling` off,
        /// goes on at once, as a reader who is still scrolling when the document
        /// is put down.
        ///
        /// The scroll event comes with the next frame, and a window nobody sees
        /// barely gets any, so it is sent here, the way WebKit sends it to a
        /// page on screen.
        func read(paragraph index: Int, at share: Double = 0.4, telling: Bool = true) -> String {
            let lines = evaluate("""
            (() => {
              const el = document.querySelectorAll('#content > p')[\(index)]
              const box = el.getBoundingClientRect()
              window.scrollTo(0, box.top + window.scrollY + \(share) * box.height - \(Self.inset))
              if (\(telling)) window.dispatchEvent(new Event('scroll'))
              return el.getAttribute('data-line')
            })()
            """) as? String ?? "?"
            if telling { waitUntilTold(lines) }
            return lines
        }

        /// Waits for the window to hear that the page is reading these lines,
        /// or is at the top for nil.
        @discardableResult
        func waitUntilTold(_ lines: String?) -> Bool {
            func told() -> Bool {
                guard let reading = controller.reading else { return false }
                return reading.place.map { "\($0.line),\($0.end)" } == lines
            }
            let deadline = Date().addingTimeInterval(15)
            while !told(), Date() < deadline { spin(0.1) }
            check(lines.map { "the page tells it is reading \($0)" } ?? "the page tells it is at the top", told(),
                  String(describing: controller.reading?.place))
            return told()
        }

        /// How many pixels the block from these lines is off the place it was
        /// left at, `share` of its height above the toolbar's edge.
        func miss(_ lines: String, at share: Double = 0.4) -> Double {
            (evaluate("""
            (() => {
              const found = document.querySelectorAll('[data-line="\(lines)"]')
              const el = found[found.length - 1]
              if (!el) return 1e6
              const box = el.getBoundingClientRect()
              return \(Self.inset) - box.top - \(share) * box.height
            })()
            """) as? Double) ?? 1e6
        }

        func close() {
            controller.close()
            spin(0.3)
        }
    }

    static func remembered(_ url: URL) -> Bool {
        written(url) != nil
    }

    /// The lines of the block written down for a document, as the page names them.
    static func written(_ url: URL) -> String? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return ReadingPlaces.entries.first { $0.path == path }.map { "\($0.place.line),\($0.place.end)" }
    }

    // MARK: - The list

    static func theList() {
        print("▸ the list the places are kept in")
        UserDefaults.standard.removeObject(forKey: "readingPlaces")

        let one = ReadingPlace(line: 4, end: 6, share: 0.25)
        let a = URL(fileURLWithPath: "/tmp/reading-a.md")
        ReadingPlaces.remember(one, of: a, digest: "x")
        check("a place comes back for the same text", ReadingPlaces.place(of: a, digest: "x") == one)
        check("and not for different text", ReadingPlaces.place(of: a, digest: "y") == nil)
        ReadingPlaces.remember(nil, of: a, digest: "x")
        check("nil forgets the document", ReadingPlaces.entries.isEmpty, "\(ReadingPlaces.entries.count)")

        for index in 0...ReadingPlaces.kept {
            ReadingPlaces.remember(one, of: URL(fileURLWithPath: "/tmp/reading-\(index).md"), digest: "x")
        }
        let entries = ReadingPlaces.entries
        check("the list stops at \(ReadingPlaces.kept)", entries.count == ReadingPlaces.kept, "\(entries.count)")
        check("the newest first", entries.first?.path == "/tmp/reading-\(ReadingPlaces.kept).md",
              entries.first?.path ?? "none")
        check("the oldest gone", !entries.contains { $0.path == "/tmp/reading-0.md" })

        let digest = ReadingPlaces.digest(of: "# Заголовок\n")
        check("the digest is SHA-256 of the text", digest.count == 64 && digest == ReadingPlaces.digest(of: "# Заголовок\n"),
              digest)
        UserDefaults.standard.removeObject(forKey: "readingPlaces")
    }

    // MARK: - Opening again

    static func openingAgain() {
        print("▸ a document opens where it was put down, while its text is the same")
        let a = fixture("# A\n\n\(filler)\n\n## Кінець\n\nThe end.\n", named: "A.md")

        var page = Page(a)
        check("a document never read opens at the top", page.scrollY == 0, "\(page.scrollY)")
        let lines = page.read(paragraph: 30)
        let leftAt = page.scrollY
        check("the page moved", leftAt > 500, "\(leftAt)")
        page.close()
        check("closing the window writes the place down", remembered(a))

        // 1. The same file in a new window.
        page = Page(a)
        check("it opens on the block it was left at", abs(page.miss(lines)) < 3, "\(page.miss(lines)) px")

        // 2. Reloading keeps the page where it is, not where it was opened.
        _ = page.read(paragraph: 10)
        let before = page.scrollY
        page.controller.reloadDocument(nil)
        spin(1.0)
        check("a reload stays where the page is", abs(page.scrollY - before) < 3, "\(page.scrollY) vs \(before)")
        _ = page.read(paragraph: 30)
        page.close()

        // 3. Another text size: the same block, somewhere else in pixels.
        Settings.textScale = Settings.textScale + 4
        page = Page(a)
        check("a bigger text size still opens on the block", abs(page.miss(lines)) < 3, "\(page.miss(lines)) px")
        check("which is not where the offset was", abs(page.scrollY - leftAt) > 100, "\(page.scrollY) vs \(leftAt)")
        page.close()
        Settings.textScale = Settings.textScale - 4

        // 4. The same bytes written again: a new date, the same document.
        let text = try! String(contentsOf: a, encoding: .utf8)
        spin(1.1)
        try! text.write(to: a, atomically: true, encoding: .utf8)
        page = Page(a)
        check("the same text written again keeps the place", abs(page.miss(lines)) < 3, "\(page.miss(lines)) px")
        page.close()

        // 5. A changed file opens at the top, and forgets the place.
        try! (text + "\nOne more paragraph.\n").write(to: a, atomically: true, encoding: .utf8)
        page = Page(a)
        check("a changed file opens at the top", page.scrollY == 0, "\(page.scrollY)")
        page.close()
        check("and its place is forgotten", !remembered(a))

        // 6. Put down at the top, nothing is kept.
        page = Page(a)
        _ = page.read(paragraph: 30)
        _ = page.evaluate("window.scrollTo(0, 0); window.dispatchEvent(new Event('scroll'))")
        page.waitUntilTold(nil)
        page.close()
        check("a document left at the top is not remembered", !remembered(a))
    }

    // MARK: - Links

    static func links() {
        print("▸ a link to the file opens it where it was read, a link to a heading at the heading")
        let b = fixture("# B\n\n\(filler)\n\n## Розділ\n\n\(filler)\n", named: "B.md")
        let c = fixture("# C\n\n- [B](B.md)\n- [A section of B](B.md#розділ)\n", named: "C.md")

        var page = Page(b)
        let lines = page.read(paragraph: 25)
        page.close()

        page = Page(c)
        _ = page.evaluate("document.querySelector('a[href$=\"B.md\"]').click()")
        spin(1.5)
        check("the link opens the file", page.controller.url == b, page.controller.url.lastPathComponent)
        check("on the block it was left at", abs(page.miss(lines)) < 3, "\(page.miss(lines)) px")
        page.controller.goBackInHistory(nil)
        spin(1.5)
        _ = page.evaluate("document.querySelector('a[href*=\"B.md#\"]').click()")
        spin(1.5)
        let heading = page.evaluate(
            "document.getElementById('розділ').getBoundingClientRect().top - \(Page.inset)"
        ) as? Double ?? -1
        check("a link to a heading lands on the heading", abs(heading - 24) < 3, "\(heading)")
        page.close()
    }

    // MARK: - Images

    static func anImageAbove() {
        print("▸ an image above the place does not push it down once it arrives")
        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 900, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        try! image.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("tall.png"))
        let d = fixture("# D\n\n![tall](tall.png)\n\n\(filler)\n", named: "D.md")

        var page = Page(d)
        let lines = page.read(paragraph: 20)
        page.close()

        page = Page(d)
        let height = page.evaluate("document.querySelector('img').getBoundingClientRect().height") as? Double ?? 0
        check("the image is on the page", height > 800, "\(height)")
        check("the page opens on the block below it", abs(page.miss(lines)) < 3, "\(page.miss(lines)) px")
        page.close()
    }

    // MARK: - When it is written

    static func writingItDown() {
        print("▸ the place is written at most every few seconds while the window is open")
        let e = fixture("# E\n\n\(filler)\n", named: "E.md")

        let page = Page(e)
        // What the first render told is written in its turn, and it is the top.
        spin(5.5)
        check("the top is not written as a place", !remembered(e))

        // The first place told after a write starts the clock.
        _ = page.read(paragraph: 30)
        let told = Date()
        spin(0.5)
        check("the place is not written straight away", !remembered(e))
        while !remembered(e), Date().timeIntervalSince(told) < 10 { spin(0.1) }
        let waited = Date().timeIntervalSince(told)
        check("it is written a few seconds later", remembered(e) && waited > 3.5 && waited < 7, "after \(waited) s")
        page.close()
    }

    // MARK: - Putting a document down

    static func puttingDown() {
        print("▸ a document put down while it is scrolling goes down where the scrolling got to")
        // The page tells its place once the scrolling stops. The PRD scrolled
        // from 11.3.2 through to 12.3 and quit at once opened on 11.3.2 again:
        // nothing had been told since the scrolling started.
        let g = fixture("# G\n\n\(filler)\n", named: "G.md")
        let h = fixture("# H\n\n\(filler)\n", named: "H.md")

        var page = Page(g)
        _ = page.read(paragraph: 20)
        var last = page.read(paragraph: 40, telling: false)
        page.close()
        spin(0.5)
        check("closing the window", written(g) == last, "\(written(g) ?? "nothing") vs \(last)")

        page = Page(g)
        _ = page.read(paragraph: 20)
        last = page.read(paragraph: 45, telling: false)
        page.controller.show(h, pushingHistory: true)
        spin(1)
        check("another document in the window", written(g) == last, "\(written(g) ?? "nothing") vs \(last)")
        page.close()
    }

    // MARK: - Quitting

    /// Quits the way the app quits, through `NSApp.terminate`, and hands over
    /// to `finish` once the app says it is going.
    static func quitting(then finish: @escaping () -> Void) {
        print("▸ quitting waits for the pages to say where they are")
        let f = fixture("# F\n\n\(filler)\n", named: "F.md")
        let k = fixture("# K\n\n\(filler)\n", named: "K.md")

        let delegate = AppDelegate()
        NSApp.delegate = delegate
        func page(for url: URL) -> Page? {
            delegate.open(url)
            let controller = NSApp.windows.lazy
                .compactMap { $0.windowController as? DocumentWindowController }
                .first { $0.url == url }
            return controller.map(Page.init)
        }
        guard let first = page(for: f), let second = page(for: k) else {
            check("the app opens its windows", false)
            return finish()
        }

        _ = first.read(paragraph: 30)
        _ = second.read(paragraph: 30)
        // Both scrolled on, and nothing turns the run loop from here to the
        // quit: whatever is written comes from asking.
        let inFirst = first.read(paragraph: 45, telling: false)
        let inSecond = second.read(paragraph: 50, telling: false)
        // A window closed just before quitting, still waiting for its page's
        // answer: closing the last window is how the app quits most often.
        second.controller.close()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            check("the document still open", written(f) == inFirst, "\(written(f) ?? "nothing") vs \(inFirst)")
            check("and the one closed on the way", written(k) == inSecond, "\(written(k) ?? "nothing") vs \(inSecond)")
            finish()
        }
        NSApp.terminate(nil)
        check("the app quits", false, "terminate returned")
        finish()
    }
}
