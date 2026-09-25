// File ▸ Open Recent.
//
//   swift build && TEST_BIN="$(swift build --show-bin-path)"
//   swiftc -parse-as-library -I "$TEST_BIN" -I "$TEST_BIN/Modules" -F "$TEST_BIN" \
//     -Xlinker -rpath -Xlinker "$TEST_BIN" \
//     $(find Sources/Imark -name '*.swift' ! -name main.swift) \
//     $(find Sources/ImarkRender -name '*.swift') \
//     Support/test-recent.swift -o /tmp/imark-test-recent && /tmp/imark-test-recent
//
// The titles are plain strings and are checked as such. The rest goes through
// real windows opened by the app delegate and the submenu the File menu really
// holds: what the menu leaves out depends on which documents have a window, and
// that is wiring, not arithmetic.

import AppKit

@main
enum RecentTest {
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

    static let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("imark-recent-\(UUID().uuidString.prefix(8))")

    static func fixture(_ name: String) -> URL {
        let url = folder.appendingPathComponent(name)
        try! "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The file names in the stored list, newest first.
    static var stored: [String] {
        Settings.recentFiles.map { ($0 as NSString).lastPathComponent }
    }

    static func main() {
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = AppDelegate()
        app.delegate = delegate
        Menu.install()
        UserDefaults.standard.removeObject(forKey: "recentFiles")

        titles()
        theList()
        theMenu(delegate)
        quitting(delegate)

        UserDefaults.standard.removeObject(forKey: "recentFiles")
        try? FileManager.default.removeItem(at: folder)
        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Titles

    static func titles() {
        func title(_ path: String) -> String { RecentFiles.title(for: path, home: "/Users/ann") }

        let home = title("/Users/ann/Documents/doc.md")
        check("a document in the home folder starts with ~", home == "~/Documents/doc.md", home)
        let outside = title("/Volumes/Work/doc.md")
        check("one outside it keeps its whole path", outside == "/Volumes/Work/doc.md", outside)
        let lookalike = title("/Users/anna/doc.md")
        check("a folder whose name only starts the same is not home", lookalike == "/Users/anna/doc.md", lookalike)

        // 67 characters abbreviated. Only the folder after the first has to go,
        // and the folders nearest the file fill the rest, to exactly 60.
        let nearest = title("/Users/ann/Documents/projects/2026/clients/acme/specs/very-long-file-name.md")
        check("a long path keeps its first folder and the ones nearest the file",
              nearest == "~/Documents/…/2026/clients/acme/specs/very-long-file-name.md", nearest)
        check("and stops at the limit", nearest.count == RecentFiles.longest, "\(nearest.count)")

        let first = title(
            "/Users/ann/Documents/projects/2026/clients/acme/specifications/a-very-long-file-name-for-the-menu.md"
        )
        check("with no room beside a long name, the first folder and the name are what is left",
              first == "~/Documents/…/a-very-long-file-name-for-the-menu.md", first)
        let absolute = title(
            "/Volumes/Archive/projects/2026/clients/acme/specifications/a-very-long-file-name-for-the-menu.md"
        )
        check("an absolute path keeps its first folder the same way",
              absolute == "/Volumes/…/a-very-long-file-name-for-the-menu.md", absolute)

        let name = String(repeating: "n", count: 50) + ".md"
        let long = title("/Users/ann/Documents/notes/" + name)
        check("a name with no room for the first folder beside it pushes that out", long == "~/…/" + name, long)
        let longer = String(repeating: "n", count: 70) + ".md"
        let longest = title("/Users/ann/Documents/notes/" + longer)
        check("and is never cut, even past the limit", longest == "~/…/" + longer, longest)

        // Every depth against every length of name: the name whole, the limit
        // kept unless the name is what breaks it, and never longer than the path.
        var broken: [String] = []
        for depth in 0...12 {
            for length in stride(from: 1, through: 80, by: 3) {
                let folders = (0..<depth).map { "folder\($0)" }
                let name = String(repeating: "x", count: length) + ".md"
                let path = (["/Users/ann"] + folders + [name]).joined(separator: "/")
                let whole = RecentFiles.abbreviated(path, home: "/Users/ann")
                let shown = title(path)
                let fits = shown.count <= RecentFiles.longest
                    || shown == "~/…/" + name
                    || shown == whole
                if !shown.hasSuffix("/" + name) || !fits || shown.count > whole.count {
                    broken.append(shown)
                }
            }
        }
        check("every title keeps the whole name and the limit", broken.isEmpty, broken.prefix(3).joined(separator: "  "))
    }

    // MARK: - The list

    static func theList() {
        Settings.recentFiles = []
        let recent = RecentFiles.shared
        for name in ["a.md", "b.md", "c.md"] { recent.note(folder.appendingPathComponent(name)) }
        check("the last one noted is on top", stored == ["c.md", "b.md", "a.md"], "\(stored)")
        recent.note(folder.appendingPathComponent("a.md"))
        check("noting one again moves it up rather than adding it twice",
              stored == ["a.md", "c.md", "b.md"], "\(stored)")

        Settings.recentFiles = []
        for index in 0...RecentFiles.kept { recent.note(folder.appendingPathComponent("\(index).md")) }
        check("the list keeps \(RecentFiles.kept)", stored.count == RecentFiles.kept, "\(stored.count)")
        check("the oldest goes first", stored.first == "\(RecentFiles.kept).md" && !stored.contains("0.md"),
              "\(stored.first ?? "") … \(stored.last ?? "")")
    }

    // MARK: - The menu

    /// The document window showing `name`, if there is one.
    static func window(showing name: String) -> DocumentWindowController? {
        NSApp.windows
            .compactMap { $0.windowController as? DocumentWindowController }
            .first { $0.url.lastPathComponent == name && $0.window?.isVisible == true }
    }

    /// Fills the submenu the way AppKit does just before it opens, and returns
    /// the file names it lists.
    static func listed(in menu: NSMenu) -> [String] {
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.compactMap { ($0.representedObject as? URL)?.lastPathComponent }
    }

    static func theMenu(_ delegate: AppDelegate) {
        guard let file = NSApp.mainMenu?.items[1].submenu else {
            return check("there is a File menu", false)
        }
        check("Open Recent comes straight after Open…",
              file.items.count > 1 && file.items[0].title == "Open…" && file.items[1].title == "Open Recent",
              file.items.prefix(3).map(\.title).joined(separator: ", "))
        guard let menu = file.items[1].submenu else {
            return check("Open Recent has a submenu", false)
        }
        check("and fills it itself", menu.delegate === RecentFiles.shared)

        Settings.recentFiles = []
        let a = fixture("a.md"), b = fixture("b.md"), c = fixture("c.md")
        delegate.open(a)
        delegate.open(b)
        spin(0.3)
        check("documents with a window are not listed", listed(in: menu).isEmpty, "\(listed(in: menu))")
        check("an empty menu cannot be cleared", menu.items.last?.title == "Clear Menu" && menu.items.last?.isEnabled == false)

        window(showing: "b.md")?.window?.close()
        spin(0.3)
        check("a closed document is listed", listed(in: menu) == ["b.md"], "\(listed(in: menu))")

        // Another document in the same window puts the first one down.
        window(showing: "a.md")?.show(c, pushingHistory: true)
        spin(0.3)
        check("so is one another document replaced, on top",
              listed(in: menu) == ["a.md", "b.md"], "\(listed(in: menu))")

        let item = menu.items.first { ($0.representedObject as? URL)?.lastPathComponent == "a.md" }
        check("an entry is titled by its path", item?.title == RecentFiles.title(for: a.path), item?.title ?? "none")

        RecentFiles.shared.note(folder.appendingPathComponent("gone.md"))
        check("a document that is gone is not listed", !listed(in: menu).contains("gone.md"), "\(listed(in: menu))")

        if let index = menu.items.firstIndex(where: { ($0.representedObject as? URL)?.lastPathComponent == "b.md" }) {
            menu.performActionForItem(at: index)
            spin(0.3)
        }
        check("choosing an entry opens it", window(showing: "b.md") != nil)
        check("and takes it off the list", listed(in: menu) == ["a.md"], "\(listed(in: menu))")

        if let clear = menu.items.last, clear.title == "Clear Menu", clear.isEnabled {
            menu.performActionForItem(at: menu.items.count - 1)
        }
        check("Clear Menu empties it", Settings.recentFiles.isEmpty && listed(in: menu).isEmpty, "\(stored)")

        // Opened p then q, closed q then p: the order is the closing one.
        let p = fixture("p.md"), q = fixture("q.md")
        delegate.open(p)
        delegate.open(q)
        spin(0.3)
        window(showing: "q.md")?.window?.close()
        window(showing: "p.md")?.window?.close()
        spin(0.3)
        check("the one put down last is on top, whenever it was opened",
              Array(listed(in: menu).prefix(2)) == ["p.md", "q.md"], "\(listed(in: menu))")

        for index in 0..<(RecentFiles.shown + 10) { RecentFiles.shared.note(fixture("many-\(index).md")) }
        let many = listed(in: menu)
        check("the menu lists \(RecentFiles.shown)", many.count == RecentFiles.shown, "\(many.count)")
        check("newest first", many.first == "many-\(RecentFiles.shown + 9).md", many.first ?? "none")

        for name in ["b.md", "c.md"] { window(showing: name)?.window?.close() }
        spin(0.3)
    }

    // MARK: - Quitting

    static func quitting(_ delegate: AppDelegate) {
        Settings.recentFiles = []
        let x = fixture("x.md"), y = fixture("y.md"), z = fixture("z.md")
        delegate.open(x)
        delegate.open(y)
        delegate.open(z)
        spin(0.3)
        window(showing: "z.md")?.window?.close()
        // Regardless: the harness is never the active app, and an inactive app
        // asking to come forward stays where it was.
        window(showing: "x.md")?.window?.orderFrontRegardless()
        spin(0.3)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        check("quitting puts every open document down, the front one on top",
              Array(stored.prefix(3)) == ["x.md", "y.md", "z.md"], "\(stored)")

        for name in ["x.md", "y.md"] { window(showing: name)?.window?.close() }
        spin(0.3)
    }
}
