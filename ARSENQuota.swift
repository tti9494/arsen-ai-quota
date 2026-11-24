import AppKit

final class Dashboard: NSWindowController {
    private let summary = NSTextField(labelWithString: "")
    private let codex = NSTextField(labelWithString: "")
    private let five = NSTextField(labelWithString: "")
    private let week = NSTextField(labelWithString: "")
    private let claude = NSTextField(labelWithString: "")
    private let codexDate = NSTextField(labelWithString: "")
    private let claudeQuota = NSTextField(labelWithString: "")
    private let agQuota = NSTextField(labelWithString: "")
    private let agThirdParty = NSTextField(labelWithString: "")
    private let fileDetails = NSTextView()
    private let scroll = NSScrollView()
    private let claudeDate = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 440),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ARSEN AI Quota"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320, height: 420)
        super.init(window: window)
        guard let content = window.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18)
        ])
        func row(_ label: NSTextField) {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        func heading(_ name: String) {
            let title = NSTextField(labelWithString: name)
            title.font = .boldSystemFont(ofSize: 18)
            row(title)
        }
        func sectionBreak(_ label: NSTextField) {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            row(label)
            stack.setCustomSpacing(17, after: label)
        }
        heading("Codex")
        row(codex)
        row(five)
        row(week)
        sectionBreak(codexDate)
        heading("Claude Code")
        row(claude)
        row(claudeQuota)
        sectionBreak(claudeDate)
        heading("Antigravity")
        row(agQuota)
        sectionBreak(agThirdParty)
        summary.textColor = .secondaryLabelColor
        row(summary)
        fileDetails.isEditable = false
        fileDetails.isRichText = false
        fileDetails.isVerticallyResizable = true
        fileDetails.textContainer?.widthTracksTextView = true
        fileDetails.autoresizingMask = [.width]
        fileDetails.font = .systemFont(ofSize: 12)
        scroll.hasVerticalScroller = true
        scroll.documentView = fileDetails
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 134).isActive = true
        scroll.isHidden = true
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func display(_ data: Snapshot, at now: Date, checked: Date?, linked: Bool) {
        func stamp(_ date: Date?) -> String {
            date?.formatted(date: .abbreviated, time: .shortened) ?? "미확인"
        }
        func model(_ label: NSTextField, _ reading: Reading) {
            label.stringValue = "최근 모델  " + (reading.model ?? "미확인")
            label.toolTip = label.stringValue + " · " + stamp(reading.modelTime)
        }
        func quota(_ label: NSTextField, _ period: String, _ window: Window?) {
            label.stringValue = period + " 잔여  " + (window?.text(at: now) ?? "미확인")
            label.toolTip = window.map { "초기화 예정  " + stamp($0.reset) }
        }
        model(codex, data.codex)
        model(claude, data.claude)
        quota(five, "5시간", data.codex.five)
        quota(week, "주간", data.codex.week)
        codexDate.stringValue = "한도 기록  " + stamp(data.codex.limitsTime)
        claudeDate.stringValue = "모델 기록  " + stamp(data.claude.modelTime)
        func fileSummary(_ pool: PoolChoice, label: String) -> String {
            let reading = data.reading(pool)
            return label + " 파일  5시간 " + (reading.five?.text(at: now) ?? "미확인")
                + " · 주간 " + (reading.week?.text(at: now) ?? "미확인")
        }
        claudeQuota.stringValue = linked ? fileSummary(.claude, label: "계정") : "구독 한도  미확인"
        agQuota.stringValue = linked ? fileSummary(.gemini, label: "Gemini") : "모델·한도  미확인"
        agThirdParty.stringValue = linked ? fileSummary(.thirdParty, label: "3p") : "공식 앱의 사용량 화면에서 확인하세요."
        if scroll.isHidden == linked {
            scroll.isHidden = !linked
            let minimum: CGFloat = linked ? 535 : 420
            window?.contentMinSize = NSSize(width: 320, height: minimum)
            if let window, let view = window.contentView, view.bounds.height < minimum {
                window.setContentSize(NSSize(width: view.bounds.width, height: minimum))
            }
        }
        if linked {
            func detail(_ name: String, _ meter: Window?) -> String {
                guard let meter, meter.reset > now else { return name + " 미확인" }
                return name + " " + meter.text(at: now) + " · 초기화 " + stamp(meter.reset)
            }
            var lines = ["선택 파일 · 현재 로그인 계정 미확인"]
            for pool in PoolChoice.allCases where pool != .codex {
                let r = data.reading(pool)
                lines += [pool.title + " · 기록 " + stamp(r.limitsTime),
                          detail("5시간", r.five), detail("주간", r.week)]
                if pool == .claude {
                    if data.selected.modelWeeks.isEmpty { lines.append("모델 전용 주간 미확인") }
                    for name in data.selected.modelWeeks.keys.sorted() {
                        lines.append(detail(name.capitalized + " 전용 주간", data.selected.modelWeeks[name]))
                    }
                }
            }
            let content = lines.joined(separator: "\n")
            if fileDetails.string != content { fileDetails.string = content }
        }
        summary.stringValue = "로컬 기록 조회  " + (checked?.formatted(date: .omitted, time: .standard) ?? "조회 중")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private var dashboard: Dashboard!
    private let modelItem = NSMenuItem()
    private var meterItems: [PoolChoice: NSMenuItem] = [:]
    private let claudeItem = NSMenuItem()
    private let home = getenv("HOME").map { String(cString: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.path
    private var prefs = MenuSelection()
    private var poolItems: [NSMenuItem] = []
    private var periodItems: [NSMenuItem] = []
    private var detachItem: NSMenuItem!
    private var data = Snapshot()
    private var checked: Date?
    private var loading = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        prefs = MenuSelection.load(home: home)
        dashboard = Dashboard()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        for item in [modelItem, claudeItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        for choice in PoolChoice.allCases {
            let item = NSMenuItem()
            item.isEnabled = false
            meterItems[choice] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let options = NSMenu()
        options.autoenablesItems = false
        func option(_ title: String, _ action: Selector, _ value: String) -> NSMenuItem {
            let item = options.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            return item
        }
        for pool in PoolChoice.allCases { poolItems.append(option(pool.title, #selector(togglePool), pool.rawValue)) }
        options.addItem(.separator())
        for period in PeriodChoice.allCases { periodItems.append(option(period.title, #selector(setPeriod), period.rawValue)) }
        let settings = NSMenuItem(title: "메뉴 막대 표시", action: nil, keyEquivalent: "")
        settings.submenu = options
        menu.addItem(settings)
        let attach = menu.addItem(withTitle: "한도 파일 연결…", action: #selector(attachFile), keyEquivalent: "")
        attach.target = self
        detachItem = menu.addItem(withTitle: "파일 연결 해제", action: #selector(detachFile), keyEquivalent: "")
        detachItem.target = self
        for (title, action) in [("상세 보기", #selector(showDetails)), ("새로 고침", #selector(refresh)), ("앱 정보", #selector(showAbout)), ("종료", #selector(quit))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        status.menu = menu
        render()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func menuWillOpen(_ menu: NSMenu) { render() }

    private func render() {
        let now = Date()
        for (choice, item) in meterItems {
            item.isHidden = !prefs.providers.contains(choice)
            item.title = data.title(choice, period: .both, at: now)
        }
        claudeItem.title = "Claude Code 최근 모델  " + (data.claude.model ?? "미확인")
        modelItem.title = "Codex 최근 모델  " + (data.codex.model ?? "미확인")
        for item in poolItems {
            item.state = (item.representedObject as? String).flatMap(PoolChoice.init(rawValue:)).map(prefs.providers.contains) == true ? .on : .off
        }
        for item in periodItems { item.state = item.representedObject as? String == prefs.period.rawValue ? .on : .off }
        detachItem.isEnabled = prefs.file != nil
        let title = data.title(prefs, at: now)
        status.button?.title = title
        status.button?.cell?.lineBreakMode = .byTruncatingTail
        status.length = min(350, (title as NSString).size(withAttributes: [.font: NSFont.menuBarFont(ofSize: 0)]).width + 20)
        status.button?.toolTip = PoolChoice.allCases.filter(prefs.providers.contains).map {
            $0.title + ($0 == .codex ? " · 세션 기록 " : " · 선택 파일 기록 ") + (data.reading($0).limitsTime?.formatted() ?? "미확인")
        }.joined(separator: "\n")
        status.button?.setAccessibilityLabel("ARSEN AI Quota " + title)
        dashboard.display(data, at: now, checked: checked, linked: prefs.file != nil)
    }

    private func save(_ change: (inout MenuSelection) -> Void) {
        var updated = prefs
        change(&updated)
        guard updated.save(home: home) else {
            let alert = NSAlert()
            alert.messageText = "현재 홈에 메뉴 선택을 저장할 수 없습니다."
            alert.runModal()
            return
        }
        if prefs.file != updated.file { data.selected = SelectedQuota() }
        prefs = updated
        render()
    }

    @objc func togglePool(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let pool = PoolChoice(rawValue: key) else { return }
        save { p in
            if p.providers.contains(pool) {
                if p.providers.count > 1 { p.providers.remove(pool) }
            } else { p.providers.insert(pool) }
        }
    }

    @objc func setPeriod(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let period = PeriodChoice(rawValue: key) else { return }
        save { $0.period = period }
    }

    @objc func attachFile() {
        let alert = NSAlert()
        alert.messageText = "한도 파일 연결"
        alert.informativeText = "이 Mac 사용자 홈에 있는 한 계정의 결과 파일 경로를 입력하세요. 서로 다른 계정이 섞인 파일은 연결하지 마세요. 보관된 수치의 로그인 계정은 확인할 수 없습니다."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 310, height: 24))
        field.placeholderString = "~/…/last-quota.json 또는 *.quota.json"
        alert.accessoryView = field
        alert.addButton(withTitle: "연결")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var path = field.stringValue
        if path.hasPrefix("~/") { path = String(path.dropFirst(2)) }
        else if path.hasPrefix(home + "/") { path = String(path.dropFirst(home.count + 1)) }
        guard SelectedQuota.allowedPath(path) else {
            let error = NSAlert()
            error.messageText = "홈 안의 last-quota.json 또는 .quota.json으로 끝나는 결과 파일을 선택하세요."
            error.runModal()
            return
        }
        save { $0.file = path }
        refresh()
    }

    @objc func detachFile() { save { $0.file = nil } }

    @objc func refresh() {
        guard !loading else { return }
        loading = true
        let home = self.home
        let path = prefs.file
        var roots: [String: String] = [:]
        for name in ["CODEX_HOME", "CLAUDE_CONFIG_DIR"] {
            if let path = getenv(name) { roots[name] = String(cString: path) }
        }
        let cliRoots = roots
        DispatchQueue.global(qos: .utility).async {
            var snapshot = LocalUsage.load(home: home, environment: cliRoots)
            snapshot.selected = SelectedQuota.read(home: home, path: path)
            let complete = snapshot
            DispatchQueue.main.async {
                self.loading = false
                guard path == self.prefs.file else { self.refresh(); return }
                self.checked = Date()
                self.data = complete
                self.render()
            }
        }
    }

    @objc func showDetails() {
        render()
        dashboard.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAbout() {
        let notice = """
        비공식 독립 오픈소스 앱이며 Google·Anthropic·OpenAI와 제휴하거나 후원받지 않습니다.
        공급자 데이터는 로컬에서 읽기 전용으로 사용하며 외부로 전송하지 않습니다. 메뉴 선택과 선택한 파일의 경로는 앱의 로컬 설정에 저장합니다.
        세션 기록 형식은 바뀔 수 있습니다. Antigravity 한도는 사용자가 만들어 선택한 로컬 파일에서만 읽습니다.
        """
        let credits = NSAttributedString(string: notice, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quit() { NSApp.terminate(nil) }
}

@main enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
