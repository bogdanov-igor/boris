import BorisCore
import SwiftUI

struct SurfacesSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsStub(text: L("The icon, the notch, the mini window and the choice of screen will be set here."))
    }
}
