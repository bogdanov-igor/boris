import AppKit
import BorisCharacter
import BorisCore
import SwiftUI

/// Owns the menu bar item, its alarm mark and the mini window.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let alarmDot = NSView()
    private let miniAnchor = MiniAnchor()
    private var icon: WalrusIcon?
    var onOpenMain: (() -> Void)?
    var onOpenSettings: ((SettingsSection) -> Void)?

    init(model: AppModel) {
        self.model = model
        Self.askForPlaceOnce()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        #if DEBUG
        // Tests must not add a second walrus to the person's menu bar.
        if ProcessInfo.processInfo.environment["BORIS_NO_STATUS_ITEM"] == "1" { item.isVisible = false }
        #endif
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: MiniWindowView(model: model, openMain: { [weak self] in
            self?.closeMiniWindow()
            self?.onOpenMain?()
        }))

        if let button = item.button {
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            alarmDot.wantsLayer = true
            alarmDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            alarmDot.layer?.cornerRadius = Renderer.alarmDot.radius
            alarmDot.isHidden = true
            button.addSubview(alarmDot)
            icon = WalrusIcon(button: button)
        }
        update()
    }

    /// Redraws the icon, the counter and the mark from the model.
    func update() {
        if item.isVisible != iconWanted { item.isVisible = iconWanted }
        guard let button = item.button else { return }
        icon?.use(WalrusArt.shared.pack)
        icon?.show(model.mood, outfit: model.outfit)
        let count = model.requestCount
        button.title = count > 0 ? " \(count)" : ""
        alarmDot.isHidden = !model.hasAlarm
        icon?.layout()
        placeAlarmDot(on: button)
        button.setAccessibilityLabel(Self.description(mood: model.mood, waiting: count))
    }

    private var iconWanted: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["BORIS_NO_STATUS_ITEM"] == "1" { return false }
        #endif
        return model.settings.surfaces.icon
    }

    /// The dot has its own layer, because a template image loses its colour. It sits where the drawing leaves room for it.
    private func placeAlarmDot(on button: NSStatusBarButton) {
        guard !alarmDot.isHidden, let image = button.cell?.imageRect(forBounds: button.bounds) else { return }
        let dot = Renderer.alarmDot
        let y = button.isFlipped ? image.minY + dot.y - dot.radius : image.maxY - dot.y - dot.radius
        alarmDot.frame = NSRect(x: image.minX + dot.x - dot.radius, y: y, width: 2 * dot.radius, height: 2 * dot.radius)
    }

    /// A new item goes to the far left of the others. On a full menu bar that is behind the notch, out of sight,
    /// so the first launch asks for a place among them. Dragging the icon with ⌘ held overrides this.
    private static func askForPlaceOnce() {
        let key = "NSStatusItem Preferred Position Item-0"
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(firstPlaceFromRight, forKey: key)
    }

    private static let firstPlaceFromRight: CGFloat = 300

    /// Whether the icon fits in the menu bar. A pushed-out icon's window sits outside every screen or behind the notch.
    /// Occlusion is not used: a locked screen or a full-screen app would count as hidden too.
    var isIconVisible: Bool {
        guard let frame = item.button?.window?.frame else { return false }
        return NSScreen.screens.contains { Self.fits(frame, on: $0.frame, left: $0.auxiliaryTopLeftArea, right: $0.auxiliaryTopRightArea) }
    }

    static func fits(_ icon: NSRect, on screen: NSRect, left: NSRect?, right: NSRect?) -> Bool {
        guard screen.intersects(icon) else { return false }
        guard let left, let right else { return true }
        return icon.maxX <= left.maxX || icon.minX >= right.minX
    }

    @objc private func buttonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggleMiniWindow()
        }
    }

    /// Behind the notch there is nothing to hang the mini window on, so the main window opens instead. The same goes when the person turned it off.
    func toggleMiniWindow() {
        let surfaces = model.settings.surfaces
        guard surfaces.mini, isIconVisible || !surfaces.icon || popover.isShown else {
            onOpenMain?()
            return
        }
        popover.isShown ? closeMiniWindow() : openMiniWindow()
    }

    func openMiniWindow() {
        guard let anchor = miniWindowAnchor, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        model.miniWindowDidOpen()
    }

    private var miniWindowAnchor: NSView? {
        if model.settings.surfaces.icon { return item.button }
        let screen = SurfaceGeometry.screen(for: model.settings.surfaceScreen, among: SurfaceScreens.current(), cursor: NSEvent.mouseLocation)
        return screen.flatMap { miniAnchor.view(at: SurfaceGeometry.miniAnchor(on: $0)) }
    }

    func closeMiniWindow() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        miniAnchor.hide()
        model.setLookingClosely(false)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        add(L("Open Boris"), #selector(openMain), to: menu)
        let now = Date()
        if model.quiet.isOn(now: now), let until = model.quiet.until {
            let title = until.timeIntervalSince(now) > Self.indefinitely / 2 ? L("Do not disturb is on") : L("Do not disturb until %@", WorkFormat.time(until))
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").state = .on
            add(L("Turn off Do not disturb"), #selector(stopQuiet), to: menu)
        } else {
            let quiet = NSMenuItem(title: L("Do not disturb"), action: nil, keyEquivalent: "")
            let choices = NSMenu()
            add(L("For an hour"), #selector(quietHour), to: choices)
            add(L("For 4 hours"), #selector(quietFourHours), to: choices)
            add(L("Until turned off"), #selector(quietUntilOff), to: choices)
            quiet.submenu = choices
            menu.addItem(quiet)
        }
        menu.addItem(.separator())
        add(L("Settings…"), #selector(openSettings), key: ",", to: menu)
        add(L("About Boris"), #selector(openAbout), to: menu)
        menu.addItem(.separator())
        add(L("Quit"), #selector(quit), key: "q", to: menu)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func add(_ title: String, _ action: Selector, key: String = "", to menu: NSMenu) {
        menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
    }

    /// Longer than anyone leaves a Mac on.
    private static let indefinitely: TimeInterval = 10 * 365 * 24 * 3600

    @objc private func openMain() { onOpenMain?() }
    @objc private func quietHour() { model.startQuiet(for: 3600) }
    @objc private func quietFourHours() { model.startQuiet(for: 4 * 3600) }
    @objc private func quietUntilOff() { model.startQuiet(for: Self.indefinitely) }
    @objc private func stopQuiet() { model.stopQuiet() }
    @objc private func openSettings() { onOpenSettings?(.general) }
    @objc private func openAbout() { onOpenSettings?(.about) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// What the icon means, for VoiceOver.
    private static func description(mood: Mood, waiting: Int) -> String {
        let word: String
        switch mood {
        case .alarm: word = L("Something broke")
        case .broken: word = L("Claude changed its data format")
        case .waiting: word = L("A session needs you")
        case .tired: word = L("Limit reached")
        case .alert: word = L("A run has gone silent")
        case .happy: word = L("Work finished")
        case .hmm: word = L("Work stopped")
        case .working: word = L("Working")
        case .sleeping: word = L("Nothing is happening")
        }
        return "Boris: \(word). " + L("Waiting for you: %lld", waiting)
    }
}
