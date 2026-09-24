#!/usr/bin/env swift
//
// The text size reaches every part of the document, in a real web view, off
// screen.
//
//   swift Support/test-type-scale.swift
//
// ⌘+ and ⌘− set the size of the paragraphs and nothing else. Headings, tables,
// code blocks, the front matter card and the footnotes were sized in pixels
// and stayed put, so a bigger text size read as a smaller document around it:
// from 20pt on an H3 was smaller than the text under it, and at 24pt a table
// was barely more than half the size of the paragraph above it.

import AppKit
import WebKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = repo.appendingPathComponent("Resources")

// The page is served over `imark://` in the app and its CSP says so, which a
// file:// load cannot satisfy. A copy without the policy is the whole of the
// difference between this harness and the real thing.
let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imark-test-type-scale")
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

const DOC = [
  '---', 'title: Sizes', 'tags: [one, two]', '---', '',
  '# One', '', '## Two', '', '### Three', '', '#### Four', '', '##### Five', '', '###### Six', '',
  'A paragraph with a footnote.[^1]', '',
  '| Name | Value |', '|---|---|', '| a | 1 |', '',
  '```js', 'const answer = 42', '```', '',
  '```diff', '@@ -1 +1 @@', '-old', '+new', '```', '',
  '```mermaid', 'this is not a diagram', '```', '',
  '[^1]: The footnote.',
].join('\\n')

await window.imark.render({ markdown: DOC, path: '/tmp/t.md', theme: 'dark' })

// Each part and its size at the default text size, which is what the page
// looked like before any of it followed the text.
const PARTS = {
  paragraph: ['#content > p', 16],
  h1: ['#content > h1', 32],
  h2: ['h2', 24],
  h3: ['h3', 19],
  h4: ['h4', 16],
  h5: ['h5', 15],
  h6: ['h6', 15],
  table: ['table', 14.5],
  tableHeader: ['th', 12],
  code: ['pre code', 13.5],
  diff: ['.diff-block', 13.5],
  frontMatterTitle: ['.fm-title', 34],
  frontMatterRow: ['.fm-row', 12.5],
  footnotes: ['.footnotes', 14],
  diagramError: ['.diagram-error', 13],
  diagramErrorDetail: ['.diagram-error pre', 12],
}
const size = (selector) => {
  const element = document.querySelector(selector)
  return element ? parseFloat(getComputedStyle(element).fontSize) : NaN
}
const scaledBy = (ratio) =>
  Object.values(PARTS).every(([selector, base]) => Math.abs(size(selector) - base * ratio) < 0.01)

const results = {}

// 1. At the default size every part is the size it always was.
window.imark.setTextScale(16)
results.theDefaultSizeChangesNothing = scaledBy(1)
const copyButton = size('.copy-btn')

// 2. A bigger text size makes every part bigger by as much as the paragraphs.
window.imark.setTextScale(24)
results.biggerTextGrowsEveryPart = scaledBy(1.5)
results.aHeadingIsNeverSmallerThanTheTextUnderIt = size('h3') > size('#content > p')

// 3. A smaller one makes every part smaller by as much.
window.imark.setTextScale(12)
results.smallerTextShrinksEveryPart = scaledBy(0.75)

// 4. The controls around the document are not the document, and keep their size.
results.theControlsKeepTheirSize = size('.copy-btn') === copyButton

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
