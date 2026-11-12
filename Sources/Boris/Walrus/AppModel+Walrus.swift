import AppKit
import BorisCharacter
import BorisCore

extension AppModel {
    /// A click on the walrus. Returns true when the credits should roll.
    func pokeWalrus(now: Date = Date()) -> Bool {
        // He was raising the alarm to be seen, and now he has been.
        if hasAlarm { acknowledgeAlarm() }
        var diary = eggs
        let birthday = diary.birthdayDue(now: now) ? WalrusLines.surprise(.birthday) : nil
        let credits = walrus.poke(pose: PoseName(mood: mood), reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, now: now, special: birthday)
        if let birthday, walrus.line?.text == birthday {
            diary.note(.birthday, now: now)
            noteEggs(diary)
        }
        return credits
    }

    /// A key typed in the main window, for his tricks. See `Eggs.swift`.
    func typedToWalrus(_ key: PlayKey, now: Date = Date()) {
        let secrets = secretWords.current()
        guard let trick = walrus.key(key, pose: PoseName(mood: mood), secrets: secrets, now: now), !quiet.isOn(now: now) else { return }
        switch trick {
        case .wizard:
            notifications.playTrick(.hmm)
        case .secret(let word):
            if let sound = secrets.first(where: { $0.word == word })?.sound { notifications.playTrick(file: sound) }
        case .konami, .name, .hoot, .obviously, .logically:
            break
        }
    }

    /// The surprises that come on their own. Looked at only when a scan brings news, so between scans they cost nothing.
    /// Do not disturb, a pack with its own lines and a walrus with something to say about the work all keep them quiet.
    func lookForSurprise(at now: Date) {
        guard !quiet.isOn(now: now), WalrusArt.shared.pack == nil, !walrus.isRestricted(PoseName(mood: mood)) else { return }
        var diary = eggs
        var working = false
        if case .working = mood { working = true }
        guard let surprise = diary.due(now: now, working: working, tokensToday: today.total, weekSpent: EggDiary.weekSpent(world.usage, now: now)),
              walrus.remark(WalrusLines.surprise(surprise), act: surprise.act, now: now) else { return }
        diary.note(surprise, now: now)
        noteEggs(diary)
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
