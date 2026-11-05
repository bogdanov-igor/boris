import BorisCore
import Testing

@Suite("Блоки текста Claude")
struct TextBlockTests {
    @Test("Текст делится на блоки") func blocks() {
        let text = "# Заголовок\n\nПервая строка\nвторая строка\n\n- один\n* два\n\n```swift\nlet a = 1\n\nlet b = 2\n```\nКонец"
        #expect(TextBlock.parse(text) == [
            .heading("Заголовок"),
            .paragraph("Первая строка вторая строка"),
            .bullet("один"),
            .bullet("два"),
            .code("let a = 1\n\nlet b = 2"),
            .paragraph("Конец"),
        ])
    }

    @Test("Незакрытый блок кода не теряется") func openFence() {
        #expect(TextBlock.parse("```\nlet a") == [.code("let a")])
    }
}
