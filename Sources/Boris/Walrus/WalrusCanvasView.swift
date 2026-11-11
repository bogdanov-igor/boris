import AppKit
import BorisCharacter
import BorisCore

/// Shows the walrus by swapping a layer's contents, so moving him redraws nothing else.
/// His lean turns that layer instead of being drawn, so the pictures already kept serve every lean.
/// A timer exists only while he is meant to move and can be seen: a still or hidden walrus costs nothing.
@MainActor
final class WalrusCanvasView: NSView {
    struct Look: Equatable {
        var pose: PoseName
        var loop: TimeInterval
        var outfit: Outfit
        var pixels: Int
        var simple: Bool
        var loops: Bool
        var pack: WalrusPack?
        var revision: Int
        var upsideDown: Bool

        /// A change of any of these starts the animation over. A new reaction does not.
        func sameArt(as other: Look) -> Bool {
            pose == other.pose && outfit == other.outfit && pixels == other.pixels && simple == other.simple && pack?.id == other.pack?.id
        }
    }

    #if DEBUG
    /// Off-screen measuring needs a walrus who believes he is seen.
    static var pretendVisible = false
    static var ticks = 0

    func refreshForTest() {
        refresh()
    }

    func leanForTest(_ degrees: CGFloat) {
        leaning = degrees
        placeArt()
    }
    #endif

    private static let maxKept = 48

    var stage: WalrusStage?
    var onPoke: (() -> Void)?
    var look: Look? {
        didSet {
            guard look != oldValue else { return }
            if let look, let oldValue, look.sameArt(as: oldValue) {
                refresh()
            } else {
                since = Date()
                lean = Lean(seed: .random(in: .min ... .max))
                kept = [:]
                shown = nil
                // Each drawing leans around its own point.
                placeArt()
                refresh()
            }
        }
    }

    private var picture: CGImage?
    /// The picture's own layer, which his lean turns.
    private let art = CALayer()
    /// Degrees the picture is turned now.
    private var leaning: CGFloat = 0
    private var timer: Timer?
    private var since = Date()
    /// He leans now and then instead of rocking, and starts upright with every new look.
    private var lean = Lean(seed: .random(in: .min ... .max))
    private var kept: [WalrusArt.Source: CGImage] = [:]
    private var shown: WalrusArt.Source?
    private var gaze: WalrusFrame.Gaze?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pointerWatch: (view: NSView, area: NSTrackingArea)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        art.contentsGravity = .resizeAspect
        // No fading between frames, and no gliding: the timer shows each step of a turn.
        art.actions = ["contents": NSNull(), "transform": NSNull(), "position": NSNull(), "bounds": NSNull(), "anchorPoint": NSNull()]
        art.contentsScale = 2
        layer?.addSublayer(art)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        art.contents = picture
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeArt()
    }

    /// Only for snapshots, which do not go through the layer.
    override func draw(_ dirtyRect: NSRect) {
        guard let picture, let context = NSGraphicsContext.current?.cgContext else { return }
        let side = min(bounds.width, bounds.height)
        let scale = side / CGFloat(max(picture.width, picture.height))
        let width = CGFloat(picture.width) * scale, height = CGFloat(picture.height) * scale
        let place = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        let share = artPivot(down: false)
        let pivot = CGPoint(x: place.minX + share.x * place.width, y: place.minY + share.y * place.height)
        context.translateBy(x: pivot.x, y: pivot.y)
        context.rotate(by: -leaning * .pi / 180)
        context.translateBy(x: -pivot.x, y: -pivot.y)
        context.draw(picture, in: place)
    }

    /// The point he leans around, as a share of the picture from its bottom left, or from its top left when y counts downwards.
    private func artPivot(down: Bool) -> CGPoint {
        let pivot = Renderer.leanPivot(simple: look?.simple ?? false)
        return CGPoint(x: pivot.x, y: down ? pivot.y : 1 - pivot.y)
    }

    /// Whether the picture's layer counts y downwards on screen. AppKit flips layers on the way down to match its views,
    /// so this depends on what the view sits in, and is worked out each time rather than assumed.
    private var layerCountsDown: Bool {
        var down = false
        var current = layer
        while let one = current {
            if one.isGeometryFlipped { down.toggle() }
            current = one.superlayer
        }
        return down
    }

    /// The picture fills the largest centred square, turned by his lean around the point the drawing tilts around.
    private func placeArt() {
        let side = min(bounds.width, bounds.height)
        let down = layerCountsDown
        let pivot = artPivot(down: down)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.setAffineTransform(.identity)
        art.anchorPoint = pivot
        art.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        art.position = CGPoint(x: (bounds.width - side) / 2 + pivot.x * side, y: (bounds.height - side) / 2 + pivot.y * side)
        // The drawing counts y downwards. Where the layer counts upwards, the same lean turns the other way round.
        art.setAffineTransform(CGAffineTransform(rotationAngle: (down ? 1 : -1) * leaning * .pi / 180))
        CATransaction.commit()
    }

    // MARK: - Being seen

    private static var reduceMotion: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["BORIS_REDUCE_MOTION"] == "1" { return true }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var isSeen: Bool {
        #if DEBUG
        if Self.pretendVisible { return true }
        #endif
        guard let window, window.isVisible, window.occlusionState.contains(.visible) else { return false }
        return !isHiddenOrHasHiddenAncestor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        if let pointerWatch { pointerWatch.view.removeTrackingArea(pointerWatch.area) }
        pointerWatch = nil
        guard let window else {
            timer?.invalidate()
            timer = nil
            kept = [:]
            return
        }
        observe(.default, NSWindow.didChangeOcclusionStateNotification, of: window)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, of: nil)
        watchPointer(in: window)
        // Which way its layer counts may have changed with the window.
        placeArt()
        refresh()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refresh()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, of object: AnyObject?) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.append((center, token))
    }

    // MARK: - Drawing

    private func refresh() {
        show(at: Date())
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let look else { return }
        let seen = isSeen
        let actLeft = self.act(at: Date())?.left
        guard let delay = WalrusMotion.nextFrame(moves: moves(look), visible: seen, reduceMotion: Self.reduceMotion, actLeft: actLeft, interval: frameInterval(look)) else {
            // Nothing to show again soon, so nothing to keep.
            kept = [:]
            return
        }
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        next.tolerance = delay / 5
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func tick() {
        #if DEBUG
        Self.ticks += 1
        #endif
        refresh()
    }

    /// The same rule as in the menu bar: what can last for hours stays still, unless the preview asks for it.
    private func moves(_ look: Look) -> Bool {
        if let pack = look.pack, pack.frames(for: look.pose.packPose).count < 2 { return false }
        return look.loops || look.pose.movesInMenuBar
    }

    private func frameInterval(_ look: Look) -> TimeInterval {
        look.pack.map { 1 / $0.framesPerSecond } ?? WalrusMotion.frameInterval
    }

    private func act(at now: Date) -> (act: Act, t: Double, left: TimeInterval)? {
        guard let stage, let look, look.pack == nil, let running = stage.play.current(now: now, restricted: stage.isRestricted(look.pose)) else { return nil }
        return (running.act, running.t, running.act.duration * (1 - running.t))
    }

    private func show(at now: Date) {
        guard let look else { return }
        let (source, degrees) = source(for: look, at: now)
        if degrees != leaning {
            leaning = degrees
            placeArt()
        }
        guard source != shown else { return }
        shown = source
        let image: CGImage?
        if isTimeless(source) {
            image = WalrusArt.shared.still(source, pixels: look.pixels, simple: look.simple)
        } else {
            if kept[source] == nil {
                if kept.count >= Self.maxKept { kept = [:] }
                kept[source] = WalrusArt.shared.picture(source, pixels: look.pixels, simple: look.simple)
            }
            image = kept[source]
        }
        // A pack's file can vanish or spoil while he is on screen. The built-in walrus is better than an empty place.
        let shownImage = image ?? WalrusArt.shared.still(.drawn(WalrusFrame(name: look.pose, outfit: look.outfit)), pixels: look.pixels, simple: look.simple)
        picture = shownImage
        art.contents = shownImage
    }

    /// A key frame looks the same every time, so it can be shared and kept for good. The rest of a pack's frames are only kept while they move.
    private func isTimeless(_ source: WalrusArt.Source) -> Bool {
        switch source {
        case .file(let url):
            return look.map { $0.pack?.frames(for: $0.pose.packPose).first == url } ?? false
        case .drawn(let frame):
            return frame.step == nil && frame.act == nil && frame.gaze == nil
        case .shelf:
            return true
        }
    }

    /// The picture to show, drawn upright, and how far to turn it.
    private func source(for look: Look, at now: Date) -> (WalrusArt.Source, CGFloat) {
        let elapsed = max(0, now.timeIntervalSince(since))
        let moving = WalrusMotion.nextFrame(moves: moves(look), visible: isSeen, reduceMotion: Self.reduceMotion) != nil
        if let pack = look.pack {
            let frames = pack.frames(for: look.pose.packPose)
            let index = moving ? Int(elapsed * pack.framesPerSecond) % frames.count : 0
            return (.file(frames[index]), 0)
        }
        var frame = WalrusFrame(name: look.pose, outfit: look.outfit)
        if moving {
            frame.step = Int((elapsed / look.loop).truncatingRemainder(dividingBy: 1) * Double(Timeline.framesPerLoop))
            frame.firstLoop = look.pose == .alarm && elapsed < look.loop
            frame.blink = look.pose.blinks && Timeline.isBlinking(elapsed: elapsed)
        }
        if let running = act(at: now), let stage {
            let t = Self.reduceMotion ? running.act.stillTime : running.t
            frame.act = running.act
            frame.actStep = Int(t * Double(WalrusFrame.actSteps))
            frame.softPoke = stage.play.isSoftPoke
        }
        let degrees = frame.showsLean ? lean.degrees(at: elapsed, moving: moving) : 0
        if look.pose.followsPointer { frame.gaze = gaze }
        frame.upsideDown = look.upsideDown
        return (.drawn(frame), degrees)
    }

    // MARK: - The pointer

    private func watchPointer(in window: NSWindow) {
        guard stage != nil, let content = window.contentView else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        content.addTrackingArea(area)
        pointerWatch = (content, area)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The drawing's y points down.
        let next = WalrusFrame.Gaze(toward: point.x - bounds.midX, bounds.midY - point.y)
        guard next != gaze else { return }
        gaze = next
        show(at: Date())
    }

    override func mouseExited(with event: NSEvent) {
        guard gaze != nil else { return }
        gaze = nil
        show(at: Date())
    }

    // MARK: - Clicks

    override func hitTest(_ point: NSPoint) -> NSView? {
        onPoke == nil ? nil : super.hitTest(point)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if onPoke != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPoke?() }
    }
}
