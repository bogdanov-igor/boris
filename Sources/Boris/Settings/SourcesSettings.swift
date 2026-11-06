import BorisCore
import SwiftUI

/// Which products and environments Boris reads, notifies about, may answer and may show on a captured screen.
struct SourcesSettings: View {
    @Bindable var model: AppModel

    private var settings: AppSettings { model.settings }
    private var sources: SourceSettings { settings.sources }

    private static let column: CGFloat = 66

    var body: some View {
        SettingsGroup {
            line {
                Text(L("Source")).frame(maxWidth: .infinity, alignment: .leading)
                header(L("Reading"))
                header(L("Notify"))
                header(L("Answer requests"))
                header(L("Screen capture"))
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Palette.text2)
            .padding(.vertical, 7)
            // The group lifts its first row by the width of a line, which this one does not draw.
            .padding(.top, 1)
            ForEach(SourceProduct.allCases) { product in
                productRow(product)
                ForEach(product.sources) { sourceRow($0) }
            }
        }
        SettingsGroup(footer: L("If some sources are off, the Usage page says that not all of them are counted. Claude itself works as usual, whatever is set here.")) {
            SettingsRow(
                title: L("Screen capture"),
                detail: L("With capture off, Boris asks macOS to leave its window out of screenshots, recordings and screen sharing, including a window where that source is shown together with others. This is a request, not a guarantee: newer recording programs that use ScreenCaptureKit can get around it. It does not stop a photo of the screen, and it does not cover Mac notifications or Telegram messages. A window that has been hidden stays hidden until you close it and open it again, and the notch until Boris restarts: macOS lets a window be hidden only once.")
            ) {
                EmptyView()
            }
        }
    }

    private func line<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }.padding(.horizontal, 12)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: Self.column)
    }

    /// A product has one switch: all of it, whatever its sources are set to.
    private func productRow(_ product: SourceProduct) -> some View {
        line {
            Text(product.title)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(product.title, isOn: Binding {
                sources.isOn(product)
            } set: {
                settings.sources.set(product, on: $0)
                model.sourcesChanged(reading: true)
            })
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .frame(width: Self.column)
            .accessibilityLabel(L("%@, reading", product.title))
            Color.clear.frame(width: Self.column * 3 + 16, height: 0)
        }
        .frame(minHeight: 30)
        .background(Palette.fill1)
        .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }

    private func sourceRow(_ source: SourceID) -> some View {
        line {
            VStack(alignment: .leading, spacing: 0) {
                Text(source.title).font(.system(size: 12.5))
                if let detail = detail(source) {
                    Text(detail)
                        .font(.system(size: 11))
                        .lineSpacing(2)
                        .foregroundStyle(Palette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(source, L("Reading"), \.read, on: sources.isOn(source.product), reason: L("The whole product is off."), reading: true)
            cell(source, L("Notify"), \.notify, on: sources.reads(source), reason: L("Reading is off, so there is nothing to notify about."))
            cell(source, L("Answer requests"), \.answer, on: sources.reads(source) && source.canAnswer, reason: answerReason(source))
            cell(source, L("Screen capture"), \.capture, on: sources.reads(source), reason: L("Reading is off, so no window shows it."))
        }
        .frame(minHeight: 34)
        .padding(.vertical, 3)
        .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }

    /// - Parameter on: whether the switch can be used. One that cannot shows as off and says why, and what the person chose stays.
    private func cell(_ source: SourceID, _ name: String, _ path: WritableKeyPath<SourceSwitches, Bool>, on enabled: Bool, reason: String, reading: Bool = false) -> some View {
        Toggle(name, isOn: Binding {
            enabled && sources[source][keyPath: path]
        } set: {
            settings.sources[source][keyPath: path] = $0
            model.sourcesChanged(reading: reading)
        })
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .disabled(!enabled)
        .frame(width: Self.column)
        // A disabled control shows no help of its own, so it hangs on the cell around it.
        .contentShape(Rectangle())
        .help(enabled ? "" : reason)
        .accessibilityLabel("\(source.title), \(name)")
        .accessibilityHint(enabled ? "" : reason)
    }

    private func answerReason(_ source: SourceID) -> String {
        switch source {
        case .cowork: return L("Requests from Cowork are answered in Claude Desktop.")
        case .chat: return L("The chat has no requests.")
        default: return L("Reading is off, so Claude does not ask through Boris.")
        }
    }

    private func detail(_ source: SourceID) -> String? {
        switch source {
        case .remote: return L("Over SSH, see Connections")
        case .cowork: return L("Requests are answered in Claude Desktop")
        case .chat: return L("The chat has no requests. To see that a reply is ready, Boris needs the Accessibility permission.")
        default: return nil
        }
    }
}

/// Above every page while nothing at all is being read, so that an empty Boris is not taken for an idle Claude.
struct SourcesOffNotice: View {
    @Bindable var model: AppModel
    var openSettings: (SettingsSection) -> Void

    var body: some View {
        if model.settings.sources.allOff {
            NoticeBanner(kind: .stopped, title: L("All sources are off"), text: L("Claude works as usual. Boris reads nothing until you turn a source back on.")) {
                Button(L("Open Sources")) { openSettings(.sources) }.buttonStyle(PlainActionStyle())
            }
        }
    }
}

/// Next to a total that leaves something out because a source is off.
struct SourcesIncompleteNote: View {
    var settings: SourceSettings

    var body: some View {
        // With everything off the notice above the page has said it already.
        if !settings.allOff, let note = SourceWords.incompleteNote(settings) {
            Text(note)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What a card says to do when a source's requests are not to be answered here.
enum SourcesRequestWords {
    static func notAnswered(_ session: WorkSession?, settings: SourceSettings) -> String? {
        guard let source = SourceID(session?.environment), !settings.answers(source) else { return nil }
        return L("Answers from Boris are off for %@. Answer in the session.", source.title)
    }
}

#if DEBUG
/// Choices made up for pictures of the screens.
@MainActor
enum SourceSnapshots {
    static func prepare(_ screen: String, model: AppModel) {
        switch screen {
        case "sourcesMixed", "spendIncomplete", "lossesIncomplete", "projectsIncomplete", "nowIncomplete", "miniIncomplete":
            model.settings.sources[.cursor].read = false
            model.settings.sources[.vsCode].notify = false
            model.settings.sources[.terminal].answer = false
            model.settings.sources.set(.cowork, on: false)
            model.settings.sources[.claudeDesktop].capture = false
        case "sourcesAllOff", "nowAllOff", "miniAllOff":
            for product in SourceProduct.allCases { model.settings.sources.set(product, on: false) }
        default:
            break
        }
    }
}
#endif
