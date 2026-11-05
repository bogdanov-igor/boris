import BorisCore
import SwiftUI

struct SourcesSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsStub(text: L("Which Claude products and environments Boris reads, notifies about and may answer will be set here."))
    }
}
