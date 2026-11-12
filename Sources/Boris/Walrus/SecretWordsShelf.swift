import AppKit
import BorisCore

/// The folder of the person's own secret words. It is read again only after its list changes.
@MainActor
final class SecretWordsShelf {
    /// Nil in a check, which never reads the person's folder.
    let folder: URL?
    private var stamp: Date?
    private var words: [SecretWord] = []

    init(folder: URL?) {
        self.folder = folder
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

    /// Makes the folder with an example the first time, and shows it in Finder.
    func open() {
        guard let folder else { return }
        let manager = FileManager.default
        let file = folder.appendingPathComponent(SecretWordsReader.fileName)
        if !manager.fileExists(atPath: file.path) {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data(SecretWordsReader.example.utf8).write(to: file, options: .withoutOverwriting)
        }
        NSWorkspace.shared.open(folder)
    }
}
