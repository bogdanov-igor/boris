import BorisCore
import SwiftUI

/// The status marks from the design, so a status can be told apart without its colour.
struct StatusGlyph: View {
    enum Kind {
        case running, silent, done, doneWithErrors, allFailed, failed, interrupted, stopped, unknown, waiting, limit, idle
    }

    var kind: Kind
    var size: CGFloat = 16

    private func ring(_ color: Color, width: CGFloat = 1.6, dash: [CGFloat] = []) -> some View {
        Circle().stroke(color, style: StrokeStyle(lineWidth: width, dash: dash)).frame(width: 12.4, height: 12.4)
    }

    private func line(_ color: Color, width: CGFloat, _ build: @escaping (inout Path) -> Void) -> some View {
        Path(build).stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private func cross(_ color: Color, _ a: CGFloat, _ b: CGFloat, width: CGFloat) -> some View {
        line(color, width: width) { path in
            path.move(to: CGPoint(x: a, y: a))
            path.addLine(to: CGPoint(x: b, y: b))
            path.move(to: CGPoint(x: b, y: a))
            path.addLine(to: CGPoint(x: a, y: b))
        }
    }

    @ViewBuilder private var mark: some View {
        switch kind {
        case .running:
            ring(Palette.running.opacity(0.3))
            line(Palette.running, width: 1.6) { $0.addArc(center: CGPoint(x: 8, y: 8), radius: 6.2, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false) }
            Circle().fill(Palette.running).frame(width: 4, height: 4)
        case .silent:
            ring(Palette.smoke, dash: [2.3, 2.2])
            Circle().fill(Palette.smoke).frame(width: 3.2, height: 3.2)
        case .done:
            Circle().fill(Palette.done).frame(width: 14, height: 14)
            line(.white, width: 1.7) { path in
                path.move(to: CGPoint(x: 4.8, y: 8.3))
                path.addLine(to: CGPoint(x: 6.9, y: 10.4))
                path.addLine(to: CGPoint(x: 11.2, y: 5.8))
            }
        case .doneWithErrors:
            Circle().stroke(Palette.done, lineWidth: 1.5).frame(width: 11.8, height: 11.8).position(x: 7.4, y: 8.6)
            line(Palette.done, width: 1.6) { path in
                path.move(to: CGPoint(x: 4.7, y: 8.8))
                path.addLine(to: CGPoint(x: 6.5, y: 10.6))
                path.addLine(to: CGPoint(x: 9.9, y: 6.9))
            }
            Circle().fill(Palette.red).frame(width: 6.2, height: 6.2).position(x: 12.6, y: 3.6)
        case .allFailed:
            Circle().fill(Palette.red).frame(width: 14.8, height: 14.8)
            cross(.white, 5.4, 10.6, width: 1.9)
        case .failed:
            ring(Palette.red)
            cross(Palette.red, 5.9, 10.1, width: 1.6)
        case .interrupted:
            ring(Palette.red)
            line(Palette.red, width: 1.6) { path in
                path.move(to: CGPoint(x: 3.8, y: 12.2))
                path.addLine(to: CGPoint(x: 12.2, y: 3.8))
            }
        case .stopped:
            RoundedRectangle(cornerRadius: 2).fill(Palette.grey).frame(width: 9, height: 9)
        case .unknown:
            ring(Palette.grey, width: 1.3)
            Text(verbatim: "?").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.grey)
        case .waiting:
            Circle().fill(Palette.waiting).frame(width: 14, height: 14)
            HStack(spacing: 0.7) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(.white).frame(width: 2.3, height: 2.3) }
            }
        case .limit:
            ring(Palette.limit, width: 1.5)
            Path { path in
                path.move(to: CGPoint(x: 5.6, y: 4.7))
                path.addLine(to: CGPoint(x: 10.4, y: 4.7))
                path.addLine(to: CGPoint(x: 8, y: 8))
                path.addLine(to: CGPoint(x: 10.4, y: 11.3))
                path.addLine(to: CGPoint(x: 5.6, y: 11.3))
                path.addLine(to: CGPoint(x: 8, y: 8))
            }
            .fill(Palette.limit)
        case .idle:
            Circle().stroke(Palette.grey, lineWidth: 1.4).frame(width: 11.2, height: 11.2)
        }
    }

    var body: some View {
        ZStack { mark }
            .frame(width: 16, height: 16)
            .scaleEffect(size / 16)
            .frame(width: size, height: size)
    }
}

extension StatusGlyph.Kind {
    init(_ state: WorkState) {
        switch state {
        case .running: self = .running
        case .silent: self = .silent
        case .waiting: self = .waiting
        case .finished: self = .done
        case .failed: self = .failed
        case .stopped: self = .stopped
        case .interrupted: self = .interrupted
        case .unreachable: self = .unknown
        }
    }
}

/// How full a limit is. The colour stays quiet: a limit is a number to know, not an alarm.
struct Meter: View {
    var percent: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { frame in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.meterTrack)
                Capsule().fill(Palette.meter).frame(width: frame.size.width * min(max(percent, 0), 100) / 100)
            }
        }
        .frame(height: height)
    }
}

/// A plain macOS-style button with the design's proportions.
struct PlainActionStyle: ButtonStyle {
    var primary = false
    var height: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: height)
            .foregroundStyle(primary ? Color.white : Palette.text1)
            .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(primary ? Palette.focus : Palette.button))
            .overlay {
                if !primary {
                    RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).strokeBorder(Palette.buttonBorder, lineWidth: 0.5)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// Mutually exclusive choices, one line high.
struct ChoiceBar<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var label: String
    var stretches = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .foregroundStyle(Palette.text1)
                        .padding(.horizontal, 9)
                        .frame(maxWidth: stretches ? .infinity : nil)
                        .frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusSmall).fill(option.value == selection ? Palette.button : .clear))
                        .overlay {
                            if option.value == selection {
                                RoundedRectangle(cornerRadius: DesignMetrics.radiusSmall).strokeBorder(Palette.buttonBorder, lineWidth: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option.value == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(Palette.fill1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A notice at the top of a page, for what the person should know right now.
struct NoticeBanner<Actions: View>: View {
    enum Tone {
        case neutral, problem, info
    }

    var kind: StatusGlyph.Kind
    var tone = Tone.neutral
    var title: String
    var text: String
    @ViewBuilder var actions: () -> Actions

    private var background: Color {
        switch tone {
        case .neutral: return Palette.fill1
        case .problem: return Palette.redSoft
        case .info: return Palette.waitingSoft
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusGlyph(kind: kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tone == .problem ? Palette.redText : Palette.text1)
                Text(text)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) { actions() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// A session in one line of its name and one of what it is doing.
struct SessionRow: View {
    var session: WorkSession
    var mode: DisplayMode
    var trailing: String
    var note: String = ""
    var compact = false
    /// A number that follows the line and must not be cut with it.
    var lineEnd: String = ""

    var body: some View {
        let waiting = session.state == .waiting
        HStack(alignment: .center, spacing: 8) {
            StatusGlyph(kind: StatusGlyph.Kind(session.state), size: compact ? 14 : 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.name(in: mode))
                        .font(.system(size: compact ? 12.5 : 13, weight: .semibold, design: session.nameIsFolder ? .monospaced : .default))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Text(WorkPhrases.environment(session.environment))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.text2)
                        .lineLimit(1)
                        .fixedSize()
                    if let place = session.place, place.isSeparateCopy { CopyBadge(place: place, mode: mode) }
                }
                HStack(spacing: 0) {
                    Text(WorkPhrases.line(session, mode: mode))
                        .foregroundStyle(waiting ? Palette.waiting : Palette.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !lineEnd.isEmpty {
                        Text(verbatim: " · \(lineEnd)").foregroundStyle(Palette.text2).lineLimit(1).fixedSize()
                    }
                }
                .font(.system(size: compact ? 11.5 : 12))
            }
            Spacer(minLength: 4)
            if !trailing.isEmpty {
                Text(trailing).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Palette.text2).lineLimit(1)
            }
            if !note.isEmpty {
                Text(note).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Palette.text3).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 5 : 6)
        .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusMedium).fill(waiting ? Palette.waitingSoft : .clear))
        .accessibilityElement(children: .combine)
    }
}

/// The limits as bars with percent and when they reset.
struct LimitsBlock: View {
    var usage: UsageSnapshot?
    var now: Date
    var compact: Bool

    var body: some View {
        if let usage, !usage.windows.filter(Self.isBar).isEmpty {
            Grid(alignment: .leading, horizontalSpacing: compact ? 8 : 10, verticalSpacing: compact ? 6 : 3) {
                ForEach(usage.windows.filter(Self.isBar)) { window in
                    GridRow {
                        Text(Self.title(window)).foregroundStyle(Palette.text2).lineLimit(1)
                        Meter(percent: window.percent, height: compact ? 4 : 5).frame(minWidth: 50)
                        Text(WorkFormat.percent(window.percent)).fontWeight(.semibold).monospacedDigit()
                        // The bar gives way, since the day of the reset is what must be read in full.
                        if compact { resets(window).fixedSize() }
                    }
                    // In a wide block the reset goes under the bar, where a long day name has room.
                    if !compact {
                        GridRow {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            resets(window).gridCellColumns(2)
                        }
                        .padding(.bottom, 4)
                    }
                }
            }
            .font(.system(size: compact ? 11.5 : 12))
        } else {
            Text(L("No data on limits")).font(.system(size: 12).italic()).foregroundStyle(Palette.text3)
        }
    }

    private func resets(_ window: UsageWindow) -> some View {
        Text(window.resetsAt.map { WorkFormat.resets($0, now: now) } ?? "").font(.system(size: 11)).foregroundStyle(Palette.text3).lineLimit(1)
    }

    private static func isBar(_ window: UsageWindow) -> Bool {
        window.kind != .extraSpend
    }

    static func title(_ window: UsageWindow) -> String {
        switch window.kind {
        case .fiveHour: return L("5 hours")
        case .week: return L("Week")
        case .weekModel(let name): return L("Week, %@", name)
        case .extraSpend: return ""
        }
    }
}
