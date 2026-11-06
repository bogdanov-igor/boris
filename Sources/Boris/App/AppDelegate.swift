import AppKit
import BorisCore
import BorisData
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launch: LaunchCoordinator
    private var model: AppModel?
    private var statusBar: StatusBarController?
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private var surface: SurfaceController?
    private let actions = SettingsActions()
    private let connect = ConnectFlow()
    private let power = PowerGuard()
    private let hotKey = HotKeyController()
    private var tickTimer: Timer?
    private var hiddenFor: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// A developer's copy must not take the launch agent's place from the installed app.
    private var managesAutostart: Bool {
        #if DEBUG
        false
        #else
        isBundled
        #endif
    }

    init(launch: LaunchCoordinator) {
        self.launch = launch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if DevSnapshot.runIfRequested() { return }
        guard DevSnapshot.mayStartForReal else {
            #if DEBUG
            FileHandle.standardError.write(Data("A debug build starts as the real app only with BORIS_ALLOW_UI=1.\n".utf8))
            #endif
            exit(2)
        }
        registerAutostartOnce()
        if managesAutostart, launch.handOverToAgentIfNeeded() {
            NSApp.terminate(nil)
            return
        }

        let model = AppModel()
        self.model = model
        let statusBar = StatusBarController(model: model)
        self.statusBar = statusBar
        let main = MainWindowController(model: model, connect: connect)
        mainWindow = main
        let settings = SettingsWindowController(model: model, connect: connect, actions: actions)
        settingsWindow = settings
        let surface = SurfaceController(model: model)
        self.surface = surface
        surface.onOpenMain = { [weak main] in main?.show() }
        surface.onOpenSettings = { [weak settings] section in settings?.show(section) }
        surface.onIconSwitch = { [weak statusBar] in statusBar?.update() }

        statusBar.onOpenMain = { [weak main] in main?.show() }
        model.onShowMainWindow = { [weak main] in main?.show() }
        statusBar.onOpenSettings = { [weak settings] section in settings?.show(section) }
        main.onOpenSettings = { [weak settings] section in settings?.show(section) }
        model.hooks.onConnect = { [weak main, weak model, connect] in
            guard let model else { return }
            // Repairing is one button: the person already agreed to these entries.
            if model.hooks.connection == .damaged {
                connect.repair(model)
                if connect.stage != .closed { main?.show() }
            } else {
                main?.show()
                connect.begin(model)
            }
        }
        actions.applyHotKey = { [weak self] in self?.registerHotKey() }
        actions.isAutostartAvailable = { [weak self] in self?.managesAutostart ?? false }
        actions.isAutostartOn = { [weak self] in self?.launch.agent.status == .enabled }
        actions.setAutostart = { [weak self] on in
            guard let self, self.managesAutostart else { return }
            if on { try? self.launch.agent.register() } else { try? self.launch.agent.unregister() }
        }
        model.onPresenceChange = { [weak self, weak statusBar, weak model] in
            statusBar?.update()
            guard let model else { return }
            self?.power.update(shouldHold: model.settings.keepAwake && model.work.isWorking)
        }

        model.notifications.onOpen = { [weak model] route in model?.open(route) }
        model.notifications.refreshPermission()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.noteWake() }
        })
        launch.listen { [weak statusBar] in statusBar?.toggleMiniWindow() }
        registerHotKey()
        model.start()
        surface.start()
        startTicking()
        if model.isFirstLaunch { main.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.hooks.quit()
        model?.persistNow()
    }

    private func registerAutostartOnce() {
        let key = "autostartConfigured"
        guard managesAutostart, !UserDefaults.standard.bool(forKey: key) else { return }
        try? launch.agent.register()
        UserDefaults.standard.set(true, forKey: key)
    }

    private func startTicking() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(seconds: 30) }
        }
    }

    private func tick(seconds: TimeInterval) {
        guard let model, let statusBar else { return }
        // Moods with an end time need redrawing even when no file changes, and another program may have edited the settings.
        model.hooks.refresh()
        model.refreshPresence()
        hiddenFor = statusBar.isIconVisible || !model.settings.surfaces.icon ? 0 : hiddenFor + seconds
        // Once, when the notice appears. Doing this on every tick would take the keyboard from the person twice a minute.
        if hiddenFor >= 60, model.noteIconHidden() { mainWindow?.show() }
    }

    private func registerHotKey() {
        guard let model else { return }
        hotKey.unregister()
        model.hotKeyTaken = false
        defer { model.settings.surfaces = model.settings.surfaces.withWayIn(hotKeyWorks: model.hotKeyWorks) }
        guard model.settings.hotKeyEnabled else { return }
        do {
            try hotKey.register(model.settings.hotKey) { [weak self] in self?.statusBar?.toggleMiniWindow() }
        } catch {
            model.hotKeyTaken = true
        }
    }
}
