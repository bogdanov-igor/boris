import BorisCore
import BorisData
import SwiftUI

/// What a session takes from this Mac, for the technical view of its page. Put it in the session's side column.
struct SessionLoadBlock: View {
    @Bindable var model: AppModel
    var session: WorkSession
    @State private var viewer = UUID()

    var body: some View {
        let place = SessionLoadPlace(session)
        if model.settings.displayMode == .technical, place != .none {
            SessionLoadContent(load: model.load.current, sessionId: session.id, place: place)
                .background {
                    // Cowork and remote sessions have only a sentence to show, so nothing needs reading for them.
                    if place == .here {
                        VisibilityProbe { [load = model.load, viewer] visible in
                            load.setVisible(visible, viewer: viewer)
                        }
                    }
                }
        }
    }
}

/// The picture of one reading, with no timers behind it.
struct SessionLoadContent: View {
    /// Nil until the first reading.
    var load: MacLoad?
    var sessionId: String
    var place: SessionLoadPlace

    var body: some View {
        VStack(alignment: .leading, spacing: LoadRowStyle.session.gap) {
            switch place {
            case .here:
                heading(L("Load on Mac · this session with agents and commands"))
                rows
                Text(L("CPU: share of the whole Mac. Memory: how much is used, the bar is out of the Mac's total."))
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .foregroundStyle(Palette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            case .cowork:
                heading(L("Load on Mac"))
                sentence(L("Cowork runs in one virtual machine, and the Mac sees it as a whole. The share of this session cannot be counted."))
            case .remote(let host):
                heading(L("Load on Mac"))
                sentence(L("The session runs on %@ and does not load this Mac.", host))
            case .none:
                EmptyView()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.fill1))
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sentence(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .lineSpacing(3)
            .foregroundStyle(Palette.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var rows: some View {
        let taken = load?.sessions[sessionId]
        let waiting = load == nil
        let memoryPercent = taken.flatMap { taken -> Double? in
            guard let total = load?.physicalMemory, total > 0 else { return nil }
            return Double(taken.memory) / Double(total) * 100
        }
        LoadRow(
            title: L("CPU"),
            reading: load?.cpuPending ?? true ? .waiting : taken.map { .value(WorkFormat.percent($0.cpu)) } ?? .noData,
            segments: load?.cpuPending ?? true ? [] : taken.map { [LoadBar.Segment(percent: $0.cpu, color: Palette.load(.claude))] } ?? [],
            style: .session
        )
        LoadRow(
            title: L("Memory used"),
            reading: waiting ? .waiting : taken.map { .value(WorkFormat.byteCount($0.memory)) } ?? .noData,
            segments: memoryPercent.map { [LoadBar.Segment(percent: $0, color: Palette.load(.claude))] } ?? [],
            style: .session
        )
    }
}
