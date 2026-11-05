import BorisCore
import SwiftUI

struct NotificationSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsStub(text: L("Which events reach you, and how, will be set here."))
    }
}
