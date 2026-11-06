import Foundation
import BorisCore

// Called by Claude Code when hook mode is on. It must never get in the way: any problem means a silent exit.
// Usage: boris-hook                  sends the event and exits
//        boris-hook --permission N   sends a request and waits for the answer. N is only the upper limit:
//                                    the app decides how long to wait and closes the connection when the time is up.

// The app can vanish while this writes, and that must end in a quiet exit too.
signal(SIGPIPE, SIG_IGN)

let socketPath = ProcessInfo.processInfo.environment["BORIS_HOOK_SOCKET"]
    ?? NSHomeDirectory() + "/Library/Application Support/Boris/hook.sock"

guard access(socketPath, F_OK) == 0 else { exit(0) }

let arguments = CommandLine.arguments
var waitSeconds: Int32? = arguments.firstIndex(of: "--permission").flatMap { index in
    index + 1 < arguments.count ? Int32(arguments[index + 1]) : nil
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }

// A source the person turned off or does not want answered must not hold Claude up. The file says which, and nothing here waits for the app.
let policy = HookPolicy.load(from: URL(fileURLWithPath: socketPath).deletingLastPathComponent().appendingPathComponent(HookPolicy.fileName))
let entrypoint = ProcessInfo.processInfo.environment["CLAUDE_CODE_ENTRYPOINT"]
    ?? (object["transcript_path"] as? String).flatMap { TranscriptHead.entrypoint(in: URL(fileURLWithPath: $0)).entrypoint }
let source = SourceDetection.source(entrypoint: entrypoint) { SourceDetection.editor(of: getpid()) }
let action = policy.action(for: source, asking: waitSeconds != nil)
if action == .leave { exit(0) }
if action == .tell { waitSeconds = nil }

var payload = HookPayload.reduce(object, withRequest: action == .ask)
if let source { payload["boris_source"] = source.rawValue }
if waitSeconds != nil { payload["wait"] = true }
guard var message = try? JSONSerialization.data(withJSONObject: payload) else { exit(0) }
message.append(0x0A)

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    buffer.copyBytes(from: pathBytes)
}
let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { exit(0) }

let sent = message.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
guard sent == message.count, let waitSeconds else { exit(0) }

// The answer is one line. Until the whole of it is here there is no answer, so a cut-off line decides nothing.
let giveUpAt = Date().addingTimeInterval(TimeInterval(waitSeconds))
var line = Data()
var buffer = [UInt8](repeating: 0, count: 16 * 1024)
while !line.contains(0x0A) {
    let left = Int32(giveUpAt.timeIntervalSinceNow * 1000)
    var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard left > 0, poll(&poller, 1, left) > 0 else { exit(0) }
    let count = read(fd, &buffer, buffer.count)
    guard count > 0 else { exit(0) }
    line.append(contentsOf: buffer[0..<count])
}

let original = object["tool_input"] as? [String: Any]
if let answer = HookAnswer(line: line), let output = answer.output(tool: object["tool_name"] as? String, input: original) {
    // This form reports a closed pipe as an error, where the older one raises an exception and crashes.
    try? FileHandle.standardOutput.write(contentsOf: output)
}
exit(0)
