import BorisCore
import SwiftUI

/// How loaded this Mac is, and by whom.
struct MacLoadBlock: View {
    enum Kind {
        case miniSimple, miniTechnical, pageSimple, pageTechnical
    }

    @Bindable var model: AppModel
    var kind: Kind

    var body: some View {
        EmptyView()
    }
}
