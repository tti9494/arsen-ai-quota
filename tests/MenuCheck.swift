import AppKit
import ApplicationServices

func fail(_ reason: String) -> Never { fputs(reason + "\n", stderr); exit(1) }
guard CommandLine.arguments.count == 4, let pid = Int32(CommandLine.arguments[1]),
      let target = NSRunningApplication(processIdentifier: pid),
      target.bundleIdentifier == "org.arsenai.quota.mac",
      target.executableURL?.path == CommandLine.arguments[2],
      ["one", "empty", "persisted"].contains(CommandLine.arguments[3]) else { fail("Unexpected target") }
guard AXIsProcessTrusted() else { fail("Accessibility unavailable") }
let root = AXUIElementCreateApplication(pid)
let empty = CommandLine.arguments[3] == "empty"
let persisted = CommandLine.arguments[3] == "persisted"

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func children(_ element: AXUIElement) -> [AXUIElement] { attr(element, "AXChildren") as? [AXUIElement] ?? [] }
func tree(_ element: AXUIElement, _ depth: Int = 0) -> [AXUIElement] {
    [element] + (depth < 12 ? children(element).flatMap { tree($0, depth + 1) } : [])
}
func labels(_ e: AXUIElement) -> String {
    ["AXTitle", "AXValue", "AXDescription"].compactMap { attr(e, $0) as? String }.joined(separator: " ")
}
func wait<T>(_ reason: String, _ operation: () -> T?) -> T {
    let end = Date().addingTimeInterval(8)
    repeat {
        if let value = operation() { return value }
        Thread.sleep(forTimeInterval: 0.08)
    } while Date() < end
    fail(reason)
}
func press(_ e: AXUIElement) {
    let status = AXUIElementPerformAction(e, "AXPress" as CFString)
    if status != .success && status != .cannotComplete { fail("AX press failed") }
}
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, "AXPosition"), let s = attr(e, "AXSize") else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
}
let status: AXUIElement = wait("Status item unavailable") {
    guard let bar = attr(root, "AXExtrasMenuBar") else { return nil }
    return children(bar as! AXUIElement).first { labels($0).contains(empty ? "미확인" : (persisted ? "Claude 계정 파일 5시간 0%" : "99.9%")) }
}
press(status)
let detail: AXUIElement = wait("Menu did not open") {
    tree(status).first { labels($0).contains("상세 보기") }
}
press(detail)
let window: AXUIElement = wait("Details unavailable") { (attr(root, "AXWindows") as? [AXUIElement])?.first }
for width in [510, 320] {
    var size = CGSize(width: width, height: persisted ? 610 : 465)
    guard let axSize = AXValueCreate(.cgSize, &size),
          AXUIElementSetAttributeValue(window, "AXSize" as CFString, axSize) == .success else { fail("Resize failed") }
    let _: Bool = wait("Missing labels, incorrect values or layout overflow") {
        guard let bounds = frame(window), abs(bounds.width - CGFloat(width)) < 1 else { return nil }
        let fields = tree(window).filter { attr($0, "AXRole") as? String == "AXStaticText" }
        let text = fields.map(labels).joined(separator: "\n")
        let expected = empty ? ["최근 모델  미확인", "주간 잔여  미확인", "5시간 잔여  미확인"] :
                               ["gpt-fixture-장문🚀", "claude-fixture", "주간 잔여  99.9%", "5시간 잔여  40%"]
        let imported = tree(window).filter { attr($0, "AXRole") as? String == "AXTextArea" }.map(labels).joined()
        if persisted {
            guard ["현재 로그인 계정 미확인", "Opus 전용 주간 17%", "5시간 0%", "주간 70%", "주간 41%", "주간 63%", "초기화"].allSatisfy(imported.contains),
                  ["Gemini 파일  5시간 31% · 주간 41%", "3p 파일  5시간 53% · 주간 63%"].allSatisfy(text.contains),
                  !imported.contains("fixture-private-marker") else { return nil }
        }
        guard (expected + ["Antigravity", persisted ? "계정 파일  5시간 0% · 주간 70%" : "구독 한도  미확인", "로컬 기록 조회"]).allSatisfy(text.contains),
              !text.contains("fixture-private-marker"), fields.allSatisfy({ frame($0).map(bounds.contains) == true }) else { return nil }
        return true
    }
    if let dir = ProcessInfo.processInfo.environment["QA_SCREENSHOTS"] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard let id = windows.first(where: {
            $0[kCGWindowOwnerPID as String] as? Int32 == pid && $0[kCGWindowLayer as String] as? Int == 0
        })?[kCGWindowNumber as String] as? Int else { fail("Candidate window unavailable for capture") }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(id), dir + "/" + CommandLine.arguments[3] + "-\(width).png"]
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { fail("Window-only capture failed") }
    }
}
print("PASS actual status menu and details at 510pt and 320pt (" + CommandLine.arguments[3] + ")")

if !empty && !persisted {
    func menuEntry(_ title: String) -> AXUIElement {
        wait("Missing menu control " + title) { tree(status).first { attr($0, "AXTitle") as? String == title } }
    }
    press(status)
    press(menuEntry("한도 파일 연결…"))
    func alertField(_ role: String, _ title: String? = nil) -> AXUIElement {
        wait("Missing file selection control") {
            let windows = attr(root, "AXWindows") as? [AXUIElement] ?? []
            return windows.flatMap { tree($0) }.first {
                attr($0, "AXRole") as? String == role && (title == nil || attr($0, "AXTitle") as? String == title)
            }
        }
    }
    let field = alertField("AXTextField")
    guard AXUIElementSetAttributeValue(field, "AXValue" as CFString, "last-quota.json" as CFString) == .success else { fail("File selection failed") }
    press(alertField("AXButton", "연결"))
    func choose(_ title: String) {
        press(status)
        _ = menuEntry("메뉴 막대 표시")
        press(menuEntry(title))
        let _: Bool = wait("Menu selection did not update") {
            labels(status).contains(title == "Claude 계정" ? "Claude 계정 파일" : "Claude 계정 파일 5시간") ? true : nil
        }
    }
    choose("Claude 계정")
    choose("5시간")
    let _: Bool = wait("Menu did not reflect selected snapshot") {
        labels(status).contains("Claude 계정 파일 5시간 0%") ? true : nil
    }
    print("PASS selected a local file, provider and period using actual menu controls")
}

if empty {
    press(status)
    let about: AXUIElement = wait("About menu item unavailable") {
        tree(status).first { attr($0, "AXTitle") as? String == "앱 정보" }
    }
    press(about)
    let _: Bool = wait("Standard About panel or disclosures unavailable") {
        let windows = attr(root, "AXWindows") as? [AXUIElement] ?? []
        return windows.contains { panel in
            let text = tree(panel).map(labels).joined(separator: " ")
            return ["비공식 독립 오픈소스", "Google·Anthropic·OpenAI와 제휴하거나 후원받지 않습니다",
                    "공급자 데이터는 로컬에서 읽기 전용", "외부로 전송하지 않습니다",
                    "앱의 로컬 설정에 저장", "세션 기록 형식은 바뀔 수 있습니다",
                    "사용자가 만들어 선택한 로컬 파일에서만"].allSatisfy(text.contains)
        } ? true : nil
    }
    print("PASS opened 앱 정보 from the actual menu and read all disclosures in the standard About panel")
}
