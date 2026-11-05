import AppKit
import BorisCore
import BorisCharacter

/// Shows moving frames over the button by swapping a layer's contents, so nothing is ever redrawn.
private final class FrameView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        // No fading between frames.
        layer?.actions = ["contents": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ image: CGImage, scale: CGFloat) {
        layer?.contentsScale = scale
        layer?.contents = image
    }

    /// Clicks go through to the button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The walrus in the menu bar. A timer runs only while the icon is meant to move and can be seen.
/// A still icon is the button's own template image, drawn by the system. Moving frames cannot be: changing that image
/// redraws the whole button, about 5% of a core at eight frames a second. So they go to a layer of their own,
/// painted for the menu bar's appearance, and the button holds an empty image of the same size.
@MainActor
final class WalrusIcon {
    private struct MovingFrame: Hashable {
        let frame: Frame
        let scale: Int
        let white: Bool
    }

    private struct Frame: Hashable {
        let name: PoseName
        let outfit: Outfit
        /// `nil` is the still key frame.
        let index: Int?
    }

    private static let tick: TimeInterval = 0.125

    private let button: NSStatusBarButton
    private let frameView = FrameView(frame: .zero)
    private let blank: NSImage = {
        let image = NSImage(size: Renderer.iconPoints)
        image.isTemplate = true
        return image
    }()
    private var frames: [Frame: NSImage] = [:]
    private var movingFrames: [MovingFrame: CGImage] = [:]
    private var moving = false
    private var mood: Mood?
    private var outfit = Outfit.none
    private var pack: WalrusPack?
    private var timer: Timer?
    private var phase = 0.0
    private var lastTick = Date()
    private var shown: Frame?
    /// Why nothing can be seen right now: the Mac sleeps, the display is off, the screen is locked or another user is active.
    private var hidden: Set<String> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(button: NSStatusBarButton) {
        self.button = button
        frameView.isHidden = true
        // VoiceOver reads the button, not each frame.
        frameView.setAccessibilityElement(false)
        button.addSubview(frameView, positioned: .below, relativeTo: nil)
        watchVisibility()
    }

    /// A pack's icon is a still template for each state, so all the rules below still hold: it just never moves.
    func use(_ pack: WalrusPack?) {
        guard pack != self.pack else { return }
        self.pack = pack
        frames = [:]
        refresh()
    }

    func show(_ mood: Mood, outfit: Outfit) {
        guard mood != self.mood || outfit != self.outfit else { return }
        self.outfit = outfit
        if PoseName(mood: mood) != self.mood.map({ PoseName(mood: $0) }) { phase = 0 }
        self.mood = mood
        refresh()
    }

    private var reduceMotion: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["BORIS_REDUCE_MOTION"] == "1" { return true }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var mayMove: Bool {
        guard let mood, pack == nil else { return false }
        return PoseName(mood: mood).movesInMenuBar && hidden.isEmpty && !reduceMotion
    }

    /// The button's title changes with the run count, and the frames must stay where its image is.
    func layout() {
        guard moving else { return }
        frameView.frame = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
    }

    private func refresh() {
        moving = mayMove
        button.image = moving ? blank : nil
        frameView.isHidden = !moving
        shown = nil
        layout()
        if moving {
            draw()
            guard timer == nil else { return }
            lastTick = Date()
            let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
            timer.tolerance = Self.tick / 5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            draw()
        }
    }

    private func step() {
        guard let mood else { return }
        let now = Date()
        phase = (phase + now.timeIntervalSince(lastTick) / Timeline.loop(for: mood)).truncatingRemainder(dividingBy: 1)
        lastTick = now
        draw()
    }

    private func draw() {
        guard let mood else { return }
        let name = PoseName(mood: mood)
        let frame = Frame(name: name, outfit: outfit, index: moving ? Int(phase * Double(Timeline.framesPerLoop)) : nil)
        guard frame != shown else { return }
        shown = frame
        if moving {
            showMoving(frame)
        } else {
            button.image = image(frame)
        }
    }

    private func showMoving(_ frame: Frame) {
        let scale = (button.window?.backingScaleFactor ?? 2) >= 2 ? 2 : 1
        let white = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = MovingFrame(frame: frame, scale: scale, white: white)
        if movingFrames[key] == nil {
            movingFrames[key] = Renderer.template(pose(frame), scale: scale, white: white)
        }
        if let image = movingFrames[key] { frameView.show(image, scale: CGFloat(scale)) }
    }

    private func pose(_ frame: Frame) -> SimplePose {
        let t = frame.index.map { CGFloat($0) / CGFloat(Timeline.framesPerLoop) } ?? frame.name.keyTime
        return Dress.apply(frame.outfit, to: Timeline.simple(frame.name, t: t, mono: true), mono: true)
    }

    private func image(_ frame: Frame) -> NSImage {
        if let known = frames[frame] { return known }
        if let pack, let icon = WalrusArt.shared.trayIcon(pack, pose: frame.name) {
            frames[frame] = icon
            return icon
        }
        let pose = pose(frame)
        let image = NSImage(size: Renderer.iconPoints)
        for scale in [2, 1] {
            guard let bitmap = Renderer.template(pose, scale: scale) else { continue }
            let representation = NSBitmapImageRep(cgImage: bitmap)
            representation.size = Renderer.iconPoints
            image.addRepresentation(representation)
        }
        image.isTemplate = true
        frames[frame] = image
        return image
    }

    private func watchVisibility() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let pairs: [(NotificationCenter, Notification.Name, Notification.Name)] = [
            (workspace, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification),
            (distributed, Notification.Name("com.apple.screenIsLocked"), Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, begin, end) in pairs {
            let reason = begin.rawValue
            observe(center, begin) { $0.hidden.insert(reason) }
            observe(center, end) { $0.hidden.remove(reason) }
        }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { _ in }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (WalrusIcon) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.lastTick = Date()
                self.refresh()
            }
        }
        observers.append((center, token))
    }
}
