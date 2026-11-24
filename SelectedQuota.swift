import Foundation
import Darwin

enum PoolChoice: String, CaseIterable, Codable {
    case codex, fileCodex, claude, gemini, thirdParty
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .fileCodex: return "Codex 파일"
        case .claude: return "Claude 계정"
        case .gemini: return "Gemini 공유"
        case .thirdParty: return "Antigravity 3p"
        }
    }
}

enum PeriodChoice: String, CaseIterable, Codable {
    case auto, five, weekly, both
    var title: String {
        switch self {
        case .auto: return "주간 우선"
        case .five: return "5시간"
        case .weekly: return "주간"
        case .both: return "5시간 + 주간"
        }
    }
}

struct MenuSelection: Codable {
    var providers: Set<PoolChoice> = [.codex]
    var period: PeriodChoice = .auto
    var file: String?
    static let filename = ".arsen-ai-quota-menu.json"

    static func load(home: String) -> Self {
        guard let data = LocalFile.bytes(home: home, relative: filename),
              let prefs = try? JSONDecoder().decode(Self.self, from: data), !prefs.providers.isEmpty,
              prefs.file.map(SelectedQuota.allowedPath) ?? true else { return Self() }
        return prefs
    }

    func save(home: String) -> Bool {
        // A fresh 0600 inode plus rename also handles interrupted writes.
        guard let bytes = try? JSONEncoder().encode(self) else { return false }
        let dir = LocalFile.directory(home)
        guard dir >= 0 else { return false }
        defer { close(dir) }
        var existing = stat()
        let exists = fstatat(dir, Self.filename, &existing, AT_SYMLINK_NOFOLLOW) == 0
        guard exists ? LocalFile.privateRegular(existing) : errno == ENOENT else { return false }
        let tmp = ".arsen-quota-" + UUID().uuidString
        let fd = openat(dir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd); unlinkat(dir, tmp, 0) }
        guard bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == bytes.count else { return false }
        return renameat(dir, tmp, dir, Self.filename) == 0
    }
}

private enum LocalFile {
    static func directory(_ path: String, at parent: Int32 = AT_FDCWD) -> Int32 {
        let fd = openat(parent, path, O_DIRECTORY | O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        var s = stat(), fs = statfs()
        guard fstat(fd, &s) == 0, s.st_uid == geteuid(), s.st_mode & 0o022 == 0,
              fstatfs(fd, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0 else { close(fd); return -1 }
        return fd
    }

    static func privateRegular(_ s: stat) -> Bool {
        s.st_mode & S_IFMT == S_IFREG && s.st_uid == geteuid() && s.st_nlink == 1 && s.st_mode & 0o077 == 0
    }

    static func bytes(home: String, relative: String) -> Data? {
        let components = relative.components(separatedBy: "/")
        guard let last = components.last, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) else { return nil }
        var parent = directory(home)
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        for part in components.dropLast() {
            let child = directory(part, at: parent)
            guard child >= 0 else { return nil }
            close(parent)
            parent = child
        }
        let fd = openat(parent, last, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var s = stat(), fs = statfs()
        guard fstat(fd, &s) == 0, privateRegular(s), (1...65536).contains(s.st_size),
              fstatfs(fd, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0,
              let data = try? handle.read(upToCount: 65537), data.count == s.st_size else { return nil }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_mtimespec.tv_sec == s.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == s.st_mtimespec.tv_nsec, after.st_size == s.st_size else { return nil }
        return data
    }
}

struct SelectedQuota {
    var pools: [PoolChoice: Reading] = [:]
    var modelWeeks: [String: Window] = [:]
    private static let models = ["fable", "opus", "sonnet", "haiku"]
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        init(_ name: String) { stringValue = name }
    }

    private static func fields(_ decoder: Decoder, allowed: [String]) throws -> KeyedDecodingContainer<Key> {
        let fields = try decoder.container(keyedBy: Key.self)
        guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported fields"))
        }
        return fields
    }

    private struct RawMeter: Decodable {
        let remaining: Double
        let reset: Date
        init(from decoder: Decoder) throws {
            let f = try fields(decoder, allowed: ["remaining", "reset"])
            remaining = try f.decode(Double.self, forKey: Key("remaining"))
            reset = try f.decode(Date.self, forKey: Key("reset"))
        }
        func window(hours: Int, recorded: Date, now: Date) -> Window? {
            guard remaining.isFinite, (0...100).contains(remaining), reset > now,
                  reset.timeIntervalSince(recorded) <= Double(hours * 3600) + 60 else { return nil }
            return Window(remaining: remaining, reset: reset)
        }
    }

    private struct RawPool: Decodable {
        let recorded: Date
        let five, week: RawMeter?
        var scopes: [String: RawMeter] = [:]
        init(from decoder: Decoder) throws {
            let claude = decoder.codingPath.last?.stringValue == "claude"
            let f = try fields(decoder, allowed: ["updated","five","weekly"] + (claude ? ["scoped","scopedName","scopedWeekly"] : []))
            recorded = try f.decode(Date.self, forKey: Key("updated"))
            five = try? f.decode(RawMeter.self, forKey: Key("five"))
            week = try? f.decode(RawMeter.self, forKey: Key("weekly"))
            guard claude else { return }
            let group = try? f.nestedContainer(keyedBy: Key.self, forKey: Key("scopedWeekly"))
            let name = (try? f.decode(String.self, forKey: Key("scopedName")))?.lowercased()
            for model in models {
                let key = Key(model)
                var entry = try? group?.decode(RawMeter.self, forKey: key)
                if name == model {
                    let legacy = try? f.decode(RawMeter.self, forKey: Key("scoped"))
                    if group?.contains(key) != true { entry = legacy }
                    else if entry?.remaining != legacy?.remaining || entry?.reset != legacy?.reset { entry = nil }
                }
                scopes[model] = entry
            }
        }
    }

    private struct Document: Decodable {
        var pools: [PoolChoice: RawPool] = [:]
        init(from decoder: Decoder) throws {
            let keys: [String: PoolChoice] = ["codex": .fileCodex, "claude": .claude, "antigravity": .gemini, "antigravity-3p": .thirdParty]
            let f = try fields(decoder, allowed: Array(keys.keys))
            for (name, choice) in keys { pools[choice] = try? f.decode(RawPool.self, forKey: Key(name)) }
        }
    }

    static func allowedPath(_ path: String) -> Bool {
        let parts = path.components(separatedBy: "/")
        guard let name = parts.last, path.utf8.count < 4096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return false }
        return name == "last-quota.json" || name.hasSuffix(".quota.json")
    }

    // The normalized format needs only unescaped ASCII keys. Reject duplicate keys before Foundation coalesces them.
    private static func uniqueKeys(_ data: Data) -> Bool {
        let bytes = Array(data)
        var stack = [Set<String>](), i = 0
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            if b == 123 {
                guard stack.count < 12 else { return false }
                stack.append([])
            } else if b == 125 {
                guard stack.popLast() != nil else { return false }
            } else if b == 34 {
                let start = i
                var escaped = false
                while i < bytes.count && bytes[i] != 34 {
                    if bytes[i] == 92 { escaped = true; i += 1 }
                    i += 1
                }
                guard i < bytes.count else { return false }
                let end = i
                i += 1
                while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 }
                if i < bytes.count && bytes[i] == 58 {
                    guard !escaped, !stack.isEmpty, let key = String(bytes: bytes[start..<end], encoding: .ascii),
                          stack[stack.count - 1].insert(key).inserted else { return false }
                }
            }
        }
        return stack.isEmpty
    }

    static func read(home: String, path: String?, now: Date = Date()) -> Self {
        var result = Self()
        guard let path, allowedPath(path), let data = LocalFile.bytes(home: home, relative: path),
              uniqueKeys(data), let doc = try? JSONDecoder().decode(Document.self, from: data) else { return result }
        for (choice, pool) in doc.pools where (0...Double(7 * 86400 + 60)).contains(now.timeIntervalSince(pool.recorded)) {
            let five = pool.five?.window(hours: 5, recorded: pool.recorded, now: now)
            let week = pool.week?.window(hours: 168, recorded: pool.recorded, now: now)
            result.pools[choice] = Reading(limitsTime: pool.recorded, five: five, week: week)
            if choice == .claude {
                result.modelWeeks = pool.scopes.compactMapValues { $0.window(hours: 168, recorded: pool.recorded, now: now) }
            }
        }
        return result
    }
}

extension Snapshot {
    func reading(_ choice: PoolChoice) -> Reading {
        choice == .codex ? codex : selected.pools[choice] ?? Reading()
    }

    func title(_ prefs: MenuSelection, at now: Date) -> String {
        PoolChoice.allCases.filter(prefs.providers.contains).map { title($0, period: prefs.period, at: now) }.joined(separator: " · ")
    }

    func title(_ choice: PoolChoice, period: PeriodChoice, at now: Date) -> String {
        let r = reading(choice)
        let five = r.five?.text(at: now) ?? "미확인", week = r.week?.text(at: now) ?? "미확인"
        let prefix = choice.title + (choice == .codex || choice == .fileCodex ? " " : " 파일 ")
        switch period {
        case .auto:
            if week != "미확인" { return prefix + "주간 잔여 " + week }
            if five != "미확인" { return prefix + "5시간 잔여 " + five }
            return prefix + "한도 미확인"
        case .five: return prefix + "5시간 " + five
        case .weekly: return prefix + "주간 " + week
        case .both: return prefix + "5시간 " + five + " / 주간 " + week
        }
    }
}
