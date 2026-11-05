import Foundation
import BorisCore

// Called by Claude Code when hook mode is on. It must never get in the way: any problem means a silent exit.
// Usage: boris-hook                  sends the event and exits
//        boris-hook --permission N   sends a permission request and waits up to N seconds for the answer

let socketPath = ProcessInfo.processInfo.environment["BORIS_HOOK_SOCKET"]
    ?? NSHomeDirectory() + "/Library/Application Support/Boris/hook.sock"

guard access(socketPath, F_OK) == 0 else { exit(0) }

let arguments = CommandLine.arguments
let waitSeconds: Int32? = arguments.firstIndex(of: "--permission").flatMap { index in
    index + 1 < arguments.count ? Int32(arguments[index + 1]) : nil
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }
var payload = HookPayload.reduce(object)
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

var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
guard poll(&poller, 1, waitSeconds * 1000) > 0 else { exit(0) }
var buffer = [UInt8](repeating: 0, count: 256)
let count = read(fd, &buffer, buffer.count)
guard count > 0 else { exit(0) }
let answer = String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

var decision: [String: Any]?
switch answer {
case "allow":
    decision = ["behavior": "allow"]
case "deny":
    decision = ["behavior": "deny", "message": "Denied in Boris"]
default:
    decision = nil
}
if let decision, let output = try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]) {
    FileHandle.standardOutput.write(output)
}
exit(0)
