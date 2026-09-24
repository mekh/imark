#!/usr/bin/env swift
//
// Mermaid diagrams drawn once and put back, in a real web view, off screen.
//
//   swift Support/test-diagrams.swift
//
// Every render drew every diagram again. Mermaid is by far the slowest part of
// a render, so a step Back to a long document with eight small diagrams took
// more than two seconds, a second and a half of it on diagrams nobody had
// changed — and so did every save of a file being followed, and every change
// in Settings, which sends the palette again.
//
// A drawing that is put back keeps the id mermaid gave it, which is how this
// tells a diagram put back from one drawn again.
//
// A drawing kept the width mermaid gave it while ⌘+ grew the text around it,
// and one wider than the column was squeezed into it at every text size, its
// labels too small to read.
//
// Diagrams were drawn in document order, the one in front of the reader after
// every one above it, and each drawing that landed above the reader pushed the
// page down under them.

import AppKit
import WebKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = repo.appendingPathComponent("Resources")

// The page is served over `imark://` in the app and its CSP says so, which a
// file:// load cannot satisfy. A copy without the policy is the whole of the
// difference between this harness and the real thing.
let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imark-test-diagrams")
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
window.webkit = { messageHandlers: { imark: { postMessage: () => {} } } }

const diagram = (label) => ['```mermaid', 'flowchart LR', `  A[${label}] --> B[End]`, '```'].join('\\n')
const doc = (...parts) => ['# Diagrams', '', ...parts.flatMap((part) => [part, ''])].join('\\n')
const render = (markdown, theme = 'dark') => window.imark.render({ markdown, path: '/tmp/t.md', theme })

const ids = () => [...document.querySelectorAll('.mermaid-block svg')].map((svg) => svg.id)
// The palette a drawing was made in shows in the colours written into it.
const inPalette = () => {
  const colour = getComputedStyle(document.documentElement).getPropertyValue('--code-bg').trim().toLowerCase()
  const svgs = [...document.querySelectorAll('.mermaid-block svg')]
  return !!colour && svgs.length > 0 && svgs.every((svg) => svg.outerHTML.toLowerCase().includes(colour))
}
// setTheme does not wait for its diagrams, and the old drawings stay up until
// the new ones replace them, so this waits for the colours to come through.
const settled = async () => {
  for (let i = 0; i < 100 && !inPalette(); i += 1) await new Promise((r) => setTimeout(r, 50))
}

const results = {}
const TWO = doc(diagram('Start'), diagram('Other'))

// 1. A document with two diagrams draws both.
await render(TWO)
const first = ids()
results.bothDiagramsAreDrawn = first.length === 2 && first.every(Boolean)
results.drawnInTheCurrentPalette = inPalette()

// 2. The same document again — Back, a second visit, a reload after a save
//    somewhere else in the file — puts the same drawings back.
await render(TWO)
results.anUnchangedDocumentIsNotDrawnAgain = JSON.stringify(ids()) === JSON.stringify(first)

// 3. And puts them back before the render has let go of the page once, so the
//    page is laid out with them in it rather than again when they arrive.
const pending = render(TWO)
results.drawingsArePutBackAtOnce = ids().length === 2
await pending

// 4. A diagram that changed is drawn again; the one beside it is not.
await render(doc(diagram('Start'), diagram('Changed')))
const changed = ids()
results.aChangedDiagramIsDrawnAgain = changed[1] !== first[1]
results.itsNeighbourIsNot = changed[0] === first[0]

// 5. Another palette is another drawing, and in its own colours.
await render(TWO)
window.imark.setTheme('light')
await settled()
const light = ids()
results.anotherPaletteIsDrawnAgain = light[0] !== first[0]
results.drawnInTheNewPalette = inPalette()

// 6. And the first palette brings back the first drawings.
window.imark.setTheme('dark')
await settled()
results.theFirstPaletteBringsBackTheFirstDrawings = JSON.stringify(ids()) === JSON.stringify(first)

// 7. Every change in Settings sends the palette again, the one already on the
//    page — a step of the text size, say — and that draws nothing. Nor does it
//    put the same drawings back in: that made WebKit lay out the whole page.
const shown = [...document.querySelectorAll('.mermaid-block svg')]
window.imark.setTheme('dark')
await new Promise((r) => setTimeout(r, 1000))
results.theSamePaletteAgainDrawsNothing = JSON.stringify(ids()) === JSON.stringify(first)
const still = [...document.querySelectorAll('.mermaid-block svg')]
results.theSamePaletteAgainLeavesThePageAlone = still.length === shown.length && still.every((svg, i) => svg === shown[i])

// 8. The same diagram twice in one document is two drawings, never one id
//    twice: an SVG styles itself by its id.
await render(doc(diagram('Start'), diagram('Start')))
const twice = ids()
results.aDiagramTwiceHasTwoIds = twice.length === 2 && twice[0] !== twice[1]

// 9. A palette that changes while diagrams are being drawn does not leave any
//    of them behind in the wrong colours for the next time. Mermaid's settings
//    are global: the diagram after the change was drawn in the new palette by
//    the old drawing, and kept under the old one.
const racing = render(doc(diagram('Racing'), diagram('Behind')))
window.imark.setTheme('light')
await racing
await settled()
window.imark.setTheme('dark')
await settled()
results.aDrawingCaughtByAPaletteChangeIsNotKept = inPalette()

// 10. A drawing grows and shrinks with the text size, by as much as the text
//     does, and is not drawn again for it: it is a vector.
window.imark.setTextScale(16)
await render(TWO)
const svg = document.querySelector('.mermaid-block svg')
const drawnWidth = svg.viewBox.baseVal.width
const width = () => svg.getBoundingClientRect().width
results.atTheDefaultSizeADiagramIsAsWideAsItWasDrawn = Math.abs(width() - drawnWidth) < 1
window.imark.setTextScale(24)
results.aDiagramGrowsWithTheText = Math.abs(width() - drawnWidth * 1.5) < 1
window.imark.setTextScale(12)
results.aDiagramShrinksWithTheText = Math.abs(width() - drawnWidth * 0.75) < 1
results.aDiagramIsNotDrawnAgainForTheTextSize = document.querySelector('.mermaid-block svg') === svg
window.imark.setTextScale(16)

// 11. A diagram wider than the column fits it at the default size, and past
//     that grows with the text as well, scrolling sideways in its block like a
//     table rather than staying squeezed into the column.
const steps = Array.from({ length: 16 }, (_, i) => `  S${i}[A step with a long label] --> S${i + 1}[A step with a long label]`)
window.imark.setWidth('full')
await render(doc(['```mermaid', 'flowchart LR', ...steps, '```'].join('\\n')))
const wide = document.querySelector('.mermaid-block svg')
const block = wide.parentElement
const fitted = wide.getBoundingClientRect().width
results.aWideDiagramFitsTheColumn = wide.viewBox.baseVal.width > block.clientWidth && Math.abs(fitted - block.clientWidth) < 1
window.imark.setTextScale(24)
results.aWideDiagramGrowsWithTheText = Math.abs(wide.getBoundingClientRect().width - fitted * 1.5) < 1
results.andScrollsSidewaysInItsBlock = block.scrollWidth > block.clientWidth + 1
window.imark.setTextScale(16)
window.imark.setWidth('normal')
const filler = (count) =>
  Array.from({ length: count }, (_, i) => `Paragraph ${i}. ${'Words to fill the page with. '.repeat(12)}`).join('\\n\\n')

// 12. The diagram in front of the reader is drawn before the ones above it: in
//     document order a change of theme repainted the one being looked at last.
await render(doc(diagram('Far above'), filler(60), diagram('Just above'), filler(60), diagram('In view'), filler(30)))
const blocks = [...document.querySelectorAll('.mermaid-block')]
blocks[2].scrollIntoView({ block: 'center' })
const order = []
const watching = new MutationObserver((records) => {
  for (const record of records) {
    const index = blocks.indexOf(record.target)
    if (!order.includes(index)) order.push(index)
  }
})
for (const block of blocks) watching.observe(block, { childList: true })
window.imark.setTheme('light')
await settled()
watching.disconnect()
results.theDiagramInViewIsDrawnFirst = order[0] === 2
results.thenTheNearestOfTheRest = JSON.stringify(order) === '[2,1,0]'
window.imark.setTheme('dark')
await settled()

// 13. What the reader is looking at stays put when a drawing lands above it.
//     A reader who scrolls on while a document's diagrams are still being
//     drawn had each one push the page down under them as it arrived.
window.scrollTo(0, 0)
const arriving = render(doc(diagram('Arriving above'), filler(60)))
const reading = [...document.querySelectorAll('#content p')].find((p) => p.textContent.startsWith('Paragraph 30.'))
window.scrollTo(0, window.scrollY + reading.getBoundingClientRect().top)
const readingAt = reading.getBoundingClientRect().top
let movedBy = null
const landing = new MutationObserver(() => {
  movedBy = reading.getBoundingClientRect().top - readingAt
})
landing.observe(document.querySelector('.mermaid-block'), { childList: true })
await arriving
landing.disconnect()
results.aDrawingAboveTheReaderIsDrawn = document.querySelector('.mermaid-block svg') !== null
results.andWhatTheyAreReadingStaysPut = movedBy !== null && Math.abs(movedBy) < 1

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
