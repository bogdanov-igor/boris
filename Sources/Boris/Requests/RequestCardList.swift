import BorisCore
import BorisData
import SwiftUI

/// The requests waiting for an answer, as cards. Every surface shows them with this.
struct RequestCardList: View {
    @Bindable var model: AppModel
    /// Where an answer given here counts as given.
    var surface: RequestPlace = .window

    var body: some View {
        let rows = model.hooks.queue.rows(now: Date())
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: surface == .mini ? 6 : 8) {
                Text(L("Waiting for you · %lld", rows.count))
                    .font(.system(size: surface == .mini ? 11.5 : 13, weight: .semibold))
                    .foregroundStyle(Palette.waiting)
                    .padding(.horizontal, surface == .mini ? 2 : 0)
                ForEach(rows) { row in
                    switch row {
                    case .open(let request): RequestCard(model: model, request: request, surface: surface)
                    case .expired, .waiting: RequestNoticeCard(model: model, row: row)
                    }
                }
            }
        }
    }
}
