import AppKit

/// File ▸ Open Recent: the documents read here lately, the one put down last
/// on top.
///
/// It works the way Sublime Text's does. A document goes to the top when it is
/// put down — its window closed, another document opened in its place, the app
/// quit — and anything that still has a window is left out, because the menu
/// is for getting back to what is no longer on screen.
///
/// A list of its own rather than NSDocumentController's, which the sidebar and
/// the menu bar icon read. That one stops at the number of recent items set in
/// System Settings, ten unless somebody changed it, and never hears when a
/// document is put down. Every document still goes to it as well, so the Dock
/// and the Finder go on hearing about them.
final class RecentFiles: NSObject, NSMenuDelegate {
    static let shared = RecentFiles()

    /// How many the menu lists.
    static let shown = 50
    /// How many are remembered, the oldest going first. More than are shown:
    /// the documents with a window and the ones that are gone are left out of
    /// the menu, and without spares they would leave it short.
    static let kept = 100
    /// The longest a title gets, in characters, before the middle of its path
    /// gives way. The file name is never cut.
    static let longest = 60

    /// Called when a document is opened and again when it is put down. The
    /// second call is the one the order comes from; the first keeps a document
    /// that was open when the app crashed from vanishing along with it.
    func note(_ url: URL) {
        let path = Self.path(of: url)
        let others = Settings.recentFiles.filter { $0 != path }
        Settings.recentFiles = Array(([path] + others).prefix(Self.kept))
    }

    /// What the menu lists, newest first.
    func listed() -> [URL] {
        let open = Set(((NSApp.delegate as? AppDelegate)?.openDocuments ?? []).map(Self.path(of:)))
        return Settings.recentFiles
            .lazy
            .filter { !open.contains($0) && FileManager.default.fileExists(atPath: $0) }
            .prefix(Self.shown)
            .map { URL(fileURLWithPath: $0) }
    }

    /// The one spelling a document is remembered by. A file reached through a
    /// symlink is still the same file, which is also how AppDelegate decides
    /// whether it is open already.
    private static func path(of url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - The menu

    /// The submenu under File ▸ Open…. Filled each time it opens rather than
    /// kept up to date: the list changes with every document opened or closed,
    /// and a file can disappear without the app hearing of it.
    func menu() -> NSMenu {
        let menu = NSMenu(title: "Open Recent")
        menu.delegate = self
        // Built fresh on every opening, with the list in hand, so each item can
        // be told whether it is enabled there and then.
        menu.autoenablesItems = false
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let files = listed()
        for url in files {
            let title = Self.title(for: url.path)
            let item = menu.addItem(withTitle: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            // The whole path, for the titles that lost the middle of theirs.
            let whole = Self.abbreviated(url.path)
            if title != whole { item.toolTip = whole }
        }
        if !files.isEmpty { menu.addItem(.separator()) }
        let clear = menu.addItem(withTitle: "Clear Menu", action: #selector(clearMenu(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !files.isEmpty
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        (NSApp.delegate as? AppDelegate)?.open(url)
    }

    /// NSDocumentController's list goes too. The sidebar and the menu bar icon
    /// read it, and a menu that was cleared while they go on naming the same
    /// documents has not forgotten anything.
    @objc func clearMenu(_ sender: Any?) {
        Settings.recentFiles = []
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    // MARK: - Titles

    /// The path with the home folder written as `~`, the way a terminal writes
    /// it and the Finder's Go to Folder reads it.
    static func abbreviated(
        _ path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        // The slash is part of the test: /Users/anna is not inside /Users/ann.
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// What the menu calls a document: its abbreviated path while that is at
    /// most `longest` characters, and past it the first folder, an ellipsis and
    /// as many of the folders nearest the file as still fit, as in
    /// `~/Documents/…/notes/plan.md`. The nearest folders say the most about a
    /// file, and the first says where it lives. The name is what people look
    /// for, so it is never cut: a name too long to share the space with the
    /// first folder pushes that out instead, and past that, the limit.
    static func title(
        for path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let whole = abbreviated(path, home: home)
        guard whole.count > longest else { return whole }
        var folders = whole.components(separatedBy: "/")
        let name = folders.removeLast()
        // `~`, or the nothing in front of the first slash of an absolute path.
        let root = folders.removeFirst()
        // A folder has to go between the first one and the file, or the
        // ellipsis would stand for nothing.
        if folders.count > 1 {
            let head = root + "/" + folders[0] + "/…/"
            if (head + name).count <= longest {
                var tail = name
                for folder in folders.dropFirst(2).reversed() {
                    guard (head + folder + "/" + tail).count <= longest else { break }
                    tail = folder + "/" + tail
                }
                return head + tail
            }
        }
        let short = root + "/…/" + name
        return short.count < whole.count ? short : whole
    }
}
