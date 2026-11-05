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

/// On real processes, because the units of the kernel's numbers can only be checked against a real clock.
@Suite("Замер на настоящих процессах", .serialized)
struct MacLoadSamplerTests {
    /// A shell that keeps one core busy through a child, then stops by itself even if the test crashes.
    private func burner(seconds: Int) throws -> Process {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "/usr/bin/yes > /dev/null & child=$!; sleep \(seconds); kill $child"]
        try shell.run()
        return shell
    }

    private func sampler() -> MacLoadSampler {
        MacLoadSampler(logRoots: { [] })
    }

    /// The kernel updates the CPU counters in bursts, so how soon a difference appears is up to it.
    private func readingWithCPU(_ sampler: MacLoadSampler) async -> MacLoad {
        var load = await sampler.read(LoadRequest())
        for _ in 0..<50 where load.cpu == nil {
            try? await Task.sleep(for: .milliseconds(100))
            load = await sampler.read(LoadRequest())
        }
        return load
    }

    @Test("Команда сессии видна в её нагрузке в единицах всего Mac")
    func commandOfASession() async throws {
        let shell = try burner(seconds: 6)
        defer { shell.terminate() }
        let sampler = sampler()
        let request = LoadRequest(sessions: ["s": shell.processIdentifier])
        _ = await sampler.read(LoadRequest(sessions: request.sessions, restart: true))
        try await Task.sleep(for: .seconds(2))
        let load = await sampler.read(request)
        let oneCore = 100 / Double(ProcessInfo.processInfo.activeProcessorCount)
        let taken = try #require(load.sessions["s"])
        // A busy machine gives the child less than a whole core, but never more.
        #expect(taken.cpu > oneCore * 0.2, "\(taken.cpu) with one core at \(oneCore)")
        #expect(taken.cpu < oneCore * 1.2, "\(taken.cpu) with one core at \(oneCore)")
        #expect(taken.memory > 0)
        // As a session it is Claude, so Claude has at least as much.
        #expect((load.cpu?.part(.claude)?.value ?? 0) >= min(taken.cpu, load.cpu?.total ?? 0) * 0.99)
    }

    @Test("Части настоящей нагрузки сходятся с итогом, а значения правдоподобны")
    func realReading() async throws {
        let sampler = sampler()
        let first = await sampler.read(LoadRequest(restart: true))
        #expect(first.cpu == nil)
        #expect(first.cpuPending, "the first reading has nothing to compare with, which is not a failure")
        #expect(first.memory != nil, "memory needs no second reading")
        let load = await readingWithCPU(sampler)
        let cpu = try #require(load.cpu)
        #expect(!load.cpuPending)
        let memory = try #require(load.memory)
        #expect((0...100).contains(cpu.points))
        #expect(memory.points > 0 && memory.points <= 100)
        #expect(cpu.parts.reduce(0) { $0 + $1.points } == cpu.points)
        #expect(memory.parts.reduce(0) { $0 + $1.points } == memory.points)
        #expect(try #require(load.diskPercent) > 0)
        #expect(load.physicalMemory == ProcessInfo.processInfo.physicalMemory)
    }

    @Test("Начало заново забывает прошлую точку отсчёта")
    func restartForgets() async throws {
        let sampler = sampler()
        _ = await sampler.read(LoadRequest(restart: true))
        #expect(await readingWithCPU(sampler).cpu != nil)
        let again = await sampler.read(LoadRequest(restart: true))
        #expect(again.cpu == nil)
        #expect(again.cpuPending)
    }

    @Test("Размер логов складывается из размеров файлов, а без папки его нет")
    func logSize() throws {
        let folder = TempFolder()
        folder.write("p/s.jsonl", String(repeating: "x", count: 1000))
        folder.write("p/s/subagents/a.jsonl", String(repeating: "x", count: 500))
        #expect(MacLoadSampler.size(of: [folder.url]) == 1500)
        let missing = folder.url.appendingPathComponent("nothing")
        #expect(MacLoadSampler.size(of: [missing]) == nil)
        #expect(MacLoadSampler.size(of: [missing, folder.url]) == 1500)
        #expect(MacLoadSampler.size(of: []) == nil)
    }

    @Test("Занятая доля диска похожа на то, что говорит система")
    func diskShare() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let percent = try #require(MacLoadSampler.diskPercent(of: home))
        #expect(percent > 0 && percent <= 100)
        #expect(MacLoadSampler.diskPercent(of: URL(fileURLWithPath: "/no/such/folder")) == nil)
    }

    /// CPU time, not the clock: a machine busy with other work must not fail this.
    @Test("Один замер стоит миллисекунды процессорного времени")
    func cost() async throws {
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let sampler = sampler()
        _ = await sampler.read(LoadRequest(restart: true))
        let began = cpuSeconds()
        let count = 50
        for _ in 0..<count { _ = await sampler.read(LoadRequest()) }
        let each = (cpuSeconds() - began) / Double(count)
        // Tests run in parallel and the whole process is counted, so this is well above the 2 ms measured alone in a debug build.
        // Even at this limit, one reading in 3 seconds would be under 1% of one core.
        #expect(each < 0.03, "\(each * 1000) ms per reading")
    }
}
