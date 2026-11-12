import BorisCore
import Darwin
import Foundation
import Testing
@testable import BorisData

/// What one reading of the Mac's load costs. It counts the whole process's CPU time, so it lives here, where the timing tests
/// run one at a time in a process of their own: next to the other suites it counted their work too and failed on a busy run.
@Suite("Цена замера нагрузки", .serialized)
struct MacLoadCostTests {
    @Test("Один замер стоит миллисекунды процессорного времени")
    func cost() async throws {
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let sampler = MacLoadSampler(logRoots: { [] })
        _ = await sampler.read(LoadRequest(restart: true))
        let began = cpuSeconds()
        let count = 50
        for _ in 0..<count { _ = await sampler.read(LoadRequest()) }
        let each = (cpuSeconds() - began) / Double(count)
        // Measured alone in a debug build it is about 2 ms. Even at this limit, one reading in 3 seconds would be under 1% of one core.
        #expect(each < 0.03, "\(each * 1000) ms per reading")
    }
}
