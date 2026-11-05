@testable import BorisCharacter
import Testing

@Test("Модуль моржа подключён")
func characterModuleLinks() {
    #expect(String(describing: BorisCharacter.self) == "BorisCharacter")
}
