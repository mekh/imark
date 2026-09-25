import CryptoKit
import Foundation
import ImarkRender

/// Where each document was being read when it was last seen, so that opening
/// it again lands on the paragraph it was left at instead of the top.
///
/// A place is a block of the file, by its lines, which means it only holds for
/// the text it was read in: in a file that changed since, the same lines can
/// be anything. So each place is kept with a digest of that text, and a file
/// whose text is different opens at the top. The text rather than the file's
/// date: saving the same bytes again, or a checkout that goes away and comes
/// back, changes the date and nothing a reader would call the document.
enum ReadingPlaces {
    /// How many documents are remembered, the one read longest ago going first.
    static let kept = 200

    /// Pages asked where they are being read whose answer is not in yet.
    /// Quitting waits for them: closing the last window quits the app, and the
    /// answer to the question that window asked on its way out is still coming.
    static let asking = DispatchGroup()

    struct Entry: Codable {
        let path: String
        let digest: String
        let place: ReadingPlace
    }

    /// What a place is remembered against. SHA-256 of a document at the 5 MB
    /// the window renders takes about as long as reading it from disk, and a
    /// fraction of a percent of laying it out.
    static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Where the document was being read, if that was in this same text.
    static func place(of url: URL, digest: String) -> ReadingPlace? {
        let path = path(of: url)
        guard let entry = entries.first(where: { $0.path == path }), entry.digest == digest else {
            return nil
        }
        return entry.place
    }

    /// Nil forgets the document: at the top there is nothing to go back to.
    static func remember(_ place: ReadingPlace?, of url: URL, digest: String) {
        let path = path(of: url)
        let others = entries.filter { $0.path != path }
        let list = place.map { [Entry(path: path, digest: digest, place: $0)] + others } ?? others
        entries = Array(list.prefix(kept))
    }

    /// Newest first. An unreadable list is an empty one: losing where somebody
    /// was is not worth an error.
    static var entries: [Entry] {
        get { Settings.readingPlaces.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? [] }
        set { Settings.readingPlaces = try? JSONEncoder().encode(newValue) }
    }

    /// The one spelling a document is remembered by, the same one AppDelegate
    /// tells open documents apart by.
    private static func path(of url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
