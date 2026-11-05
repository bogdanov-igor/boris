#if DEBUG
import BorisCore
import SwiftUI

extension DevData {
    /// Invented numbers, in the shapes the screens have to survive.
    var macLoad: MacLoad {
        let gigabyte = UInt64(1 << 30)
        switch self {
        case .empty:
            return MacLoad()
        case .busy:
            return MacLoad(
                cpu: LoadSplit(total: 60, named: [.claude: 20, .vsCode: 12, .boris: 1]),
                memory: LoadSplit(total: 71, named: [.claude: 18, .vsCode: 9, .boris: 1]),
                diskPercent: 62,
                claudeLogs: gigabyte * 28 / 10,
                physicalMemory: 16 * gigabyte,
                sessions: ["a1": SessionLoad(cpu: 9, memory: gigabyte * 12 / 10), "b1": SessionLoad(cpu: 14, memory: gigabyte * 2)]
            )
        case .long:
            return MacLoad(
                cpu: LoadSplit(total: 98.4, named: [.claude: 31.3, .cowork: 9.2, .vsCode: 14.1, .cursor: 6.3, .claudeDesktop: 4.4, .boris: 0.4]),
                memory: LoadSplit(total: 97.2, named: [.claude: 28.5, .cowork: 22.1, .vsCode: 12.2, .cursor: 9.3, .claudeDesktop: 6.1, .boris: 0.8]),
                diskPercent: 99.6,
                claudeLogs: 1400 * gigabyte,
                physicalMemory: 128 * gigabyte,
                sessions: ["a1": SessionLoad(cpu: 87.5, memory: 96 * gigabyte), "b1": SessionLoad(cpu: 0.2, memory: 950 * 1 << 20)],
                offWithProcesses: [.cursor, .claudeDesktop]
            )
        }
    }
}

/// Every look of the block next to each other, as the board has them. Nothing here reads the Mac.
struct LoadGallery: View {
    @Bindable var model: AppModel

    private var load: MacLoad? { model.load.current }
    private var mode: DisplayMode { model.settings.displayMode }

    /// The cases the data sets do not cover.
    private var memoryFailed: MacLoad? {
        load.map {
            var changed = $0
            changed.memory = nil
            changed.claudeLogs = nil
            return changed
        }
    }

    /// Everything but CPU load comes with the first reading.
    private var firstReading: MacLoad? {
        load.map {
            var changed = $0
            changed.cpu = nil
            changed.cpuPending = true
            return changed
        }
    }

    private var vsCodeOff: MacLoad {
        MacLoad(
            cpu: LoadSplit(total: 60, named: [.claude: 20, .boris: 1]),
            memory: LoadSplit(total: 71, named: [.claude: 18, .boris: 1]),
            diskPercent: 62,
            claudeLogs: 3_006_477_107,
            physicalMemory: 17_179_869_184,
            offWithProcesses: [.vsCode]
        )
    }

    /// The widths are the real ones: the cards column of the usage page and the narrow side column of a session.
    private func card<Content: View>(_ title: String, width: CGFloat = 320, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.system(size: 11.5)).foregroundStyle(Palette.text2)
            content()
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                .frame(width: width, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.window))
                .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).strokeBorder(Palette.separator, lineWidth: 1))
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                card("page") { MacLoadContent(load: load, kind: mode == .technical ? .pageTechnical : .pageSimple) }
                card("page, technical") { MacLoadContent(load: load, kind: .pageTechnical) }
                card("page, first moment") { MacLoadContent(load: firstReading, kind: mode == .technical ? .pageTechnical : .pageSimple) }
            }
            VStack(alignment: .leading, spacing: 16) {
                card("memory unreadable") { MacLoadContent(load: memoryFailed, kind: .pageTechnical) }
                card("VS Code off") { MacLoadContent(load: vsCodeOff, kind: .pageTechnical) }
                card("simple, no data") { MacLoadContent(load: MacLoad(), kind: .pageSimple) }
                card("mini", width: 360) { MacLoadContent(load: load, kind: mode == .technical ? .miniTechnical : .miniSimple) }
                card("mini, first moment", width: 360) { MacLoadContent(load: firstReading, kind: .miniTechnical) }
            }
            VStack(alignment: .leading, spacing: 16) {
                card("session here") { SessionLoadContent(load: load, sessionId: "a1", place: .here) }
                card("session with no process") { SessionLoadContent(load: load, sessionId: "none", place: .here) }
                card("session, first moment") { SessionLoadContent(load: firstReading, sessionId: "a1", place: .here) }
                card("session in Cowork") { SessionLoadContent(load: load, sessionId: "c1", place: .cowork) }
                card("session on a remote machine") { SessionLoadContent(load: load, sessionId: "r1", place: .remote(host: "a-build-machine-with-a-very-long-name.example.internal")) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Palette.desk)
        .foregroundStyle(Palette.text1)
    }
}
#endif
