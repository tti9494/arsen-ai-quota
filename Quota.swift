import Foundation
import Darwin

struct Reading {
    var model: String?
    var modelTime: Date?
    var limitsTime: Date?
    var five: Window?
    var week: Window?
}

struct Window {
    let remaining: Double
    let reset: Date

    func text(at now: Date) -> String {
        guard reset > now else { return "미확인" }
        if remaining > 0 && remaining < 0.1 { return "<0.1%" }
        if remaining > 99.9 && remaining < 100 { return ">99.9%" }
        return remaining.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }
}

struct Snapshot {
    var codex = Reading()
    var claude = Reading()
    var selected = SelectedQuota()

    func menu(at now: Date) -> String {
        title(MenuSelection(), at: now)
    }
}

enum LocalUsage {
    // Decode only the fields used in the panel. Session text and tool inputs have no representation here.
    private struct Event: Decodable {
        let timestamp: String
        let type: String
        let isSidechain: Bool?
        let message: Message?
        let payload: Payload?
    }
    private struct Message: Decodable { let model: String? }
    private struct Payload: Decodable {
        let type: String?
        let model: String?
        let rate_limits: Limits?
    }
    private struct Limits: Decodable {
        let limit_id: String?
        let primary: Period?
        let secondary: Period?

        enum CodingKeys: String, CodingKey { case limit_id, primary, secondary }
        init(from decoder: Decoder) throws {
            let d = try decoder.container(keyedBy: CodingKeys.self)
            limit_id = try d.decodeIfPresent(String.self, forKey: .limit_id)
            primary = try? d.decode(Period.self, forKey: .primary)
            secondary = try? d.decode(Period.self, forKey: .secondary)
        }
    }
    private struct Period: Decodable {
        let used_percent: Double
        let window_minutes: Int
        let resets_at: Double
        let usageKnown: Bool?
        let usage_known: Bool?
    }
    private static let tailSize = 4 * 1024 * 1024

    // Every component must be a real directory. Opened logs must be regular, singly linked and owned by this user.
    private static func names(_ path: String) -> [String] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        guard let dir = fdopendir(fd) else { close(fd); return [] }
        defer { closedir(dir) }
        var result: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !name.hasPrefix(".") { result.append(name) }
        }
        return result
    }

    private static func recentFile(in directories: [String], codex: Bool) -> String? {
        var newest: (time: timespec, path: String)?
        for dir in directories {
            for name in names(dir) where name.hasSuffix(".jsonl") {
                let stem = String(name.dropLast(6))
                if codex {
                    guard stem.hasPrefix("rollout-"), stem.count == 64,
                          stem.dropFirst(27).first == "-",
                          UUID(uuidString: String(stem.suffix(36))) != nil else { continue }
                } else if UUID(uuidString: stem) == nil { continue }
                let path = dir + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0, valid(info) else { continue }
                let t = info.st_mtimespec
                if let n = newest,
                   (t.tv_sec, t.tv_nsec, path) <= (n.time.tv_sec, n.time.tv_nsec, n.path) { continue }
                newest = (t, path)
            }
        }
        return newest?.path
    }

    private static func valid(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1 && info.st_uid == geteuid()
    }

    private static func window(_ field: Period?, minutes: Int, now: Date) -> Window? {
        guard let v = field, v.window_minutes == minutes, v.usageKnown != false, v.usage_known != false,
              (0...100).contains(v.used_percent), v.resets_at > now.timeIntervalSince1970,
              v.resets_at <= now.timeIntervalSince1970 + Double(minutes * 60) + 60 else { return nil }
        return Window(remaining: 100 - v.used_percent, reset: Date(timeIntervalSince1970: v.resets_at))
    }

    private static func read(_ path: String?, codex: Bool, now: Date) -> Reading {
        var result = Reading()
        guard let path else { return result }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY)
        guard fd >= 0 else { return result }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, valid(info) else { return result }
        let offset = max(0, info.st_size - Int64(tailSize))
        guard (try? file.seek(toOffset: UInt64(offset))) != nil,
              let data = try? file.read(upToCount: tailSize) else { return result }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        let decoder = JSONDecoder()
        for line in lines.dropFirst(offset > 0 ? 1 : 0).dropLast() {
            guard let event = try? decoder.decode(Event.self, from: Data(line)),
                  let date = fractional.date(from: event.timestamp) ?? plain.date(from: event.timestamp), date <= now else { continue }
            if codex && event.type == "turn_context" || !codex && event.type == "assistant" && event.isSidechain != true {
                let model = codex ? event.payload?.model : event.message?.model
                result.model = model.flatMap {
                    guard !$0.isEmpty, $0.utf8.count <= 256,
                          !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                          $0 != "<synthetic>" else { return nil }
                    return $0
                }
                result.modelTime = date
            }
            guard codex, event.type == "event_msg", event.payload?.type == "token_count",
                  let limits = event.payload?.rate_limits, limits.limit_id == nil || limits.limit_id == "codex" else { continue }
            result.limitsTime = date
            let fields = [limits.primary, limits.secondary]
            result.five = fields.compactMap { window($0, minutes: 300, now: now) }.first
            result.week = fields.compactMap { window($0, minutes: 10080, now: now) }.first
        }
        return result
    }

    static func load(home: String, environment: [String: String], now: Date = Date()) -> Snapshot {
        func root(_ key: String, _ fallback: String) -> String? {
            let path = environment[key] ?? (home + "/" + fallback)
            guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else { return nil }
            return path
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd"
        let days = root("CODEX_HOME", ".codex").map { base in
            (0..<8).map { base + "/sessions/" + formatter.string(from: now.addingTimeInterval(-86400 * Double($0))) }
        } ?? []
        let projects = root("CLAUDE_CONFIG_DIR", ".claude").map { $0 + "/projects" }
        let dirs = projects.map { root in names(root).map { root + "/" + $0 } } ?? []
        return Snapshot(codex: read(recentFile(in: days, codex: true), codex: true, now: now),
                        claude: read(recentFile(in: dirs, codex: false), codex: false, now: now))
    }
}
