// Escape in the Settings window.
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

import AppKit

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

        defaults.removeObject(forKey: "authorName")
        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }
}
