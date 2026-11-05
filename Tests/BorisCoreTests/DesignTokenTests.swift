import BorisCore
import Testing

@Suite("Токены дизайна")
struct DesignTokenTests {
    @Test("Весь текст читается на всех поверхностях в обеих темах")
    func textContrast() {
        for (textName, text) in DesignTokens.textColors {
            for (surfaceName, surface) in DesignTokens.surfaces {
                let light = text.light.contrast(on: surface.light)
                let dark = text.dark.contrast(on: surface.dark)
                #expect(light >= 4.5, "\(textName) на \(surfaceName), светлая: \(light)")
                #expect(dark >= 4.5, "\(textName) на \(surfaceName), тёмная: \(dark)")
            }
        }
    }

    @Test("Чёрный на белом даёт контраст 21")
    func contrastFormula() {
        let black = TokenColor(hex: 0x000000)
        let white = TokenColor(hex: 0xFFFFFF)
        #expect(abs(black.contrast(on: white) - 21) < 0.01)
    }

    @Test("Прозрачный цвет смешивается с фоном")
    func blending() {
        let half = TokenColor(hex: 0x000000, alpha: 0.5).over(TokenColor(hex: 0xFFFFFF))
        #expect(abs(half.red - 0.5) < 0.001)
        #expect(half.alpha == 1)
    }
}

@Suite("Языки")
struct LocalizationTests {
    @Test("Выбирается первый поддерживаемый язык системы", arguments: [
        (["ru-RU", "en-US"], AppLanguage.ru),
        (["en-GB", "ru"], AppLanguage.en),
        (["uz-UZ", "ru-RU"], AppLanguage.ru),
        (["de-DE"], AppLanguage.en),
        ([], AppLanguage.en),
    ])
    func preferred(languages: [String], expected: AppLanguage) {
        #expect(AppLanguage.preferred(from: languages) == expected)
    }

    @Test("Без таблицы перевода остаётся ключ на английском")
    func missingTable() {
        // The language itself stays as it is: other tests running at the same time read it, and Russian numbers would fail them.
        #expect(Localizer.string("Hello from a test", language: .ru) == "Hello from a test")
    }

    @Test("Английский не подхватывает язык системы")
    func englishStaysEnglish() {
        Localizer.use(.en)
        #expect(Localizer.string("Done") == "Done")
    }

    @Test("Подстановка значений работает")
    func format() {
        #expect(L("%lld agents", 3) == "3 agents")
    }
}
