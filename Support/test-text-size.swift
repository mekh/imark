#!/usr/bin/env swift
//
// Changing the text size or the column width keeps the reader's place, in a
// real web view, off screen.
//
//   swift Support/test-text-size.swift
//
// The page kept its scroll offset in pixels, and the text moved under it. With
// the text a size bigger every paragraph above the window is taller, so the
// same offset is further up the document: each ⌘+ scrolled the page back, and
// each ⌘− scrolled it on. A narrower or wider column did the same.

import AppKit
import WebKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = repo.appendingPathComponent("Resources")

// The page is served over `imark://` in the app and its CSP says so, which a
// file:// load cannot satisfy. A copy without the policy is the whole of the
// difference between this harness and the real thing.
let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imark-test-text-size")
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

const words = 'Words that wrap onto more than one line at every text size and width. '.repeat(5)
const lines = ['# A long document', '']
for (let i = 0; i < 160; i += 1) {
  if (i % 20 === 0) lines.push(`## Section ${i / 20}`, '')
  lines.push(`Paragraph ${i}. ${words}`, '')
  if (i % 30 === 5) lines.push('- one item', '- and another', '', '| a | b |', '|---|---|', '| 1 | 2 |', '')
}
const DOC = lines.join('\\n')

// The toolbar stands on the top of the page, as it does in a window.
const INSET = 52
window.imark.setTopInset(INSET)
await window.imark.render({ markdown: DOC, path: '/tmp/t.md', theme: 'dark' })
await sleep(300)

const paragraph = [...document.querySelectorAll('#content p')].find((p) => p.textContent.startsWith('Paragraph 100.'))
// How far into the paragraph the view starts, under the toolbar, as a share of
// its height: the line being read, whatever size the lines are.
const share = () => {
  const box = paragraph.getBoundingClientRect()
  return (INSET - box.top) / box.height
}
const onTheSameLine = () => Math.abs(share() - 1 / 3) < 0.05

const results = {}

// A reader a third of the way into a paragraph far down the document.
const box = paragraph.getBoundingClientRect()
window.scrollBy(0, box.top - INSET + box.height / 3)
await sleep(100)
results.theReaderStartsAThirdIn = onTheSameLine()

// 1. ⌘+ and ⌘− leave them on the same line.
window.imark.setTextScale(20)
await sleep(100)
results.biggerTextKeepsThePlace = onTheSameLine()
window.imark.setTextScale(13)
await sleep(100)
results.smallerTextKeepsThePlace = onTheSameLine()

// 2. So does another column width, which wraps every paragraph differently.
window.imark.setWidth('narrow')
await sleep(100)
results.aNarrowerColumnKeepsThePlace = onTheSameLine()
window.imark.setWidth('full')
await sleep(100)
results.aWiderColumnKeepsThePlace = onTheSameLine()

// 3. And a reader whose line falls in the gap between two paragraphs is still
//    between the same two afterwards.
const next = paragraph.nextElementSibling
const gap = next.getBoundingClientRect().top - paragraph.getBoundingClientRect().bottom
window.scrollBy(0, paragraph.getBoundingClientRect().bottom + gap / 2 - INSET)
await sleep(100)
const inTheGap = () =>
  paragraph.getBoundingClientRect().bottom <= INSET && next.getBoundingClientRect().top > INSET
results.theReaderStartsInTheGap = gap > 4 && inTheGap()
window.imark.setTextScale(22)
await sleep(100)
results.theGapIsKeptToo = inTheGap()

// 4. Every window is sent every setting on any change in Settings. The ones
//    that did not change move nothing, not even a pixel.
const y = window.scrollY
window.imark.setTextScale(22)
window.imark.setWidth('full')
await sleep(100)
results.anUnchangedSettingDoesNotMoveThePage = window.scrollY === y

// 5. The top of the document stays the top.
window.scrollTo(0, 0)
await sleep(100)
window.imark.setTextScale(18)
window.imark.setWidth('normal')
await sleep(100)
results.theTopStaysTheTop = window.scrollY === 0

return JSON.stringify(results)
"""

final class Harness: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_400, height: 1_000))
    private var window: NSWindow?

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
