import BorisCore
import SwiftUI

/// A temporary page to check tokens, themes and languages until the real screens arrive.
struct TokenPage: View {
    @Bindable var settings: AppSettings

    private var swatches: [(String, Color)] {
        [
            (L("Running"), Palette.running), (L("Waiting"), Palette.waiting), (L("Done"), Palette.done),
            (L("Failed"), Palette.redText), (L("Limit"), Palette.limit),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Language and theme"))
                .font(.system(size: DesignMetrics.textHeading, weight: .semibold))
                .foregroundStyle(Palette.text1)
            Picker(L("Language"), selection: $settings.language) {
                ForEach(AppLanguage.allCases, id: \.self) { Text($0.nativeName).tag($0) }
            }
            Picker(L("Theme"), selection: $settings.theme) {
                Text(L("Light")).tag(ThemeMode.light)
                Text(L("Dark")).tag(ThemeMode.dark)
                Text(L("System")).tag(ThemeMode.system)
            }
            Divider().overlay(Palette.separator)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Primary text")).foregroundStyle(Palette.text1)
                Text(L("Secondary text")).foregroundStyle(Palette.text2)
                Text(L("Quiet text")).foregroundStyle(Palette.text3)
            }
            .font(.system(size: DesignMetrics.textBody))
            HStack(spacing: 8) {
                ForEach(swatches, id: \.0) { name, color in
                    Text(name)
                        .font(.system(size: DesignMetrics.textCaption, weight: .medium))
                        .foregroundStyle(color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Palette.fill1, in: RoundedRectangle(cornerRadius: DesignMetrics.radiusSmall))
                }
            }
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: DesignMetrics.radiusSmall).fill(Palette.brandRed).frame(width: 40, height: 16)
                RoundedRectangle(cornerRadius: DesignMetrics.radiusSmall).fill(Palette.brandGold).frame(width: 40, height: 16)
                Text(L("Brand, only next to the walrus"))
                    .font(.system(size: DesignMetrics.textCaption))
                    .foregroundStyle(Palette.text2)
            }
        }
        .padding(20)
        .background(Palette.window)
        .id(settings.language)
    }
}
