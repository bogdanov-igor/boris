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
    private var iconWatch = IconWatch()
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
        startLog()
        registerAutostartOnce()
        if managesAutostart, launch.handOverToAgentIfNeeded() {
            AppLog.note(.handedToAgent)
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
                connect.repair(model, asker: .repairOnRequestCard)
                if connect.stage != .closed { main?.show() }
            } else {
                main?.show()
                connect.begin(model)
            }
        }
        actions.applyHotKey = { [weak self] in self?.registerHotKey() }
        actions.isAutostartAvailable = { [weak self] in self?.managesAutostart ?? false }
        actions.autostartState = { [weak self] in self?.launch.autostartState ?? .off }
        actions.setAutostart = { [weak self, weak model] on in
            guard let self, self.managesAutostart else { return true }
            return self.launch.setAutostart(on) { model?.persistNow() }
        }
        actions.openLoginItems = { SMAppService.openSystemSettingsLoginItems() }
        model.onPresenceChange = { [weak self, weak statusBar, weak model] in
            statusBar?.update()
            guard let model else { return }
            self?.power.update(shouldHold: model.shouldKeepAwake)
        }

        model.notifications.onOpen = { [weak model] route in model?.open(route) }
        model.notifications.refreshPermission()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak model] _ in
            AppLog.note(.macWoke)
            MainActor.assumeIsolated { model?.noteWake() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            AppLog.note(.macSleeping)
        })
        launch.listen { [weak statusBar] in statusBar?.toggleMiniWindow() }
        registerHotKey()
        model.start()
        model.updates.start()
        surface.start()
        startTicking()
        if model.isFirstLaunch { main.show() }
        if managesAutostart, launch.shouldReopenSettings() { settings.show(.general) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.remote.quit()
        model?.hooks.quit()
        model?.chat.quit()
        model?.persistNow()
        SettingsLog.flush()
        AppLog.note(.appQuit)
        AppLog.flush()
    }

    /// Only here, in the app itself: tests, snapshots and tools have no log file.
    private func startLog() {
        AppLog.add(AppLogStore())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? BorisCore.version
        #if DEBUG
        AppLog.note(.appStarted, .version(version), .word(.debugBuild))
        #else
        AppLog.note(.appStarted, .version(version), .word(.releaseBuild))
        #endif
    }

    private func registerAutostartOnce() {
        let key = "autostartConfigured"
        guard managesAutostart, !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try launch.agent.register()
            AppLog.note(.autostartChanged, .flag(true))
        } catch {
            AppLog.note(.autostartFailed, .failure(error))
        }
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
        // The window comes forward once, when the notice appears. Coming forward at every tick would take the keyboard from the person until they answer.
        if iconWatch.note(visible: statusBar.isIconVisible, wanted: model.settings.surfaces.icon, seconds: seconds), model.noteIconHidden() {
            mainWindow?.show()
        }
    }

    private func registerHotKey() {
        guard let model else { return }
        hotKey.unregister()
        model.hotKeyTaken = false
        defer { model.settings.surfaces = model.settings.surfaces.withWayIn(hotKeyWorks: model.hotKeyWorks) }
        guard model.settings.hotKeyEnabled else {
            AppLog.note(.hotKeyOff)
            return
        }
        do {
            try hotKey.register(model.settings.hotKey) { [weak self] in self?.statusBar?.toggleMiniWindow() }
            AppLog.note(.hotKeyRegistered, .keys(model.settings.hotKey.label))
        } catch {
            model.hotKeyTaken = true
            AppLog.note(.hotKeyTaken, .keys(model.settings.hotKey.label))
        }
    }
}
