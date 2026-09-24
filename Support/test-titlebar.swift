// Double-clicking the title bar, in a window built the way a document window is.
//
//   swiftc -parse-as-library $(find Sources/ImarkRender -name '*.swift') \
//     Support/test-titlebar.swift -o /tmp/imark-test-titlebar && /tmp/imark-test-titlebar
//
// A document runs up under the toolbar, so the renderer's web view sits beneath
// the title bar too. A web view says no to `mouseDownCanMoveWindow`, and AppKit
// took that as the title bar there being something to click: double-clicking it
// did not zoom the window, and there was no second double-click to put it back.
//
// The window is on screen, because zooming is worked out against a screen, and
// invisible, so the suite does not flash anything across the desktop. The clicks
// go to the window as events, the way the window server hands them over.

import AppKit
import WebKit

@main
enum TitlebarTest {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("OK   \(name)")
        } else {
            failures += 1
            print("FAIL \(name)  \(detail())")
        }
    }

    static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Nothing in the toolbar, only its flexible space: the title bar is title
    /// and empty space all the way across.
    final class Toolbar: NSObject, NSToolbarDelegate {
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }
        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier identifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? { nil }
    }

    static let toolbar = Toolbar()
    static let frame = NSRect(x: 200, y: 200, width: 900, height: 600)

    /// The same style as DocumentWindowController's, with `content` filling it.
    static func documentWindow(showing content: NSView?) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Titlebar"
        window.titlebarAppearsTransparent = true
        let bar = NSToolbar(identifier: "test")
        bar.delegate = toolbar
        window.toolbar = bar
        window.toolbarStyle = .unified
        if let content, let host = window.contentView {
            content.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        window.setFrame(frame, display: true)
        window.alphaValue = 0
        window.orderFrontRegardless()
        spin(1.0)
        return window
    }

    /// Two clicks in the middle of the title bar. The mouse-up is queued before
    /// each mouse-down: a mouse-down on a part of the window that moves it starts
    /// a loop that waits for the mouse to come back up.
    static func doubleClickTitleBar(of window: NSWindow) {
        let point = NSPoint(x: window.frame.width / 2, y: window.frame.height - 25)
        func event(_ type: NSEvent.EventType, _ count: Int) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: 1
            )!
        }
        for count in [1, 2] {
            NSApp.postEvent(event(.leftMouseUp, count), atStart: false)
            window.sendEvent(event(.leftMouseDown, count))
            while let queued = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
                window.sendEvent(queued)
            }
        }
        spin(1.0)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // "Do Nothing" or "Minimize" in System Settings would make every check
        // below meaningless.
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        guard action == "Maximize" else {
            print("skipped: title bar double-click is set to \(action) in System Settings")
            exit(0)
        }

        print("▸ a window with nothing under its title bar, to show the clicks land")
        let empty = documentWindow(showing: nil)
        doubleClickTitleBar(of: empty)
        check("double-clicking the title bar zooms it", empty.isZoomed)
        empty.close()

        print("▸ the same window with the renderer under its title bar")
        let renderer = RendererView(frame: .zero)
        let window = documentWindow(showing: renderer)
        doubleClickTitleBar(of: window)
        check("double-clicking the title bar zooms the window", window.isZoomed, "\(window.frame)")
        doubleClickTitleBar(of: window)
        check("and doing it again puts the window back", !window.isZoomed && window.frame == frame,
              "\(window.frame)")

        // The web view saying yes to moving the window must not let a drag across
        // the page do it.
        let origin = window.frame.origin
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        NSApp.postEvent(mouse(.leftMouseDragged, NSPoint(x: 700, y: 250)), atStart: false)
        NSApp.postEvent(mouse(.leftMouseUp, NSPoint(x: 700, y: 250)), atStart: false)
        window.sendEvent(mouse(.leftMouseDown, NSPoint(x: 600, y: 300)))
        spin(0.8)
        check("a drag across the page does not move the window", window.frame.origin == origin,
              "\(window.frame.origin) from \(origin)")
        window.close()

        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }
}
