import AppKit
import BorisCore
import BorisData
import Observation
import SwiftUI

/// What the section shows. The whole file goes through memory only while the section is on screen, and it is read off the main thread.
@MainActor
@Observable
final class LogFeed {
    var period = LogView.Period.lastHour { didSet { if period != oldValue { rearrange() } } }
    var onlyProblems = false { didSet { if onlyProblems != oldValue { rearrange() } } }
    private(set) var rows: [LogRow] = []
    /// The file has been read, so an empty list means there is nothing.
    private(set) var loaded = false
    /// Grows when `rows` is replaced as a whole, rather than added to.
    private(set) var generation = 0
    private(set) var cannotWrite = false

    @ObservationIgnored var following = true
    /// Everything kept, whatever the period and the filter.
    @ObservationIgnored private var all: [LogRow] = []
    @ObservationIgnored private var lastRecord: LogRecord?
    @ObservationIgnored private var renderer = LogRenderer()
    @ObservationIgnored private var store: AppLogStore?
    /// The view that has the feed open. A change of language makes a new view, and the old one may say goodbye after the new one said hello.
    @ObservationIgnored private var owner: UUID?
    /// Tells this opening from an earlier one whose answers may still be on their way.
    @ObservationIgnored private var opening = 0
    @ObservationIgnored private var waiting: [LogChange] = []
    @ObservationIgnored private var applyPlanned = false
    @ObservationIgnored private var arranging = 0
    @ObservationIgnored private var changedWhileArranging = false
    @ObservationIgnored private var isReading = false
    #if DEBUG
    @ObservationIgnored private var isSnapshot = false
    #endif

    func open(from source: AppLogStore? = AppLogStore.current, owner newOwner: UUID = UUID()) {
        #if DEBUG
        if isSnapshot { return }
        #endif
        if store != nil {
            guard newOwner != owner else { return }
            close(owner: owner)
        }
        owner = newOwner
        guard let source else {
            loaded = true
            return
        }
        store = source
        opening += 1
        isReading = true
        renderer = LogRenderer()
        let token = opening
        let (period, onlyProblems) = (period, onlyProblems)
        Task.detached(priority: .userInitiated) { [weak self] in
            let records = source.attach { change in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.hear(change, token: token) }
                }
            }
            var renderer = LogRenderer()
            let rows = records.map { renderer.row($0) }
            let shown = LogView.arrange(rows, period: period, onlyProblems: onlyProblems, now: Date())
            let broken = source.isBroken
            await self?.finishedReading(rows, shown: shown, last: records.last, broken: broken, token: token)
        }
    }

    func close(owner closing: UUID?) {
        guard closing == owner else { return }
        store?.detach()
        store = nil
        opening += 1
        arranging += 1
        all = []
        rows = []
        waiting = []
        lastRecord = nil
        isReading = false
        loaded = false
        following = true
        generation += 1
    }

    private func finishedReading(_ rows: [LogRow], shown: [LogRow], last: LogRecord?, broken: Bool, token: Int) {
        guard token == opening else { return }
        isReading = false
        all = rows
        lastRecord = last
        cannotWrite = broken
        self.rows = shown
        generation += 1
        loaded = true
        // The period or the filter may have changed in the meantime.
        if changedWhileArranging {
            changedWhileArranging = false
            rearrange()
        }
        applyWaiting()
    }

    private func rearrange(now: Date = Date()) {
        guard !isReading else {
            changedWhileArranging = true
            return
        }
        arranging += 1
        changedWhileArranging = false
        following = true
        let token = arranging
        let (source, period, onlyProblems) = (all, period, onlyProblems)
        Task.detached(priority: .userInitiated) { [weak self] in
            let shown = LogView.arrange(source, period: period, onlyProblems: onlyProblems, now: now)
            await self?.arranged(shown, token: token)
        }
    }

    private func arranged(_ shown: [LogRow], token: Int) {
        guard token == arranging else { return }
        // New lines came in while this was being worked out, so it is already out of date.
        if changedWhileArranging {
            rearrange()
            return
        }
        rows = shown
        generation += 1
    }

    private func hear(_ change: LogChange, token: Int) {
        guard token == opening else { return }
        waiting.append(change)
        guard !applyPlanned else { return }
        applyPlanned = true
        // A burst becomes one update of the table.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.applyPlanned = false
                self?.applyWaiting()
            }
        }
    }

    private func applyWaiting() {
        guard !isReading, !waiting.isEmpty else { return }
        for change in waiting {
            switch change {
            case .added(let record):
                lastRecord = record
                let row = renderer.row(record)
                all.append(row)
                LogView.append(row, to: &rows, onlyProblems: onlyProblems)
            case .repeated(let count, let lastAt):
                guard var record = lastRecord, !all.isEmpty else { continue }
                record.count = count
                record.lastAt = lastAt
                lastRecord = record
                let row = renderer.row(record)
                all[all.count - 1] = row
                if let last = rows.last, !last.isDay, last.at == row.at { rows[rows.count - 1] = row }
            case .saving(let saving):
                cannotWrite = !saving
            }
        }
        waiting = []
        changedWhileArranging = true
    }

    /// Lines leave the last hour as time goes on, but not from under someone reading them.
    func dropExpired(now: Date = Date()) {
        guard period == .lastHour, following, let oldest = rows.first(where: { !$0.isDay }), now.timeIntervalSince(oldest.lastAt) > LogView.hour else { return }
        rearrange(now: now)
    }

    func copyText() async -> String {
        let (rows, period) = (rows, period)
        return await Task.detached(priority: .userInitiated) { LogView.copyText(rows, period: period, now: Date()) }.value
    }

    #if DEBUG
    func showForSnapshot(_ records: [LogRecord], period: LogView.Period, onlyProblems: Bool) {
        isSnapshot = true
        var renderer = LogRenderer()
        all = records.map { renderer.row($0) }
        self.period = period
        self.onlyProblems = onlyProblems
        // What those two have just started has nothing to add.
        arranging += 1
        rows = LogView.arrange(all, period: period, onlyProblems: onlyProblems, now: Date())
        generation += 1
        loaded = true
    }
    #endif
}

/// The section «Log» in the settings.
struct LogSection: View {
    @Bindable var model: AppModel
    @State private var following = true
    @State private var jumps = 0
    @State private var copied = false
    @State private var token = UUID()

    private var feed: LogFeed { model.logFeed }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.settingsSection.title).font(.system(size: 17, weight: .bold))
            Text(L("What Boris has been doing, kept for 24 hours and up to 5 MB. No prompts, commands, paths or project names, so you can paste it into a public bug report."))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            if feed.cannotWrite {
                Text(L("New lines are not being saved: the log file is not available."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.redText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controls
            list
        }
        .padding(EdgeInsets(top: 34, leading: 22, bottom: 18, trailing: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { feed.open(owner: token) }
        .onDisappear { feed.close(owner: token) }
        .background(LogWindowProbe(onOpen: { feed.open(owner: token) }, onClose: { feed.close(owner: token) }))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                feed.dropExpired()
            }
        }
    }

    private var period: Binding<LogView.Period> { Binding { feed.period } set: { feed.period = $0 } }
    private var filter: Binding<Bool> { Binding { feed.onlyProblems } set: { feed.onlyProblems = $0 } }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    periodChoice
                    filterChoice
                }
                VStack(alignment: .leading, spacing: 6) {
                    periodChoice
                    filterChoice
                }
            }
            HStack(spacing: 8) {
                Text(L("Lines: %lld", feed.rows.lazy.filter { !$0.isDay }.count))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Palette.text3)
                Spacer(minLength: 0)
                Button(copied ? L("Copied") : L("Copy what is shown")) { copy() }
                    .buttonStyle(PlainActionStyle(height: 22))
                    .disabled(feed.rows.isEmpty)
                    .opacity(feed.rows.isEmpty ? 0.5 : 1)
            }
        }
    }

    private var periodChoice: some View {
        ChoiceBar(options: [(LogView.Period.lastHour, L("Last hour")), (LogView.Period.everything, L("Everything kept"))], selection: period, label: L("Period"))
            .fixedSize()
    }

    private var filterChoice: some View {
        ChoiceBar(options: [(false, L("All lines")), (true, L("Warnings and errors"))], selection: filter, label: L("Lines"))
            .fixedSize()
    }

    private func copy() {
        Task {
            let text = await feed.copyText()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    private var list: some View {
        ZStack(alignment: .bottom) {
            LogTable(rows: feed.rows, generation: feed.generation, jumps: jumps) { now in
                following = now
                feed.following = now
            }
            if feed.loaded, feed.rows.isEmpty {
                Text(feed.onlyProblems ? L("No warnings or errors in this period.") : L("Nothing in this period yet."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !following {
                Button {
                    following = true
                    jumps += 1
                } label: {
                    Text(L("↓ Go to latest"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.text1)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Capsule().fill(Palette.pop))
                        .overlay(Capsule().strokeBorder(Palette.buttonBorder, lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            }
        }
        .background(Palette.fill1)
        .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A closed window keeps its views, so only the window can say when the log is no longer being looked at.
private struct LogWindowProbe: NSViewRepresentable {
    var onOpen: () -> Void
    var onClose: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onOpen = onOpen
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onOpen = onOpen
        view.onClose = onClose
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.stop()
    }

    final class ProbeView: NSView {
        var onOpen: () -> Void = {}
        var onClose: () -> Void = {}
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose() }
            })
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onOpen() }
            })
        }

        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }
}

/// A table and not a SwiftUI list: at 5 MB there are some sixty thousand rows, and this one only ever makes the few on screen.
struct LogTable: NSViewRepresentable {
    var rows: [LogRow]
    var generation: Int
    var jumps: Int
    var onFollowing: (Bool) -> Void

    func makeCoordinator() -> LogTableController { LogTableController() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.onFollowing = onFollowing
        context.coordinator.update(rows: rows, generation: generation, jumps: jumps)
    }
}

@MainActor
final class LogTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scroll = NSScrollView()
    let table = NSTableView()
    var onFollowing: (Bool) -> Void = { _ in }
    private(set) var following = true

    private var rows: [LogRow] = []
    private var generation = -1
    private var jumps = 0
    private var perLine = 80
    private var lastClipHeight: CGFloat = 0
    private var layout = LogRowLayout()
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private static let cellID = NSUserInterfaceItemIdentifier("logLine")

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // Clicking in the log must not take the keyboard from anything.
        table.refusesFirstResponder = true
        table.setAccessibilityLabel(L("Log"))
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false

        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        })
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resized() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func update(rows new: [LogRow], generation newGeneration: Int, jumps newJumps: Int) {
        let old = rows
        rows = new
        if newGeneration != generation || new.count < old.count {
            generation = newGeneration
            if table.tableColumns.first?.width != table.bounds.width { table.sizeLastColumnToFit() }
            table.reloadData()
            setFollowing(true)
            holdAtBottom()
        } else {
            if new.count > old.count { table.insertRows(at: IndexSet(old.count..<new.count), withAnimation: []) }
            // The last line of what was there may have got a new count.
            let recounted = !old.isEmpty && new[old.count - 1] != old[old.count - 1]
            if recounted {
                let index = IndexSet(integer: old.count - 1)
                table.noteHeightOfRows(withIndexesChanged: index)
                table.reloadData(forRowIndexes: index, columnIndexes: IndexSet(integer: 0))
            }
            if following, recounted || new.count > old.count { holdAtBottom() }
        }
        if newJumps != jumps {
            jumps = newJumps
            setFollowing(true)
            holdAtBottom()
        }
    }

    private func setFollowing(_ now: Bool) {
        guard now != following else { return }
        following = now
        // A change of state in the middle of a view update would be lost, and SwiftUI says so.
        let report = onFollowing
        DispatchQueue.main.async { report(now) }
    }

    private var distanceFromBottom: CGFloat {
        rows.isEmpty ? 0 : table.rect(ofRow: rows.count - 1).maxY - scroll.contentView.bounds.maxY
    }

    /// A person scrolled, or the table was moved to its end. A resize also moves the bounds, and that is not leaving the bottom.
    private func moved() {
        let height = scroll.contentView.bounds.height
        if height != lastClipHeight {
            lastClipHeight = height
            if following { holdAtBottom() }
            return
        }
        setFollowing(distanceFromBottom <= 8)
    }

    private func resized() {
        lastClipHeight = scroll.contentView.bounds.height
        let width = scroll.contentView.bounds.width
        if table.tableColumns.first?.width != width { table.tableColumns.first?.width = width }
        let fits = layout.charactersPerLine(inRowOfWidth: width)
        if fits != perLine {
            perLine = fits
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            }
        }
        if following { holdAtBottom() }
    }

    func holdAtBottom() {
        guard !rows.isEmpty else { return }
        let clip = scroll.contentView
        let bottom = table.rect(ofRow: rows.count - 1).maxY
        // Otherwise the clip view holds the bounds inside the size the table had before this update.
        if table.frame.height < bottom { table.setFrameSize(NSSize(width: table.frame.width, height: bottom)) }
        clip.scroll(to: NSPoint(x: 0, y: max(0, bottom - clip.bounds.height)))
        scroll.reflectScrolledClipView(clip)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return LogRowLayout.lineHeight }
        return layout.height(of: rows[row], perLine: perLine)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? LogCell ?? LogCell()
        cell.identifier = Self.cellID
        cell.show(rows[row], layout: layout)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }
}

/// Where the columns of a line stand. All in characters of one width, so that a row's height can be worked out without measuring its text.
@MainActor
struct LogRowLayout {
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let dayFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let lineHeight: CGFloat = 15
    static let rowPadding: CGFloat = 3
    static let sidePadding: CGFloat = 10
    /// A text field keeps this much free on each side of its text.
    static let fieldInset: CGFloat = 2
    static let characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width

    /// Asked for in the language of the moment: a changed language makes the section anew.
    let levelStop: CGFloat
    let messageStop: CGFloat
    let paragraph: NSParagraphStyle

    init() {
        let width = Self.characterWidth
        levelStop = (width * 10).rounded(.up)
        let longest = LogLevel.allCases.map(\.label.count).max() ?? 7
        messageStop = levelStop + (width * CGFloat(longest + 2)).rounded(.up)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: levelStop), NSTextTab(textAlignment: .left, location: messageStop)]
        style.headIndent = messageStop
        style.lineBreakMode = .byWordWrapping
        style.minimumLineHeight = Self.lineHeight
        style.maximumLineHeight = Self.lineHeight
        paragraph = style
    }

    func charactersPerLine(inRowOfWidth width: CGFloat) -> Int {
        max(10, Int((width - 2 * (Self.sidePadding + Self.fieldInset) - messageStop) / Self.characterWidth))
    }

    func height(of row: LogRow, perLine: Int) -> CGFloat {
        if row.isDay { return Self.lineHeight + 2 * Self.rowPadding + 4 }
        let lines = row.messageLength <= perLine ? 1 : LogView.lines(of: row.message, perLine: perLine)
        return CGFloat(lines) * Self.lineHeight + 2 * Self.rowPadding
    }

    private static let timeColor = NSColor(Palette.text3)
    private static let areaColor = NSColor(Palette.text2)
    private static let textColor = NSColor(Palette.text1)
    private static let warningColor = NSColor(Palette.waiting)
    private static let errorColor = NSColor(Palette.redText)

    func attributed(_ row: LogRow) -> NSAttributedString {
        if row.isDay {
            return NSAttributedString(string: row.text, attributes: [.font: Self.dayFont, .foregroundColor: Self.areaColor])
        }
        let levelColor: NSColor
        switch row.level {
        case .info: levelColor = Self.timeColor
        case .warning: levelColor = Self.warningColor
        case .error: levelColor = Self.errorColor
        }
        let text = NSMutableAttributedString(string: "\(row.time)\t\(row.levelWord)\t", attributes: [.font: Self.font, .foregroundColor: Self.timeColor, .paragraphStyle: paragraph])
        text.addAttribute(.foregroundColor, value: levelColor, range: NSRange(location: row.time.utf16.count + 1, length: row.levelWord.utf16.count))
        text.append(NSAttributedString(string: "\(row.area): ", attributes: [.font: Self.font, .foregroundColor: Self.areaColor, .paragraphStyle: paragraph]))
        text.append(NSAttributedString(string: row.text, attributes: [.font: Self.font, .foregroundColor: Self.textColor, .paragraphStyle: paragraph]))
        return text
    }
}

final class LogCell: NSView {
    let field = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.usesSingleLineMode = false
        field.isSelectable = false
        addSubview(field)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(_ row: LogRow, layout: LogRowLayout) {
        field.attributedStringValue = layout.attributed(row)
    }

    override func layout() {
        super.layout()
        field.frame = bounds.insetBy(dx: LogRowLayout.sidePadding, dy: LogRowLayout.rowPadding)
    }
}
