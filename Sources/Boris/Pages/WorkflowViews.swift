import BorisCore
import SwiftUI

extension StatusGlyph.Kind {
    init(_ status: RunStatus) {
        switch status {
        case .running: self = .running
        case .silent: self = .silent
        case .completed: self = .done
        case .completedWithErrors: self = .doneWithErrors
        case .allAgentsFailed: self = .allFailed
        case .failed: self = .failed
        case .stopped: self = .stopped
        case .interrupted: self = .interrupted
        case .unknown: self = .unknown
        }
    }

    init(_ failure: WorkFailure) {
        switch failure.source {
        case .session: self = .interrupted
        case .sessionError, .agent: self = failure.cause == .limit ? .limit : .failed
        case .workflow(let status, _, _): self = StatusGlyph.Kind(status)
        }
    }
}

extension RunStatus {
    var color: Color {
        switch self {
        case .running: return Palette.running
        case .silent: return Palette.text2
        case .completed: return Palette.done
        case .completedWithErrors, .allAgentsFailed, .failed, .interrupted: return Palette.redText
        case .stopped, .unknown: return Palette.grey
        }
    }
}

/// The ribbon of a run: its phases in order, each split by how its agents are doing. A failure stands taller, so it shows without its colour.
struct WorkflowRibbon: View {
    var phases: [WorkflowPhase]

    private static let aheadWidth: CGFloat = 18
    private static let narrowest: CGFloat = 3

    private func gap(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let separate = phases[index].title == nil && phases.contains { $0.title != nil }
        return separate ? 6 : 2
    }

    private var label: String {
        let total = phases.reduce(0) { $0 + $1.total }
        return L("Run ribbon: started %lld, done %lld, failed %lld, running %lld, cancelled %lld", total, phases.reduce(0) { $0 + $1.done }, phases.reduce(0) { $0 + $1.failed }, phases.reduce(0) { $0 + $1.running }, phases.reduce(0) { $0 + $1.cancelled })
    }

    var body: some View {
        GeometryReader { frame in
            let gaps = phases.indices.reduce(CGFloat(0)) { $0 + gap(before: $1) }
            let ahead = CGFloat(phases.filter(\.isAhead).count) * Self.aheadWidth
            let widths = widths(free: max(frame.size.width - gaps - ahead, 0))
            HStack(spacing: 0) {
                ForEach(Array(phases.enumerated()), id: \.element.id) { index, phase in
                    Color.clear.frame(width: gap(before: index), height: 1)
                    if phase.isAhead {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Palette.text3, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            .frame(width: Self.aheadWidth, height: 6)
                    } else {
                        segments(phase, width: widths[index])
                    }
                }
            }
            .frame(height: frame.size.height, alignment: .center)
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// Each phase by its share of the agents. A tiny one stays visible at the expense of the others, so the ribbon still ends where the line ends.
    private func widths(free: CGFloat) -> [CGFloat] {
        let total = CGFloat(max(phases.reduce(0) { $0 + $1.total }, 1))
        func isTiny(_ phase: WorkflowPhase) -> Bool { free * CGFloat(phase.total) / total < Self.narrowest }
        let started = phases.filter { !$0.isAhead }
        let others = started.filter { !isTiny($0) }
        let left = max(free - CGFloat(started.count - others.count) * Self.narrowest, 0)
        let shares = CGFloat(max(others.reduce(0) { $0 + $1.total }, 1))
        return phases.map { isTiny($0) ? Self.narrowest : left * CGFloat($0.total) / shares }
    }

    private func segments(_ phase: WorkflowPhase, width: CGFloat) -> some View {
        let parts: [(count: Int, color: Color, height: CGFloat)] = [
            (phase.done, Palette.ribbonDone, 4),
            (phase.failed, Palette.ribbonFailed, 8),
            (phase.running, Palette.ribbonRunning, 4),
            (phase.cancelled, Palette.ribbonCancelled, 4),
        ]
        return HStack(spacing: 0) {
            ForEach(parts.indices, id: \.self) { index in
                if parts[index].count > 0 {
                    parts[index].color.frame(width: max(width * CGFloat(parts[index].count) / CGFloat(max(phase.total, 1)), 1), height: parts[index].height)
                }
            }
        }
        .frame(width: width, height: 8, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

/// Simple words for how far a phase has come.
enum PhaseWords {
    /// `8 of 8 · done`, `1 of 4 · running`, `3 of 12 · failed 2`.
    static func summary(_ phase: WorkflowPhase) -> (text: String, color: Color) {
        if phase.isAhead { return (L("ahead, no agents yet"), Palette.text3) }
        let count = L("%lld of %lld", phase.done, phase.total)
        if phase.failed > 0 { return ("\(count) · \(L("failed %lld", phase.failed))", Palette.redText) }
        if phase.running > 0 { return ("\(count) · \(L("running"))", Palette.running) }
        if phase.cancelled > 0 { return ("\(count) · \(L("cancelled %lld", phase.cancelled))", Palette.text2) }
        return ("\(count) · \(L("done"))", Palette.done)
    }

    /// The progress line of the simple mode.
    static func progress(_ phases: [WorkflowPhase]) -> String? {
        guard let current = phases.last(where: \.isCurrent)?.title else { return nil }
        if let finished = phases.last(where: { $0.title != nil && !$0.isCurrent && !$0.isAhead && $0.running == 0 })?.title {
            return L("%@ done, %@ in progress", finished, current)
        }
        return L("%@ in progress", current)
    }
}

/// A workflow on its way, in plain words: how far it has come.
struct WorkflowProgressCard: View {
    var node: WorkNode

    var body: some View {
        if let details = node.workflow {
            let phases = node.phases
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StatusGlyph(kind: StatusGlyph.Kind(details.status))
                    Text(WorkPhrases.workflowName(node.title, mode: .simple))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(WorkPhrases.workflow(details.status, mode: .simple))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(details.status.color)
                        .lineLimit(1)
                }
                progressBar(details)
                if let line = PhaseWords.progress(phases) {
                    Text(line).font(.system(size: 12)).foregroundStyle(Palette.text2).lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.separator))
        }
    }

    private func progressBar(_ details: WorkflowDetails) -> some View {
        let settled = details.done + details.failed
        let share = Double(settled) / Double(max(details.total, 1))
        return GeometryReader { frame in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.meterTrack)
                Capsule().fill(Palette.running).frame(width: frame.size.width * min(share, 1))
            }
        }
        .frame(height: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Progress"))
        .accessibilityValue(WorkFormat.percent(share * 100))
    }
}
