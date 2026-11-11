import AppKit
import BorisCharacter
import BorisCore
import SwiftUI

/// The names on the Walrus page. Outfits and reactions are named for what they are in the code of the walrus.
enum WalrusPageText {
    static func name(_ state: WalrusPageState.PreviewState) -> String {
        switch state {
        case .watch: return L("On duty")
        case .work: return L("Working")
        case .wait: return L("Waiting")
        case .happy: return L("Happy")
        case .hmm: return L("Hm?")
        case .alert: return L("On guard")
        case .tired: return L("Tired")
        case .alarm: return L("Alarm")
        case .broken: return L("Broken")
        case .sleep: return L("Asleep")
        }
    }

    static func name(_ cue: WalrusCue) -> String {
        switch cue {
        case .poke: return L("On a click")
        case .request: return L("Request")
        case .finish: return L("Finish")
        case .failure: return L("Failure")
        case .limit: return L("Limit near")
        }
    }

    static func name(_ outfit: Outfit) -> String {
        switch outfit {
        case .none: return L("Bowler and monocle")
        case .santa: return L("New Year")
        case .witch: return L("Halloween")
        case .party: return L("Celebration")
        case .scholar: return L("September 1")
        case .nightcap: return L("Night")
        case .pixel: return L("Programmer's Day")
        case .hearts: return L("February 14")
        case .flower: return L("March 8")
        case .crow: return L("Friday the 13th")
        case .fish: return L("Fish")
        }
    }

    static func when(_ outfit: Outfit) -> String {
        switch outfit {
        case .none: return L("On all the other days")
        case .santa: return L("December 20 to January 10")
        case .witch: return L("October 25 to 31")
        case .party: return L("Birthdays and ten clean runs in a row")
        case .scholar: return L("September 1")
        case .nightcap: return L("Midnight to 5 am")
        case .pixel: return L("The 256th day of the year")
        case .hearts: return L("February 14")
        case .flower: return L("March 8")
        case .crow: return L("Friday the 13th")
        case .fish: return L("A reward for 100 finished runs")
        }
    }

    static func name(_ act: Act) -> String {
        switch act {
        case .hoot: return L("Bellow")
        case .yawn: return L("Yawn")
        case .poke: return L("Poke")
        case .annoyed: return L("Annoyed")
        case .back: return L("Back turned")
        case .wink: return L("Wink")
        case .spin: return L("Full turn")
        case .dizzy: return L("Dizzy")
        }
    }

    static func describe(_ problem: WalrusPackProblem) -> String {
        switch problem {
        case .noManifest: return L("The description file pack.json")
        case .badManifest: return L("pack.json cannot be read")
        case .noName: return L("The pack's name in pack.json")
        case .noBaseLanguage: return L("The base language in pack.json")
        case .noBasePose: return L("The base pose: pictures in poses/base")
        case .noTrayIcon: return L("The one-colour menu bar icon: icon/base.png")
        case .noLines(let language): return L("Lines in the base language: lines/%@.json", language)
        case .badLines(let language): return L("lines/%@.json cannot be read", language)
        case .noLinesForCue(let cue): return L("Lines for the event “%@”", name(cue))
        case .noPlainLine(let cue): return L("A line without {project} for the event “%@”", name(cue))
        case .lineTooLong(let cue): return L("A line for the event “%@” is too long", name(cue))
        case .badImage(let path): return L("Cannot be read as PNG: %@", path)
        case .tooLarge(let path): return L("Too large: %@", path)
        case .tooManyFrames(let path): return L("Too many pictures in %@", path)
        case .link(let path): return L("A link instead of a file: %@", path)
        case .cannotCopy: return L("Boris could not copy the files")
        }
    }

    static func isMissing(_ problem: WalrusPackProblem) -> Bool {
        switch problem {
        case .noManifest, .noName, .noBaseLanguage, .noBasePose, .noTrayIcon, .noLines, .noLinesForCue, .noPlainLine: return true
        case .badManifest, .badLines, .lineTooLong, .badImage, .tooLarge, .tooManyFrames, .link, .cannotCopy: return false
        }
    }
}

struct WalrusSectionTitle: View {
    var title: String
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(Palette.text3)
            }
        }
    }
}

/// A kept picture of the walrus at a size of its own, for lists and tiles.
private struct WalrusTile: View {
    var source: WalrusArt.Source
    var size: CGFloat

    var body: some View {
        Group {
            if let image = WalrusArt.shared.still(source, pixels: Int(size * 2), simple: size < WalrusView.simpleBelow) {
                Image(decorative: image, scale: 2).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The outfits and, under them, the reactions.
struct WalrusOutfitsTab: View {
    @Bindable var model: AppModel

    private var page: WalrusPageState { model.walrusPage }
    private var usesPack: WalrusPack? { WalrusArt.shared.pack }
    private var outfits: [Outfit] { Outfit.allCases.filter { $0 != .fish || model.hasFish } }
    /// Four and five in a row at the usual size, fewer on a narrow window.
    private let tiles = [GridItem(.adaptive(minimum: 120), spacing: 10)]
    private let small = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    private func isChosen(_ outfit: Outfit) -> Bool {
        switch model.settings.wardrobe.mode {
        case .off: return outfit == .none
        case .manual(let chosen): return outfit == chosen
        case .byDate: return false
        }
    }

    private var isByDate: Bool {
        model.settings.wardrobe.mode == .byDate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WalrusSectionTitle(title: L("Outfits"), note: usesPack.map { L("Only the built-in walrus has them. The pack “%@” is in use now.", $0.name) })
            LazyVGrid(columns: tiles, spacing: 10) {
                tile(name: L("By the calendar"), detail: isByDate ? L("worn") : L("built-in"), chosen: isByDate, outfit: isByDate ? model.outfit : calendarOutfit) {
                    model.setWardrobe(.byDate)
                }
                ForEach(outfits, id: \.self) { outfit in
                    tile(name: WalrusPageText.name(outfit), detail: isChosen(outfit) ? L("worn") : L("built-in"), chosen: isChosen(outfit), outfit: outfit) {
                        model.setWardrobe(outfit == .none ? .off : .manual(outfit))
                    }
                }
            }
            .disabled(usesPack != nil)
            .opacity(usesPack != nil ? 0.5 : 1)
            WalrusSectionTitle(title: L("Reactions"), note: L("short animations over the pose")).padding(.top, 6)
            LazyVGrid(columns: small, spacing: 10) {
                ForEach(Act.allCases, id: \.self) { act in
                    Button {
                        page.stage.perform(act)
                    } label: {
                        VStack(spacing: 6) {
                            reaction(act)
                            Text(WalrusPageText.name(act))
                                .font(.system(size: 11.5))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.fill1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(usesPack != nil)
            .opacity(usesPack != nil ? 0.5 : 1)
        }
    }

    private func reaction(_ act: Act) -> some View {
        var frame = WalrusFrame(name: .watch, outfit: model.outfit)
        frame.act = act
        frame.actStep = Int(act.stillTime * Double(WalrusFrame.actSteps))
        return WalrusTile(source: .drawn(frame), size: 56)
    }

    /// What the calendar would dress him in today, whatever he wears now.
    private var calendarOutfit: Outfit {
        var settings = model.settings.wardrobe
        settings.mode = .byDate
        return Wardrobe.outfit(at: model.now, settings: settings)
    }

    private func tile(name: String, detail: String, chosen: Bool, outfit: Outfit, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                WalrusTile(source: .shelf(outfit), size: 72)
                Text(name)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.system(size: 11)).foregroundStyle(chosen ? Palette.focus : Palette.text3)
            }
            .padding(EdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 6))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.fill1))
            .overlay {
                if chosen {
                    RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.focus, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A theme is what he wears by himself: the calendar decides, unless the person does.
struct WalrusThemesTab: View {
    @Bindable var model: AppModel

    private var settings: AppSettings { model.settings }
    private var outfits: [Outfit] { Outfit.allCases.filter { $0 != .none && ($0 != .fish || model.hasFish) } }

    private enum Theme: Hashable {
        case calendar, chosen, plain
    }

    private var theme: Binding<Theme> {
        Binding {
            switch settings.wardrobe.mode {
            case .byDate: return .calendar
            case .manual: return .chosen
            case .off: return .plain
            }
        } set: { choice in
            switch choice {
            case .calendar: model.setWardrobe(.byDate)
            case .plain: model.setWardrobe(.off)
            case .chosen:
                if case .manual = settings.wardrobe.mode { return }
                model.setWardrobe(.manual(model.outfit == .none ? .santa : model.outfit))
            }
        }
    }

    private var hasBirthday: Binding<Bool> {
        Binding { settings.wardrobe.userBirthday != nil } set: { on in
            if on {
                let today = Calendar.current.dateComponents([.month, .day], from: Date())
                settings.wardrobe.userBirthday = MonthDay(month: today.month ?? 1, day: today.day ?? 1)
            } else {
                settings.wardrobe.userBirthday = nil
            }
            model.refreshPresence()
        }
    }

    private var birthday: Binding<Date> {
        Binding {
            guard let day = settings.wardrobe.userBirthday else { return Date() }
            return Calendar.current.date(from: DateComponents(year: 2000, month: day.month, day: day.day)) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.month, .day], from: date)
            if let month = parts.month, let day = parts.day {
                settings.wardrobe.userBirthday = MonthDay(month: month, day: day)
                model.refreshPresence()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WalrusSectionTitle(title: L("Themes"), note: WalrusArt.shared.pack.map { L("Only the built-in walrus has them. The pack “%@” is in use now.", $0.name) })
            // Chips and not one bar: on the narrowest window three names do not fit in a line, and a bar that does not fit pushes the whole window aside.
            WalrusChipFlow {
                ForEach([(Theme.calendar, L("By the calendar")), (.chosen, L("Chosen outfit")), (.plain, L("Bowler and monocle"))], id: \.0) { choice, title in
                    WalrusChip(title: title, selected: theme.wrappedValue == choice) { theme.wrappedValue = choice }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Themes"))
            Text(L("By the calendar he changes by himself, on the dates below. On all the other days he wears the bowler."))
                .font(.system(size: 12))
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(outfits, id: \.self) { outfit in
                    HStack(spacing: 10) {
                        WalrusTile(source: .shelf(outfit), size: 36)
                        themeWords(outfit)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    if outfit != outfits.last { Rectangle().fill(Palette.separator).frame(height: 1) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.fill1))
            HStack(spacing: 10) {
                Toggle(L("A party hat on your birthday"), isOn: hasBirthday).toggleStyle(.checkbox).font(.system(size: 12.5))
                if settings.wardrobe.userBirthday != nil {
                    DatePicker(L("Your birthday"), selection: birthday, displayedComponents: .date)
                        .labelsHidden()
                        .font(.system(size: 12.5))
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            Text(L("It stays on this Mac.")).font(.system(size: 11)).foregroundStyle(Palette.text3)
        }
    }

    /// One under the other, so the row fits a narrow window. An outfit named after its date has nothing more to say.
    private func themeWords(_ outfit: Outfit) -> some View {
        let name = WalrusPageText.name(outfit)
        let when = WalrusPageText.when(outfit)
        return VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.system(size: 12.5))
            if when != name {
                Text(when)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The built-in walrus and the packs that came from files.
struct WalrusPacksTab: View {
    @Bindable var model: AppModel

    private var page: WalrusPageState { model.walrusPage }
    private var active: WalrusPack? { WalrusArt.shared.pack }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WalrusSectionTitle(title: L("Packs"))
            row(
                picture: .shelf(.none),
                name: L("Boris the walrus"),
                details: [L("Drawn in code. Only he has outfits and reactions.")],
                inUse: active == nil,
                use: { model.usePack(nil) },
                remove: nil
            )
            ForEach(page.packs) { pack in
                row(
                    picture: .file(pack.baseFrames[0]),
                    name: pack.name,
                    details: details(pack),
                    inUse: active?.id == pack.id,
                    icon: pack.baseIcon,
                    use: { model.usePack(pack) },
                    remove: { model.removePack(pack) }
                )
            }
            if page.packs.isEmpty {
                VStack(spacing: 4) {
                    Text(L("No packs of your own yet")).font(.system(size: 13, weight: .semibold))
                    Text(L("A pack is a folder with a description, pictures, a menu bar icon and lines. There is no code in it."))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
    }

    private func details(_ pack: WalrusPack) -> [String] {
        var lines: [String] = []
        if let author = pack.author, !author.isEmpty { lines.append(L("by %@", author)) }
        lines.append(L("Own animation for %lld of %lld states. The rest show the base pose.", pack.poses.count, WalrusPose.allCases.count))
        lines.append(L("Languages of the lines: %@", pack.lines.keys.sorted().joined(separator: ", ")))
        return lines
    }

    private func row(picture: WalrusArt.Source, name: String, details: [String], inUse: Bool, icon: URL? = nil, use: @escaping () -> Void, remove: (() -> Void)?) -> some View {
        // The buttons go under the words: beside them, on a narrow window, the words would break in the middle.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                WalrusTile(source: picture, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    ForEach(details, id: \.self) { detail in
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    if let icon, let image = NSImage(contentsOf: icon) {
                        HStack(spacing: 6) {
                            Text(L("Menu bar icon:")).font(.system(size: 11.5)).foregroundStyle(Palette.text2).fixedSize()
                            Image(nsImage: image).resizable().renderingMode(.template).frame(width: 21, height: 18).foregroundStyle(Palette.text1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if inUse {
                    Text(L("In use")).font(.system(size: 12)).foregroundStyle(Palette.focus).frame(height: 24).fixedSize()
                } else {
                    Button(L("Use"), action: use).buttonStyle(PlainActionStyle()).fixedSize()
                }
                if let remove {
                    Button(L("Remove"), action: remove).buttonStyle(PlainActionStyle()).fixedSize()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.fill1))
        .overlay {
            if inUse {
                RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.focus, lineWidth: 2)
            }
        }
    }
}

/// Says what is wrong with a pack that did not come in, and does nothing else.
struct WalrusPackErrorSheet: View {
    var rejection: WalrusPackRejection
    var close: () -> Void

    private var items: [String] { rejection.problems.map(WalrusPageText.describe) }

    private var explanation: String {
        rejection.problems.allSatisfy(WalrusPageText.isMissing)
            ? L("The pack “%@” is missing files. Add them and import again.", rejection.name)
            : L("Something is wrong with the pack “%@”. Fix it and import again.", rejection.name)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    WalrusView(mood: .hmm, outfit: .none, size: 48, style: .simple)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Pack not imported")).font(.system(size: 14, weight: .bold))
                        Text(explanation)
                            .font(.system(size: 12.5))
                            .lineSpacing(3)
                            .foregroundStyle(Palette.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(verbatim: "•")
                                Text(item).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 12.5))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(Palette.fill1))
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(L("Copy the list")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(items.joined(separator: "\n"), forType: .string)
                    }
                    .buttonStyle(PlainActionStyle(height: 26))
                    Button(L("Got it"), action: close)
                        .buttonStyle(PlainActionStyle(primary: true, height: 26))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
            .frame(width: 440)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(Palette.pop))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        }
    }
}
