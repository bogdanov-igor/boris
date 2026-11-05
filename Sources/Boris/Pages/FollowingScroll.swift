import AppKit
import BorisCore
import SwiftUI

/// A scroll view that goes with its last record until the person scrolls up, and then offers the way back.
struct FollowingScroll<Content: View>: View {
    /// What is shown, oldest first. The count of new records comes from this.
    var ids: [String]
    /// A short feed sits at the bottom, as a log does.
    var alignsToBottom = false
    @ViewBuilder var content: () -> Content

    @State private var following = true
    /// The last record seen before the person scrolled away.
    @State private var seen: String?
    /// Each change sends the feed to its newest record, also when the person asked for that with the button.
    @State private var jumps = 0

    private static var end: String { "feed-end" }

    private var newCount: Int { SessionFeed.newCount(ids: ids, seen: seen) }

    var body: some View {
        GeometryReader { frame in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if alignsToBottom { Spacer(minLength: 0) }
                        content()
                        Color.clear.frame(height: 1).id(Self.end)
                    }
                    .frame(maxWidth: .infinity, minHeight: alignsToBottom ? frame.size.height : nil)
                    .background(BottomFollower(following: $following, jumps: jumps))
                }
                .overlay(alignment: .bottom) {
                    if !following {
                        Button {
                            following = true
                            jumps += 1
                            proxy.scrollTo(Self.end, anchor: .bottom)
                        } label: {
                            Text(newCount > 0 ? L("↓ Go to latest · %lld new", newCount) : L("↓ Go to latest"))
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.text1)
                                .padding(.horizontal, 14)
                                .frame(height: 28)
                                .background(Capsule().fill(Palette.pop))
                                .overlay(Capsule().strokeBorder(Palette.buttonBorder, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.25), radius: 9, y: 6)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .onChange(of: following) { _, now in
            seen = now ? nil : ids.last
        }
    }
}

/// Holds a scroll view at its bottom as its content changes, until the person scrolls away, and again once they come back.
private struct BottomFollower: NSViewRepresentable {
    @Binding var following: Bool
    let jumps: Int

    func makeNSView(context: Context) -> FollowerView {
        let view = FollowerView()
        view.onChange = { value in following = value }
        return view
    }

    func updateNSView(_ view: FollowerView, context: Context) {
        view.onChange = { value in following = value }
        view.update(following: following, jumps: jumps)
    }
}

private final class FollowerView: NSView {
    /// A person who has barely moved has not left the bottom.
    private static let nearBottom: CGFloat = 8
    /// A wheel step moves the view a moment later, so a move this soon after one is the person's doing.
    private static let wheelEcho: TimeInterval = 0.4

    var onChange: ((Bool) -> Void)?
    private var following = true
    private var jumps = 0
    private var observers: [NSObjectProtocol] = []
    private var wheelMonitor: Any?
    private weak var scrollView: NSScrollView?
    private var lastWheel = Date.distantPast
    private var lastWheelTowardNewest = false

    private var wheelJustMoved: Bool { Date().timeIntervalSince(lastWheel) < Self.wheelEcho }

    func update(following: Bool, jumps: Int) {
        let returned = following && !self.following
        let asked = jumps != self.jumps
        self.following = following
        self.jumps = jumps
        if returned || asked { holdAtBottom() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopWatching()
        guard window != nil, let scrollView = enclosingScrollView else { return }
        self.scrollView = scrollView
        let center = NotificationCenter.default
        for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
            observers.append(center.addObserver(forName: name, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.personMoved() }
            })
        }
        // A mouse wheel with steps scrolls without any live-scroll notification, so the move that follows its event is watched instead.
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, event.window === self.window, self.isOverScrollView(event) { self.noteWheel(event) }
            return event
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.wheelJustMoved == true { self?.personMoved() }
            }
        })
        holdAtBottom()
    }

    override func removeFromSuperview() {
        stopWatching()
        super.removeFromSuperview()
    }

    private func stopWatching() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
    }

    /// This view lies behind the whole content, so its size changes with it: a new record, a record that got its result, a lazy row measured.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard following else { return }
        DispatchQueue.main.async { [weak self] in self?.holdAtBottom() }
    }

    private func noteWheel(_ event: NSEvent) {
        lastWheel = Date()
        lastWheelTowardNewest = event.scrollingDeltaY < 0
    }

    private func isOverScrollView(_ event: NSEvent) -> Bool {
        guard let scrollView else { return false }
        return scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil))
    }

    private var distanceFromBottom: CGFloat {
        guard let scrollView, let document = scrollView.documentView else { return 0 }
        let visible = scrollView.contentView.bounds
        return document.isFlipped ? document.frame.height - visible.maxY : visible.minY
    }

    private func personMoved() {
        let atBottom = distanceFromBottom <= Self.nearBottom
        guard atBottom != following else { return }
        // Scrolling down while a new record has just arrived is not leaving the bottom.
        if !atBottom, wheelJustMoved, lastWheelTowardNewest { return }
        following = atBottom
        onChange?(atBottom)
    }

    private func holdAtBottom() {
        guard following, !wheelJustMoved, let scrollView, let document = scrollView.documentView, abs(distanceFromBottom) > 0.5 else { return }
        let visible = scrollView.contentView.bounds
        let y = document.isFlipped ? max(0, document.frame.height - visible.height) : 0
        scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// Tells a feed which window it is in. A closed window keeps its views, so only the window knows whether anyone can see them.
struct HostWindowProbe: NSViewRepresentable {
    var store: FeedStore

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.store = store
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.store = store
        store.hostWindow = view.window
    }

    final class ProbeView: NSView {
        weak var store: FeedStore?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            store?.hostWindow = window
        }
    }
}

extension View {
    /// Keeps a feed reading for as long as this view is around and its window is on screen.
    func readsFeed(_ store: FeedStore) -> some View {
        background(HostWindowProbe(store: store))
            .onAppear { store.viewerAppeared() }
            .onDisappear { store.viewerLeft() }
    }

    /// Shows the changes someone asked to see in full.
    func showsDiffs(of store: FeedStore) -> some View {
        sheet(item: Bindable(store).shownDiff) { request in
            DiffSheet(title: request.title, entries: request.entries, store: store)
        }
    }
}
