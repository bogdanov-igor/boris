import BorisCore
import Foundation
import Testing

/// The trees here are invented, in the shapes real ones have.
@Suite("Нагрузка на Mac: группы и суммы")
struct MacLoadTests {
    /// VS Code with helpers, a Claude session in its extension host, and that session's command and MCP server.
    private var editorTree: [LoadProcess] {
        [
            LoadProcess(pid: 100, parent: 1, mark: .vsCode, cpu: 2, memory: 300),
            LoadProcess(pid: 101, parent: 100, mark: .vsCode, cpu: 1, memory: 100),
            LoadProcess(pid: 102, parent: 100, mark: .vsCode, cpu: 3, memory: 200),
            LoadProcess(pid: 200, parent: 102, mark: .claude, cpu: 5, memory: 400),
            LoadProcess(pid: 201, parent: 200, cpu: 4, memory: 50),
            LoadProcess(pid: 202, parent: 201, cpu: 6, memory: 60),
            LoadProcess(pid: 203, parent: 200, mark: nil, cpu: 1, memory: 70),
        ]
    }

    private func total(_ split: LoadSplit?) -> Int {
        split?.parts.reduce(0) { $0 + $1.points } ?? -1
    }

    @Test("Приложение из многих процессов считается одной группой")
    func manyHelpersAreOneGroup() {
        let groups = LoadGrouping.groups(of: editorTree, sessions: [])
        #expect([100, 101, 102].allSatisfy { groups[$0] == .vsCode })
    }

    @Test("Claude в редакторе входит только в Claude, вместе с потомками")
    func claudeIsTakenOutOfTheEditor() {
        let load = LoadGrouping.load(processes: editorTree, sessions: ["s": 200], totalCPU: 50, usedMemory: 2000, physicalMemory: 10000)
        #expect(load.cpu?.part(.claude)?.value == 16)
        #expect(load.cpu?.part(.vsCode)?.value == 6)
        #expect(load.cpu?.part(.rest)?.value == 28)
        #expect(load.memory?.part(.claude)?.value == 5.8)
        #expect(load.memory?.part(.vsCode)?.value == 6)
    }

    @Test("Сессия из реестра без примет Claude всё равно Claude")
    func registeredSessionWithoutMark() {
        var tree = editorTree
        tree[3].mark = nil
        let groups = LoadGrouping.groups(of: tree, sessions: [200])
        #expect(groups[200] == .claude)
        #expect(groups[202] == .claude)
        // Without the registry this one looks like a plain helper of the editor.
        #expect(LoadGrouping.groups(of: tree, sessions: [])[202] == .vsCode)
    }

    @Test("Claude важнее ближайшего родителя: команда из сессии не уходит в другой редактор")
    func programStartedByClaude() {
        let tree = [
            LoadProcess(pid: 10, parent: 1, mark: .claude),
            LoadProcess(pid: 11, parent: 10, mark: .cursor),
            LoadProcess(pid: 12, parent: 11),
        ]
        let groups = LoadGrouping.groups(of: tree, sessions: [])
        #expect(groups[11] == .claude)
        #expect(groups[12] == .claude)
    }

    @Test("Каждый процесс считается ровно один раз")
    func nothingCountedTwice() {
        let processes = editorTree
        let load = LoadGrouping.load(processes: processes, sessions: ["s": 200], totalCPU: 100, usedMemory: 10000, physicalMemory: 10000)
        let named = (load.cpu?.parts ?? []).filter { $0.group != .rest }.reduce(0) { $0 + $1.value }
        #expect(named == processes.reduce(0) { $0 + $1.cpu })
    }

    @Test("Сумма частей равна итогу и в целых числах на экране")
    func partsAddUp() {
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<2000 {
            let total = Double.random(in: 0...100, using: &generator)
            var named: [LoadGroup: Double] = [:]
            for group in LoadGroup.allCases where group != .rest && Bool.random(using: &generator) {
                named[group] = Double.random(in: 0...40, using: &generator)
            }
            let split = LoadSplit(total: total, named: named)
            #expect(split.parts.reduce(0) { $0 + $1.points } == split.points)
            // A rest that got no whole percent has no line, and only that may be missing from the exact sum. It is always under one.
            let allowed = split.part(.rest) == nil ? 1 : 0.000001
            #expect(abs(split.parts.reduce(0) { $0 + $1.value } - split.total) < allowed)
            #expect(split.points == Int(total.rounded()))
        }
    }

    @Test("Если процессы вместе больше итога, они сжимаются, а итог не растёт")
    func moreThanTotalIsScaled() {
        let split = LoadSplit(total: 50, named: [.claude: 60, .vsCode: 40])
        #expect(split.points == 50)
        #expect(split.part(.claude)?.points == 30)
        #expect(split.part(.vsCode)?.points == 20)
        #expect(split.part(.rest) == nil)
    }

    @Test("Группа без процессов не показывается, а тихая показывается")
    func groupsWithoutProcesses() {
        let load = LoadGrouping.load(
            processes: [LoadProcess(pid: 5, parent: 1, mark: .boris, cpu: 0, memory: 1)],
            sessions: [:], totalCPU: 40, usedMemory: 40, physicalMemory: 100
        )
        #expect(load.cpu?.parts.map(\.group) == [.boris, .rest])
        #expect(load.cpu?.part(.boris)?.points == 0)
    }

    @Test("Части идут в порядке макета")
    func order() {
        let split = LoadSplit(total: 100, named: [.boris: 1, .claude: 1, .cursor: 1, .cowork: 1, .vsCode: 1, .claudeDesktop: 1])
        #expect(split.parts.map(\.group) == LoadGroup.allCases)
    }

    @Test("«Нет данных» отличается от нуля")
    func noDataIsNotZero() {
        let unread = LoadGrouping.load(processes: editorTree, sessions: [:], totalCPU: nil, usedMemory: nil, physicalMemory: 100)
        #expect(unread.cpu == nil)
        #expect(unread.memory == nil)
        let idle = LoadGrouping.load(processes: [], sessions: [:], totalCPU: 0, usedMemory: 0, physicalMemory: 100)
        #expect(idle.cpu?.points == 0)
        #expect(idle.cpu?.parts.isEmpty == true)
        let noMemorySize = LoadGrouping.load(processes: [], sessions: [:], totalCPU: 0, usedMemory: 5, physicalMemory: 0)
        #expect(noMemorySize.memory == nil)
    }

    @Test("Выключенный источник уходит в «Остальное» вместе с Claude внутри него")
    func offSource() {
        let load = LoadGrouping.load(processes: editorTree, sessions: [:], off: [.vsCode], totalCPU: 50, usedMemory: 2000, physicalMemory: 10000)
        #expect(load.cpu?.part(.vsCode) == nil)
        #expect(load.cpu?.part(.claude) == nil)
        #expect(load.cpu?.part(.rest)?.points == 50)
        #expect(load.offWithProcesses == [.vsCode])
    }

    @Test("Выключенный Cursor не трогает Claude в терминале и не упоминается, если не запущен")
    func offSourceElsewhere() {
        let tree = [LoadProcess(pid: 10, parent: 1, mark: .claude, cpu: 3)]
        let load = LoadGrouping.load(processes: tree, sessions: [:], off: [.cursor], totalCPU: 10, usedMemory: 0, physicalMemory: 100)
        #expect(load.cpu?.part(.claude)?.value == 3)
        #expect(load.offWithProcesses.isEmpty)
    }

    @Test("Выключенный Claude Code целиком тоже в «Остальном»")
    func offClaude() {
        let load = LoadGrouping.load(processes: editorTree, sessions: [:], off: [.claude], totalCPU: 50, usedMemory: 0, physicalMemory: 100)
        #expect(load.cpu?.part(.claude) == nil)
        #expect(load.cpu?.part(.vsCode)?.value == 6)
        #expect(load.offWithProcesses == [.claude])
    }

    @Test("Сессия это её процесс со всеми потомками, и только они")
    func sessionLoad() {
        let tree = editorTree + [
            LoadProcess(pid: 300, parent: 102, mark: .claude, cpu: 7, memory: 80),
            LoadProcess(pid: 301, parent: 300, cpu: 2, memory: 20),
        ]
        let load = LoadGrouping.load(processes: tree, sessions: ["first": 200, "second": 300, "gone": 999], totalCPU: 60, usedMemory: 0, physicalMemory: 100)
        #expect(load.sessions["first"] == SessionLoad(cpu: 16, memory: 580))
        #expect(load.sessions["second"] == SessionLoad(cpu: 9, memory: 100))
        #expect(load.sessions["gone"] == nil)
    }

    @Test("Сессия внутри сессии входит в обе, а в группе Claude считается один раз")
    func nestedSession() {
        let tree = [
            LoadProcess(pid: 10, parent: 1, mark: .claude, cpu: 1, memory: 1),
            LoadProcess(pid: 11, parent: 10, mark: .claude, cpu: 2, memory: 2),
        ]
        let load = LoadGrouping.load(processes: tree, sessions: ["outer": 10, "inner": 11], totalCPU: 10, usedMemory: 0, physicalMemory: 100)
        #expect(load.sessions["outer"]?.cpu == 3)
        #expect(load.sessions["inner"]?.cpu == 2)
        #expect(load.cpu?.part(.claude)?.value == 3)
    }

    @Test("Сломанное дерево не зависает и не теряет процессы")
    func brokenTree() {
        let tree = [
            LoadProcess(pid: 20, parent: 21, cpu: 1),
            LoadProcess(pid: 21, parent: 20, cpu: 1),
            LoadProcess(pid: 22, parent: 22, mark: .boris, cpu: 1),
            LoadProcess(pid: 23, parent: 9999, cpu: 1),
        ]
        let groups = LoadGrouping.groups(of: tree, sessions: [])
        #expect(groups[20] == .rest)
        #expect(groups[22] == .boris)
        #expect(groups[23] == .rest)
    }

    @Test("Три ядра из десяти это 30 %")
    func unifiedScale() {
        #expect(LoadGrouping.percentOfMac(cpuNanoseconds: 30_000_000_000, overNanoseconds: 10_000_000_000, cores: 10) == 30)
        #expect(LoadGrouping.percentOfMac(cpuNanoseconds: 1, overNanoseconds: 0, cores: 10) == 0)
    }

    @Test("Кого узнаём по пути", arguments: [
        ("/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)", LoadGroup.vsCode),
        ("/Applications/Visual Studio Code - Insiders.app/Contents/MacOS/Code", LoadGroup.vsCode),
        ("/Applications/Cursor.app/Contents/MacOS/Cursor", LoadGroup.cursor),
        ("/Users/x/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper", LoadGroup.cursor),
        ("/Applications/Claude.app/Contents/MacOS/Claude", LoadGroup.claudeDesktop),
        ("/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper", LoadGroup.claudeDesktop),
        ("/Applications/Boris.app/Contents/MacOS/Boris", LoadGroup.boris),
        ("/Users/x/.vscode/extensions/anthropic.claude-code-2.1.3-darwin-arm64/resources/native-binary/claude", LoadGroup.claude),
        ("/Users/x/.cursor/extensions/anthropic.claude-code-2.1.3/resources/native-binary/claude", LoadGroup.claude),
        ("/Users/x/.local/share/claude/versions/2.1.318", LoadGroup.claude),
        ("/Users/x/Library/Application Support/Claude/claude-code/2.1.3/claude", LoadGroup.claude),
    ])
    func marks(path: String, group: LoadGroup) {
        #expect(LoadGrouping.mark(path: path) == group)
    }

    @Test("Чужих по пути не трогаем", arguments: [
        "/bin/zsh",
        "/usr/bin/node",
        "/Applications/NotCursor.app/Contents/MacOS/NotCursor",
        "/Applications/Claude Helper Tool.app/Contents/MacOS/Tool",
        "/Applications/Claude.app/Contents/Helpers/chrome-native-host",
        "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService",
        "",
    ])
    func noMark(path: String) {
        #expect(LoadGrouping.mark(path: path) == nil)
    }

    @Test("Виртуальная машина это Cowork, только если её запросил Claude")
    func virtualMachines() {
        let machine = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
        #expect(LoadGrouping.mark(path: machine, responsible: "/Applications/Claude.app/Contents/MacOS/Claude") == .cowork)
        #expect(LoadGrouping.mark(path: machine, responsible: "/Applications/Docker.app/Contents/MacOS/com.docker.backend") == nil)
        #expect(LoadGrouping.mark(path: machine) == nil)
    }

    @Test("Что говорит страница сессии о её нагрузке")
    func sessionPlaces() {
        func session(_ environment: WorkEnvironment?, _ state: WorkState) -> WorkSession {
            WorkSession(id: "s", environment: environment, state: state, root: WorkNode(id: "s", kind: .main))
        }
        #expect(SessionLoadPlace(session(.vsCode, .running)) == .here)
        #expect(SessionLoadPlace(session(.terminal, .waiting)) == .here)
        #expect(SessionLoadPlace(session(nil, .silent)) == .here)
        #expect(SessionLoadPlace(session(.vsCode, .finished)) == .none)
        #expect(SessionLoadPlace(session(.cowork, .running)) == .cowork)
        #expect(SessionLoadPlace(session(.cowork, .finished)) == .cowork)
        #expect(SessionLoadPlace(session(.remote(host: "m1"), .running)) == .remote(host: "m1"))
        #expect(SessionLoadPlace(session(.chat, .running)) == .none)
    }

    @Test("Размеры")
    func sizes() {
        #expect(WorkFormat.byteCount(0) == "0 KB")
        #expect(WorkFormat.byteCount(950 * 1024) == "950 KB")
        #expect(WorkFormat.byteCount(480 * 1 << 20) == "480 MB")
        #expect(WorkFormat.byteCount(3_006_477_107) == "2.8 GB")
        #expect(WorkFormat.byteCount(1400 * 1 << 30) == "1.4 TB")
    }
}

/// Numbers that are random yet the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
