import BorisCore
import BorisData
import SwiftUI

/// All that can be known about a chat: an answer is being written, or it is ready. The page says so plainly, rather than showing empty numbers.
struct ChatSessionView: View {
    @Bindable var model: AppModel
    var session: WorkSession

    private var mode: DisplayMode { model.settings.displayMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Crumbs(model: model, project: .some(nil), projectIsLast: false)
                HStack(spacing: 10) {
                    Text(session.displayName)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    EnvironmentChip(environment: session.environment)
                    HStack(spacing: 6) {
                        StatusGlyph(kind: StatusGlyph.Kind(session.state), size: 14)
                        Text(WorkPhrases.line(session, mode: mode)).lineLimit(1)
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(session.state.color)
                    .fixedSize()
                    Spacer(minLength: 0)
                    OpenSessionButton(model: model, session: session)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 20))
            Rectangle().fill(Palette.separator).frame(height: 1)
            PageEmpty(title: WorkPhrases.line(session, mode: mode), text: L("For a chat in Claude Desktop, only whether an answer is ready can be known. Its tokens and actions are not available, and its text is never read."))
        }
    }
}
