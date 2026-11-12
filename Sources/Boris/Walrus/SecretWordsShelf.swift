import AppKit
import BorisCore

/// The folder of the person's own secret words. It is read again only after its list changes.
@MainActor
final class SecretWordsShelf {
    /// Nil in a check, which never reads the person's folder.
    let folder: URL?
    private var stamp: Date?
    private var words: [SecretWord] = []

    /// The first time, the folder comes with an example, so a word is on the Walrus page from the start.
    init(folder: URL?) {
        self.folder = folder
        if let folder, !FileManager.default.fileExists(atPath: folder.path) { seed(folder) }
    }

    /// Looked at only when a key is pressed in the main window: one look at the file's date, a read only after it changed.
    func current() -> [SecretWord] {
        guard let folder else { return [] }
        let file = folder.appendingPathComponent(SecretWordsReader.fileName)
        let changed = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        if changed != stamp {
            stamp = changed
            words = changed == nil ? [] : SecretWordsReader.read(folder)
        }
        return words
    }

    /// Shows the folder in Finder, with the example back in it if the list is gone.
    func open() {
        guard let folder else { return }
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(SecretWordsReader.fileName).path) { seed(folder) }
        NSWorkspace.shared.open(folder)
    }

    private func seed(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(SecretWordsReader.example.utf8).write(to: folder.appendingPathComponent(SecretWordsReader.fileName), options: .withoutOverwriting)
    }
}
