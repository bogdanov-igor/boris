import AppKit
import BorisCore
import BorisData
import SwiftUI

enum MainPhrases {
    static func sessionsAtWork(_ count: Int) -> String {
        count == 1 ? L("%lld session at work", count) : L("%lld sessions at work", count)
    }
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let connect: ConnectFlow
    private var window: NSWindow?
    var onOpenSettings: ((SettingsSection) -> Void)?

    init(model: AppModel, connect: ConnectFlow) {
        self.model = model
        self.connect = connect
    }

    func show() {
        if window == nil {
            let host = WindowFit.host(MainWindowView(model: model, connect: connect, openSettings: { [weak self] section in
                self?.onOpenSettings?(section)
            }))
            let created = NSWindow(contentViewController: host)
            created.title = "Boris"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isMovableByWindowBackground = true
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.setContentSize(NSSize(width: 1200, height: 800))
            created.minSize = NSSize(width: 900, height: 600)
            created.setFrameAutosaveName("main")
            if !created.setFrameUsingName("main") { created.center() }
            if let visible = (created.screen ?? NSScreen.main)?.visibleFrame {
                created.setFrame(WindowFit.fitted(created.frame, in: visible), display: false)
            }
            window = created
        }
        if window?.isVisible != true { AppLog.note(.windowOpened, .word(.mainWindow)) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.setLookingClosely(true, from: .mainWindow)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.acknowledgeAlarm()
    }

    func windowWillClose(_ notification: Notification) {
        AppLog.note(.windowClosed, .word(.mainWindow))
        model.setLookingClosely(false, from: .mainWindow)
    }
}

struct MainWindowView: View {
    @Bindable var model: AppModel
    var connect: ConnectFlow
    var openSettings: (SettingsSection) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, openSettings: openSettings)
            Rectangle().fill(Palette.separator).frame(width: 1)
            ZStack(alignment: .bottomTrailing) {
                PageContent(model: model, connect: connect, openSettings: openSettings)
                VStack(alignment: .trailing, spacing: 12) {
                    if model.offerConnecting, connect.stage == .closed {
                        ConnectOffer(model: model, connect: connect)
                    }
                    if model.showIconNotice {
                        IconNotice(model: model, openSettings: openSettings)
                    }
                }
                .padding(20)
                ConnectSheet(model: model, connect: connect)
            }
        }
        .overlay(alignment: .bottomLeading) {
            WalrusLineOverlay(stage: model.walrus).padding(EdgeInsets(top: 0, leading: 218, bottom: 110, trailing: 0))
        }
        // A text whose values stay the same would otherwise keep the old language while the window is open.
        .id(model.settings.language)
        .background(Palette.window)
        .foregroundStyle(Palette.text1)
        .ignoresSafeArea()
        .onChange(of: model.settings.displayMode) { _, mode in
            if !model.page.isShown(in: mode) { model.page = .now }
        }
    }
}

private struct Sidebar: View {
    @Bindable var model: AppModel
    var openSettings: (SettingsSection) -> Void

    private var mode: Binding<DisplayMode> {
        Binding { model.settings.displayMode } set: { model.settings.displayMode = $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 38)
            ForEach(AppPage.allCases.filter { $0.isShown(in: model.settings.displayMode) }) { page in
                item(page.title, selected: model.page == page, badge: page == .requests ? model.requestCount : 0) {
                    model.choose(page)
                }
            }
            item(L("Settings"), selected: false, badge: 0) { openSettings(.general) }
            Spacer(minLength: 8)
            SidebarWalrus(model: model, openAbout: { openSettings(.about) })
                .padding(.bottom, 10)
            ChoiceBar(options: [(DisplayMode.simple, L("Simple")), (DisplayMode.technical, L("Technical"))], selection: mode, label: L("View"), stretches: true)
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 12, trailing: 10))
        .frame(width: 210)
        .background(Palette.side)
    }

    private func item(_ title: String, selected: Bool, badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if badge > 0 {
                    Text(verbatim: "\(badge)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Palette.waiting))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(selected ? Palette.fill2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PageContent: View {
    @Bindable var model: AppModel
    var connect: ConnectFlow
    var openSettings: (SettingsSection) -> Void

    private var subtitle: String {
        if model.page == .activity { return L("Actions of all sessions in one feed") }
        return model.page == .now ? WorkFormat.today(model.now) : ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // The page of projects has a header of its own, with the way back and its filters.
            if model.page != .projects {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.page.title).font(.system(size: 18, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.text2).lineLimit(1)
                    if model.page == .walrus { WalrusPageTabs(model: model) }
                    if model.page == .requests { RequestsHeader(model: model) } else { Spacer(minLength: 0) }
                    if model.page == .walrus { WalrusImportButton(model: model) }
                    if model.page == .losses { LossPeriodBar(store: model.losses) }
                    if model.page == .spend {
                        SpendHeaderControls(usage: model.usage)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    }
                }
                .padding(.horizontal, 24)
                .frame(height: 52)
                Rectangle().fill(Palette.separator).frame(height: 1)
            }
            ConnectionNotices(model: model, connect: connect)
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .now: NowPage(model: model)
        case .projects: ProjectsPage(model: model)
        case .spend: SpendPage(model: model)
        case .requests: RequestsPage(model: model)
        case .activity: ActivityPage(model: model)
        case .losses: LossesPage(model: model)
        case .walrus: WalrusPage(model: model)
        }
    }
}

/// A page that is not built yet says so, rather than pretending there is no data.
struct PageStub: View {
    var text: String

    var body: some View {
        VStack(spacing: 8) {
            Text(L("This page is still being built")).font(.system(size: 15, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(Palette.text2).multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

/// What the person should know about the connection, above every page.
struct ConnectionNotices: View {
    @Bindable var model: AppModel
    var connect: ConnectFlow

    var body: some View {
        let problems = model.connectionStatus.problems
        VStack(spacing: 0) {
            ForEach(problems, id: \.self) { problem in
                notice(problem)
            }
        }
    }

    @ViewBuilder private func notice(_ problem: ConnectionStatus.Problem) -> some View {
        switch problem {
        case .claudeFolderMissing:
            EmptyView()
        case .filesUnreadable, .formatChanged:
            NoticeBanner(kind: .doneWithErrors, title: L("Claude changed its data format"), text: L("Some data may not show. Copy the diagnostics so that Boris can be updated.")) {
                Button(L("Copy diagnostics")) { model.copyDiagnostics() }.buttonStyle(PlainActionStyle())
            }
        case .settingsUnreadable:
            NoticeBanner(kind: .failed, tone: .problem, title: L("Claude's settings file looks damaged"), text: L("Boris will not write to a file it cannot read reliably. Everything else keeps working.")) {
                EmptyView()
            }
        case .hooksDamaged:
            NoticeBanner(kind: .failed, tone: .problem, title: L("Answers from Boris are not working"), text: L("The hooks in Claude's settings were removed or changed. Data keeps updating.")) {
                Button(L("Repair")) { connect.repair(model, asker: .repairInMainWindow) }.buttonStyle(PlainActionStyle())
            }
        case .hooksSilent:
            NoticeBanner(kind: .unknown, title: L("No events from the hooks"), text: L("The hooks are connected and Claude is working, but no events are coming. Start a new Claude session, and if that does not help, copy the diagnostics.")) {
                Button(L("Copy diagnostics")) { model.copyDiagnostics() }.buttonStyle(PlainActionStyle())
            }
        case .hooksDisabledInSettings:
            NoticeBanner(kind: .stopped, title: L("Hooks are turned off in Claude's settings"), text: L("No instant updates or answers from Boris while `disableAllHooks` is on. Everything else works.")) {
                EmptyView()
            }
        case .hooksDisabledByPolicy:
            NoticeBanner(kind: .stopped, title: L("Hooks are forbidden by your company's policy"), text: L("No instant updates or answers from Boris. Everything else works.")) {
                EmptyView()
            }
        }
    }
}
