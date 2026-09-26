// Escape in the Settings window, and Settings over the document.
//
//   swift build && TEST_BIN="$(swift build --show-bin-path)"
//   swiftc -parse-as-library -I "$TEST_BIN" -I "$TEST_BIN/Modules" -F "$TEST_BIN" \
//     -Xlinker -rpath -Xlinker "$TEST_BIN" \
//     $(find Sources/Imark -name '*.swift' ! -name main.swift) \
//     $(find Sources/ImarkRender -name '*.swift') \
//     Support/test-settings.swift -o /tmp/imark-test-settings && /tmp/imark-test-settings
//
// The Keyboard Shortcuts panel closed on Escape and the Settings window did not:
// it was a plain window, which passes Escape on as `cancel:`, and nothing
// answered that. The key goes to the real window as an event, the way the window
// server hands it over, once with nothing in particular focused and once while a
// name is being typed, because the two reach the window by different roads.
//
// Settings went behind a document at the first click there, and ⌘Tab or the Dock
// then brought the document back with Settings still open underneath. It is now
// a child window of the document being read. Nothing in the suite becomes main
// (it never activates), so a document becoming the main window is told by
// posting the notification AppKit sends.

import AppKit
import ObjectiveC

@main
enum SettingsTest {
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

    static func pressEscape(in window: NSWindow) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53
        )!
        window.sendEvent(event)
        spin(0.2)
    }

    /// The name field, the only control in the window you can type into.
    static func nameField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(nameField).first
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // Settings reads Sparkle's preference, which starts Sparkle. In a bare
        // executable it cannot start, and says so a moment later in an alert run
        // for the whole app, which nobody can press in a window nobody sees: the
        // suite hung there once it ran longer than that moment. The alert is
        // printed and answered at once instead.
        method_exchangeImplementations(
            class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal))!,
            class_getInstanceMethod(NSAlert.self, #selector(NSAlert.answeredAtOnce))!
        )
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "authorName")

        let controller = PreferencesWindowController.shared
        guard let window = controller.window else {
            print("FAIL the Settings window was never made")
            exit(1)
        }
        window.alphaValue = 0

        print("▸ nothing in particular focused")
        controller.showWindow(nil)
        window.makeFirstResponder(nil)
        spin(0.2)
        pressEscape(in: window)
        check("Escape closes the window", !window.isVisible)

        print("▸ a name being typed")
        controller.showWindow(nil)
        spin(0.2)
        check("the window opens again after Escape", window.isVisible)
        guard let field = nameField(in: window.contentView!) else {
            print("FAIL no name field in the window")
            exit(1)
        }
        window.makeFirstResponder(field)
        field.currentEditor()?.insertText("Ada")
        pressEscape(in: window)
        check("Escape closes the window", !window.isVisible)
        check("the name is kept", defaults.string(forKey: "authorName") == "Ada",
              "stored \(defaults.string(forKey: "authorName") ?? "nothing")")

        overTheDocument(settings: window)

        defaults.removeObject(forKey: "authorName")
        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }

    static func document(_ name: String, in folder: URL) -> DocumentWindowController {
        let url = folder.appendingPathComponent(name)
        try? "# \(name)\n\nSome text.\n".write(to: url, atomically: true, encoding: .utf8)
        let controller = DocumentWindowController(url: url)
        controller.showWindow(nil)
        spin(0.3)
        return controller
    }

    static func becomesMain(_ window: NSWindow?) {
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        spin(0.1)
    }

    static func overTheDocument(settings: NSWindow) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("imark-settings-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        print("▸ over the document")
        let first = document("first.md", in: folder)
        guard let a = first.window, let screen = a.screen?.visibleFrame else {
            return check("the first document has a window on a screen", false)
        }
        // Wholly on the screen, wherever the frame saved by another run left it.
        // In the middle, with room above and below for a Settings taller than
        // the document. It widens a little at its first layout, so it is let
        // settle first.
        a.setFrame(NSRect(x: screen.midX - 450, y: screen.midY - 300, width: 900, height: 600), display: false)
        spin(0.2)
        PreferencesWindowController.show()
        spin(0.2)
        check("Settings opens over the document being read", settings.parent === a,
              "parent \(settings.parent?.title ?? "none")")
        check("centred on it",
              abs(settings.frame.midX - a.frame.midX) < 1 && abs(settings.frame.midY - a.frame.midY) < 1,
              "Settings at \(settings.frame.midX), \(settings.frame.midY); document at \(a.frame.midX), \(a.frame.midY)")
        settings.setFrameOrigin(NSPoint(x: settings.frame.minX + 25, y: settings.frame.minY + 15))
        let placed = settings.frame.origin
        PreferencesWindowController.show()
        spin(0.1)
        check("shown again while open, it stays where it was put", settings.frame.origin == placed)

        let before = settings.frame.origin
        a.setFrameOrigin(NSPoint(x: a.frame.minX + 40, y: a.frame.minY - 30))
        spin(0.1)
        check("it moves with the document",
              settings.frame.origin == NSPoint(x: before.x + 40, y: before.y - 30),
              "moved by \(settings.frame.minX - before.x), \(settings.frame.minY - before.y)")

        let second = document("second.md", in: folder)
        guard let b = second.window else { return check("the second document has a window", false) }
        becomesMain(b)
        check("it goes over the document that becomes the main window", settings.parent === b)
        check("and leaves the one before", a.childWindows?.contains(settings) != true)

        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFront(nil)
        becomesMain(other)
        check("a window that is not a document can come above it", settings.parent === b)
        other.orderOut(nil)

        b.close()
        spin(0.2)
        check("closing the document leaves Settings open", settings.isVisible)
        check("on its own", settings.parent == nil)
        becomesMain(a)
        check("the next document to become main takes it", settings.parent === a)

        pressEscape(in: settings)
        check("Escape still closes it", !settings.isVisible)
        check("closed, it is no longer the document's", a.childWindows?.contains(settings) != true)
        a.orderFront(nil)
        becomesMain(a)
        spin(0.1)
        check("and it does not come back with the document", !settings.isVisible)

        // AppKit puts a window it orders in back on the screen, off a side as
        // well as off the bottom, though its documentation promises only the
        // top edge (checked on macOS 26). Settings leaves it to AppKit, and this
        // says so if a macOS stops.
        a.setFrameOrigin(NSPoint(x: screen.maxX - 200, y: a.frame.minY))
        PreferencesWindowController.show()
        spin(0.1)
        check("over a document hanging off the side of the screen, it opens on the screen",
              screen.contains(settings.frame), "Settings at \(settings.frame), screen \(screen)")
        pressEscape(in: settings)
        a.close()
    }
}

extension NSAlert {
    @objc func answeredAtOnce() -> NSApplication.ModalResponse {
        print("     (alert: \(messageText))")
        return .alertFirstButtonReturn
    }
}
