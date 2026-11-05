import AppKit
import BorisCharacter
import BorisCore

extension AppModel {
    /// A click on the walrus. Returns true when the credits should roll.
    func pokeWalrus() -> Bool {
        // He was raising the alarm to be seen, and now he has been.
        if hasAlarm { acknowledgeAlarm() }
        return walrus.poke(pose: PoseName(mood: mood), reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func setWardrobe(_ mode: WardrobeMode) {
        settings.wardrobe.mode = mode
        refreshPresence()
    }

    /// `nil` brings the built-in walrus back.
    func usePack(_ pack: WalrusPack?) {
        settings.wardrobe.pack = pack?.id
        WalrusArt.shared.pack = pack
        // The sample line must now come from him too.
        walrusPage.choose(cue: walrusPage.cue)
        refreshPresence()
    }

    func refreshPacks() {
        walrusPage.packs = packShelf.list()
    }

    func removePack(_ pack: WalrusPack) {
        if WalrusArt.shared.pack?.id == pack.id { usePack(nil) }
        packShelf.remove(id: pack.id)
        refreshPacks()
    }

    /// The work happens off the main thread: every picture of the pack is opened and checked.
    func importPack(from folder: URL) {
        let shelf = packShelf
        walrusPage.importing = true
        Task {
            let result = await Task.detached { shelf.add(from: folder) }.value
            walrusPage.importing = false
            switch result {
            case .success(let pack):
                // A new version takes the old one's place on the shelf, so he must not stay on files that are gone.
                if WalrusArt.shared.pack?.name == pack.name { usePack(pack) }
                refreshPacks()
                walrusPage.tab = .packs
            case .failure(let rejection):
                walrusPage.rejection = rejection
            }
        }
    }
}
