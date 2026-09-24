#!/usr/bin/env swift
//
// A diagram opened over the page to be looked at closer, in a real web view,
// off screen.
//
//   swift Support/test-diagram-viewer.swift
//
// A diagram could only be read at the size the column gave it, and one wider
// than the column was squeezed into it, its labels too small to read at any
// text size. A click now opens it over the page, where it can be zoomed and
// panned, and Escape puts it back.
//
// The viewer holds the drawing itself, not a copy: an SVG styles itself by its
// own id, and a copy would put the same id in the document twice.

import AppKit
import WebKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = repo.appendingPathComponent("Resources")

// The page is served over `imark://` in the app and its CSP says so, which a
// file:// load cannot satisfy. A copy without the policy is the whole of the
// difference between this harness and the real thing.
let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imark-test-diagram-viewer")
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

let SCRIPT = """
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
window.webkit = { messageHandlers: { imark: { postMessage: () => {} } } }

const words = 'Words that fill the page above and below the diagram. '.repeat(8)
const fence = (label) => ['```mermaid', 'flowchart LR', `  A[${label}] --> B[End]`, '```'].join('\\n')
const doc = (label) => ['# A diagram', words, words, fence(label),
  ...Array.from({ length: 30 }, (_, i) => `Paragraph ${i}. ${words}`)].join('\\n\\n')
const render = (markdown) => window.imark.render({ markdown, path: '/tmp/t.md', theme: 'dark' })

const click = (element) => element.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }))
const press = (key, extra = {}) => {
  const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...extra })
  document.activeElement.dispatchEvent(event)
  return event
}
const viewer = () => document.querySelector('.diagram-viewer')
const width = (element) => element.getBoundingClientRect().width

const results = {}

await render(doc('Start'))
window.scrollTo(0, 120)
await sleep(100)
const block = document.querySelector('.mermaid-block')
const svg = block.querySelector('svg')
const style = svg.getAttribute('style')
const blockHeight = block.getBoundingClientRect().height
const scrolled = window.scrollY
const drawn = svg.viewBox.baseVal.width

// 1. A click on a diagram opens it over the page: the drawing itself, so its
//    id is still in the document once.
click(svg.querySelector('g') ?? svg)
results.aClickOpensTheDiagram = !!viewer() && viewer().contains(svg)
results.itIsTheDrawingItselfNotACopy = document.querySelectorAll(`[id="${svg.id}"]`).length === 1

// 2. The page under it stays where it was: the block keeps the drawing's room.
results.thePageUnderItStaysPut =
  Math.abs(block.getBoundingClientRect().height - blockHeight) < 1 && window.scrollY === scrolled

// 3. A small diagram opens at twice its size, not blown up to fill the window.
results.aSmallDiagramOpensAtTwiceItsSize = Math.abs(width(svg) - drawn * 2) < 1

// 4. + and − zoom in and out. ⌘+ does too, and is taken, so the text size
//    behind the viewer is left alone.
const opened = width(svg)
press('+')
results.plusZoomsIn = Math.abs(width(svg) - opened * 1.25) < 1
press('-')
results.minusZoomsOut = Math.abs(width(svg) - opened) < 1
const commandPlus = press('=', { metaKey: true })
results.commandPlusZoomsTheDiagram = commandPlus.defaultPrevented && Math.abs(width(svg) - opened * 1.25) < 1

// 5. 0 fits the whole diagram in the window.
press('0')
const fitted = svg.getBoundingClientRect()
results.zeroFitsItInTheWindow = fitted.width > opened * 1.25 &&
  fitted.left >= 0 && fitted.top >= 0 && fitted.right <= window.innerWidth && fitted.bottom <= window.innerHeight

// 6. The buttons do the same.
viewer()?.querySelector('[data-action="actual"]').click()
results.theActualSizeButtonShowsItAsDrawn = Math.abs(width(svg) - drawn) < 1
viewer()?.querySelector('[data-action="in"]').click()
results.theZoomInButtonZoomsIn = Math.abs(width(svg) - drawn * 1.25) < 1

// 7. A click on the diagram leaves it open; a click beside it closes it, and
//    the drawing is back in its block as it was.
click(svg)
results.aClickOnTheDiagramLeavesItOpen = !!viewer()
if (viewer()) click(viewer())
results.aClickBesideItClosesIt = !viewer()
results.theDrawingIsBackAsItWas = block.contains(svg) && svg.getAttribute('style') === style &&
  block.style.height === '' && Math.abs(block.getBoundingClientRect().height - blockHeight) < 1

// 8. Escape closes it, and so does the close button.
click(svg)
press('Escape')
results.escapeClosesIt = !viewer() && block.contains(svg)
click(svg)
viewer()?.querySelector('[data-action="close"]').click()
results.theCloseButtonClosesIt = !viewer() && block.contains(svg)

// 9. A scroll over the viewer is the viewer's and never the page's, whether
//    the diagram fits in the window or not: WebKit passed one the viewer had
//    no room for on to the page behind it.
const wheel = (target, deltaY, deltaX = 0) => {
  const event = new WheelEvent('wheel', { deltaX, deltaY, bubbles: true, cancelable: true })
  target.dispatchEvent(event)
  return event
}
click(svg)
const pageAt = window.scrollY
results.aScrollOverADiagramThatFitsIsTaken = wheel(svg, 200).defaultPrevented && window.scrollY === pageAt
// Zoomed in, the diagram, which runs across, is wider than the window.
for (let i = 0; i < 6; i += 1) press('+')
const view = viewer()
view.scrollLeft = 0
const scrolledBy = wheel(svg, 0, 100)
results.aScrollOverABigDiagramScrollsTheViewer = scrolledBy.defaultPrevented && view.scrollLeft === 100
view.scrollLeft = view.scrollWidth
results.aScrollPastItsEndIsTakenToo = wheel(view, 100, 100).defaultPrevented && window.scrollY === pageAt
results.soAreTheKeysThatScroll = ['ArrowDown', 'PageDown', ' ', 'End'].every((key) => press(key).defaultPrevented)
press('Escape')

// 10. Words picked out of a label are a selection, and open nothing.
const label = [...svg.querySelectorAll('span, text')].find((node) => node.textContent.includes('Start'))
const range = document.createRange()
range.selectNodeContents(label)
window.getSelection().removeAllRanges()
window.getSelection().addRange(range)
click(label)
results.aSelectionInALabelOpensNothing = !viewer()
window.getSelection().removeAllRanges()

// 11. A render — the file saved, another document — closes it first.
click(svg)
const rendering = render(doc('Saved'))
results.aRenderClosesIt = !viewer()
await rendering

// 12. The diagram drawn again while it is open, in another palette, is not
//     joined by the old drawing when it closes: that would be the same
//     diagram twice.
const again = document.querySelector('.mermaid-block')
const old = again.querySelector('svg')
click(old)
window.imark.setTheme('light')
for (let i = 0; i < 100 && !again.querySelector('svg'); i += 1) await sleep(50)
press('Escape')
results.aDiagramDrawnAgainWhileOpenIsNotDoubled =
  !viewer() && again.querySelectorAll('svg').length === 1 && !again.contains(old)

// 13. Quick Look opens nothing: the panel has no room for it.
window.imark.setPreview(true)
click(again.querySelector('svg'))
results.quickLookOpensNothing = !viewer()

return JSON.stringify(results)
"""

final class Harness: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_400, height: 1_000))
    private var window: NSWindow?

    func run() {
        webView.navigationDelegate = self
        // Mermaid measures its labels, which needs a page that is laid out.
        // Parked off screen, as in test-plus.swift.
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
            webView.callAsyncJavaScript(SCRIPT, in: nil, in: .page) { result in
                switch result {
                case .failure(let error):
                    FileHandle.standardError.write(Data("js failed: \(error)\n".utf8))
                    exit(1)
                case .success(let value):
                    report(String(describing: value))
                }
            }
        }
    }
}

func report(_ json: String) {
    guard let data = json.data(using: .utf8),
          let checks = try? JSONSerialization.jsonObject(with: data) as? [String: Bool]
    else {
        FileHandle.standardError.write(Data("unreadable response: \(json)\n".utf8))
        exit(1)
    }
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
