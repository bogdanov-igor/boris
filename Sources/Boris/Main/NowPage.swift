import AppKit
import BorisCore
import SwiftUI

/// What is going on right now.
struct NowPage: View {
    @Bindable var model: AppModel

    private var mode: DisplayMode { model.settings.displayMode }
    private var nothing: Bool { model.work.waitingSessions.isEmpty && model.activeSessions.isEmpty }

    var body: some View {
        if !model.world.claudeFolderFound {
            FolderMissing(model: model)
        } else if nothing {
            idle
        } else {
            ScrollView {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        sessions.frame(minWidth: 460, maxWidth: .infinity)
                        numbers.frame(width: 320)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        sessions
                        numbers
                    }
                }
                .padding(EdgeInsets(top: 18, leading: 24, bottom: 24, trailing: 24))
            }
        }
    }

    private var idle: some View {
        VStack(spacing: 10) {
            WalrusView(mood: model.mood, outfit: model.outfit, size: 120)
            Text(L("Nothing is going on")).font(.system(size: 17, weight: .semibold))
            Text(L("Nobody is waiting for an answer. Boris will say when something starts."))
                .font(.system(size: 13))
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text(L("Tokens today: %@", WorkFormat.tokens(model.today.total)))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Palette.text3)
        }
        .padding(24)
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !model.work.waitingSessions.isEmpty {
                section(L("Waiting for you · %lld", model.work.waitingSessions.count), color: Palette.waiting) {
                    ForEach(model.work.waitingSessions) { row($0) }
                }
            }
            if !model.activeSessions.isEmpty {
                section(L("Active sessions · %lld", model.activeSessions.count), color: Palette.text1) {
                    ForEach(model.activeSessions) { row($0) }
                }
            }
        }
    }

    private func row(_ session: WorkSession) -> some View {
        SessionRow(
            session: session,
            mode: mode,
            trailing: mode == .technical ? (session.root.tokens.map { WorkFormat.tokens($0.total) } ?? "") : "",
            note: session.startedAt.map { WorkFormat.duration(model.now.timeIntervalSince($0)) } ?? ""
        )
    }

    private func section<Content: View>(_ title: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(color).padding(.bottom, 2)
            content()
        }
    }

    private var numbers: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                Text(L("Tokens today")).font(.system(size: 12)).foregroundStyle(Palette.text2)
                Text(WorkFormat.tokens(model.today.total)).font(.system(size: 24, weight: .semibold).monospacedDigit())
                if mode == .technical {
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
                if let fetched = model.world.usage?.fetchedAt {
                    Text(L("updated %@", WorkFormat.ago(model.now.timeIntervalSince(fetched))))
                        .font(.system(size: 11)).foregroundStyle(Palette.text3)
                }
            }
        }
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
            Text(L("Boris looks in ~/.claude. If Claude Code keeps its data somewhere else, choose that folder."))
                .font(.system(size: 12))
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 6) {
                Button(L("Copy diagnostics")) { model.copyDiagnostics() }.buttonStyle(PlainActionStyle())
                Button(L("Choose folder…")) { choose() }.buttonStyle(PlainActionStyle(primary: true))
            }
        }
        .padding(24)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { model.chooseClaudeFolder(url) }
    }
}
