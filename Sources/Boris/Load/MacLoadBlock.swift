import BorisCore
import BorisData
import SwiftUI

/// How loaded this Mac is, and by whom. It reads the load only while it can be seen.
struct MacLoadBlock: View {
    enum Kind {
        case miniSimple, miniTechnical, pageSimple, pageTechnical
    }

    @Bindable var model: AppModel
    var kind: Kind
    @State private var viewer = UUID()

    var body: some View {
        MacLoadContent(load: model.load.current, kind: kind)
            .background(VisibilityProbe { [load = model.load, viewer] visible in
                load.setVisible(visible, viewer: viewer)
            })
    }
}

/// The picture of one reading, with no timers behind it.
struct MacLoadContent: View {
    /// Nil until the first reading.
    var load: MacLoad?
    var kind: MacLoadBlock.Kind

    var body: some View {
        switch kind {
        case .pageSimple: simple
        case .pageTechnical: technical
        case .miniSimple: mini(showsClaude: false)
        case .miniTechnical: mini(showsClaude: true)
        }
    }

    private var cpuIsComing: Bool { load?.cpuPending ?? true }

    private var title: some View {
        Text(L("Load on Mac")).font(.system(size: 12.5, weight: .semibold))
    }

    // MARK: - Page, simple

    private var simple: some View {
        VStack(alignment: .leading, spacing: 10) {
            title
            LoadBar(segments: load?.cpu.map(claudeAndRest) ?? [], height: 8, dashed: !cpuIsComing && load?.cpu == nil)
            sentence
                .font(.system(size: 13))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var sentence: some View {
        if let cpu = load?.cpu {
            if let claude = cpu.part(.claude) {
                Text(L("The Mac is %lld%% loaded, %lld%% of it by Claude.", cpu.points, claude.points))
            } else {
                Text(L("The Mac is %lld%% loaded.", cpu.points))
            }
        } else if cpuIsComing {
            Text(verbatim: "—").foregroundStyle(Palette.text3)
        } else {
            Text(L("no data")).italic().foregroundStyle(Palette.text3)
        }
    }

    private func claudeAndRest(_ split: LoadSplit) -> [LoadBar.Segment] {
        let claude = split.part(.claude)?.points ?? 0
        return [
            LoadBar.Segment(percent: Double(claude), color: Palette.load(.claude)),
            LoadBar.Segment(percent: Double(split.points - claude), color: Palette.load(.rest)),
        ]
    }

    // MARK: - Page, technical

    private var technical: some View {
        VStack(alignment: .leading, spacing: LoadRowStyle.page.gap) {
            title
            splitRow(L("CPU"), load?.cpu, coming: cpuIsComing, expected: load?.memory)
            splitRow(L("Memory"), load?.memory, coming: load == nil)
            diskRow
            Text(note)
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(Palette.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var note: String {
        let off = load?.offWithProcesses ?? []
        return ([L("CPU: 100% is the whole Mac. Activity Monitor counts each core as 100%, so its numbers are higher.")]
            + off.map { $0 == .claude ? L("Claude from sources that are off is counted in the rest.") : L("%@: reading is off, its load is counted in the rest.", $0.title) })
            .joined(separator: " ")
    }

    private func reading(_ split: LoadSplit?, coming: Bool) -> LoadReading {
        if let split { return .value(WorkFormat.percent(split.total)) }
        return coming ? .waiting : .noData
    }

    /// - Parameter expected: holds the legend's place while the value is on its way, so the block does not jump a second later.
    private func splitRow(_ title: String, _ split: LoadSplit?, coming: Bool, expected: LoadSplit? = nil) -> some View {
        var legend = split?.parts.map { LoadLegendItem(color: Palette.load($0.group), text: "\($0.group.title) \($0.points)") } ?? []
        if split == nil, coming {
            legend = expected?.parts.map { LoadLegendItem(color: Palette.load($0.group), text: "\($0.group.title) —") } ?? []
        }
        return LoadRow(
            title: title,
            reading: reading(split, coming: coming),
            segments: split?.parts.map { LoadBar.Segment(percent: Double($0.points), color: Palette.load($0.group)) } ?? [],
            legend: legend,
            style: .page
        )
    }

    private var diskRow: some View {
        let percent = load?.diskPercent
        var legend: [LoadLegendItem] = []
        if let load {
            legend.append(LoadLegendItem(
                color: Palette.load(.claude),
                text: load.claudeLogs.map { L("Claude logs %@", WorkFormat.byteCount($0)) } ?? L("Claude logs: no data")
            ))
        }
        return LoadRow(
            title: L("Disk"),
            reading: load == nil ? .waiting : percent.map { .value(WorkFormat.percent($0)) } ?? .noData,
            segments: percent.map { [LoadBar.Segment(percent: $0.rounded(), color: Palette.meter)] } ?? [],
            legend: legend,
            style: .page
        )
    }

    // MARK: - Mini window

    private func mini(showsClaude: Bool) -> some View {
        VStack(alignment: .leading, spacing: LoadRowStyle.mini.gap) {
            miniRow(L("CPU"), load?.cpu, coming: cpuIsComing, showsClaude: showsClaude)
            miniRow(L("Memory"), load?.memory, coming: load == nil, showsClaude: showsClaude)
        }
    }

    private func miniRow(_ title: String, _ split: LoadSplit?, coming: Bool, showsClaude: Bool) -> some View {
        let claude = showsClaude ? split?.part(.claude)?.points : nil
        // The same place is kept for it while CPU load is on its way, so the window does not change size a second later.
        let claudeIsComing = showsClaude && split == nil && coming && load?.memory?.part(.claude) != nil
        var segments: [LoadBar.Segment] = []
        if let split {
            if let claude { segments.append(LoadBar.Segment(percent: Double(claude), color: Palette.load(.claude))) }
            segments.append(LoadBar.Segment(percent: Double(split.points - (claude ?? 0)), color: Palette.meter))
        }
        return LoadRow(
            title: title,
            reading: reading(split, coming: coming),
            segments: segments,
            legend: claudeIsComing
                ? [LoadLegendItem(color: Palette.load(.claude), text: "Claude —")]
                : claude.map { [LoadLegendItem(color: Palette.load(.claude), text: "Claude \(WorkFormat.percent(Double($0)))")] } ?? [],
            style: .mini
        )
    }
}
