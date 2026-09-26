#!/usr/bin/env swift
//
// How a table shares its width between its columns, in a real web view, off
// screen.
//
//   swift Support/test-tables.swift
//
// WebKit gives each column a share in proportion to its longest line, so a
// column of paragraphs took nearly all of the width. Beside it `V-1` broke at
// the hyphen, a label of four words took four lines, and the paragraphs ran to
// 120 characters a line at the Wide column. The page now shares the width out
// itself: short columns keep their text on one line, long ones split the rest
// evenly, and none is wider than a comfortable line.

import AppKit
import WebKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = repo.appendingPathComponent("Resources")

// The page is served over `imark://` in the app and its CSP says so, which a
// file:// load cannot satisfy. A copy without the policy is the whole of the
// difference between this harness and the real thing.
let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imark-test-tables")
try? FileManager.default.removeItem(at: stage)
try! FileManager.default.copyItem(at: resources, to: stage)
let page = stage.appendingPathComponent("index.html")
var html = try! String(contentsOf: page, encoding: .utf8)
html = html.replacingOccurrences(
    of: #"<meta[^>]*Content-Security-Policy[^>]*>"#,
    with: "",
    options: [.regularExpression, .caseInsensitive]
)
// And the bundle is asked for by scheme, which only the app's handler answers.
html = html.replacingOccurrences(of: "imark://app/", with: "")
try! html.write(to: page, atomically: true, encoding: .utf8)

// An image a column has to make room for.
let badge = stage.appendingPathComponent("badge.png")
let picture = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
try! picture.representation(using: .png, properties: [:])!.write(to: badge)

// Shared by every script: what a table looks like from the outside.
let HELPERS = """
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const tables = () => [...document.querySelectorAll('#content table')]
const table = (n) => tables()[n]
const column = (t, i) => [...t.rows].map((row) => row.cells[i])
const width = (element) => element.getBoundingClientRect().width
const font = (t) => parseFloat(getComputedStyle(t).fontSize)
// Lines of text in a cell, from the height of its words.
const lines = (cell) => {
  const range = document.createRange()
  range.selectNodeContents(cell)
  return Math.round(range.getBoundingClientRect().height / parseFloat(getComputedStyle(cell).lineHeight))
}
const oneLine = (cells) => cells.every((cell) => lines(cell) === 1)
const room = (t) => width(t.parentElement)
// About 75 characters of the table's own text, and a pixel for rounding.
const comfortable = (t, i) => width(t.rows[0].cells[i]) <= 36 * font(t) + 1
const sized = (t) => [...t.rows[0].cells].some((cell) => cell.style.getPropertyValue('--column-width'))
"""

let SCRIPT = HELPERS + "\n" + """
window.webkit = { messageHandlers: { imark: { postMessage: () => {} } } }

const paragraph = (n) =>
  'Words that make up a long paragraph, the kind a table carries in its last column. '.repeat(n).trim()
const medium = 'period, document, heads, balances'

// Read from disk, so it arrives after the first layout the way an image in a
// document does.
const image = '\(badge.absoluteString)'

const DOC = [
  '# Tables', '',
  // 0: ids and a label beside a column of paragraphs.
  '| # | Vector | What closes it |', '|---|---|---|',
  `| V-1 | Stolen credentials without MFA | ${paragraph(4)} |`,
  `| V-2 | Broken access control in the API | ${paragraph(3)} |`,
  `| V-10 | A short one | ${paragraph(2)} |`, '',
  // 1: two columns of paragraphs.
  '| Case | Before | After |', '|---|---|---|',
  `| C-1 | ${paragraph(3)} | ${paragraph(3)} |`,
  `| C-2 | ${paragraph(2)} | ${paragraph(4)} |`, '',
  // 2: a table that fits.
  '| Name | Value |', '|---|---|', '| alpha | 1 |', '| beta | 2 |', '',
  // 3: one long column beside a label.
  '| Axis | Position |', '|---|---|',
  `| Time to value | ${paragraph(3)} |`, `| Traceability | ${paragraph(2)} |`, '',
  // 4: more columns than a narrow window has room for.
  `| # | ${Array.from({ length: 8 }, (_, i) => `Step ${i}`).join(' | ')} |`,
  `|---|${'---|'.repeat(8)}`,
  ...Array.from({ length: 3 }, (_, r) => `| UW-0${r} | ${Array(8).fill(medium).join(' | ')} |`), '',
  // 5: spans, left to WebKit.
  '<table><tr><td colspan="2">across both</td></tr><tr><td>a</td><td>b</td></tr></table>', '',
  // 6: inside a list item.
  '- An item with a table in it', '',
  '  | # | Text |', '  |---|---|', `  | V-1 | ${paragraph(3)} |`, '',
  // 7: an image that arrives late.
  '| Badge | Note |', '|---|---|', `| <img src="${image}" alt="b"> | ${paragraph(3)} |`, '',
  // 8: a note on the last row.
  '| # | Text |', '|---|---|', `| N-1 | ${paragraph(3)} |`, `| N-2 | ${paragraph(3)} |`, `| N-3 | ${paragraph(3)} |`, '',
  '<!-- imark quote="N-3" nth="1" by="miguel" at="2026-09-26T10:00Z"', 'The last row.', '-->', '',
  // 9: math, set in fonts that arrive after the first layout.
  '| Formula | Note |', '|---|---|',
  `| $\\\\sum_{i=1}^{n} x_i^2 + \\\\int_0^1 f(x)\\\\,dx$ | ${paragraph(3)} |`, '',
].join('\\n')

document.documentElement.dataset.width = 'wide'
await window.imark.render({ markdown: DOC, path: '/tmp/t.md', theme: 'dark' })
await sleep(300)

const results = {}
const [ids, pair, small, label, crowded, spans, listed, pictured, noted, math] = tables()

// 1. Short text stays on one line beside a column of paragraphs.
results.idsStayOnOneLine = oneLine(column(ids, 0))
results.labelsStayOnOneLine = oneLine(column(ids, 1))
// 2. The paragraphs wrap at a comfortable length.
results.paragraphsWrapAtAComfortableLength = comfortable(ids, 2)
// 3. WebKit keeps to the widths it is given.
results.theWidthsAreKept = [...ids.rows[0].cells].every(
  (cell) => Math.abs(width(cell) - parseFloat(cell.style.getPropertyValue('--column-width'))) < 1,
)
// 4. Two columns of paragraphs split the room evenly.
results.longColumnsShareEvenly =
  Math.abs(width(pair.rows[0].cells[1]) - width(pair.rows[0].cells[2])) < 1 && oneLine(column(pair, 0))
// 5. A table whose columns all fit on one line is left as WebKit lays it out.
results.aTableThatFitsIsLeftAlone = !sized(small) && oneLine([...small.querySelectorAll('td')])
// 6. Spans are left to WebKit too.
results.spansAreLeftAlone = !sized(spans)
// 7. A table inside a list item keeps to the item.
results.aTableInAListKeepsToTheItem =
  listed.getBoundingClientRect().right <= listed.parentElement.getBoundingClientRect().right + 0.5 &&
  oneLine(column(listed, 0))
// 8. An image that arrives late gets its room, rather than being shrunk into
//    the column measured before it came.
const badge = pictured.querySelector('img')
results.aLateImageGetsItsRoom =
  badge.complete && Math.abs(width(badge) - badge.naturalWidth) < 1 && pictured.scrollWidth <= pictured.clientWidth + 1
// 9. So does math, once its fonts are in.
await document.fonts.ready
await sleep(100)
const formula = math.querySelector('.katex')
results.mathGetsItsRoom =
  !!formula && oneLine(column(math, 0)) && math.scrollWidth <= math.clientWidth + 1 &&
  width(formula) <= width(math.rows[1].cells[0])
// 10. A note's dot sits beside the row it is about, measured after the widths.
const dot = document.querySelector('.note-dot')
const lastRow = noted.rows[noted.rows.length - 1]
results.aNoteSitsBesideItsRow =
  !!dot && Math.abs(dot.getBoundingClientRect().top - lastRow.getBoundingClientRect().top) < 8

// 11. With the whole window, one long column stops short of it rather than
//     running on.
window.imark.setWidth('full')
results.oneLongColumnStopsShort = comfortable(label, 1) && width(label) < room(label) - 100
results.paragraphsStayComfortableAtFullWidth = comfortable(ids, 2) && comfortable(pair, 1)

// 12. A narrow column reshares, and a table with no room for its short text
//     scrolls sideways rather than breaking it.
window.imark.setWidth('narrow')
results.aNarrowColumnReshares = width(ids) <= room(ids) + 0.5 && oneLine(column(ids, 0))
results.aCrowdedTableScrolls = crowded.scrollWidth > crowded.clientWidth + 1
results.aCrowdedTableKeepsItsIdsWhole = oneLine(column(crowded, 0))
// Scrolling anyway, it gives each column room for a few words rather than one.
const words = (cell) => cell.textContent.trim().split(/\\s+/).length
results.aCrowdedTableKeepsAFewWordsToALine = column(crowded, 1).slice(1).every((cell) => lines(cell) < words(cell))

// 13. A bigger text size is measured again.
window.imark.setTextScale(24)
results.biggerTextIsMeasuredAgain =
  oneLine(column(ids, 0)) && width(ids) <= room(ids) + 0.5 && comfortable(ids, 2)
window.imark.setTextScale(16)
window.imark.setWidth('normal')

// 14. Every window is sent every setting on any change in Settings. The ones
//     that did not change write nothing into the page.
let writes = 0
const watcher = new MutationObserver((records) => { writes += records.length })
watcher.observe(document.getElementById('content'), { attributes: true, subtree: true, childList: true })
window.imark.setTextScale(16)
window.imark.setWidth('normal')
await sleep(50)
watcher.disconnect()
results.anUnchangedSettingWritesNothing = writes === 0

return JSON.stringify(results)
"""

// After the window is made narrower, with nothing in the page asked to do it.
let AFTER_RESIZE = HELPERS + "\n" + """
await sleep(300)
const [ids] = tables()
return JSON.stringify({
  aNarrowerWindowReshares: ids.scrollWidth <= ids.clientWidth + 1 && oneLine(column(ids, 0)),
})
"""

// Paper is not as wide as the window the widths were worked out for, so the
// page is printed as WebKit lays it out.
let IN_PRINT = HELPERS + "\n" + """
const [ids] = tables()
const first = ids.rows[0].cells[0]
return JSON.stringify({
  theWidthsAreForTheScreenOnly: sized(ids) && getComputedStyle(first).minWidth !== first.style.getPropertyValue('--column-width'),
})
"""

final class Harness: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_400, height: 1_000))
    private var window: NSWindow?
    private var results: [String: Bool] = [:]

    func run() {
        webView.navigationDelegate = self
        // Parked off screen, as in test-plus.swift: a page with no window is
        // never laid out the way one in a window is.
        let window = NSWindow(
            contentRect: NSRect(x: -6_000, y: 0, width: 1_400, height: 1_000),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        self.window = window
        webView.loadFileURL(page, allowingReadAccessTo: stage)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.evaluate(SCRIPT) {
                // Normal is 80ch, which a 700-point window cannot hold.
                self.window?.setContentSize(NSSize(width: 700, height: 1_000))
                self.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 1_000)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.evaluate(AFTER_RESIZE) {
                        self.webView.mediaType = "print"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.evaluate(IN_PRINT) { report(self.results) }
                        }
                    }
                }
            }
        }
    }

    private func evaluate(_ script: String, then next: @escaping () -> Void) {
        webView.callAsyncJavaScript(script, in: nil, in: .page) { result in
            switch result {
            case .failure(let error):
                FileHandle.standardError.write(Data("js failed: \(error)\n".utf8))
                exit(1)
            case .success(let value):
                guard let data = (value as? String)?.data(using: .utf8),
                      let checks = try? JSONSerialization.jsonObject(with: data) as? [String: Bool]
                else {
                    FileHandle.standardError.write(Data("unreadable response: \(String(describing: value))\n".utf8))
                    exit(1)
                }
                self.results.merge(checks) { $1 }
                next()
            }
        }
    }
}

func report(_ checks: [String: Bool]) {
    var failed = 0
    for key in checks.keys.sorted() {
        let ok = checks[key] == true
        if !ok { failed += 1 }
        print("\(ok ? "OK  " : "FAIL ") \(key)")
    }
    print(failed == 0 ? "\nall good" : "\n\(failed) failing")
    exit(failed == 0 ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let harness = Harness()
harness.run()
app.run()
