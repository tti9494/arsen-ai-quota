import Foundation
import Darwin

func checkSelectedFixtures(root: URL, now: Date) throws {
    let fm = FileManager.default
    typealias Object = [String: Any]
    let marker = "fixture-private-marker"
    let recorded = now.addingTimeInterval(-20).timeIntervalSinceReferenceDate
    let reset = now.addingTimeInterval(3600).timeIntervalSinceReferenceDate
    func meter(_ value: Any) -> Object { ["remaining": value, "reset": reset] }
    let legacy: Object = [
        "codex": ["updated": recorded, "weekly": meter(80)],
        "claude": ["updated": recorded, "five": meter(0), "weekly": meter(70), "scopedName": "Opus",
                   "scoped": meter(17), "scopedWeekly": ["opus": meter(17), "fable": meter(25)]],
        "antigravity": ["updated": recorded, "five": meter(31), "weekly": meter(41)],
        "antigravity-3p": ["updated": recorded, "five": meter(53), "weekly": meter(63)]
    ]
    let one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two")
    let url = one.appendingPathComponent("last-quota.json")
    let other = two.appendingPathComponent("last-quota.json")
    func put(_ obj: Object, at file: URL) throws {
        try JSONSerialization.data(withJSONObject: obj).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func read(_ name: String = "last-quota.json", _ home: URL = one) -> SelectedQuota {
        SelectedQuota.read(home: home.path, path: name, now: now)
    }
    func check(_ value: Bool, _ reason: String) { if !value { fatalError(reason) } }
    try put(legacy, at: url)
    try put(["claude": ["updated": recorded, "weekly": meter(12)]], at: other)
    let q = read()
    check(q.pools[.claude]?.five?.remaining == 0 && q.pools[.claude]?.week?.remaining == 70, "account windows")
    check(q.pools[.gemini]?.week?.remaining == 41 && q.pools[.thirdParty]?.five?.remaining == 53, "two independent pools")
    check(q.modelWeeks["opus"]?.remaining == 17 && q.modelWeeks["fable"]?.remaining == 25, "explicit scopes")
    check(q.pools[.fileCodex]?.week?.remaining == 80 && q.pools[.codex] == nil, "file Codex isolated")
    check(read("last-quota.json", two).pools[.claude]?.week?.remaining == 12, "two homes")
    check(read("../two/last-quota.json").pools.isEmpty && read(other.path).pools.isEmpty, "foreign home")
    let prefs = MenuSelection(providers: [.claude,.thirdParty], period: .both, file: "last-quota.json")
    check(prefs.save(home: two.path), "save menu")
    let saved = MenuSelection.load(home: two.path)
    check(saved.period == .both && saved.file == prefs.file && saved.providers == prefs.providers, "menu persistence")
    check(MenuSelection.load(home: one.path).file == nil, "menu isolation")
    let fixture = one.appendingPathComponent("invalid.quota.json")
    for bad: Object in [
        ["five": meter(true)], ["five": meter(-1)], ["weekly": meter(101)], ["five": ["remaining": 7]],
        ["five": ["remaining": 2, "reset": recorded]], ["five": ["remaining": 8, "reset": reset + 86400]],
        ["five": meter(8), "error": marker], ["five": meter(8), "account": marker],
        ["five": ["remaining": marker, "reset": reset]], ["five": meter(3), "updated": recorded + 3600],
        ["five": meter(3), "updated": recorded - 8 * 86400]
    ] {
        var fields: Object = ["updated": recorded]
        fields.merge(bad) { _, new in new }
        try put(["claude": fields], at: fixture)
        let data = read(fixture.lastPathComponent)
        check(data.pools[.claude]?.five == nil && data.pools[.claude]?.week == nil, "invalid meter")
    }
    let untrustedDir = one.appendingPathComponent("writable")
    try fm.createDirectory(at: untrustedDir, withIntermediateDirectories: false)
    try put(legacy, at: untrustedDir.appendingPathComponent("last-quota.json"))
    try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: untrustedDir.path)
    check(read("writable/last-quota.json").pools.isEmpty, "writable parent")
    check(SelectedQuota.read(home: one.path, path: "last-quota.json", now: now.addingTimeInterval(4000)).pools[.claude]?.five == nil, "expired selected value")
    try put(["claude": ["updated": -1e100, "five": meter(30)]], at: fixture)
    check(read(fixture.lastPathComponent).pools.isEmpty, "implausible timestamp")
    try put(["claude": ["five": meter(30)]], at: fixture)
    check(read(fixture.lastPathComponent).pools.isEmpty, "missing timestamp")
    try put(legacy.merging(["accounts": [[marker: 1]]]) { _, b in b }, at: fixture)
    check(read(fixture.lastPathComponent).pools.isEmpty, "mixed account document")
    try put(["claude": ["updated": recorded, "scopedName": "Opus", "scoped": meter(1),
                        "scopedWeekly": ["opus": meter(2), marker: meter(4)]]], at: fixture)
    check(read(fixture.lastPathComponent).modelWeeks.isEmpty, "conflicting or arbitrary scope")
    let dup = "{\"claude\":{},\"claude\":" + String(decoding: try JSONSerialization.data(withJSONObject: legacy["claude"]!), as: UTF8.self) + "}"
    try Data(dup.utf8).write(to: fixture)
    check(read(fixture.lastPathComponent).pools.isEmpty, "duplicate pool")
    try put(legacy, at: fixture)
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.path)
    check(read(fixture.lastPathComponent).pools.isEmpty, "file permissions")
    try fm.removeItem(at: fixture)
    try fm.createSymbolicLink(at: fixture, withDestinationURL: other)
    check(read(fixture.lastPathComponent).pools.isEmpty, "selected symlink")
    try fm.removeItem(at: fixture)
    try fm.linkItem(at: url, to: fixture)
    check(read().pools.isEmpty, "hard link")
    try fm.removeItem(at: fixture)
    try fm.createSymbolicLink(at: one.appendingPathComponent("other-home"), withDestinationURL: two)
    check(read("other-home/last-quota.json").pools.isEmpty, "linked parent")
    var oversized = try JSONSerialization.data(withJSONObject: legacy)
    oversized.append(Data(repeating: 32, count: 65537))
    try oversized.write(to: fixture)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.path)
    check(read(fixture.lastPathComponent).pools.isEmpty, "size cap")
    print("PASS selected legacy files, periods, scope, ownership boundaries, limits and separate home preferences")
}
