import Foundation
import Darwin

@main enum Fixtures {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(-10))
        let day = String(iso.prefix(10)).replacingOccurrences(of: "-", with: "/")
        let id = "00000000-0000-4000-8000-000000000001"
        let log = ".codex/sessions/" + day + "/rollout-2001-01-01T00-00-00-" + id + ".jsonl"
        let projectLog = ".claude/projects/sample/" + id + ".jsonl"
        typealias Obj = [String: Any]
        func line(_ type: String, _ payload: Obj) -> Obj {
            ["timestamp": iso, "type": type, "payload": payload]
        }
        func window(_ percent: Any, _ minutes: Int, _ reset: Double = 3600) -> Obj {
            ["used_percent": percent, "window_minutes": minutes, "resets_at": now.timeIntervalSince1970 + reset]
        }
        func limits(_ fields: Obj) -> Obj {
            line("event_msg", ["type": "token_count", "rate_limits": fields])
        }
        func write(_ home: String, _ path: String, _ rows: [Obj]) throws {
            let url = root.appendingPathComponent(home).appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var bytes = Data()
            for row in rows {
                bytes.append(try JSONSerialization.data(withJSONObject: row))
                bytes.append(10)
            }
            try bytes.write(to: url)
        }
        func load(_ name: String, _ env: [String: String] = [:]) -> Snapshot {
            LocalUsage.load(home: root.appendingPathComponent(name).path, environment: env, now: now)
        }
        func check(_ value: Bool, _ label: String) {
            if !value { fatalError(label) }
        }
        // Negative controls verify the constraints used to run both the fixture reader and the signed GUI.
        let credential = root.appendingPathComponent("auth.json").path
        check(fm.createFile(atPath: credential, contents: Data("fixture-private-marker".utf8)), "fixture write")
        let handle = open(credential, O_RDONLY)
        check(handle < 0 && errno == EPERM, "credential read must be denied")
        var child: pid_t = 0
        let args = [strdup("/usr/bin/true"), nil]
        defer { free(args[0]) }
        check(posix_spawn(&child, args[0]!, nil, nil, args, nil) == EPERM, "child process must be denied")
        var peer = sockaddr_in()
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        peer.sin_port = UInt16(9).bigEndian
        peer.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        if socketFD >= 0 {
            defer { close(socketFD) }
            let status = withUnsafePointer(to: &peer) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            check(status == -1 && errno == EPERM, "outbound socket must be denied")
        } else { check(errno == EPERM, "socket denial") }
        let empty = "empty"
        try fm.createDirectory(at: root.appendingPathComponent(empty), withIntermediateDirectories: true)
        check(load(empty).menu(at: now) == "Codex 한도 미확인", "empty")
        let model = "gpt-fixture-" + String(repeating: "장문🚀", count: 18)
        let context = line("turn_context", ["model": model, "irrelevant": "fixture-private-marker"])
        let claude: Obj = ["type": "assistant", "timestamp": iso, "message": ["model": "claude-fixture", "content": "fixture-private-marker"]]
        try write("one", projectLog, [claude])
        try write("one", log, [context, limits(["primary": window(60, 300), "secondary": window(0.1, 10080)])])
        var a = load("one")
        check(a.codex.model == model && a.claude.model == "claude-fixture", "models")
        check(a.codex.five?.remaining == 40 && a.codex.week?.remaining == 99.9, "windows")
        check(a.codex.week?.text(at: now.addingTimeInterval(7200)) == "미확인", "elapsed while open")
        try write("two", log, [line("turn_context", ["model": "o-fixture"]), limits(["primary": window(100, 10080)])])
        check(load("two").codex.week?.remaining == 0 && load("two").claude.model == nil, "homes independent")
        check(Window(remaining: 0.001, reset: now.addingTimeInterval(60)).text(at: now) == "<0.1%", "tiny nonzero")
        check(Window(remaining: 99.999, reset: now.addingTimeInterval(60)).text(at: now) == ">99.9%", "partial remaining")
        let custom = ["CODEX_HOME": root.appendingPathComponent("one/.codex").path,
                      "CLAUDE_CONFIG_DIR": root.appendingPathComponent("one/.claude").path]
        check(load(empty, custom).codex.model == model && load(empty, custom).claude.model == "claude-fixture", "CLI roots")
        check(load("one", ["CODEX_HOME": "."]).codex.model == nil, "invalid root fails closed")
        for bad in [window(101, 300), window(true, 300), window(0, 300, -1), window(0, 60),
                    window(0, 300).merging(["usageKnown": false]) { _, new in new }] {
            try write("bad", log, [limits(["primary": bad])])
            check(load("bad").codex.five == nil, "unverified window")
        }
        try write("bad", log, [limits(["limit_id": "other", "secondary": window(0, 10080)])])
        check(load("bad").codex.week == nil, "different pool")
        let realLog = root.appendingPathComponent("one/" + log)
        let alias = root.appendingPathComponent("bad/" + log)
        try fm.removeItem(at: alias)
        try fm.createSymbolicLink(at: alias, withDestinationURL: realLog)
        check(load("bad").codex.model == nil, "symlink")
        try fm.removeItem(at: alias)
        try fm.linkItem(at: realLog, to: alias)
        check(load("bad").codex.model == nil, "hard link")
        try fm.removeItem(at: alias)
        let linked = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: linked, withDestinationURL: root.appendingPathComponent("one"))
        check(load("link").codex.model == nil && load("link").claude.model == nil, "linked directory")
        try write("bad", log, [line("user", ["model": "fixture-private-marker"])])
        a = load("bad")
        check(a.codex.model == nil && a.codex.limitsTime == nil, "unrelated event")
        try checkSelectedFixtures(root: root, now: now)
        print("PASS synthetic homes, models, periods, percentages, invalid data, resets, overrides and links")
    }
}
