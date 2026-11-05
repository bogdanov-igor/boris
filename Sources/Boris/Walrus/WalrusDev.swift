#if DEBUG
import AppKit
import BorisCharacter
import BorisCore
import SwiftUI

/// For checking the walrus without clicking. `BORIS_OUTFIT` and `BORIS_MOOD` dress and pose him on any screen, `BORIS_PACK=1` gives him a made-up pack, and `BORIS_WALRUS_LINE=1` makes him speak.
@MainActor
enum WalrusDev {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static func dress(_ model: AppModel) {
        let outfit = environment["BORIS_OUTFIT"].flatMap(Outfit.init(rawValue:))
        model.showWalrusForSnapshot(mood: environment["BORIS_MOOD"].flatMap(mood), outfit: outfit)
        if environment["BORIS_PACK"] == "1" { WalrusArt.shared.pack = makePack(in: model.packShelf) }
        if environment["BORIS_WALRUS_LINE"] == "1" {
            model.walrus.sayForSnapshot(L("We shall answer in the notch, we shall answer in the menu bar. We shall never surrender."), count: 1)
        }
    }

    private static func mood(_ name: String) -> Mood? {
        switch name {
        case "alarm": return .alarm
        case "broken": return .broken
        case "waiting": return .waiting
        case "tired": return .tired
        case "alert": return .alert
        case "happy": return .happy
        case "hmm": return .hmm
        case "working": return .working(agents: 3)
        case "sleeping": return .sleeping
        default: return nil
        }
    }

    /// The states of the Walrus page that cannot be reached by data alone.
    static func prepare(_ screen: String, model: AppModel, long: Bool) {
        let page = model.walrusPage
        model.page = .walrus
        switch screen {
        case "walrusThemes":
            page.tab = .themes
        case "walrusPacks":
            let pack = makePack(in: model.packShelf, name: long ? "Борис в отпуске, в длинной-предлинной шляпе и с очень подробным названием" : "Борис в отпуске")
            model.usePack(pack)
            page.tab = .packs
        case "walrusError":
            if long {
                page.rejection = WalrusPackRejection(name: "Борис в отпуске, в длинной-предлинной шляпе и с очень подробным названием", problems: [.noBasePose, .noLinesForCue(.limit), .noTrayIcon] + (1...30).map { .badImage("poses/working/\($0).png") })
            } else {
                page.rejection = rejectionOfIncompletePack(on: model.packShelf)
            }
        case "walrusLine":
            model.page = .now
            model.walrus.sayForSnapshot(
                L("An agent fell in %@. This is not the end. It is not even the beginning of the end.", long ? "a-very-long-project-name-that-nobody-would-ever-want-to-type-by-hand-more-than-once" : "shop-api"),
                count: 12
            )
        default:
            break
        }
        if long { page.showLineForSnapshot(L("We shall answer in the notch, we shall answer in the menu bar. We shall never surrender.")) }
    }

    /// One outfit or pack on every surface side by side, the menu bar included, which a snapshot cannot otherwise reach.
    static func surfaces(_ model: AppModel) -> some View {
        WalrusSurfacesSheet(model: model)
    }

    /// `BORIS_WALRUS_CPU=seconds` prints what the walrus costs. It stays off-screen.
    static func measureIfRequested() -> Bool {
        guard let seconds = environment["BORIS_WALRUS_CPU"].flatMap(TimeInterval.init) else { return false }
        WalrusCanvasView.pretendVisible = true
        Task { @MainActor in
            for (name, mood) in [("sleeping", Mood.sleeping), ("waiting", .waiting), ("working", .working(agents: 3))] {
                let host = NSHostingView(rootView: WalrusView(mood: mood, outfit: .none, size: 190))
                let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 190, height: 190), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.orderBack(nil)
                // One loop to fill the kept pictures, which only happens once.
                try? await Task.sleep(for: .seconds(4))
                WalrusCanvasView.ticks = 0
                let before = cpuSeconds()
                try? await Task.sleep(for: .seconds(seconds))
                let spent = cpuSeconds() - before
                print("\(name): \(String(format: "%.2f", spent / seconds * 100))% of a core, \(WalrusCanvasView.ticks) timer fires in \(Int(seconds)) s")
                window.orderOut(nil)
            }
            exit(0)
        }
        return true
    }

    private static func cpuSeconds() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return TimeInterval(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    /// A pack of made-up pictures, read through the same door as a real one.
    @discardableResult
    static func makePack(in shelf: WalrusPackShelf, name: String = "Борис в отпуске") -> WalrusPack? {
        let source = writePackFolder(name: name)
        defer { try? FileManager.default.removeItem(at: source) }
        return try? shelf.add(from: source).get()
    }

    /// What the real import says about a pack with files missing.
    private static func rejectionOfIncompletePack(on shelf: WalrusPackShelf) -> WalrusPackRejection? {
        let source = writePackFolder(name: "Борис в отпуске")
        defer { try? FileManager.default.removeItem(at: source) }
        let manager = FileManager.default
        try? manager.removeItem(at: source.appendingPathComponent("poses/base"))
        try? manager.removeItem(at: source.appendingPathComponent("icon/base.png"))
        let lines = ["poke": ["Я в отпуске."], "request": ["Вас ждут."], "finish": ["Готово."], "failure": ["Упало."]]
        try? JSONSerialization.data(withJSONObject: lines).write(to: source.appendingPathComponent("lines/ru.json"))
        if case .failure(let rejection) = shelf.add(from: source) { return rejection }
        return nil
    }

    private static func writePackFolder(name: String) -> URL {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("boris-dev-pack-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        try? manager.createDirectory(at: source, withIntermediateDirectories: true)
        func folder(_ path: String) -> URL {
            let url = source.appendingPathComponent(path, isDirectory: true)
            try? manager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ colour: (CGFloat, CGFloat, CGFloat), mark: CGFloat, to url: URL, side: Int = 256) {
            guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let s = CGFloat(side)
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
            context.fillEllipse(in: CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8))
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: s * 0.3, y: s * 0.45, width: s * 0.4 * mark, height: s * 0.1))
            guard let image = context.makeImage(), let target = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(target, image, nil)
            CGImageDestinationFinalize(target)
        }
        try? JSONSerialization.data(withJSONObject: ["name": name, "author": "Выдуманный автор", "baseLanguage": "ru", "framesPerSecond": 4], options: .prettyPrinted).write(to: source.appendingPathComponent("pack.json"))
        write((0.2, 0.5, 0.8), mark: 1, to: folder("poses/base").appendingPathComponent("1.png"))
        for step in 1...4 {
            write((0.1, 0.6, 0.4), mark: CGFloat(step) / 4, to: folder("poses/working").appendingPathComponent("\(step).png"))
        }
        write((0.8, 0.2, 0.2), mark: 0.5, to: folder("poses/alarm").appendingPathComponent("1.png"))
        write((0, 0, 0), mark: 1, to: folder("icon").appendingPathComponent("base.png"), side: 36)
        let lines: [String: [String]] = [
            "poke": ["Я в отпуске."],
            "request": ["Вас ждут в {project}.", "Вас ждут."],
            "finish": ["Готово."],
            "failure": ["Упало в {project}.", "Упало."],
            "limit": ["Лимит близко."],
        ]
        try? JSONSerialization.data(withJSONObject: lines).write(to: folder("lines").appendingPathComponent("ru.json"))
        return source
    }
}

private struct WalrusSurfacesSheet: View {
    @Bindable var model: AppModel

    private var trayImages: [CGImage] {
        let pose = PoseName(mood: model.mood)
        let frame = WalrusFrame(name: pose, outfit: model.outfit)
        return [2, 1].compactMap { Renderer.template(frame.simplePose(mono: true), scale: $0) }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(spacing: 8) {
                if let pack = WalrusArt.shared.pack, let icon = WalrusArt.shared.trayIcon(pack, pose: PoseName(mood: model.mood)) {
                    Image(nsImage: icon).resizable().renderingMode(.template).frame(width: 21, height: 18).foregroundStyle(Palette.text1)
                } else {
                    ForEach(trayImages, id: \.width) { image in
                        Image(decorative: image, scale: CGFloat(image.width) / 21).renderingMode(.template).foregroundStyle(Palette.text1)
                    }
                }
                Text(verbatim: "tray").font(.system(size: 11))
            }
            surface("notch 28", size: 28, style: .simple)
            surface("mini 40", size: 40, style: .simple)
            surface("shelf 72", size: 72, style: .simple)
            surface("about 120", size: 120, style: .full)
            surface("sidebar 190", size: 190, style: .full)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.window)
        .foregroundStyle(Palette.text1)
    }

    private func surface(_ name: String, size: CGFloat, style: WalrusView.Style) -> some View {
        VStack(spacing: 8) {
            WalrusView(mood: model.mood, outfit: model.outfit, size: size, style: style)
            Text(verbatim: name).font(.system(size: 11))
        }
    }
}
#endif
