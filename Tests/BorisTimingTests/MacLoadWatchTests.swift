import BorisCore
import Darwin
import Foundation
import Testing
@testable import BorisData

/// Waits until something holds, without betting on the machine's speed.
@MainActor
private func eventually(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(seconds)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private final class Readings {
    var requests: [LoadRequest] = []

    var reader: MacLoadWatch.Reader {
        { request in
            await MainActor.run { self.requests.append(request) }
            return MacLoad(diskPercent: 1)
        }
    }
}

extension TimingTests {
    @Suite("Замер только пока блок виден")
    @MainActor
    struct MacLoadWatchTests {
        private func watch(_ readings: Readings) -> MacLoadWatch {
            MacLoadWatch(reader: readings.reader, period: .milliseconds(5), secondReadingAfter: .milliseconds(1))
        }

        @Test("Пока никто не смотрит, замеров нет")
        func nobodyLooking() async {
            let readings = Readings()
            let watch = watch(readings)
            try? await Task.sleep(for: .milliseconds(100))
            #expect(readings.requests.isEmpty)
            #expect(!watch.isReading)
            #expect(watch.current == nil)
        }

        @Test("Блок появился: замеры идут и значения приходят")
        func looking() async {
            let readings = Readings()
            let watch = watch(readings)
            watch.setVisible(true, viewer: UUID())
            #expect(await eventually { watch.current != nil && readings.requests.count >= 3 })
            #expect(readings.requests.first?.restart == true)
            #expect(readings.requests.dropFirst().allSatisfy { !$0.restart })
        }

        @Test("Блок скрыт: замеры прекращаются, а старые цифры не остаются")
        func stops() async {
            let readings = Readings()
            let watch = watch(readings)
            let viewer = UUID()
            watch.setVisible(true, viewer: viewer)
            #expect(await eventually { watch.current != nil })
            watch.setVisible(false, viewer: viewer)
            #expect(!watch.isReading)
            #expect(watch.current == nil)
            // A reading under way may still finish, so the count settles first.
            try? await Task.sleep(for: .milliseconds(50))
            let settled = readings.requests.count
            try? await Task.sleep(for: .milliseconds(100))
            #expect(readings.requests.count == settled)
            #expect(watch.current == nil)
        }

        @Test("Пока виден хотя бы один блок, замеры идут, и лишние сообщения ничего не ломают")
        func twoViewers() async {
            let readings = Readings()
            let watch = watch(readings)
            let mini = UUID()
            let page = UUID()
            watch.setVisible(true, viewer: mini)
            watch.setVisible(true, viewer: mini)
            watch.setVisible(true, viewer: page)
            watch.setVisible(false, viewer: page)
            watch.setVisible(false, viewer: page)
            #expect(watch.isReading)
            watch.setVisible(false, viewer: mini)
            #expect(!watch.isReading)
        }

        @Test("Снова открытый блок начинает с новой точки отсчёта")
        func restart() async {
            let readings = Readings()
            let watch = watch(readings)
            let viewer = UUID()
            watch.setVisible(true, viewer: viewer)
            #expect(await eventually { readings.requests.count >= 2 })
            watch.setVisible(false, viewer: viewer)
            try? await Task.sleep(for: .milliseconds(50))
            let before = readings.requests.count
            watch.setVisible(true, viewer: viewer)
            #expect(await eventually { readings.requests.count > before })
            #expect(readings.requests[before].restart)
            watch.setVisible(false, viewer: viewer)
        }

        @Test("Без читателя, как на снимках экранов, ничего не запускается и цифры остаются")
        func snapshotsReadNothing() {
            let watch = MacLoadWatch()
            watch.showForSnapshot(MacLoad(diskPercent: 5))
            watch.setVisible(true, viewer: UUID())
            #expect(!watch.isReading)
            watch.setVisible(false, viewer: UUID())
            #expect(watch.current?.diskPercent == 5)
        }

        @Test("Новый читатель подхватывается, пока блок открыт")
        func newReader() async {
            let old = Readings()
            let new = Readings()
            let watch = watch(old)
            let viewer = UUID()
            watch.setVisible(true, viewer: viewer)
            #expect(await eventually { !old.requests.isEmpty })
            watch.reader = new.reader
            #expect(await eventually { !new.requests.isEmpty })
            watch.setVisible(false, viewer: viewer)
        }

        @Test("Замер получает сессии и выключенные источники")
        func requestCarriesContext() async {
            let readings = Readings()
            let watch = watch(readings)
            watch.sessions = { ["s": 7] }
            watch.off = [.cursor]
            watch.setVisible(true, viewer: UUID())
            #expect(await eventually { !readings.requests.isEmpty })
            #expect(readings.requests.first?.sessions == ["s": 7])
            #expect(readings.requests.first?.off == [.cursor])
        }
    }
}
