import AppKit
import BorisCore
import SwiftUI

/// What is going on right now.
struct NowPage: View {
    @Bindable var model: AppModel
    @State private var width: CGFloat = 1000

    private var mode: DisplayMode { model.settings.displayMode }
    /// Decided by the room there is, not by how long the names happen to be: a long name is cut, it does not rearrange the page.
    private var hasTwoColumns: Bool { width >= 830 }

    var body: some View {
        let digest = NowDigest(model.work, now: model.now)
        if !model.world.claudeFolderFound {
            FolderMissing(model: model)
        } else if !model.loaded {
            // Before the first scan nothing is known, which is not the same as nothing going on.
            Color.clear
        } else if digest.isQuiet, model.requestCount == 0 {
            idle
        } else {
            ScrollView {
                Group {
                    if hasTwoColumns {
                        HStack(alignment: .top, spacing: 24) {
                            sessions(digest).frame(maxWidth: .infinity, alignment: .leading)
                            numbers(digest).frame(width: 330)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            sessions(digest)
                            numbers(digest)
                        }
                    }
                }
                .padding(EdgeInsets(top: 18, leading: 24, bottom: 24, trailing: 24))
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
        }
    }

    private var idle: some View {
        VStack(spacing: 10) {
            WalrusView(mood: model.mood, outfit: model.outfit, size: 120)
            Text(L("Nothing is going on")).font(.system(size: 17, weight: .semibold))
            Text(L("Nobody is waiting for an answer and nothing has broken. Boris will say when something starts."))
                .font(.system(size: 13))
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text(idleNumbers)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Palette.text3)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    /// `Tokens today: 1.84M · 5 hours 62%, resets at 18:40`.
    private var idleNumbers: String {
        var parts = [L("Tokens today: %@", model.usage.todayText(model.today))]
        if let window = model.world.usage?.windows.first(where: { $0.kind != .extraSpend }) {
            var limit = "\(LimitsBlock.title(window)) \(WorkFormat.percent(window.percent))"
            if let resets = window.resetsAt { limit += ", \(WorkFormat.resets(resets, now: model.now))" }
            parts.append(limit)
        }
        return parts.joined(separator: " · ")
    }

    private func sessions(_ digest: NowDigest) -> some View {
        // A session with a card above still counts among those at work. One without a held request has its notice among the cards only.
        let held = Set(model.hooks.pending.map(\.session))
        let activeRows = digest.waiting.filter { held.contains($0.id) } + digest.active
        return VStack(alignment: .leading, spacing: 20) {
            RequestCardList(model: model)
            if !activeRows.isEmpty {
                section(L("Active sessions · %lld", activeRows.count), color: Palette.text1) {
                    ForEach(activeRows) { row($0) }
                }
            }
            if !digest.failures.isEmpty {
                section(L("Recent failures · %lld", digest.failures.count), color: Palette.text1) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(digest.failures) { failure($0) }
                    }
                }
            }
        }
    }

    private func row(_ session: WorkSession) -> some View {
        RowButton {
            model.openSession(session.id)
        } label: {
            SessionRow(
                session: session,
                mode: mode,
                trailing: mode == .technical ? (model.usage.book?.spent(session: session.id).map { WorkFormat.tokens($0.total) } ?? "") : "",
                note: session.startedAt.map { WorkFormat.duration(model.now.timeIntervalSince($0)) } ?? ""
            )
            .frame(minHeight: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
        }
        .accessibilityHint(L("Opens the session"))
    }

    private func failure(_ failure: WorkFailure) -> some View {
        Button {
            model.openSession(failure.sessionId)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                StatusGlyph(kind: StatusGlyph.Kind(failure))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(WorkPhrases.failureName(failure, mode: mode)).fontWeight(.semibold)
                        if let project = failure.project {
                            Text(verbatim: " · \(project)").foregroundStyle(Palette.text2)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Text(WorkPhrases.failure(failure, mode: mode))
                        .foregroundStyle(Palette.redText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12.5))
                Spacer(minLength: 4)
                if let at = failure.at {
                    Text(WorkFormat.time(at)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Palette.text2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.redSoft))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(L("Opens the session"))
    }

    private func section<Content: View>(_ title: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(color).padding(.bottom, 2)
            content()
        }
    }

    private func numbers(_ digest: NowDigest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                Text(L("Tokens today")).font(.system(size: 12)).foregroundStyle(Palette.text2)
                Text(model.usage.todayText(model.today))
                    .font(model.usage.book != nil ? .system(size: 24, weight: .semibold).monospacedDigit() : .system(size: 15).italic())
                    .foregroundStyle(model.usage.book != nil ? Palette.text1 : Palette.text3)
                if let estimate = UsageFormat.estimateLine(model.usage.book?.report(.today).estimate) {
                    Text(estimate).font(.system(size: 11.5)).foregroundStyle(Palette.text3)
                }
                if mode == .technical, model.usage.book != nil {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow { detail(L("Input"), model.today.input); detail(L("Output"), model.today.output) }
                        GridRow { detail(L("Cache, read"), model.today.cacheRead); detail(L("Cache, write"), model.today.cacheWrite) }
                    }
                    .padding(.top, 6)
                }
            }
            card {
                Text(L("Limits")).font(.system(size: 12)).foregroundStyle(Palette.text2)
                LimitsBlock(usage: model.world.usage, now: model.now, compact: false)
                if model.world.usage != nil || model.world.account == .signedIn { LimitsFreshness(model: model) }
            }
            if !digest.finished.isEmpty {
                card {
                    Text(L("Recently finished")).font(.system(size: 12)).foregroundStyle(Palette.text2)
                    ForEach(digest.finished) { finished($0) }
                }
            }
        }
    }

    private func finished(_ session: WorkSession) -> some View {
        Button {
            model.openSession(session.id)
        } label: {
            HStack(spacing: 8) {
                StatusGlyph(kind: .done, size: 14)
                Text(session.displayName)
                    .font(.system(size: 12.5, weight: .semibold, design: session.nameIsFolder ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(WorkPhrases.environment(session.environment))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(WorkPhrases.state(.finished, mode: mode))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.done)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(L("Opens the session"))
    }

    private func detail(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(Palette.text3)
            Text(WorkFormat.tokens(value)).monospacedDigit()
        }
        .font(.system(size: 11.5))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.separator))
    }
}

/// Without Claude's folder there is nothing to show, and the way out is to name the folder.
struct FolderMissing: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            WalrusView(mood: .broken, outfit: model.outfit, size: 110)
            Text(L("Cannot find Claude's folder")).font(.system(size: 14, weight: .bold))
            Text(Self.explanation(model))
                .font(.system(size: 12))
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 6) {
                CopyDiagnosticsButton(model: model)
                Button(L("Choose folder…")) { Self.choose(model) }.buttonStyle(PlainActionStyle(primary: true))
            }
        }
        .padding(24)
    }

    /// Names the folder being looked for, which may be one the person chose earlier and that has gone since.
    @MainActor
    static func explanation(_ model: AppModel) -> String {
        let folder = model.hooks.settingsFile.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return L("Boris looks in %@. If Claude Code keeps its data somewhere else, choose that folder.", folder)
    }

    @MainActor
    static func choose(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { model.chooseClaudeFolder(url) }
    }
}
