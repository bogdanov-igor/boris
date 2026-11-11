import BorisCore
import Darwin
import Foundation
import Testing
@testable import BorisData

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

    @Test("Занятый заново номер это новый процесс, а exec новая программа того же процесса")
    func reusedNumberAndExec() {
        typealias Seen = MacLoadSampler.Seen
        var asked = 0
        func mark() -> LoadGroup? {
            asked += 1
            return .claude
        }
        let before = Seen(start: 1, cpuNanoseconds: 500, program: 7, mark: .vsCode)

        let same = Seen.next(after: before, start: 1, cpuNanoseconds: 800, program: 7, mark: mark)
        #expect(same.spent == 300)
        #expect(same.seen.mark == .vsCode)
        #expect(asked == 0, "looking up the path of every process on every reading would cost for nothing")

        var unmarked = before
        unmarked.mark = nil
        #expect(Seen.next(after: unmarked, start: 1, cpuNanoseconds: 800, program: 7, mark: mark).seen.mark == nil)
        #expect(asked == 0, "most processes say nothing about themselves, and they are not asked again either")

        let reused = Seen.next(after: before, start: 2, cpuNanoseconds: 100, program: 7, mark: mark)
        #expect(reused.spent == 100, "all its time is new, however the old one's compares")
        #expect(reused.seen.mark == .claude)
        #expect(asked == 1)

        let exec = Seen.next(after: before, start: 1, cpuNanoseconds: 800, program: 9, mark: mark)
        #expect(exec.spent == 300, "the process goes on, and so does its time")
        #expect(exec.seen.mark == .claude)
        #expect(asked == 2)

        let new = Seen.next(after: nil, start: 3, cpuNanoseconds: 40, program: 7, mark: mark)
        #expect(new.spent == 40)
        #expect(new.seen.mark == .claude)

        let backwards = Seen.next(after: before, start: 1, cpuNanoseconds: 400, program: 7, mark: mark)
        #expect(backwards.spent == 0)
    }

    /// A shell that waits for a line and then becomes a program named `claude`. Started this way, the process keeps its number and start time.
    @Test("Процесс, который стал другой программой через exec, узнаётся заново")
    func execIsSeen() async throws {
        let folder = TempFolder()
        let claude = folder.url.appendingPathComponent("claude")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: claude)
        // The system kills a copy of its own program unless the copy is signed anew.
        let signing = Process()
        signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["-f", "-s", "-", claude.path]
        signing.standardError = FileHandle.nullDevice
        try signing.run()
        signing.waitUntilExit()
        try #require(signing.terminationStatus == 0)

        let shell = Process()
        let input = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "read line; exec \"$0\" 20", claude.path]
        shell.standardInput = input
        try shell.run()
        defer { shell.terminate() }
        let pid = shell.processIdentifier

        let sampler = sampler()
        _ = await sampler.read(LoadRequest(restart: true))
        // /bin/sh hands over to the real shell, so it is a shell only a moment later.
        try await Task.sleep(for: .milliseconds(200))
        _ = await sampler.read(LoadRequest())
        #expect(await sampler.seen[pid]?.mark == nil)

        input.fileHandleForWriting.write(Data("go\n".utf8))
        var mark: LoadGroup?
        for _ in 0..<100 where mark == nil {
            try await Task.sleep(for: .milliseconds(20))
            _ = await sampler.read(LoadRequest())
            mark = await sampler.seen[pid]?.mark
        }
        #expect(mark == .claude)
    }

    @Test("Процессы, исчезающие во время замера, ничего не ломают, и части сходятся")
    func vanishingProcesses() async throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "i=0; while [ $i -lt 150 ]; do /usr/bin/true & i=$((i+1)); done; wait"]
        try shell.run()
        defer { shell.terminate() }
        let sampler = sampler()
        let request = LoadRequest(sessions: ["s": shell.processIdentifier])
        _ = await sampler.read(LoadRequest(sessions: request.sessions, restart: true))
        for _ in 0..<30 {
            let load = await sampler.read(request)
            if let cpu = load.cpu { #expect(cpu.parts.reduce(0) { $0 + $1.points } == cpu.points) }
            if let memory = load.memory { #expect(memory.parts.reduce(0) { $0 + $1.points } == memory.points) }
        }
        waitUntilGone(shell, seconds: 30)
        // A session whose process has gone has nothing to show, and that is not a zero.
        #expect(await sampler.read(request).sessions["s"] == nil)
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
