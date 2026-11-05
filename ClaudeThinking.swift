import Cocoa
import ScreenCaptureKit
import Vision
import ServiceManagement

// Claude Code의 실제 상태
enum ClaudeState { case idle, thinking, working }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var state = ClaudeState.idle
    var cpu = 0.0
    var testMode = false
    var presence = 0.0        // 0 = 완전히 쉼, 1 = 완전히 생각 중 (부드럽게 전환)
    var clock = 0.0           // 갸웃 동작 시간
    var lastKey = ""          // 같은 그림이면 다시 그리지 않음
    /// 프레임: 0 = 가변(화면 주사율을 따라가고, 움직임이 없으면 낮춤), 그 밖 = 고정 fps. 기억해 둔다.
    var fpsSetting = UserDefaults.standard.object(forKey: "fps") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(fpsSetting, forKey: "fps"); startClock() }
    }
    var timer: Timer?, link: CADisplayLink?, linkFast: Bool?
    var lastTick = CACurrentMediaTime(), lastRender = 0.0
    let roller = MenuRoller()
    let fpsMenu = NSMenu()
    let width: CGFloat = 24
    let label = NSMenuItem(title: "Claude Code: 대기 중", action: nil, keyEquivalent: "")
    var testItem: NSMenuItem!
    var stage: DesktopStage!
    var stageItem: NSMenuItem!, frontItem: NSMenuItem!, followItem: NSMenuItem!
    let watcher = AgentWatcher()
    let watchQ = DispatchQueue(label: "agent-watch")
    var lastFollow = Date.distantPast
    let menu = NSMenu()
    // 노치 영역: 메뉴바 별이 굴러가다 부딪히고 돌아오는 벽. 기본은 화면이 알려 주는 노치이고,
    // 사용자가 왼쪽·오른쪽 끝을 직접 옮겨 맞출 수 있다(pt, 기억함). 새 기기의 노치/아일랜드 폭이 달라도 맞출 수 있게.
    let notchMenu = NSMenu()
    let notchOverlay = NotchOverlay()
    var notchOn = UserDefaults.standard.object(forKey: "notchWall") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notchOn, forKey: "notchWall") }
    }
    var notchEdges = UserDefaults.standard.array(forKey: "notchEdges") as? [Double] ?? [0, 0] {   // [왼쪽 끝, 오른쪽 끝] 이동량
        didSet { UserDefaults.standard.set(notchEdges, forKey: "notchEdges"); showNotchArea() }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: width)
        menu.addItem(label)
        menu.addItem(.separator())
        testItem = NSMenuItem(title: "테스트 모드", action: #selector(toggleTest), keyEquivalent: "t")
        testItem.target = self
        menu.addItem(testItem)
        menu.addItem(.separator())
        stageItem = NSMenuItem(title: "바탕화면 고양이와 별", action: #selector(toggleStage), keyEquivalent: "")
        stageItem.target = self; stageItem.state = .on
        menu.addItem(stageItem)
        frontItem = NSMenuItem(title: "창 위에 보이기", action: #selector(toggleFront), keyEquivalent: "")
        frontItem.target = self
        menu.addItem(frontItem)
        let screenMenu = NSMenu(); screenMenu.delegate = self   // 열 때마다 연결된 모니터로 채움
        let screenItem = NSMenuItem(title: "표시할 모니터", action: nil, keyEquivalent: "")
        screenItem.submenu = screenMenu
        menu.addItem(screenItem)
        followItem = NSMenuItem(title: "작업이 멈추면 그 앱으로 이동", action: #selector(toggleFollow), keyEquivalent: "")
        followItem.target = self; followItem.state = .on
        menu.addItem(followItem)
        notchMenu.delegate = self
        let notchItem = NSMenuItem(title: "노치 영역", action: nil, keyEquivalent: "")
        notchItem.submenu = notchMenu
        menu.addItem(notchItem)
        // 로그인 시 자동 실행: .app으로 실행했을 때만 쓸 수 있다
        let loginItem = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self; loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginItem.isEnabled = Bundle.main.bundleIdentifier != nil
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        render(angle: 0, spin: 0)
        stage = DesktopStage()
        stage.onMove = { [weak self] in if self?.fpsSetting == 0 { self?.startClock() } }   // 다른 모니터 주사율로
        startClock()
        fpsMenu.delegate = self
        let fpsItem = NSMenuItem(title: "프레임", action: nil, keyEquivalent: "")
        fpsItem.submenu = fpsMenu
        menu.insertItem(fpsItem, at: menu.index(of: frontItem) + 2)
        RunLoop.main.add(Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }, forMode: .common)
        sample()
    }

    @objc func toggleStage() {
        stage.visible.toggle(); stageItem.state = stage.visible ? .on : .off
    }
    @objc func toggleFront() {
        stage.inFront.toggle(); frontItem.state = stage.inFront ? .on : .off
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        if m === fpsMenu {
            let maxFPS = stage.screen?.maximumFramesPerSecond ?? 60
            for (tag, title) in [(0, "가변 (화면에 맞춤, 최대 \(maxFPS)fps)"), (24, "24fps"), (30, "30fps"), (60, "60fps"), (120, "120fps")] {
                let it = NSMenuItem(title: title, action: #selector(pickFPS(_:)), keyEquivalent: "")
                it.target = self; it.tag = tag; it.state = tag == fpsSetting ? .on : .off
                it.isEnabled = tag <= maxFPS || tag == 0      // 화면이 못 내는 주사율은 비활성
                m.addItem(it)
            }
            return
        }
        if m === notchMenu {
            let on = NSMenuItem(title: "노치에 부딪히고 돌아오기", action: #selector(toggleNotch), keyEquivalent: "")
            on.target = self; on.state = notchOn ? .on : .off
            m.addItem(on)
            let info = notchArea(on: notchScreen).map { String(format: "영역 x %.0f ~ %.0f (폭 %.0fpt)", $0.minX, $0.maxX, $0.width) }
            m.addItem(NSMenuItem(title: info ?? "노치 있는 화면이 없어요 (화면 왼쪽 끝까지 굴러감)", action: nil, keyEquivalent: ""))
            m.addItem(.separator())
            for (tag, title) in [(0, "왼쪽 끝 ←"), (1, "왼쪽 끝 →"), (2, "오른쪽 끝 ←"), (3, "오른쪽 끝 →")] {
                for fine in [false, true] {   // ⌥를 누르면 1pt씩
                    let it = NSMenuItem(title: title + (fine ? " 1pt" : " 5pt"), action: #selector(nudgeNotch(_:)), keyEquivalent: "")
                    it.target = self; it.tag = tag + (fine ? 10 : 0); it.isEnabled = notchOn && info != nil
                    if fine { it.isAlternate = true; it.keyEquivalentModifierMask = .option }
                    m.addItem(it)
                }
            }
            for (tag, title) in [(8, "영역 보기"), (9, "화면의 노치로 되돌리기")] {
                let it = NSMenuItem(title: title, action: #selector(nudgeNotch(_:)), keyEquivalent: "")
                it.target = self; it.tag = tag; it.isEnabled = notchOn && info != nil
                m.addItem(it)
            }
            return
        }
        let cur = stage.screen?.displayID
        for s in NSScreen.screens {
            let it = NSMenuItem(title: s.localizedName, action: #selector(pickScreen(_:)), keyEquivalent: "")
            it.target = self; it.tag = Int(s.displayID); it.state = s.displayID == cur ? .on : .off
            m.addItem(it)
        }
    }
    @objc func pickScreen(_ i: NSMenuItem) { stage.displayID = CGDirectDisplayID(i.tag) }
    @objc func pickFPS(_ i: NSMenuItem) { fpsSetting = i.tag }
    @objc func toggleNotch() { notchOn.toggle() }
    @objc func nudgeNotch(_ i: NSMenuItem) {
        switch i.tag {
        case 8: showNotchArea()
        case 9: notchEdges = [0, 0]
        default:
            let k = i.tag % 10
            notchEdges[k / 2] += (k % 2 == 0 ? -1 : 1) * (i.tag >= 10 ? 1 : 5)
        }
    }

    /// 메뉴바 별이 있는 화면 (없으면 노치 있는 첫 화면)
    var notchScreen: NSScreen? { item.button?.window?.screen ?? NSScreen.screens.first { $0.notchRect != nil } }

    /// 사용자가 맞춘 노치 영역. 꺼져 있거나 그 화면에 노치가 없으면 nil
    func notchArea(on scr: NSScreen?) -> NSRect? {
        guard notchOn, let n = scr?.notchRect else { return nil }
        let l = n.minX + CGFloat(notchEdges[0]), r = max(n.maxX + CGFloat(notchEdges[1]), l + 1)
        return NSRect(x: l, y: n.minY, width: r - l, height: n.height)
    }

    func showNotchArea() { if let a = notchArea(on: notchScreen) { notchOverlay.flash(a) } }

    @objc func toggleLogin(_ i: NSMenuItem) {
        let s = SMAppService.mainApp
        do { if s.status == .enabled { try s.unregister() } else { try s.register() } }
        catch { NSAlert(error: error).runModal() }
        i.state = s.status == .enabled ? .on : .off
    }

    @objc func toggleFollow() { followItem.state = followItem.state == .on ? .off : .on }

    @objc func toggleTest() { testMode.toggle(); testItem.state = testMode ? .on : .off; updateLabel() }

    // MARK: - 에이전트 작업이 멈추면 그 앱으로

    /// 멈춘 에이전트(pid)가 들어 있는 앱을 찾아 앞으로 가져온다.
    /// 앱 창이 다른 데스크톱에 있으면 별이 먼저 그쪽으로 굴러가고, 고양이가 뒤따라 뛰는 순간 데스크톱이 바뀐다.
    func agentStopped(_ pid: pid_t) {
        guard followItem.state == .on, let app = Self.guiApp(for: pid),
              app.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier,
              Date().timeIntervalSince(lastFollow) > 3, !stage.traveling else { return }
        lastFollow = Date()
        if stage.visible, let dir = Spaces.direction(toAppPid: app.processIdentifier) {
            stage.travel(dir: dir) { Self.bringForward(app) }
        } else {
            Self.bringForward(app)
        }
    }

    static func bringForward(_ app: NSRunningApplication) {
        app.activate(options: [])
        // 백그라운드 앱의 활성화 요청은 거절될 수 있다 → 실패하면 앱을 다시 열어 앞으로 가져온다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier,
                  let url = app.bundleURL else { return }
            let c = NSWorkspace.OpenConfiguration(); c.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: c)
        }
    }

    /// 에이전트 프로세스에서 부모를 따라 올라가며 처음 만나는 일반 앱(터미널, Claude, Cursor 등)
    static func guiApp(for pid: pid_t) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<32 where p > 1 {
            if let a = NSRunningApplication(processIdentifier: p), a.activationPolicy == .regular { return a }
            var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, p]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            p = info.kp_eproc.e_ppid
        }
        return nil
    }

    // MARK: - 상태 읽기

    func sample() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (s, c) = Self.readClaude()
            DispatchQueue.main.async {
                guard let self else { return }
                self.state = s; self.cpu = c
                self.updateLabel()
            }
        }
        watchQ.async { [weak self] in
            guard let self else { return }
            let stopped = self.watcher.poll()
            if !stopped.isEmpty { DispatchQueue.main.async { stopped.forEach(self.agentStopped) } }
        }
    }

    func updateLabel() {
        let s = testMode ? .thinking : state
        switch s {
        case .idle: label.title = "Claude Code: 대기 중"
        case .thinking: label.title = "Claude Code: 생각 중…"
        case .working: label.title = String(format: "Claude Code: 작업 실행 중 (CPU %.0f%%)", cpu)
        }
    }

    /// Claude Code는 생각하는 동안 CPU를 거의 안 쓴다. 그래서 대화 기록(~/.claude/projects/*/*.jsonl)의
    /// 마지막 기록을 본다: 사용자 메시지/도구 결과 뒤 → 모델이 생각 중, 도구 호출 뒤 → 작업 실행 중,
    /// 답변이 끝남(end_turn) → 대기.
    /// Claude Code의 상태와 CPU. 1초마다 불린다(sample 큐에서만).
    /// - 세션 목록(~/.claude/sessions/<pid>.json의 status)으로 바쁜 세션만 고른다 → 아무도 안 바쁘면 대화 기록을 읽지 않는다.
    /// - 바쁜 세션의 대화 기록(~/.claude/projects/<cwd>/<sessionId>.jsonl)은 크기·수정 시각이 바뀌었을 때만 끝 64KB를 다시 읽는다:
    ///   사용자 메시지/도구 결과 뒤 → 생각 중, 도구 호출 뒤 → 작업 실행 중, 답변 끝 → 대기.
    /// - CPU는 세션 프로세스들의 CPU 시간 변화량을 커널에서 직접 읽는다 (ps를 띄우지 않음).
    static func readClaude() -> (ClaudeState, Double) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var pids: [pid_t] = [], best = ClaudeState.idle
        for f in (try? fm.contentsOfDirectory(at: home.appendingPathComponent(".claude/sessions"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "json" {
            guard let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: Any],
                  let pid = d["pid"] as? Int, kill(pid_t(pid), 0) == 0 else { continue }
            pids.append(pid_t(pid))
            guard d["status"] as? String == "busy", let sid = d["sessionId"] as? String, let cwd = d["cwd"] as? String, best != .thinking else { continue }
            let dir = String(cwd.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" })
            let s = cachedState(of: home.appendingPathComponent(".claude/projects/\(dir)/\(sid).jsonl"))
            let st = s == .idle ? ClaudeState.thinking : s     // 바쁜데 기록이 "답변 끝"이면 막 새로 시작한 것
            if st == .thinking { best = .thinking } else if best == .idle { best = .working }
        }
        return (best, cpuPercent(of: pids))
    }

    private static var stateCache: [String: (mtime: Date, size: Int, state: ClaudeState)] = [:]
    static func cachedState(of url: URL) -> ClaudeState {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = a[.modificationDate] as? Date, let size = a[.size] as? Int else { return .thinking }
        if let c = stateCache[url.path], c.mtime == m, c.size == size { return c.state }
        let s = lastState(of: url)
        stateCache[url.path] = (m, size, s)
        return s
    }

    static func lastState(of url: URL) -> ClaudeState {
        guard let h = try? FileHandle(forReadingFrom: url) else { return .idle }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        guard let data = try? h.readToEnd() else { return .idle }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if obj["isSidechain"] as? Bool == true { continue }
            switch type {
            case "user", "api-request": return .thinking
            case "assistant":
                let msg = obj["message"] as? [String: Any]
                let stop = msg?["stop_reason"] as? String
                if stop == "tool_use" { return .working }
                if stop == nil { return .thinking }     // 답변을 쓰는 중
                return .idle                            // end_turn 등: 답변 완료
            default: continue
            }
        }
        return .idle
    }

    private static var cpuPrev: [pid_t: UInt64] = [:], cpuPrevT = 0.0
    private static let ticksToNs: Double = { var tb = mach_timebase_info(); mach_timebase_info(&tb); return Double(tb.numer) / Double(tb.denom) }()
    /// 프로세스들의 CPU 사용률(%) — 지난 호출 이후 CPU 시간 변화량 / 지난 시간
    static func cpuPercent(of pids: [pid_t]) -> Double {
        let now = CACurrentMediaTime()
        var cur: [pid_t: UInt64] = [:]
        for pid in pids {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size { cur[pid] = info.pti_total_user + info.pti_total_system }
        }
        defer { cpuPrev = cur; cpuPrevT = now }
        let dt = now - cpuPrevT
        guard cpuPrevT > 0, dt > 0 else { return 0 }
        var used = 0.0
        for (p, t) in cur { if let o = cpuPrev[p], t >= o { used += Double(t - o) * ticksToNs } }
        return used / (dt * 1e9) * 100
    }

    // MARK: - 움직임

    static func smooth(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }

    // MARK: - 프레임

    func startClock() {
        timer?.invalidate(); timer = nil
        link?.invalidate(); link = nil; linkFast = nil
        lastTick = CACurrentMediaTime()
        if fpsSetting == 0 {
            // 무대가 있는 모니터의 디스플레이 링크: 그 화면 주사율(ProMotion 가변 포함)을 따른다.
            // (무대를 숨겨도 메뉴바 별은 계속 움직이도록 뷰가 아니라 화면 기준)
            guard let scr = stage.screen ?? NSScreen.main else { return }
            let l = scr.displayLink(target: self, selector: #selector(onLink(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1 / Double(fpsSetting), repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    @objc func onLink(_ l: CADisplayLink) {
        tick()
        // 움직이는 게 있으면 화면 최대 주사율, 0.5초 넘게 가만하면 10fps로 낮춰 전력 절약
        let fast = CACurrentMediaTime() - stage.lastDraw < 0.5 || presence > 0
        guard fast != linkFast else { return }
        linkFast = fast
        let maxFPS = Float(stage.screen?.maximumFramesPerSecond ?? 60)
        l.preferredFrameRateRange = fast ? CAFrameRateRange(minimum: 30, maximum: maxFPS, preferred: maxFPS)
                                         : CAFrameRateRange(minimum: 8, maximum: 10, preferred: 10)
    }

    func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 1.0 / 15)   // 멈췄다 돌아와도 한 번에 크게 튀지 않게
        lastTick = now
        let s = testMode ? .thinking : state
        stage.update(busy: s != .idle, cpu: testMode ? max(cpu, 40) : cpu, dt: dt)
        let target = s == .idle ? 0.0 : 1.0
        presence += (target - presence) * (1 - pow(0.94, dt * 24))
        if roller.active {   // 메뉴바 나들이 중에는 시계를 멈추고 나들이만
            if !roller.step(dt) {
                clock = (clock / Self.cycle).rounded(.down) * Self.cycle + 7.0   // 돌아오면 잠깐 쉼부터
                lastKey = ""; render(angle: 0, spin: 0)
            }
            return
        }
        if target == 0 && presence < 0.01 {
            presence = 0
            if lastKey != "idle" { render(angle: 0, spin: 0); lastKey = "idle" }
            clock = 0
            return   // 대기 중에는 다시 그리지 않는다
        }
        // 사람이 고민할 때처럼: 오른쪽으로 천천히 갸웃 → 머무름 → 왼쪽으로 갸웃 → 머무름
        // → 똑바로 돌아와 메뉴바를 굴러 화면 왼쪽 끝에 쿵 박고 돌아옴 → 잠깐 쉼. 한 주기 약 8초 + 나들이.
        // 작업 실행 중(CPU 사용)이면 조금 더 빨리 반복한다.
        let speed = s == .working ? 1.0 + min(cpu, 100) / 200 : 1.0
        let before = clock.truncatingRemainder(dividingBy: Self.cycle)
        clock += dt * speed
        let ph = clock.truncatingRemainder(dividingBy: Self.cycle)
        // 똑바로 선 뒤: 제자리 한 바퀴 대신 메뉴바를 굴러 왼쪽 끝까지 다녀온다
        // 별 왼쪽에 노치 영역이 있으면 거기(오른쪽 끝)에 부딪히고, 없으면 화면 왼쪽 끝까지
        if before < 5.8 && ph >= 5.8 && presence > 0.9, let b = item.button,
           roller.start(button: b, wall: notchArea(on: b.window?.screen).flatMap { b.window!.frame.minX >= $0.maxX ? $0.maxX : nil }) {
            clock += 5.8 - ph
            b.image = NSImage(size: NSSize(width: width, height: 18)); lastKey = "roll"
            return
        }
        let (tilt, spin) = Self.pose(ph)
        let angle = tilt * 13 * presence
        let key = String(format: "%.1f|%.1f", angle, spin)
        // 메뉴바 아이콘은 그림을 바꿀 때마다 WindowServer가 메뉴바를 다시 그려 비싸다 → 최대 30fps
        if key == lastKey || now - lastRender < 1.0 / 30 { return }
        lastRender = now
        lastKey = key
        render(angle: CGFloat(angle), spin: CGFloat(spin))
    }

    static let cycle = 8.0

    /// 주기 안의 시간 t(초) → (갸웃 정도 -1…1, 회전 각도)
    static func pose(_ t: Double) -> (Double, Double) {
        switch t {
        case ..<0.9: return (smooth(t / 0.9), 0)                       // 오른쪽으로 기울이기
        case ..<2.6: return (1, 0)                                     // 머무르기
        case ..<3.5: return (1 - 2 * smooth((t - 2.6) / 0.9), 0)       // 왼쪽으로 넘어가기
        case ..<5.2: return (-1, 0)                                    // 머무르기
        case ..<5.8: return (-1 + smooth((t - 5.2) / 0.6), 0)          // 똑바로
        case ..<7.0: return (0, 360 * smooth((t - 5.8) / 1.2))         // 한 바퀴
        default:     return (0, 0)                                     // 쉼
        }
    }

    func render(angle: CGFloat, spin: CGFloat) {
        item.button?.image = Self.starImage(angle: angle, spin: spin, width: width)
    }

    static func drawStar(in r: NSRect, angle: CGFloat, spin: CGFloat, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        // 갸웃: 별 아래쪽(목)을 축으로 기울임
        t.translateX(by: r.midX, yBy: r.minY + 2)
        t.rotate(byDegrees: -angle)
        t.translateX(by: 0, yBy: 7)
        // 한 바퀴: 별 가운데를 축으로 회전
        t.rotate(byDegrees: -spin)
        t.concat()
        let path = NSBezierPath()
        path.lineWidth = 2; path.lineCapStyle = .round
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4, len: CGFloat = i % 2 == 0 ? 7 : 5.5
            path.move(to: NSPoint(x: cos(a) * 1.5, y: sin(a) * 1.5))
            path.line(to: NSPoint(x: cos(a) * len, y: sin(a) * len))
        }
        color.setStroke(); path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func starImage(angle: CGFloat, spin: CGFloat, width: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: width, height: 18), flipped: false) { r in
            drawStar(in: r, angle: angle, spin: spin, color: .black); return true
        }
        img.isTemplate = true
        return img
    }

    /// 확인용: 한 주기 동작을 0.25초 간격으로 그려 한 장의 PNG로 저장한다.
    /// 사용법: ./ClaudeThinking --frames 저장할파일.png
    static func exportFrames(to path: String) {
        let cols = 8, step = 0.25, n = Int(cycle / step)
        let cw = 24, ch = 22, scale = 4
        let rows = (n + cols - 1) / cols
        let w = cols * cw * scale, h = rows * ch * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        let ctx = NSAffineTransform(); ctx.scale(by: CGFloat(scale)); ctx.concat()
        for i in 0..<n {
            let (tilt, spin) = pose(Double(i) * step)
            let col = i % cols, row = rows - 1 - i / cols
            let cell = NSRect(x: col * cw, y: row * ch, width: cw, height: ch)
            NSColor(white: 0.85, alpha: 1).setStroke(); NSBezierPath(rect: cell.insetBy(dx: 0.25, dy: 0.25)).stroke()
            drawStar(in: NSRect(x: cell.minX, y: cell.minY + 3, width: cell.width, height: 18),
                     angle: CGFloat(tilt * 13), spin: CGFloat(spin), color: .black)
            let label = String(format: "%.2fs", Double(i) * step) as NSString
            label.draw(at: NSPoint(x: cell.minX + 1, y: cell.minY + 0.3),
                       withAttributes: [.font: NSFont.systemFont(ofSize: 2.6), .foregroundColor: NSColor.gray])
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - 노치 컨테이너

extension NSScreen {
    /// 노치 영역(전역 좌표). 노치 없는 화면이면 nil. 좌우 보조 영역 너비로 계산해 노치 폭이 달라도 맞는다.
    var notchRect: NSRect? {
        guard safeAreaInsets.top > 0, let l = auxiliaryTopLeftArea, let r = auxiliaryTopRightArea else { return nil }
        let h = safeAreaInsets.top
        return NSRect(x: frame.minX + l.width, y: frame.maxY - h, width: frame.width - l.width - r.width, height: h)
    }
}

/// 노치 영역을 맞출 때 잠깐 빨간 테두리로 보여 준다 (노치 자체는 화면이 없어 가장자리만 보임)
final class NotchOverlay {
    private let win = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var hide: DispatchWorkItem?
    init() {
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false; win.hidesOnDeactivate = false
        win.ignoresMouseEvents = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let v = NSView(); v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.25).cgColor
        v.layer?.borderColor = NSColor.systemRed.cgColor; v.layer?.borderWidth = 2
        win.contentView = v
    }
    func flash(_ r: NSRect) {
        win.setFrame(r.insetBy(dx: -2, dy: 0), display: true); win.orderFrontRegardless()
        hide?.cancel()
        let h = DispatchWorkItem { [weak self] in self?.win.orderOut(nil) }
        hide = h; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: h)
    }
}

// MARK: - 메뉴바 별 나들이

/// 메뉴바 별이 아이콘 자리에서 나와 메뉴바 아래 가장자리를 딛고, 가려는 쪽으로 몸을 기울여 일어선 뒤
/// 굴러서 노치 영역(사용자가 맞춘 것)의 오른쪽 끝, 노치가 없으면 화면 왼쪽 끝까지 가서 쿵 박고, 돌아서서 다시 굴러 아이콘 자리로 돌아온다.
final class MenuRoller {
    private let win: NSPanel, view = SpriteView()
    private enum Phase { case lean, roll, bonk, turn, back, home }
    private var phase: Phase?
    private var t = 0.0, x: CGFloat = 0, y: CGFloat = 0, angle: CGFloat = 0, wobble: CGFloat = 0, v: CGFloat = 0
    private var home = NSPoint.zero, floor: CGFloat = 0, left: CGFloat = 0, a0: CGFloat = 0, y0: CGFloat = 0
    private var color = NSColor.white
    var active: Bool { phase != nil }
    var position: (NSPoint, CGFloat) { (NSPoint(x: x, y: y), angle + wobble) }
    static let r: CGFloat = 7, accel: CGFloat = 2200, vmax: CGFloat = 950, lean: CGFloat = 24

    init() {
        win = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false
        win.ignoresMouseEvents = true; win.hidesOnDeactivate = false
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)   // 메뉴바 위
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view.wantsLayer = true; win.contentView = view
        view.paint = { [unowned self] in Self.draw(at: NSPoint(x: x, y: y), angle: angle + wobble, color: color) }
    }

    /// 별 가운데가 바닥에서 얼마나 떠야 가장 낮은 끝이 바닥에 닿는지 (기울기 angle도, 반시계 +)
    static func support(_ angle: CGFloat) -> CGFloat {
        (0..<8).map { i -> CGFloat in
            let a = CGFloat(i) * .pi / 4 + angle * .pi / 180, len: CGFloat = i % 2 == 0 ? 7 : 5.5
            return -sin(a) * len
        }.max()!
    }

    static func draw(at c: NSPoint, angle: CGFloat, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform(); t.translateX(by: c.x, yBy: c.y); t.rotate(byDegrees: angle); t.concat()
        let path = NSBezierPath(); path.lineWidth = 2; path.lineCapStyle = .round
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4, len: CGFloat = i % 2 == 0 ? 7 : 5.5
            path.move(to: NSPoint(x: cos(a) * 1.5, y: sin(a) * 1.5))
            path.line(to: NSPoint(x: cos(a) * len, y: sin(a) * len))
        }
        color.setStroke(); path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 메뉴바 아이콘 버튼에서 출발. wall = 부딪힐 벽의 x (nil이면 화면 왼쪽 끝)
    func start(button: NSStatusBarButton, wall: CGFloat? = nil) -> Bool {
        guard let bw = button.window, let scr = bw.screen else { return false }
        let bar = scr.frame.maxY - scr.visibleFrame.maxY
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        begin(home: NSPoint(x: bw.frame.midX, y: bw.frame.midY),
              floor: bar > 0 && bar < 60 ? scr.visibleFrame.maxY : bw.frame.minY,   // 메뉴바 아래 가장자리
              left: wall ?? scr.frame.minX, color: dark ? .white : .black)
        place(); win.orderFrontRegardless()
        return true
    }

    func begin(home: NSPoint, floor: CGFloat, left: CGFloat, color: NSColor) {
        self.home = home; self.floor = floor; self.left = left; self.color = color
        x = home.x; y = home.y; angle = 0; wobble = 0; v = 0; t = 0; phase = .lean
    }

    /// 한 프레임. 끝나면 false
    func step(_ dt: Double) -> Bool {
        guard let ph = phase else { return false }
        t += dt
        let step = CGFloat(dt), deg = 180 / CGFloat.pi
        func k(_ d: Double) -> CGFloat { CGFloat(AppDelegate.smooth(t / d)) }
        func onFloor() -> CGFloat { floor + Self.support(angle + wobble) }
        switch ph {
        case .lean:
            // 아이콘 자리에서 내려와 메뉴바 바닥을 딛으며, 왼쪽(갈 쪽)으로 몸을 기울여 일어선다
            let q = k(0.35)
            angle = Self.lean * q
            x = home.x + sin(.pi * q) * 2                       // 살짝 반동
            y = home.y + (onFloor() - home.y) * q + sin(.pi * q) * 2
            if t >= 0.35 { phase = .roll; t = 0; v = 0 }
        case .roll:
            v = min(v + Self.accel * step, Self.vmax)
            let dx = min(v * step, x - (left + Self.r))
            x -= dx; angle += dx / Self.r * deg              // 왼쪽으로 구르면 반시계로 돈다
            y = onFloor()
            if x <= left + Self.r + 0.5 { phase = .bonk; t = 0; v = 320 }   // 쿵
        case .bonk:
            // 벽에 박고 튕겨 나오며 통, 어질어질 흔들림
            x += v * step; angle -= v * step / Self.r * deg * 0.5; v *= pow(0.004, step)
            wobble = sin(CGFloat(t) * 26) * 9 * exp(-CGFloat(t) * 5)
            y = onFloor() + (t < 0.28 ? sin(.pi * CGFloat(t / 0.28)) * 6 : 0)
            if t >= 0.7 { phase = .turn; t = 0; wobble = 0; a0 = angle }
        case .turn:
            // 돌아갈 쪽(오른쪽)으로 몸을 기울여 일어섬
            angle = a0 - Self.lean * k(0.3)
            y = onFloor()
            if t >= 0.3 { phase = .back; t = 0; v = 0 }
        case .back:
            let remain = home.x - x
            v = min(v + Self.accel * step, Self.vmax, sqrt(2 * Self.accel * max(remain, 0)) + 20)   // 다 와서는 천천히
            let dx = min(v * step, remain)
            x += dx; angle -= dx / Self.r * deg
            y = onFloor()
            if remain - dx < 0.5 { phase = .home; t = 0; a0 = angle; y0 = y }
        case .home:
            // 똑바로 서며 아이콘 자리로 쏙
            let q = k(0.35)
            let upright = (a0 / 90).rounded() * 90
            angle = a0 + (upright - a0) * q
            x = home.x; y = y0 + (home.y - y0) * q
            if t >= 0.35 { phase = nil; win.orderOut(nil); return false }
        }
        place()
        return true
    }

    private func place() {
        guard win.isVisible || phase != nil else { return }
        win.setFrameOrigin(NSPoint(x: (x - 20).rounded(), y: (y - 20).rounded()))
        view.needsDisplay = true
    }

    /// 확인용: 가짜 메뉴바(너비 700, 높이 24)에서 나들이를 그린다. ./ClaudeThinking --roller-frames 파일.png
    static func exportFrames(to path: String) {
        let r = MenuRoller(), W: CGFloat = 700, H: CGFloat = 24
        r.begin(home: NSPoint(x: 640, y: H / 2), floor: 0, left: 0, color: .black)
        var frames: [(String, NSPoint, CGFloat)] = []
        var t = 0.0, i = 0
        while r.step(1.0 / 60) { t += 1.0 / 60; i += 1; if i % 6 == 0 { let p = r.position; frames.append((String(format: "%.2f", t), p.0, p.1)) } }
        let rowH: CGFloat = 30, scale: CGFloat = 2
        let w = Int(W * scale), h = Int(rowH * CGFloat(frames.count) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = NSAffineTransform(); s.scale(by: scale); s.concat()
        for (n, f) in frames.enumerated() {
            let y0 = rowH * CGFloat(frames.count - 1 - n)
            NSColor(white: 0.85, alpha: 1).setFill(); NSRect(x: 0, y: y0 + 3, width: W, height: H).fill()   // 메뉴바
            NSColor.white.setFill(); NSRect(x: 0, y: y0, width: W, height: 3).fill()
            NSColor.red.setFill(); NSRect(x: 0, y: y0 + 3, width: W, height: 0.5).fill()                       // 메뉴바 아래 가장자리
            draw(at: NSPoint(x: f.1.x, y: y0 + 3 + f.1.y), angle: f.2, color: .black)
            (f.0 as NSString).draw(at: NSPoint(x: 4, y: y0 + 10), withAttributes: [.font: NSFont.systemFont(ofSize: 7)])
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("프레임 수:", frames.count, "총 시간:", String(format: "%.2f초", t))
    }
}

// MARK: - 화면 인식 (발판 찾기)

/// 고양이 주변 작은 영역만 찍어(ScreenCaptureKit) 기기 안 Vision 모델로 글자 줄과 사각형(입력창·버튼·카드)을 찾고,
/// 그 윗변을 발판으로 돌려준다. 앱 종류와 상관없이 화면에 보이는 그대로 인식한다. 고양이·별 창은 캡처에서 뺀다.
enum LedgeVision {
    private static var content: SCShareableContent?, contentAt = 0.0
    private static var permitted: Bool?, permittedAt = 0.0
    static var scale: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["CT_SCALE"] ?? "") ?? 2)   // 2배율: 줄 단위로 잡힘
    static var useOCR = ProcessInfo.processInfo.environment["CT_MODE"] == "ocr"

    /// 화면 기록 권한이 있는지 (10초마다 다시 확인)
    static var ready: Bool {
        let now = CACurrentMediaTime()
        if permitted == nil || now - permittedAt > 10 { permitted = CGPreflightScreenCaptureAccess(); permittedAt = now }
        return permitted ?? false
    }

    /// rect: 전역 좌표(아래가 0). done은 아무 큐에서나 불린다. 실패하면 nil.
    static func detect(in rect: NSRect, primaryH: CGFloat, done: @escaping ([NSRect]?) -> Void) {
        let now = CACurrentMediaTime()
        if let c = content, now - contentAt < 5 { shoot(c, rect, primaryH, done); return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in
            guard let c else { done(nil); return }
            content = c; contentAt = CACurrentMediaTime()
            shoot(c, rect, primaryH, done)
        }
    }

    private static func shoot(_ c: SCShareableContent, _ rect: NSRect, _ primaryH: CGFloat, _ done: @escaping ([NSRect]?) -> Void) {
        // 화면 좌표(위가 0)로 바꿔 그 모니터 안으로 자른다
        let cg = CGRect(x: rect.minX, y: primaryH - rect.maxY, width: rect.width, height: rect.height)
        guard let d = c.displays.first(where: { $0.frame.contains(CGPoint(x: cg.midX, y: cg.midY)) }) else { done(nil); return }
        let clip = cg.intersection(d.frame)
        guard clip.width > 20, clip.height > 20 else { done([]); return }
        let me = c.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = clip.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
        cfg.width = Int(clip.width * scale); cfg.height = Int(clip.height * scale)
        cfg.showsCursor = false
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, _ in
            guard let img else { done(nil); return }
            done(recognize(img, area: NSRect(x: clip.minX, y: primaryH - clip.maxY, width: clip.width, height: clip.height)))
        }
    }

    /// 이미지에서 글자 줄·사각형을 찾아 윗변 발판으로 (area: 이미지가 덮는 전역 영역, 아래가 0)
    static func recognize(_ img: CGImage, area: NSRect) -> [NSRect] {
        let text: VNImageBasedRequest
        if useOCR {
            let r = VNRecognizeTextRequest(); r.recognitionLevel = .fast; r.usesLanguageCorrection = false; text = r
        } else {
            let r = VNDetectTextRectanglesRequest(); r.reportCharacterBoxes = false; text = r
        }
        let boxes = VNDetectRectanglesRequest()
        boxes.maximumObservations = 12; boxes.minimumSize = 0.06; boxes.minimumAspectRatio = 0.04
        boxes.minimumConfidence = 0.5; boxes.quadratureTolerance = 8
        try? VNImageRequestHandler(cgImage: img).perform([text, boxes])
        var tops: [NSRect] = []
        for o in ((text.results as? [VNDetectedObjectObservation]) ?? []) + (boxes.results ?? []) {
            let b = o.boundingBox
            tops.append(NSRect(x: area.minX + b.minX * area.width, y: area.minY + b.maxY * area.height + 1, width: b.width * area.width, height: 0))
        }
        // 같은 줄의 낱말 상자들은 하나로 잇는다
        tops.sort { abs($0.minY - $1.minY) > 4 ? $0.minY < $1.minY : $0.minX < $1.minX }
        var out: [NSRect] = []
        for t in tops {
            if let last = out.last, abs(last.minY - t.minY) <= 4, t.minX <= last.maxX + 24 {
                out[out.count - 1] = NSRect(x: last.minX, y: max(last.minY, t.minY), width: max(last.maxX, t.maxX) - last.minX, height: 0)
            } else { out.append(t) }
        }
        return out.filter { $0.width >= 30 }
    }
}

// MARK: - 여러 에이전트 플랫폼의 작업 상태

/// 1초마다 불러서 "작업 중 → 멈춤"으로 바뀐 에이전트의 pid를 돌려준다. (agent-watch 큐에서만 사용)
/// - Claude Code (터미널·데스크톱 앱·IDE·SDK): ~/.claude/sessions/<pid>.json 의 status
/// - Codex (CLI·앱): ~/.codex/sessions/날짜/rollout-*.jsonl 의 task_started / task_complete / turn_aborted.
///   pid는 그 파일을 열고 있는 프로세스(lsof).
/// - 그 밖의 플랫폼(Grok, Gemini, Cursor 에이전트 등): Stop 훅에서
///   `mkdir -p ~/.claudethinking/done && echo $PPID > ~/.claudethinking/done/$PPID` 를 실행하면 된다.
final class AgentWatcher {
    private var wasBusy: [String: Bool] = [:]
    var busyKeys: [String] { wasBusy.filter(\.value).map(\.key).sorted() }
    private let fm = FileManager.default
    private lazy var home = fm.homeDirectoryForCurrentUser

    func poll(takeDrops: Bool = true) -> [pid_t] {
        var now: [String: (busy: Bool, pid: () -> pid_t?)] = [:]

        // Claude Code
        for f in files(in: home.appendingPathComponent(".claude/sessions")) where f.pathExtension == "json" {
            guard let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: Any],
                  let pid = d["pid"] as? Int, let st = d["status"] as? String else { continue }
            now["claude:\(pid)"] = (st == "busy", { pid_t(pid) })
        }

        // Codex: 오늘·어제 폴더에서 10분 안에 바뀐 기록만
        let cal = Calendar.current
        for back in [0, -1] {
            let day = cal.date(byAdding: .day, value: back, to: Date())!
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = home.appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!))
            for f in files(in: dir) where f.pathExtension == "jsonl" && recent(f) {
                now["codex:\(f.path)"] = (Self.codexBusy(f), { Self.openedBy(f) })
            }
        }

        var stopped: [pid_t] = []
        for (key, s) in now {
            if wasBusy[key] == true && !s.busy, let pid = s.pid() { stopped.append(pid) }
        }
        wasBusy = now.mapValues { $0.busy }

        // 훅으로 알려 온 것
        let drop = home.appendingPathComponent(".claudethinking/done")
        for f in files(in: drop) where takeDrops {
            if let s = try? String(contentsOf: f, encoding: .utf8),
               let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) { stopped.append(pid) }
            try? fm.removeItem(at: f)
        }
        return stopped
    }

    private func files(in dir: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    }

    private func recent(_ f: URL) -> Bool {
        guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
        return Date().timeIntervalSince(m) < 600
    }

    static func codexBusy(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? h.readToEnd() else { return false }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            if line.contains("\"payload\":{\"type\":\"task_started\"") { return true }
            if line.contains("\"payload\":{\"type\":\"task_complete\"") || line.contains("\"payload\":{\"type\":\"turn_aborted\"") { return false }
        }
        return false
    }

    static func openedBy(_ url: URL) -> pid_t? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-t", "--", url.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self).split(separator: "\n").first.flatMap { pid_t($0) }
    }
}

// MARK: - 데스크톱(Spaces)

/// macOS는 데스크톱 순서를 공개 API로 알려 주지 않아서 WindowServer의 비공개 함수를 쓴다.
/// 함수가 없으면(향후 macOS) 방향을 모른다고 보고 애니메이션 없이 앱만 앞으로 가져온다.
enum Spaces {
    typealias ConnFn = @convention(c) () -> Int32
    typealias DisplaysFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias ForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    static func sym<T>(_ name: String, _: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }   // RTLD_DEFAULT
    }

    /// 앱 창이 다른 데스크톱에 있으면 그쪽 방향(+1 오른쪽, -1 왼쪽). 지금 데스크톱에 있거나 알 수 없으면 nil.
    static func direction(toAppPid pid: pid_t) -> CGFloat? {
        guard let conn = sym("CGSMainConnectionID", ConnFn.self),
              let displays = sym("CGSCopyManagedDisplaySpaces", DisplaysFn.self),
              let forWindows = sym("CGSCopySpacesForWindows", ForWindowsFn.self) else { return nil }
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let wins = all.filter {
            ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
                && (($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 40
        }
        if wins.contains(where: { $0[kCGWindowIsOnscreen as String] as? Bool == true }) { return nil }   // 이미 여기 있음
        let ids = wins.compactMap { $0[kCGWindowNumber as String] as? Int }
        let cid = conn()
        guard !ids.isEmpty,
              let target = (forWindows(cid, 7, ids as CFArray)?.takeRetainedValue() as? [NSNumber])?.first?.uint64Value,
              let list = displays(cid)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        func id(_ s: Any?) -> UInt64 {
            let d = s as? [String: Any]
            return ((d?["id64"] ?? d?["ManagedSpaceID"]) as? NSNumber)?.uint64Value ?? 0
        }
        for d in list {
            let order = (d["Spaces"] as? [Any] ?? []).map(id)
            guard let ti = order.firstIndex(of: target), let ci = order.firstIndex(of: id(d["Current Space"])), ti != ci else { continue }
            return ti > ci ? 1 : -1
        }
        return nil
    }
}

// MARK: - 바탕화면 무대: 고양이와 별

extension NSScreen {
    var displayID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
}

/// 규칙
/// - Claude가 쉬는 중: 고양이는 별 옆에서 웅크려 자고, 별은 옆에 앉아 있다. (다시 그리지 않음)
/// - Claude가 바쁨: 고양이가 깨어 별을 쫓고, 별은 도망간다. 고양이 속도 = Claude CPU 사용량.
///   별이 화면 끝에 몰리면 고양이를 뛰어넘어(한 바퀴 돌며) 반대쪽으로 도망간다.
/// - Claude가 일을 끝냄: 고양이가 별을 따라잡고, 둘이 나란히 쉰다.
/// - 마우스가 닿으면 둘 다 그 자리에서 멈춘다.
/// - 모니터가 여러 대면 "디스플레이 배열" 그대로 이어진 세계다. 고양이와 별은 각자 다른 모니터에 있을 수 있고,
///   별이 아래 모니터로 가면 고양이가 위 모니터 바닥을 뚫고 떨어지고, 위로 가면 뛰어오른다.
enum CatMode { case sleep, run }

/// 고양이와 별의 상태와 그리기. 좌표는 모두 전역 화면 좌표(모니터 배열 그대로, 아래가 0).
/// 각자 지금 딛고 있는 바닥(catFloor/starFloor: 그 모니터의 Dock 위 가장자리)과 그 위 높이(catY/starY)를 가진다.
final class Pets {
    var catX: CGFloat = 0, catY: CGFloat = 0, catFloor: CGFloat = 0, catFacing: CGFloat = 1, catPhase: CGFloat = 0, catMode = CatMode.sleep
    var starX: CGFloat = 0, starY: CGFloat = 0, starFloor: CGFloat = 0, starAngle: CGFloat = 0

    var dragging = false, held = false   // held: 고양이가 별을 입에 물고 누워 있음
    var dragLock = false                 // 고양이가 매달려 그랩이 풀린 뒤, 버튼을 뗄 때까지 끌기 무시
    var hanging = false, catSway: CGFloat = 0   // 고양이가 별을 물고 매달려 있음
    var draggingCat = false, grabPoint = NSPoint.zero   // 고양이 목덜미를 잡고 있음 (잡은 곳, 전역)
    var dangling: Bool { hanging || draggingCat }
    var starScale: CGFloat = 1
    // 고양이 몸짓: 몸 기울기(도, +는 머리 위로), 웅크림 0…1, 공중, 고개 들기(도), 다리 움직임 0…1, 신남 0…1, 꼬리 시계
    var catPitch: CGFloat = 0, crouch: CGFloat = 0, catAir = false, headUp: CGFloat = 0
    var moving: CGFloat = 1, excite: CGFloat = 0, tailT: CGFloat = 0
    func resetPose() { catPitch = 0; crouch = 0; catAir = false; headUp = 0; moving = 1; excite = 0.3 }

    var starCenter: NSPoint { NSPoint(x: starX, y: starFloor + starY + 11) }
    /// 같은 바닥: 화면 인식은 같은 글자 줄도 몇 px씩 다르게 잡으므로 14px 안이면 같은 줄로 본다
    var sameFloor: Bool { abs(catFloor - starFloor) < 14 }

    /// 고양이·별이 그려지는 영역(전역, 여유 포함)
    func catRect() -> NSRect {
        let anchor = hanging ? starCenter : draggingCat ? grabPoint : nil
        return anchor.map { NSRect(x: $0.x - 60, y: $0.y - 75, width: 120, height: 100) }
            ?? NSRect(x: catX - 50, y: catFloor + catY - 12, width: 100, height: 80)
    }
    func starRect() -> NSRect { NSRect(x: starX - 30, y: starFloor + starY - 19, width: 60, height: 60) }

    /// 별 가운데가 바닥에서 얼마나 떠야 가장 낮은 끝이 바닥에 닿는지 (기울기에 따라 다름, 똑바로면 11)
    static func support(_ angle: CGFloat) -> CGFloat {
        (0..<8).map { i -> CGFloat in
            let a = CGFloat(i) * .pi / 4 - angle * .pi / 180, len: CGFloat = i % 2 == 0 ? 11 : 8.5
            return -sin(a) * len
        }.max()!
    }
    /// 쓰러져 두 끝(긴 것·짧은 것)으로 바닥을 딛는 기울기(도)
    static let restTilt = atan2(11 - 8.5 * sin(CGFloat.pi / 4), 8.5 * cos(CGFloat.pi / 4)) * 180 / .pi

    // 닿았는지(전역 좌표): 그림 크기 + 여유 4px
    func onCat(_ p: NSPoint) -> Bool {
        abs(p.x - catX) < 31 && p.y > catFloor + catY - 4 && p.y < catFloor + catY + 35
    }
    func onStar(_ p: NSPoint) -> Bool { hypot(p.x - starX, p.y - starCenter.y) < 15 }

    private let outline = NSColor(white: 1, alpha: 0.9)
    private let fur = NSColor(white: 0.16, alpha: 1)

    func drawCat() {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        if hanging {
            // 입(22, 17)을 별 가운데에 붙이고 몸은 아래로 늘어뜨림
            t.translateX(by: starCenter.x, yBy: starCenter.y)
            t.rotate(byDegrees: 90 * catFacing + catSway)
            t.scaleX(by: catFacing, yBy: 1)
            t.translateX(by: -22, yBy: -17)
        } else if draggingCat {
            // 목덜미(12, 25)를 잡힌 채 몸이 아래로 늘어짐
            t.translateX(by: grabPoint.x, yBy: grabPoint.y)
            t.rotate(byDegrees: 90 * catFacing + catSway)
            t.scaleX(by: catFacing, yBy: 1)
            t.translateX(by: -12, yBy: -25)
        } else {
            t.translateX(by: catX, yBy: catFloor + catY)
            t.scaleX(by: catFacing, yBy: 1)
            t.translateX(by: 0, yBy: 12); t.rotate(byDegrees: catPitch); t.translateX(by: 0, yBy: -12)   // 몸 기울기
        }
        t.concat()
        let body = NSBezierPath(), extra = NSBezierPath()
        switch catMode {
        case .run:
            let s = sin(catPhase)
            let bob = (catAir || dangling ? 0 : abs(s) * 2.5) - crouch * 5   // 웅크리면 몸이 낮아짐
            // 다리 4개
            let legs = NSBezierPath(); legs.lineWidth = 3.2; legs.lineCapStyle = .round
            for (hipX, off) in [(-10.0, 0.0), (-6.0, CGFloat.pi), (8.0, CGFloat.pi * 0.5), (12.0, CGFloat.pi * 1.5)] {
                let front = hipX > 0
                legs.move(to: NSPoint(x: hipX, y: 10 + bob))
                if dangling {
                    // 매달림: 다리가 아래(꼬리 쪽)로 늘어져 허우적
                    let k = sin(tailT * 9 + off) * 3
                    legs.line(to: NSPoint(x: hipX - 7 + k, y: 6 + bob + (front ? 2 : -2)))
                } else if catAir {
                    // 점프: 앞발은 앞으로 뻗고, 뒷발은 뒤로 쭉
                    legs.line(to: front ? NSPoint(x: hipX + 9, y: 15 + bob) : NSPoint(x: hipX - 9, y: 4 + bob))
                } else {
                    // 달리기(멈춰 있으면 다리를 모으고 섬), 웅크리면 무릎을 굽힘
                    let sw = sin(catPhase + off) * 5 * moving
                    legs.line(to: NSPoint(x: hipX + sw + crouch * (front ? 3 : -3),
                                          y: max(0, 1 + cos(catPhase + off) * 2 * moving)))
                }
            }
            body.append(NSBezierPath(ovalIn: NSRect(x: -16, y: 8 + bob, width: 32, height: 14)))
            // 머리: 목(13, 19)을 축으로 별 쪽을 올려다봄
            let head = NSBezierPath(ovalIn: NSRect(x: 10, y: 14 + bob, width: 14, height: 13))
            head.move(to: NSPoint(x: 12, y: 24 + bob)); head.line(to: NSPoint(x: 13.5, y: 31 + bob)); head.line(to: NSPoint(x: 17, y: 26 + bob)); head.close()
            head.move(to: NSPoint(x: 18, y: 26 + bob)); head.line(to: NSPoint(x: 21.5, y: 31 + bob)); head.line(to: NSPoint(x: 23, y: 23 + bob)); head.close()
            let eye = NSBezierPath(ovalIn: NSRect(x: 18.5, y: 20.5 + bob, width: 2.6, height: 2.6))
            let look = NSAffineTransform()
            look.translateX(by: 13, yBy: 19 + bob); look.rotate(byDegrees: headUp); look.translateX(by: -13, yBy: -19 - bob)
            head.transform(using: look as AffineTransform); eye.transform(using: look as AffineTransform)
            body.append(head)
            // 꼬리: 늘 살랑살랑, 신나면(쫓을 때) 크게
            let wag = sin(tailT * (3 + 5 * excite)) * (4 + 6 * excite)
            extra.lineWidth = 3.2; extra.lineCapStyle = .round
            extra.move(to: NSPoint(x: -15, y: 17 + bob))
            extra.curve(to: NSPoint(x: -26, y: 24 + wag + bob),
                        controlPoint1: NSPoint(x: -21, y: 17 + bob), controlPoint2: NSPoint(x: -25, y: 19 + wag * 0.6 + bob))
            for p in [legs, extra] { outline.setStroke(); p.lineWidth += 2.4; p.stroke(); p.lineWidth -= 2.4 }
            outline.setStroke(); body.lineWidth = 2.4; body.stroke()
            fur.setFill(); body.fill()
            fur.setStroke(); legs.stroke(); extra.stroke()
            NSColor(calibratedRed: 1, green: 0.85, blue: 0.3, alpha: 1).setFill()
            eye.fill()
        case .sleep:
            // 웅크린 모습: 동그란 몸, 몸에 기댄 머리, 몸을 감싼 꼬리
            body.append(NSBezierPath(ovalIn: NSRect(x: -16, y: 0, width: 30, height: 15)))
            body.append(NSBezierPath(ovalIn: NSRect(x: 5, y: 2, width: 13, height: 11)))
            body.move(to: NSPoint(x: 7, y: 11)); body.line(to: NSPoint(x: 8.5, y: 17)); body.line(to: NSPoint(x: 11.5, y: 12.5)); body.close()
            body.move(to: NSPoint(x: 12.5, y: 12.5)); body.line(to: NSPoint(x: 16, y: 16.5)); body.line(to: NSPoint(x: 17.5, y: 9.5)); body.close()
            extra.lineWidth = 3.2; extra.lineCapStyle = .round
            extra.move(to: NSPoint(x: -15, y: 5))
            extra.curve(to: NSPoint(x: 4, y: 1.5), controlPoint1: NSPoint(x: -18, y: -1), controlPoint2: NSPoint(x: -4, y: -1))
            outline.setStroke(); body.lineWidth = 2.4; body.stroke()
            extra.lineWidth = 5.6; extra.stroke(); extra.lineWidth = 3.2
            fur.setFill(); body.fill()
            fur.setStroke(); extra.stroke()
            // 감은 눈
            let eye = NSBezierPath(); eye.lineWidth = 1; eye.lineCapStyle = .round
            eye.move(to: NSPoint(x: 12.5, y: 7)); eye.curve(to: NSPoint(x: 15.5, y: 7), controlPoint1: NSPoint(x: 13.5, y: 6), controlPoint2: NSPoint(x: 14.5, y: 6))
            NSColor(white: 0.75, alpha: 1).setStroke(); eye.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    func drawStar() {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        // 기울면 가장 낮은 끝이 바닥에 닿도록 가운데 높이를 맞춘다
        t.translateX(by: starX, yBy: starFloor + starY + Self.support(starAngle) * starScale)
        t.rotate(byDegrees: -starAngle)
        t.scale(by: starScale)          // 입에 문 별은 조금 작게 (천천히 바뀜)
        t.concat()
        let path = NSBezierPath(); path.lineCapStyle = .round
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4, len: CGFloat = i % 2 == 0 ? 11 : 8.5
            path.move(to: NSPoint(x: cos(a) * 2, y: sin(a) * 2))
            path.line(to: NSPoint(x: cos(a) * len, y: sin(a) * len))
        }
        path.lineWidth = 6; NSColor(white: 0.1, alpha: 0.85).setStroke(); path.stroke()
        path.lineWidth = 3.4; NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setStroke(); path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// 고양이나 별 하나를 그리는 작은 투명 창의 내용. 창은 그 개체를 따라 전역 좌표에서 움직인다.
/// (모니터를 가로질러도 따로 움직일 수 있게 개체마다 창이 하나씩)
final class SpriteView: NSView {
    var paint: () -> Void = {}
    var onDown: (NSPoint) -> Void = { _ in }, onDrag: (NSPoint) -> Void = { _ in }, onUp: () -> Void = {}
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let w = window else { return }
        let t = NSAffineTransform(); t.translateX(by: -w.frame.minX, yBy: -w.frame.minY); t.concat()   // 전역 → 창 안
        paint()
    }
    // 끌 때는 창이 개체를 따라 움직이므로 창 안 좌표 대신 전역 커서 위치를 쓴다
    override func mouseDown(with e: NSEvent) { onDown(NSEvent.mouseLocation) }
    override func mouseDragged(with e: NSEvent) { onDrag(NSEvent.mouseLocation) }
    override func mouseUp(with e: NSEvent) { onUp() }
}

final class DesktopStage {
    let pets = Pets()
    let catWin: NSWindow, starWin: NSWindow
    let catView = SpriteView(), starView = SpriteView()
    static let catSize = NSSize(width: 140, height: 120), starSize = NSSize(width: 70, height: 70)
    var visible = true { didSet { orderWindows() } }
    var inFront = false { didSet { applyLevel() } }

    private var jump: (from: CGFloat, to: CGFloat, t: Double)?
    private var lastBusy = false, catGrabbable = false, starGrabbable = false
    private var hop = 0.0
    private var dirty = true

    // MARK: 세계: 모니터 배열

    /// 각 모니터의 쓸 수 있는 영역(Dock·메뉴바 제외). minY가 그 모니터의 바닥. 확인용 그림에서는 가짜 배열을 쓴다.
    var simScreens: [NSRect]?
    var screens: [NSRect] { simScreens ?? NSScreen.screens.map(\.visibleFrame) }

    /// x에서 높이 y 아래로 가장 가까운 바닥(그 모니터 영역). excluding: 뚫고 떨어질 때 지금 바닥은 빼고 찾는다.
    func ground(x: CGFloat, y: CGFloat, excluding: CGFloat? = nil, cat: Bool = false, star: Bool = false) -> NSRect? {
        // 뛰는 중엔 노린 발판(또는 뛴 자리 이하)에만 내려앉는다: 줄 사이를 지나며 엉뚱한 줄에 서지 않게
        let usable = hopTarget.map { t in ledges.filter { abs($0.minY - t.y) < 0.5 || $0.minY <= hopFrom + 0.5 } } ?? ledges
        // 발판(앱 안의 글자 줄·상자·창 윗변)은 늘 바닥이다. 고양이는 별이 딛고 선 발판에도 설 수 있다.
        // 발을 헛디뎌 떨어지는 중이면 앱 요소는 무시하고 모니터 바닥까지
        let all = screens + (cat && !catTumble ? usable + (starPerch.map { [$0] } ?? []) : []) + (star && !starTumble ? starLedges : [])
        return all.filter { r in
            x >= r.minX && x <= r.maxX && r.minY <= y + 1 && (excluding.map { abs(r.minY - $0) > 0.5 } ?? true)
        }.max { $0.minY < $1.minY }
    }
    /// 바닥 높이가 floor인 모니터 중 x에 가장 가까운 것
    func screenRect(floor: CGFloat, near x: CGFloat) -> NSRect {
        let same = screens.filter { abs($0.minY - floor) < 0.5 }
        func d(_ r: NSRect) -> CGFloat { x < r.minX ? r.minX - x : x > r.maxX ? x - r.maxX : 0 }
        // 발판 위에 있으면 그 발판이 속한 모니터
        return same.min { d($0) < d($1) } ?? screens.first { $0.contains(NSPoint(x: x, y: floor + 1)) } ?? screens.first ?? .zero
    }
    /// 높이가 바뀌지 않게 지금 아래에 있는 바닥으로 갈아탄다 (더 낮은 바닥이면 공중에 뜬 셈 → 떨어진다)
    /// from: 지난 프레임의 발 높이(전역). 그 사이에 걸친 얇은 발판(글자 줄)을 한 프레임에 뚫고 지나가지 않게, 지난 높이 기준으로 바닥을 찾는다.
    func settle(x: CGFloat, floor: inout CGFloat, h: inout CGFloat, through: Bool = false, cat: Bool = false, star: Bool = false, from prev: CGFloat? = nil) {
        // 착지하는 프레임에 살짝 바닥 아래로 파고든 건 "그 바닥 위"로 본다 (안 그러면 아래 모니터로 빠져 버림)
        let now = floor + max(h, 0)
        let gy = max(now, prev ?? now)
        if let r = ground(x: x, y: gy, excluding: through ? floor : nil, cat: cat, star: star), abs(r.minY - floor) > 0.5 { h = floor + h - r.minY; floor = r.minY }
    }

    /// 고양이가 있는 모니터 (디스플레이 링크·메뉴 표시용)
    var screen: NSScreen? {
        NSScreen.screens.first { abs($0.visibleFrame.minY - pets.catFloor) < 0.5 && pets.catX >= $0.frame.minX && pets.catX <= $0.frame.maxX }
            ?? NSScreen.screens.first
    }

    /// 메뉴에서 고른 모니터 (기억해 둔다). 고르면 고양이와 별이 그 모니터로 옮겨 간다.
    var displayID = CGDirectDisplayID(UserDefaults.standard.integer(forKey: "stageDisplay")) {
        didSet {
            UserDefaults.standard.set(Int(displayID), forKey: "stageDisplay")
            if let s = NSScreen.screens.first(where: { $0.displayID == displayID }) { place(on: s.visibleFrame) }
        }
    }
    var onMove: (() -> Void)?
    private var lastScreenID: CGDirectDisplayID?

    func place(on r: NSRect) {
        let p = pets
        play = .none; jump = nil; trip = nil; p.held = false; p.hanging = false; p.dragging = false; p.draggingCat = false
        wasDragging = false; wasCatDrag = false; catVy = 0; dropping = false; dropFrom = nil
        p.catX = r.midX - 20; p.catFloor = r.minY; p.catY = 0; p.catFacing = 1; p.catMode = .sleep; p.resetPose()
        p.starX = p.catX + 38; p.starFloor = r.minY; p.starY = 0; p.starAngle = 0
        dirty = true
    }

    // MARK: 창

    init() {
        func makeWindow(_ v: SpriteView, _ size: NSSize) -> NSWindow {
            // 잡을 때도 지금 쓰는 앱의 활성 상태를 빼앗지 않도록 non-activating 패널
            let w = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            w.hidesOnDeactivate = false
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.ignoresMouseEvents = true          // 클릭은 그대로 아래로 통과 (개체 위에서만 잡을 수 있음)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]   // 전체 화면 앱 위에도
            v.wantsLayer = true
            w.contentView = v
            return w
        }
        catWin = makeWindow(catView, Self.catSize)
        starWin = makeWindow(starView, Self.starSize)
        catView.paint = { [unowned self] in pets.drawCat() }
        starView.paint = { [unowned self] in pets.drawStar() }
        for v in [catView, starView] {
            v.onDown = { [unowned self] p in mouseDown(p) }
            v.onDrag = { [unowned self] p in mouseDragged(p) }
            v.onUp = { [unowned self] in mouseUp() }
        }
        applyLevel()
        let home = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.screens.first
        place(on: home?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
        orderWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.screensChanged() }
        watchScroll()
    }

    var baseLevel: NSWindow.Level {
        inFront ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    func applyLevel() {
        // 기본: 바탕화면 아이콘 바로 위(앱 창들 아래). 선택 시: 모든 창 위.
        catWin.level = baseLevel; starWin.level = baseLevel
    }

    private func orderWindows() {
        guard !simulate else { return }
        if visible {
            catWin.orderFrontRegardless()
            starWin.order(.above, relativeTo: catWin.windowNumber)   // 별이 고양이 위에 보이게 (입에 문 모습)
        } else { catWin.orderOut(nil); starWin.orderOut(nil) }
    }

    /// 모니터를 빼거나 배열을 바꾸면, 사라진 바닥 위에 있던 개체는 남은 바닥으로 옮긴다
    private func screensChanged() {
        let p = pets
        if ground(x: p.catX, y: p.catFloor + p.catY) == nil || ground(x: p.starX, y: p.starFloor + p.starY) == nil {
            place(on: (NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.screens.first)?.visibleFrame ?? .zero)
        } else {
            settle(x: p.catX, floor: &p.catFloor, h: &p.catY); settle(x: p.starX, floor: &p.starFloor, h: &p.starY)
        }
        dirty = true
    }

    private func setGrabbable(cat: Bool, star: Bool) {
        // 닿은 개체는 잠깐 모든 창 위로 올린다 (앱 창이 화면을 덮고 있어도 잡을 수 있게)
        if cat != catGrabbable { catGrabbable = cat; catWin.ignoresMouseEvents = !cat }
        if star != starGrabbable { starGrabbable = star; starWin.ignoresMouseEvents = !star }
        let over = cat || star
        if over != grabCursor { grabCursor = over; (over ? NSCursor.openHand : NSCursor.arrow).set() }
    }
    private var grabCursor = false

    // MARK: 잡기 (전역 좌표)

    func mouseDown(_ p: NSPoint) {
        let v = pets
        v.dragLock = false
        if v.onStar(p) { v.dragging = true; v.held = false }
        else if v.onCat(p) { v.draggingCat = true; v.grabPoint = p }
        else { return }
        NSCursor.closedHand.set()
        mouseDragged(p)
    }

    func mouseDragged(_ p: NSPoint) {
        let v = pets
        if v.dragging {
            // 커서 아래 바닥 위로 (Dock 위에서 끌면 그 모니터 바닥에 붙음)
            let floor = ground(x: p.x, y: p.y - 11)?.minY
                ?? screens.first(where: { NSMouseInRect(p, $0.insetBy(dx: 0, dy: -200), false) })?.minY ?? v.starFloor
            v.starX = p.x; v.starFloor = floor; v.starY = max(p.y - 11 - floor, 0)
        } else if v.draggingCat {
            v.grabPoint = p
        } else { return }
        dirty = true
        flush()
    }

    func mouseUp() {
        let v = pets
        if v.dragLock { v.dragLock = false; return }
        v.dragging = false; v.draggingCat = false   // 놓으면 물리로 떨어진다
        NSCursor.openHand.set()
    }

    var simulate = false   // 확인용 그림 저장 중에는 창·마우스를 쓰지 않음

    // MARK: 매 프레임

    func update(busy: Bool, cpu: Double, dt: Double) {
        guard visible || simulate else { return }
        let v = pets
        v.tailT += CGFloat(dt)
        // 물었을 때 별 크기가 툭 바뀌지 않게 천천히
        let scaleTarget: CGFloat = v.held ? 0.7 : 1
        if abs(v.starScale - scaleTarget) > 0.002 { v.starScale += (scaleTarget - v.starScale) * min(1, 8 * CGFloat(dt)); dirty = true }
        if busy && !lastBusy { v.held = false }   // Claude가 새로 바빠지면 별을 놓고 다시 쫓기 시작
        lastBusy = busy
        defer { noteScreen(); flush() }
        if !simulate { checkCommand() }
        if trip != nil { setGrabbable(cat: false, star: false); stepTrip(dt); dirty = true; return }

        // 마우스가 고양이나 별에 닿으면 그 자리에서 멈춘다. 닿은 개체는 손 모양으로 잡을 수 있다.
        let m = NSEvent.mouseLocation
        let overStar = !simulate && v.onStar(m), overCat = !simulate && v.onCat(m) && !overStar
        setGrabbable(cat: (overCat || v.draggingCat) && !v.hanging && !v.dragging && play != .carry,
                     star: (overStar || v.dragging) && !v.hanging && !v.draggingCat)
        // 헛디뎌 떨어지는 상태 풀기: 잡았거나, 물고 있거나, 모니터 바닥에 멈췄으면 (계속 남으면 이후 모든 발판을 무시하게 됨)
        if v.dragging || v.held || (v.starY <= 0.5 && sv.dy == 0 && onScreenFloor(v.starFloor)) { starTumble = false }
        if v.draggingCat || (v.catY <= 0 && onScreenFloor(v.catFloor)) { catTumble = false }
        perchTick()
        // 발판 위(앱 요소 위)에 있으면 화면 바닥 전용인 평소 쫓기 대신 놀이 단계로
        let onLedges = !v.held && (!onScreenFloor(v.catFloor) || !onScreenFloor(v.starFloor))
        if v.dragging || wasDragging || v.draggingCat || wasCatDrag || v.catY > 0 || dropping || dropFrom != nil || play != .none || onLedges
            || (!v.held && !v.sameFloor) {
            stepPlay(dt); dirty = true; return
        }
        if v.held {
            // 문 별을 입 위치로 부드럽게 옮김
            let ease = min(1, 10 * CGFloat(dt))
            v.starFloor = v.catFloor
            let tx = v.catX + v.catFacing * 18, ty: CGFloat = -6
            if abs(v.starX - tx) + abs(v.starY - ty) + abs(v.starAngle - 20) > 0.05 {
                v.starX += (tx - v.starX) * ease; v.starY += (ty - v.starY) * ease; v.starAngle += (20 - v.starAngle) * ease
                dirty = true
            }
            return
        }
        if (overCat || overStar) && v.catMode == .run { return }
        v.resetPose()

        // 고양이와 별이 같은 모니터 바닥에 있을 때: 그 모니터 안에서 쫓고 도망간다
        let r = screenRect(floor: v.catFloor, near: v.catX)
        let lo = r.minX + 30, hi = r.maxX - 30
        let catSpeed = CGFloat(70 + min(cpu, 200) * 1.2)   // 픽셀/초: CPU를 많이 쓸수록 빨리 달림
        let gap = v.starX - v.catX

        if busy || v.catMode == .run || jump != nil {
            if v.catMode == .sleep { v.catMode = .run }     // 잠에서 깸
            // 고양이: 별을 향해 달린다
            let dirToStar: CGFloat = gap >= 0 ? 1 : -1
            if jump == nil { v.catFacing = dirToStar }
            v.catX += dirToStar * catSpeed * CGFloat(dt) * (abs(gap) > 38 ? 1 : 0)
            v.catPhase += catSpeed * CGFloat(dt) / 7

            if var j = jump {
                // 고양이를 뛰어넘으며 한 바퀴
                j.t += dt / 0.7
                let k = CGFloat(AppDelegate.smooth(j.t))
                v.starX = j.from + (j.to - j.from) * k
                v.starY = sin(.pi * CGFloat(min(j.t, 1))) * 46
                v.starAngle = 360 * k * (j.to > j.from ? 1 : -1)
                jump = j.t >= 1 ? nil : j
                if jump == nil { v.starY = 0; v.starAngle = 0 }
            } else if busy {
                // 별: 고양이 반대쪽으로 콩콩 뛰며 도망
                let away: CGFloat = gap >= 0 ? 1 : -1
                let d = abs(gap)
                let starSpeed = catSpeed * (d < 120 ? 1.3 : d > 260 ? 0.55 : 1.0)
                v.starX += away * starSpeed * CGFloat(dt)
                hop += dt * Double(starSpeed) / 14
                v.starY = CGFloat(abs(sin(hop))) * 7
                v.starAngle = CGFloat(sin(hop)) * 12 * away
                if v.starX < lo || v.starX > hi {
                    v.starX = min(max(v.starX, lo), hi)
                    let to = min(max(v.catX - away * 180, lo), hi)
                    jump = (v.starX, to, 0)
                }
            } else {
                // Claude가 일을 끝냄 → 별은 멈추고, 고양이가 따라잡으면 함께 쉰다
                v.starY = 0; v.starAngle = 0
                if abs(gap) <= 38 {
                    v.catMode = .sleep
                    v.catFacing = dirToStar
                }
            }
            v.catX = min(max(v.catX, lo), hi)
            dirty = true
        }
    }

    /// 확인용 원격 명령: ~/.claudethinking/cmd 에 "star x y" 를 쓰면 별을 그 자리(전역, 아래가 0)에 놓은 것처럼 한다
    private var cmdAt = 0.0
    private func checkCommand() {
        let now = CACurrentMediaTime()
        guard now - cmdAt > 0.3 else { return }
        cmdAt = now
        let path = NSHomeDirectory() + "/.claudethinking/cmd"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: path)
        let w = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard w.count >= 3, w[0] == "star", let x = Double(w[1]), let y = Double(w[2]) else { return }
        let v = pets, p = NSPoint(x: x, y: y)
        v.held = false; v.dragging = false; wasDragging = false; jump = nil
        v.starX = p.x
        v.starFloor = ground(x: p.x, y: p.y - 11)?.minY ?? v.starFloor
        v.starY = max(p.y - 11 - v.starFloor, 0)
        play = .free; sv = .zero; spin = 0; toppled = false; starTumble = false
        starRelease = CACurrentMediaTime(); if !starLedgeBusy { starLedgeAt = 0 }   // 놓은 것처럼: 아래를 바로 다시 찾음
        dirty = true
    }

    /// 고양이가 다른 모니터로 넘어가면 기억해 두고(다음 실행 때 그 모니터에서 시작), 그 모니터 주사율로 바꾼다
    private func noteScreen() {
        guard !simulate, let id = screen?.displayID, id != lastScreenID else { return }
        let first = lastScreenID == nil
        lastScreenID = id
        if !first { UserDefaults.standard.set(Int(id), forKey: "stageDisplay"); onMove?() }
    }

    // MARK: 별 놀이 (잡기 · 물리 · 고양이가 잡으러 옴)
    // - 잡으면 별이 일어서고, 끄는 방향 반대로 흔들린다.
    // - 놓으면 중력으로 떨어져 튀고, 바닥에 멈추면 쓰러진다.
    // - 고양이는 일어나 별 밑으로 달려가 점프해서 문다. 가까이 놓으면 제자리 점프만.
    // - 오래 들고 있으면(1초) 고양이가 점프로 잡으려 하고, 닿는 높이면 물고 매달린다 → 그랩이 풀리고 같이 떨어짐.
    // - 물고 바닥에 내려오면 입에 문 채로 눕는다.
    // - 별이 다른 모니터 바닥에 있으면 고양이가 그리로 간다: 아래면 바닥을 뚫고 떨어지고, 위면 뛰어오르고,
    //   옆 모니터면 가장자리에서 걸어 내려가거나 뛰어오른다.
    private enum Play { case none, free, carry, hang, reunite }
    private var play = Play.none
    private var wasDragging = false, grabTime = 0.0
    private var lastStar = NSPoint.zero, dragV = CGVector.zero
    private var sv = CGVector.zero, spin: CGFloat = 0     // 별 속도(px/s), 회전 속도(도/s)
    private var catVy: CGFloat = 0, jumpWait = 0.0, hangT = 0.0
    let gravity: CGFloat = 1500, starGravity: CGFloat = 2400, maxJump: CGFloat = 90, catchRadius: CGFloat = 16
    private var crouchT = 0.0, pendingVy: CGFloat = 0, landT = 0.0
    private var catVx: CGFloat = 0, pendingVx: CGFloat = 0
    let maxJumpX: CGFloat = 340, maxLaunchVx: CGFloat = 620     // 한 번에 옆으로 뛸 수 있는 거리, 낼 수 있는 가로 속도

    /// 착지점(전역 x, 바닥 높이 y)까지의 포물선: 높이 차와 거리에 맞춰 꼭대기 높이와 체공 시간을 정하고, 그에 맞는 가로·세로 속도.
    /// 너무 멀거나 높으면 nil (현실적인 한계: 위로 maxHop, 옆으로 maxJumpX, 가로 속도 maxLaunchVx)
    private func plannedJump(to land: NSPoint) -> (vx: CGFloat, vy: CGFloat)? {
        let v = pets, foot = v.catFloor + max(v.catY, 0)
        let dx = land.x - v.catX, dy = land.y - foot
        guard abs(dx) <= maxJumpX, dy <= maxHop, dy >= -900 else { return nil }
        let apex = max(dy, 0) + 26 + min(abs(dx) * 0.12, 36)                 // 착지점보다 조금 더 높이 솟았다가 내려앉는다
        let vy = sqrt(2 * gravity * apex)
        let t = vy / gravity + sqrt(2 * (apex - dy) / gravity)               // 꼭대기까지 + 꼭대기에서 착지 높이까지
        let vx = dx / t
        guard abs(vx) <= maxLaunchVx else { return nil }
        return (vx, vy)
    }
    private var wasCatDrag = false, lastGrab = NSPoint.zero, grabV = CGVector.zero, catSwayV: CGFloat = 0
    private var dropping = false, dropT = 0.0              // 지금 바닥을 뚫고 아래 모니터로 떨어지는 중
    private var dropFrom: CGFloat?                         // 뚫고 나온 바닥: 그 높이 아래로 내려갈 때까지 다시 딛지 않음

    // MARK: 발판: 위 모니터로 올라갈 때 밟는 창 윗변, 글자·버튼·입력창 윗변 (고양이 전용, 올라가는 동안만)
    /// 발판이 무엇의 윗변인지: 창, 또는 글자·버튼 요소(와 그 안의 몇 번째 줄). 다시 찾아 위치를 따라가는 데 쓴다.
    enum LedgeSource { case window(CGWindowID), element(AXUIElement, lineOffset: CGFloat), vision, none }
    let maxHop: CGFloat = 170
    private(set) var climbing = false
    private var ledges: [NSRect] = []                      // 높이 0인 사각형: 윗변 = minY
    private var ledgeSrcs: [LedgeSource] = []              // ledges와 같은 순서
    private var stand: (rect: NSRect, src: LedgeSource)?   // 지금 고양이가 딛고 선 발판
    private var standAt = 0.0, standBusy = false
    private var hopTarget: NSPoint?                        // 뛸 때 정한 착지점 (공중에서 바꾸지 않음)
    private var hopFrom: CGFloat = 0                        // 뛴 자리 높이
    private var ledgeDone: (floor: CGFloat, at: Double)?    // 마지막으로 다 찾아본 바닥과 시각

    /// 지금 바닥에서 발판을 다 찾아봤는지 (아직이면 크게 뛰지 말고 기다린다)
    private func ledgesReady(for floor: CGFloat) -> Bool {
        if simulate { return true }
        guard let d = ledgeDone else { return false }
        return abs(d.floor - floor) < 1 && CACurrentMediaTime() - d.at < 1
    }
    var simLedges: [NSRect]?                               // 확인용 가짜 발판
    private var ledgeAt = 0.0, ledgeBusy = false, axAsked = false
    private let ledgeQ = DispatchQueue(label: "ledges")

    /// 영역 안의 발판 찾기: 화면 인식(권한 있으면) 또는 AX + 창 윗변. done은 메인 큐에서.
    private func findLedges(in area: NSRect, done: @escaping ([(NSRect, LedgeSource)], String) -> Void) {
        if !axAsked {   // 화면 인식이 안 될 때를 위해 손쉬운 사용 권한도 (처음 한 번만 물어봄)
            axAsked = true
            if !LedgeVision.ready { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
        }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0, me = getpid()
        if LedgeVision.ready {
            LedgeVision.detect(in: area, primaryH: primaryH) { vis in
                let found = Self.collectLedges(in: area, primaryH: primaryH, me: me, useAX: vis == nil && AXIsProcessTrusted())
                    + (vis ?? []).map { ($0, LedgeSource.vision) }
                DispatchQueue.main.async { done(found, vis == nil ? "AX(인식 실패)" : "화면 인식") }
            }
            return
        }
        let ax = AXIsProcessTrusted()
        ledgeQ.async {
            let found = Self.collectLedges(in: area, primaryH: primaryH, me: me, useAX: ax)
            DispatchQueue.main.async { done(found, ax ? "AX" : "창 윗변만") }
        }
    }

    /// 고양이 주변 발판을 0.35초마다 새로 모은다. 기본은 발밑부터 한 번에 닿는 높이까지, down이면 떨어질 아래쪽.
    private func wantLedges(near p: NSPoint, down: Bool = false) {
        if simulate { let sim = simLedges ?? []; ledges = sim; ledgeSrcs = sim.map { _ in .none }; ledgeDone = (p.y, CACurrentMediaTime()); return }
        let now = CACurrentMediaTime()
        guard !ledgeBusy, now - ledgeAt > 0.35 else { return }
        ledgeBusy = true; ledgeAt = now
        let area = down ? NSRect(x: p.x - 330, y: p.y - 520, width: 660, height: 560)
                        : NSRect(x: p.x - 330, y: p.y - 40, width: 660, height: maxHop + 110)
        findLedges(in: area) { [weak self] found, how in self?.applyLedges(found, from: p, how: how) }
    }

    /// 새로 찾은 발판 반영 (메인 큐)
    private func applyLedges(_ found: [(NSRect, LedgeSource)], from p: NSPoint, how: String) {
        let t = CACurrentMediaTime()
        // 확인용: 지금 고양이가 본 발판 (방법, 개수, 한 번에 닿는 것)
        let reach = found.filter { $0.0.minY > p.y + 22 && $0.0.minY <= p.y + maxHop }.map { String(format: "%.0f", $0.0.minY) }
        try? "\(how)  위치 (\(Int(p.x)),\(Int(p.y)))  발판 \(found.count)개  한 번에 닿음: \(reach.joined(separator: ","))\n"
            .write(toFile: NSHomeDirectory() + "/.claudethinking/ledges.txt", atomically: true, encoding: .utf8)

        // 화면 인식으로 찾은 발판 위에 서 있으면: 새 장면에서 같은 줄을 찾아 따라가고, 두 번 연속 안 보이면 떨어진다
        if let st = stand, case .vision = st.src {
            let x = pets.catX
            let match = found.filter { if case .vision = $0.1 { return true } else { return false } }
                .map(\.0).filter { abs($0.minY - st.rect.minY) < 26 && x >= $0.minX - 6 && x <= $0.maxX + 6 }
                .min { abs($0.minY - st.rect.minY) < abs($1.minY - st.rect.minY) }
            if let m = match {
                visionMiss = 0
                if abs(m.minY - st.rect.minY) > 1.5 { standMoved(from: st.rect, to: NSRect(x: min(m.minX, x - 1), y: m.minY, width: max(m.maxX, x + 1) - min(m.minX, x - 1), height: 0)) }
            } else {
                visionMiss += 1
                if visionMiss >= 3 { visionMiss = 0; standMoved(from: st.rect, to: nil) }
            }
        }
        // 방금 찾은 것 + 지금 딛고 선 발판 + 뛰는 중이면 착지할 발판·뛴 자리 (오래된 발판은 남기지 않는다 → 허공을 딛지 않게)
        var keep: [(NSRect, LedgeSource)] = []
        for (i, r) in ledges.enumerated() where i < ledgeSrcs.count {
            let landing = hopTarget.map { abs(r.minY - $0.y) < 0.5 && $0.x >= r.minX && $0.x <= r.maxX } ?? false
            let takeoff = hopTarget != nil && abs(r.minY - hopFrom) < 0.5
            if (r == stand?.rect || landing || takeoff) && !found.contains(where: { $0.0 == r }) { keep.append((r, ledgeSrcs[i])) }
        }
        let all = found + keep
        let v = pets, onLedge = v.catY <= 0 && !onScreenFloor(v.catFloor)
        let had = ledges.contains { abs($0.minY - v.catFloor) < 0.5 && v.catX >= $0.minX && v.catX <= $0.maxX }
        let has = all.contains { abs($0.0.minY - v.catFloor) < 0.5 && v.catX >= $0.0.minX && v.catX <= $0.0.maxX }
        if onLedge && had && !has {
            climbLog(String(format: "목록에서 딛던 발판 빠짐: 바닥 %.1f x%.0f, stand %@, 찾은 %d개(요청 위치 %.0f)", v.catFloor, v.catX,
                            stand.map { String(format: "%.1f x%.0f~%.0f", $0.rect.minY, $0.rect.minX, $0.rect.maxX) } ?? "없음", found.count, p.y))
        }
        ledges = all.map(\.0); ledgeSrcs = all.map(\.1)
        ledgeBusy = false
        ledgeDone = (p.y, t)
    }
    private var visionMiss = 0

    func onScreenFloor(_ f: CGFloat) -> Bool { screens.contains { abs($0.minY - f) < 0.5 } }

    // MARK: 별의 발판: 놓으면 아래 앱 요소 위에 멈추고, 그 요소가 움직이면 같이, 사라지면 떨어진다
    private(set) var starLedges: [NSRect] = []
    private var starLedgeAt = 0.0, starLedgeBusy = false, starMiss = 0
    private var starLedgeDoneAt = 0.0, starRelease = 0.0      // 마지막 인식 완료 시각, 별을 놓은 시각
    /// 별이 딛고 선 발판 (모니터 바닥이면 nil)
    var starPerch: NSRect? {
        let v = pets
        guard !v.held, !onScreenFloor(v.starFloor) else { return nil }
        return starLedges.first { abs($0.minY - v.starFloor) < 0.5 && v.starX >= $0.minX - 2 && v.starX <= $0.maxX + 2 }
    }

    private func wantStarLedges() {
        let v = pets
        if simulate { starLedges = simLedges ?? []; starLedgeAt = CACurrentMediaTime(); return }
        let now = CACurrentMediaTime()
        guard !starLedgeBusy, now - starLedgeAt > 0.4 else { return }
        starLedgeBusy = true; starLedgeAt = now
        let c = v.starCenter, floor = v.starFloor
        // 공중이면 아래쪽 넓게, 발판 위면 그 둘레
        let area = v.starY > 2 ? NSRect(x: c.x - 220, y: c.y - 520, width: 440, height: 560) : NSRect(x: c.x - 220, y: floor - 120, width: 440, height: 240)
        findLedges(in: area) { [weak self] found, _ in
            guard let self else { return }
            self.starLedgeBusy = false; self.starLedgeDoneAt = CACurrentMediaTime()
            let rects = found.map(\.0)
            let v = self.pets
            self.climbLog(String(format: "별 발판 %d개 (요청 높이 %.0f, 지금 별 %.0f+%.0f, 영역 y%.0f~%.0f, 별 x에 걸리는 것: %@)", rects.count, c.y, v.starFloor, v.starY, area.minY, area.maxY,
                                 rects.filter { v.starX >= $0.minX && v.starX <= $0.maxX }.map { String(format: "%.0f", $0.minY) }.joined(separator: ",")))
            // 발판 위에 있었다면: 같은 줄(가까운 높이)을 찾아 따라가고, 두 번 연속 없으면 떨어진다
            if !v.held && !v.dragging && !self.onScreenFloor(floor) && abs(v.starFloor - floor) < 0.5 && v.starY <= 0.5 {
                if let m = rects.filter({ abs($0.minY - floor) <= 10 && v.starX >= $0.minX - 6 && v.starX <= $0.maxX + 6 })
                    .min(by: { abs($0.minY - floor) < abs($1.minY - floor) }) {   // 10px 안 흔들림은 같은 줄
                    self.starMiss = 0
                    v.starFloor = m.minY
                    self.starLedges = rects.filter { $0 != m } + [NSRect(x: min(m.minX, v.starX - 1), y: m.minY, width: max(m.maxX, v.starX + 1) - min(m.minX, v.starX - 1), height: 0)]
                    self.dirty = true
                    return
                }
                // 같은 줄이 안 보임: 스크롤 등으로 크게 움직였으면(근처에 비슷한 줄이 다른 높이로 보임) 바로, 아니면 세 번 연속 못 보면 떨어진다
                self.starMiss += 1
                if self.starMiss < 3 { return }                         // 인식이 한두 번 놓친 건 봐준다 (스크롤·창 이동은 따로 바로 감지)
                self.starLedges = rects
                self.knockStar()
                return
            }
            self.starLedges = rects
        }
    }

    /// 매 프레임: 고양이·별이 발판 위에 있거나 공중이면 주변 발판을 계속 확인한다
    private func perchTick() {
        let v = pets
        checkBases()
        // 고양이: 떨어지는 중이면 아래를, 발판 위면 둘레를 본다
        if !v.draggingCat && !v.hanging && trip == nil {
            if (v.catY > 0 && catVy <= 0) || dropFrom != nil {
                wantLedges(near: NSPoint(x: v.catX, y: v.catFloor + v.catY), down: true)
            } else if !onScreenFloor(v.catFloor) {
                wantLedges(near: NSPoint(x: v.catX, y: v.catFloor))   // 발판 위: 계속 확인 (움직이면 따라가고, 사라지면 떨어짐)
            }
            // 딛던 발판이 목록에서 사라졌으면 떨어지기 시작
            if v.catY <= 0 && !onScreenFloor(v.catFloor) && ground(x: v.catX, y: v.catFloor + 1, cat: true).map({ abs($0.minY - v.catFloor) > 0.5 }) ?? true {
                knockCat()                                                // 딛던 요소가 없어짐 → 바닥까지 떨어짐
            }
        }
        // 별을 끄는 동안: 놓았을 때 바로 앉을 수 있게 커서 아래 발판을 미리 찾아 둔다
        if v.dragging { wantStarLedges() }
        // 별: 자유롭게 떨어지는 중이거나 발판 위면
        if !v.held && !v.dragging && !v.hanging && play != .carry && trip == nil && (v.starY > 0.5 || !onScreenFloor(v.starFloor)) {
            wantStarLedges()
            if v.starY <= 0.5 && !onScreenFloor(v.starFloor) && starPerch == nil && starMiss == 0 && !starLedgeBusy && starLedgeAt > 0 {
                knockStar()                                               // 딛던 요소가 없어짐 → 바닥까지 떨어짐
            }
        }
    }

    private static var axEnabledPIDs = Set<pid_t>()
    /// 화면 좌표(위가 0)의 사각형 → 우리 좌표(아래가 0)의 윗변 발판
    static func collectLedges(in area: NSRect, primaryH: CGFloat, me: pid_t, useAX: Bool) -> [(NSRect, LedgeSource)] {
        var out: [(NSRect, LedgeSource)] = []
        func add(x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat, _ src: LedgeSource) {
            guard w >= 40, h >= 12, h < 900 else { return }
            let y = primaryH - top
            if !out.contains(where: { abs($0.0.minY - y) < 3 && abs($0.0.minX - x) < 3 }) { out.append((NSRect(x: x, y: y, width: w, height: 0), src)) }
        }
        // 1) 보이는 창들의 윗변
        for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            add(x: b["X"] ?? 0, top: b["Y"] ?? 0, w: b["Width"] ?? 0, h: b["Height"] ?? 0,
                .window(CGWindowID(w[kCGWindowNumber as String] as? Int ?? 0)))
        }
        // 2) 고양이 위쪽의 글자·버튼·입력창 (손쉬운 사용 권한이 있을 때)
        guard useAX else { return out }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        for py in stride(from: area.minY + 10, through: area.maxY, by: 34) {
            for px in stride(from: area.minX + 10, through: area.maxX, by: 52) {
                var el: AXUIElement?
                guard AXUIElementCopyElementAtPosition(sys, Float(px), Float(primaryH - py), &el) == .success, var e = el else { continue }
                var pid: pid_t = 0; AXUIElementGetPid(e, &pid)
                if pid == me { continue }
                if !axEnabledPIDs.contains(pid) {   // Electron 앱(Claude 등)은 이걸 켜야 안쪽 요소를 알려 준다
                    axEnabledPIDs.insert(pid)
                    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
                }
                for _ in 0..<2 {   // 그 요소와 바로 위 부모(문단·상자)의 윗변
                    var pv: CFTypeRef?, sv: CFTypeRef?, rv: CFTypeRef?
                    var pos = CGPoint.zero, size = CGSize.zero
                    if AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
                       AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success {
                        AXValueGetValue(pv as! AXValue, .cgPoint, &pos); AXValueGetValue(sv as! AXValue, .cgSize, &size)
                        add(x: pos.x, top: pos.y, w: size.width, h: size.height, .element(e, lineOffset: 0))
                        // 글자 덩어리(문단·터미널 글자 영역)는 줄마다 발판: 글자를 한 줄씩 밟고 올라간다
                        AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &rv)
                        let role = rv as? String ?? ""
                        if role == kAXStaticTextRole || role == kAXTextAreaRole, size.height > 30, size.width >= 40 {
                            let bandLo = primaryH - area.maxY, bandHi = primaryH - area.minY   // 화면 좌표(위가 0)
                            for lineTop in stride(from: pos.y + 18, to: pos.y + size.height - 8, by: 18) where lineTop > bandLo && lineTop < bandHi {
                                add(x: pos.x, top: lineTop, w: size.width, h: 18, .element(e, lineOffset: lineTop - pos.y))
                            }
                        }
                    }
                    var parent: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parent) == .success, let pe = parent else { break }
                    e = pe as! AXUIElement
                }
            }
        }
        return out
    }

    /// 발판이 지금 어디 있는지 다시 찾는다 (없어졌으면 nil)
    static func locate(_ src: LedgeSource, primaryH: CGFloat) -> NSRect? {
        switch src {
        case .none, .vision: return nil
        case .window(let id):
            guard let w = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
                  w[kCGWindowIsOnscreen as String] as? Bool == true, let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return NSRect(x: b["X"] ?? 0, y: primaryH - (b["Y"] ?? 0), width: b["Width"] ?? 0, height: 0)
        case .element(let e, let off):
            var pv: CFTypeRef?, sv: CFTypeRef?
            var pos = CGPoint.zero, size = CGSize.zero
            guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
                  AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
            AXValueGetValue(pv as! AXValue, .cgPoint, &pos); AXValueGetValue(sv as! AXValue, .cgSize, &size)
            guard off < size.height, size.width >= 40 else { return nil }     // 그 줄이 없어짐
            return NSRect(x: pos.x, y: primaryH - (pos.y + off), width: size.width, height: 0)
        }
    }

    /// 딛고 선 발판을 0.15초마다 다시 찾는다: 움직였으면 고양이도 같이 실려 가고, 사라졌으면 떨어진다
    private func trackStand() {
        guard let st = stand else { return }
        if case .none = st.src { return }                  // 확인용 가짜 발판은 움직이지 않음
        if case .vision = st.src { return }                // 화면 인식 발판은 새 인식 결과로 따라간다 (applyLedges)
        let now = CACurrentMediaTime()
        guard !standBusy, now - standAt > 0.15 else { return }
        standBusy = true; standAt = now
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        ledgeQ.async { [weak self] in
            let r = Self.locate(st.src, primaryH: primaryH)
            DispatchQueue.main.async { self?.standMoved(from: st.rect, to: r); self?.standBusy = false }
        }
    }

    /// 확인용 기록: ~/.claudethinking/climb.log (파일이 있을 때만)
    func climbLog(_ m: String) {
        guard !simulate else { return }
        let line = String(format: "%.2f ", CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)) + m + "\n"
        // 파일이 있을 때만 기록 (touch ~/.claudethinking/climb.log 하면 켜지고, 지우면 꺼짐)
        let path = NSHomeDirectory() + "/.claudethinking/climb.log"
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    }

    private func standMoved(from old: NSRect, to new: NSRect?) {
        guard let s = stand, s.rect == old else { return }
        let v = pets
        let onIt = abs(v.catFloor - old.minY) < 0.5 && v.catY <= 0
        let idx = ledges.firstIndex(of: old)
        // 화면 인식은 같은 줄도 몇 px씩 흔들려 잡히므로 10px까지는 그대로 서 있는 것으로 본다 (창·AX 위치는 정확: 3px)
        var tol: CGFloat = 3
        if case .vision = s.src { tol = 10 }
        if let n = new, abs(n.minY - old.minY) <= tol, abs(n.minX - old.minX) <= max(tol, 40), v.catX >= n.minX - 6, v.catX <= n.maxX + 6 {
            if n == old { return }
            if onIt { v.catFloor = n.minY }                  // 작은 흔들림: 그 줄에 붙어 있는다
            if let i = idx { ledges[i] = n } else { ledges.append(n); ledgeSrcs.append(s.src) }
            stand = (n, s.src); dirty = true
            return
        }
        // 발판이 스크롤·창 이동으로 움직였거나 사라짐 → 발을 헛디뎌 맨 아래 바닥까지 떨어진다
        climbLog(String(format: "발판 %@ %.0f (새 위치 %@)", new == nil ? "사라짐" : "움직임", old.minY,
                        new.map { String(format: "%.0f x%.0f~%.0f", $0.minY, $0.minX, $0.maxX) } ?? "없음"))
        if let i = idx { ledges.remove(at: i); ledgeSrcs.remove(at: i) }
        stand = nil
        if onIt { knockCat() }
        dirty = true
    }

    /// 고양이가 딛던 발판을 잃음: 맨 아래 바닥까지 떨어진다 (중간의 다른 앱 요소에는 걸리지 않음). 물고 있던 별도 놓친다.
    private func knockCat() {
        let v = pets
        catTumble = true; hopTarget = nil; climbing = false
        if v.catY <= 0 { v.catY = 0.1 }; catVy = min(catVy, 0)
        if v.held { v.held = false; knockStar() }
    }
    /// 별이 딛던 발판을 잃음: 맨 아래 바닥까지 떨어진다
    private func knockStar() {
        let v = pets
        starTumble = true; starMiss = 0
        if play == .none || play == .reunite { play = .free }
        sv = .zero; toppled = false
        if v.starY <= 0.5 { v.starY = 1 }
    }
    private var catTumble = false, starTumble = false
    var debugState: String { "별발판\(starLedges.count) 별헛디딤\(starTumble) 놀이\(play) 물기\(pets.held) 가로속도\(Int(catVx)) 보는쪽\(Int(pets.catFacing))" }

    // MARK: 받침 창: 고양이·별이 서 있는 앱 창. 스크롤되거나 창이 움직이면 발을 헛디뎌 떨어진다.
    private var catBase: (id: CGWindowID, frame: CGRect)?, starBase: (id: CGWindowID, frame: CGRect)?
    private var baseCheckAt = 0.0
    private var scrollMonitor: Any?

    /// (x, 받침 윗변 바로 아래) 점에 있는 맨 앞 앱 창
    static func windowUnder(_ p: NSPoint, primaryH: CGFloat, me: pid_t) -> (CGWindowID, CGRect)? {
        let q = CGPoint(x: p.x, y: primaryH - p.y)
        for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.contains(q) { return (CGWindowID(w[kCGWindowNumber as String] as? Int ?? 0), r) }
        }
        return nil
    }
    static func frameOf(_ id: CGWindowID) -> CGRect? {
        guard let w = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              w[kCGWindowIsOnscreen as String] as? Bool == true, let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    }

    /// 받침 창 기록·확인 (0.3초마다): 앱 요소 위에 막 섰으면 그 창을 기억하고, 그 창이 움직이거나 닫히면 떨어뜨린다
    private func checkBases() {
        guard !simulate else { return }
        let now = CACurrentMediaTime()
        guard now - baseCheckAt > 0.3 else { return }
        baseCheckAt = now
        let v = pets, H = NSScreen.screens.first?.frame.height ?? 0, me = getpid()
        let catOn = v.catY <= 0 && !onScreenFloor(v.catFloor) && !v.draggingCat
        let starOn = !v.held && v.starY <= 0.5 && !onScreenFloor(v.starFloor) && !v.dragging
        if catOn {
            if let b = catBase { if Self.frameOf(b.id).map({ !$0.equalTo(b.frame) }) ?? true { catBase = nil; climbLog("고양이 받침 창이 움직임/닫힘"); knockCat() } }
            else { catBase = Self.windowUnder(NSPoint(x: v.catX, y: v.catFloor - 3), primaryH: H, me: me).map { ($0.0, $0.1) } }
        } else { catBase = nil }
        if starOn {
            if let b = starBase { if Self.frameOf(b.id).map({ !$0.equalTo(b.frame) }) ?? true { starBase = nil; climbLog("별 받침 창이 움직임/닫힘"); knockStar() } }
            else { starBase = Self.windowUnder(NSPoint(x: v.starX, y: v.starFloor - 3), primaryH: H, me: me).map { ($0.0, $0.1) } }
        } else { starBase = nil }
    }

    /// 사용자가 스크롤하면: 그 창 위에 서 있던 고양이·별은 발을 헛디뎌 떨어진다 (스크롤 이벤트는 권한 없이 받을 수 있음)
    private func watchScroll() {
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, abs(e.scrollingDeltaY) + abs(e.scrollingDeltaX) > 0.5 else { return }
            let H = NSScreen.screens.first?.frame.height ?? 0, m = NSEvent.mouseLocation, q = CGPoint(x: m.x, y: H - m.y)
            if let b = self.catBase, b.frame.contains(q) { self.catBase = nil; self.climbLog("고양이 받침 창에서 스크롤"); self.knockCat() }
            if let b = self.starBase, b.frame.contains(q) { self.starBase = nil; self.climbLog("별 받침 창에서 스크롤"); self.knockStar() }
        }
    }

    /// 고양이가 지금 딛고 선 발판 (모니터 바닥이면 nil)
    private func standingLedge() -> NSRect? {
        let v = pets
        guard !screens.contains(where: { abs($0.minY - v.catFloor) < 0.5 }) else { return nil }
        return ledges.first { abs($0.minY - v.catFloor) < 0.5 && v.catX >= $0.minX && v.catX <= $0.maxX }
    }

    /// 지금 발에서 한 번에 닿는 발판 중, 목표 쪽으로 가장 높이 올라가는 것
    /// (발판 위라면 그 발판 끝에서 한 번 뛰어 옆으로 닿는 거리 안에서만)
    private func bestLedge(foot: CGFloat, column: CGFloat, below top: CGFloat) -> NSRect? {
        let x = pets.catX
        // 지금 선 줄의 어느 끝에서든 포물선 한 번(옆으로 maxJumpX)에 닿는 범위
        let cur = standingLedge(), lo = (cur?.minX ?? x) - maxJumpX, hi = (cur?.maxX ?? x) + maxJumpX
        return ledges.filter { l in
            l.minY > foot + 22 && l.minY <= foot + maxHop && l.minY < top - 10
                && l.maxX > lo && l.minX < hi && l.width >= 40
                && screens.contains { $0.contains(NSPoint(x: min(max(column, l.minX + 18), l.maxX - 18), y: l.minY + 1)) }
        }.max { a, b in
            func score(_ l: NSRect) -> CGFloat { (l.minY - foot) - 0.25 * abs(min(max(column, l.minX + 18), l.maxX - 18) - x) }
            return score(a) < score(b)
        }
    }

    private func stepPlay(_ dt: Double) {
        let v = pets, step = CGFloat(dt)

        // ---- 고양이 목덜미 잡기: 몸이 늘어져 흔들리고, 놓으면 떨어져 네 발로 착지 (어느 모니터든)
        if v.draggingCat {
            if !wasCatDrag {
                wasCatDrag = true; lastGrab = v.grabPoint; grabV = .zero
                v.catMode = .run; v.catY = 0; catVy = 0; crouchT = 0; v.catSway = 0; dropping = false; dropFrom = nil
                if v.held || play == .carry {                       // 물고 있던 별은 떨어뜨림
                    v.held = false; play = .free; sv = .zero; toppled = false
                    v.starY = max(v.starY, 0)
                }
            }
            let inst = CGVector(dx: (v.grabPoint.x - lastGrab.x) / step, dy: (v.grabPoint.y - lastGrab.y) / step)
            grabV = CGVector(dx: grabV.dx * 0.6 + inst.dx * 0.4, dy: grabV.dy * 0.6 + inst.dy * 0.4)
            lastGrab = v.grabPoint
            // 끄는 반대쪽으로 처지는 진자 + 버둥
            let target = min(max(-grabV.dx * 0.05, -45), 45) * v.catFacing + sin(v.tailT * 5) * 4
            catSwayV += ((target - v.catSway) * 140 - catSwayV * 9) * step
            v.catSway += catSwayV * step
            v.catX = v.grabPoint.x
        } else if wasCatDrag {
            wasCatDrag = false
            // 놓음: 늘어진 몸 → 가로 자세로 바꿔 그 아래 바닥으로 떨어뜨림 (엉덩이 = 잡은 곳 아래)
            v.catX = v.grabPoint.x - v.catFacing * 10
            let foot = v.grabPoint.y - 28
            v.catFloor = ground(x: v.catX, y: foot, cat: true)?.minY ?? screenRect(floor: v.catFloor, near: v.catX).minY
            v.catY = max(0.1, foot - v.catFloor)
            catVy = min(max(grabV.dy * 0.3, -300), 300)
            v.catPitch = -20; v.catSway = 0; catSwayV = 0
        }
        if !v.draggingCat { v.held = false }

        // ---- 별
        if v.dragging {
            if !wasDragging { grabTime = 0; dragV = .zero; lastStar = v.starCenter; play = .none; v.catY = max(v.catY, 0) }
            grabTime += dt
            let c = v.starCenter
            let inst = CGVector(dx: (c.x - lastStar.x) / step, dy: (c.y - lastStar.y) / step)
            dragV = CGVector(dx: dragV.dx * 0.6 + inst.dx * 0.4, dy: dragV.dy * 0.6 + inst.dy * 0.4)
            lastStar = c
            // 일어서기 + 끄는 방향 반대로 처지며 흔들림(스프링)
            let target = min(max(dragV.dx * 0.05, -40), 40)
            spin += ((target - v.starAngle) * 160 - spin * 12) * step
            v.starAngle += spin * step
        } else if wasDragging && play != .hang {
            // 놓음 → 던진 속도로 자유낙하. 묵직하게: 던진 속도의 40%만, 최대 550px/s
            play = .free
            starRelease = CACurrentMediaTime(); if !starLedgeBusy { starLedgeAt = 0 }   // 놓은 자리 아래를 바로 다시 찾는다
            sv = CGVector(dx: min(max(dragV.dx * 0.4, -550), 550), dy: min(max(dragV.dy * 0.4, -550), 550))
            spin = sv.dx * 0.6
        }
        wasDragging = v.dragging

        // 막 놓았는데 아래 발판을 아직 모르면: 인식이 끝날 때까지(최대 0.3초) 그 자리에 잠깐 떠 있는다
        let awaiting = !simulate && play == .free && CACurrentMediaTime() - starRelease < 0.3 && starLedgeDoneAt < starRelease
        if awaiting { wantStarLedges() }
        if play == .free && !awaiting {
            let grounded = v.starY <= 0 && sv.dy == 0
            if !grounded { sv.dy -= starGravity * step; v.starAngle += spin * step; sv.dx *= pow(0.45, step) }   // 공기 저항
            // 벽(모니터가 없는 곳, 더 높은 옆 모니터)에 부딪히면 튕김. 낮은 옆 모니터 쪽이면 굴러 떨어진다.
            let nx = v.starX + sv.dx * step, side: CGFloat = sv.dx >= 0 ? 12 : -12
            if ground(x: nx + side, y: v.starFloor + v.starY, star: true) == nil { sv.dx = -sv.dx * 0.5 } else { v.starX = nx }
            let prevGy = v.starFloor + max(v.starY, 0)
            v.starY += sv.dy * step
            // 내려오면서만 발판에 앉는다 (올라가는 중엔 지나침). 딛던 발판 끝을 넘으면 떨어진다.
            let starFloorGone = ground(x: v.starX, y: v.starFloor + 1, star: true).map { abs($0.minY - v.starFloor) > 0.5 } ?? true
            if sv.dy <= 0 || starFloorGone { settle(x: v.starX, floor: &v.starFloor, h: &v.starY, star: true, from: sv.dy <= 0 ? prevGy : nil) }
            if v.starY <= 0 {
                v.starY = 0
                if sv.dy < -220 { sv.dy = -sv.dy * 0.25; spin *= 0.5; sv.dx *= 0.6 }   // 둔하게 통
                else {
                    if !grounded { spin = 0; toppled = false; starTumble = false }   // 막 내려앉음
                    sv.dy = 0
                    topple(step)                                              // 쓰러짐
                }
                sv.dx *= pow(0.005, step)                                     // 바닥 마찰
            }
        }

        if play == .hang {
            // 고양이를 매단 채 떨어짐 → 고양이 발이 바닥에 닿으면 눕는다
            hangT += dt
            sv.dy -= gravity * step
            v.starY += sv.dy * step; v.starX += sv.dx * step; sv.dx *= pow(0.2, step)
            settle(x: v.starX, floor: &v.starFloor, h: &v.starY, star: true)
            v.catSway = CGFloat(sin(hangT * 7)) * 14 * CGFloat(max(0, 1 - hangT))
            if v.starY + 11 <= 44 { v.catFloor = v.starFloor; holdNow() }
            return
        }

        if v.draggingCat { return }

        // ---- 고양이
        if play == .none && !v.sameFloor && !v.held { play = .reunite }      // 다른 모니터의 별에게 가기
        if play == .reunite && v.sameFloor && v.catY <= 0 && !dropping { play = .none }
        // 별이 더 높은 바닥에 있을 때만 발판을 쓴다 (평소엔 창 위에 아무렇게나 올라서지 않게)
        // 오르는 중인지는 땅에 있을 때만 다시 정한다 (공중에서 바뀌면 발판이 사라져 떨어짐)
        let shouldClimb = (play == .reunite || play == .free) && !v.sameFloor && v.starFloor > v.catFloor && !v.draggingCat
        if shouldClimb != climbing && (v.catY <= 0 || v.draggingCat) {
            climbLog("오르기 \(shouldClimb ? "시작" : "끝") (놀이 \(play), 별 바닥 \(Int(v.starFloor)), 고양이 바닥 \(Int(v.catFloor)))")
            climbing = shouldClimb
        }
        let chasing = play == .free || play == .reunite || (v.dragging && grabTime > 1.0)
        if play == .carry || chasing || v.dragging { v.catMode = .run }
        let dxs = v.starX - v.catX
        var moved: CGFloat = 0
        let grounded = v.catY <= 0 && catVy == 0 && !dropping && dropFrom == nil

        if chasing && crouchT <= 0 {
            // 어디로 갈지: 같은 바닥이면 입이 별 밑에 오도록. 다르면 그 높이로 건너갈 착지점을 정해 포물선으로 뛴다.
            var targetX = v.starX - (dxs >= 0 ? 1 : -1) * 22        // 별이 있는 쪽에서 다가가 입이 별 밑에 오도록
            var jumpTo: NSPoint?                                  // 포물선으로 뛸 착지점 (x, 바닥 높이)
            var jumpIsHop = false                                 // 노린 발판에만 내려앉는 점프
            var bigLeap: CGFloat?                                 // 디딜 곳이 없을 때: 이 높이까지 크게 한 번
            var drop = false                                      // 지금 바닥을 뚫고 떨어지기
            if !v.sameFloor {
                let cs = screenRect(floor: v.catFloor, near: v.catX), ss = screenRect(floor: v.starFloor, near: v.starX)
                let lo = max(cs.minX, ss.minX) + 25, hi = min(cs.maxX, ss.maxX) - 25
                let below = v.starFloor < v.catFloor
                if lo <= hi {
                    let col = min(max(v.starX, lo), hi)
                    targetX = col
                    if below {
                        // 아래에 있는 별: 한 번에 닿으면 대각선으로 뛰어내리고, 아니면 그쪽으로 가서 바닥을 뚫고 떨어진다
                        let side: CGFloat = v.starX >= v.catX ? 1 : -1
                        let land = NSPoint(x: v.starX - side * 24, y: v.starFloor)
                        // 착지점 위가 지금 딛고 선 것(발판·모니터 바닥)으로 막혀 있으면 뛰어내릴 수 없다 → 그땐 뚫고 떨어진다
                        let support = standingLedge() ?? cs
                        if plannedJump(to: land) != nil && (land.x < support.minX - 4 || land.x > support.maxX + 4) { jumpTo = land }
                        else if abs(targetX - v.catX) < 6 { drop = true }
                    } else {
                        let foot = v.catFloor + v.catY, goal = v.starFloor      // 목표: 별이 딛고 선 높이
                        wantLedges(near: NSPoint(x: v.catX, y: v.catFloor))   // 공중에 있어도 딛고 선 바닥 기준으로 찾는다
                        if goal - foot <= maxHop {
                            // 별이 있는 높이(위 모니터 바닥이든 앱 요소든)까지 한 번에 닿음
                            let land = starPerch.map { min(max(col, $0.minX + 18), $0.maxX - 18) } ?? col
                            jumpTo = NSPoint(x: land, y: goal); jumpIsHop = true
                        } else if let l = bestLedge(foot: v.catFloor, column: col, below: goal) {
                            // 다음 발판 위 착지점: 목표 쪽으로, 단 지금 자리에서 한 번에 뛰어 닿는 범위 안
                            let reachLo = max(l.minX + 18, v.catX - maxJumpX), reachHi = min(l.maxX - 18, v.catX + maxJumpX)
                            let land = reachLo <= reachHi ? min(max(col, reachLo), reachHi) : min(max(col, l.minX + 18), l.maxX - 18)
                            jumpTo = NSPoint(x: land, y: l.minY); jumpIsHop = true
                        } else if ledgesReady(for: v.catFloor), abs(targetX - v.catX) < 6 {
                            bigLeap = goal                                            // 이 바닥에서 찾아봤는데 디딜 곳이 없으면 크게 한 번
                        }
                    }
                } else {
                    // 옆 모니터: 낮으면 가장자리 너머로 걸어 내려가고, 높으면 가장자리에서 대각선으로 뛰어오른다
                    let right = ss.midX > cs.midX
                    targetX = right ? cs.maxX + 30 : cs.minX - 30
                    let edge = right ? cs.maxX - 4 : cs.minX + 4
                    if !below && abs(v.catX - edge) < 8 { jumpTo = NSPoint(x: edge + (right ? 70 : -70), y: ss.minY) }
                }
            }
            // 한 번에 뛸 수 있으면 제자리에서 바로 뛰고, 너무 멀면 착지점 쪽으로 걸어간다
            if let j = jumpTo { targetX = plannedJump(to: j) == nil ? j.x : v.catX }
            // 발판(글자 줄 등) 위에서는 그 줄 끝을 넘어 걸어 나가지 않는다 → 끝에서 뛴다
            if v.catY <= 0, let cur = standingLedge() { targetX = min(max(targetX, cur.minX + 8), cur.maxX - 8) }
            let dx = targetX - v.catX
            if abs(dx) > 3 && v.catY <= 0 {                       // 걷기는 땅에서만 (공중에선 뛸 때 정한 대로 날아간다)
                let step1 = min(abs(dx), 320 * step) * (dx > 0 ? 1 : -1)
                // 바닥이 없는 곳(모니터 밖, 더 높은 옆 모니터)으로는 못 감
                if ground(x: v.catX + step1, y: v.catFloor + v.catY, cat: true) != nil {
                    moved = step1; v.catX += moved
                    v.catPhase += abs(moved) / 7
                }
            }
            jumpWait -= dt
            if grounded && jumpWait <= 0 {
                if drop {
                    dropping = true; dropT = 0; crouchT = 0.12; pendingVy = 120; pendingVx = 0   // 살짝 웅크렸다 바닥 아래로 폴짝
                    jumpWait = 0.6
                } else if let j = jumpTo, let jv = plannedJump(to: j) {
                    // 포물선 점프: 착지점까지 거리·높이에 맞춘 가로·세로 속도로 한 번에 (멀수록 웅크림도 깊게)
                    pendingVy = jv.vy; pendingVx = jv.vx
                    crouchT = 0.14 + Double(min(hypot(j.x - v.catX, j.y - v.catFloor) / 1200, 0.12)); jumpWait = 0.7
                    if abs(jv.vx) > 20 { v.catFacing = jv.vx > 0 ? 1 : -1 }
                    hopTarget = jumpIsHop ? j : nil; hopFrom = v.catFloor
                    climbLog(String(format: "뜀: (%.0f, %.0f) → (%.0f, %.0f) 가로 %.0f 세로 %.0f", v.catX, v.catFloor, j.x, j.y, jv.vx, jv.vy))
                } else if let top = bigLeap {
                    pendingVy = sqrt(2 * gravity * max(top - (v.catFloor + v.catY) + 45, 20)); pendingVx = 0
                    crouchT = 0.22; jumpWait = 0.8; hopTarget = nil; hopFrom = v.catFloor
                } else if v.sameFloor {
                    let rise = v.starY + 11 - 17                       // 별 가운데 - 서 있을 때 입 높이
                    if abs(dx) < 24 && rise > 8 {
                        pendingVy = sqrt(2 * gravity * min(rise, maxJump)); pendingVx = 0   // 닿을 높이면 딱 거기까지, 아니면 최대로
                        crouchT = 0.14                                       // 뛰기 전에 살짝 웅크림
                        jumpWait = 0.6
                    }
                }
            }
        }
        if crouchT > 0 {
            crouchT -= dt
            if crouchT <= 0 { catVy = pendingVy; catVx = pendingVx; if v.catY <= 0 { v.catY = 0.1 } }   // 도약
        }
        let wasAir = v.catY > 0
        let prevCatGy = v.catFloor + max(v.catY, 0)
        if v.catY > 0 || catVy > 0 {
            catVy -= gravity * step; v.catY += catVy * step
            // 공중: 뛸 때 받은 가로 속도 그대로 (조종 없음). 벽(모니터 없는 곳·더 높은 옆 모니터)에 부딪히면 가로 속도를 잃는다.
            if catVx != 0 {
                let nx = v.catX + catVx * step
                if ground(x: nx, y: v.catFloor + max(v.catY, 0), cat: true) != nil { v.catX = nx }   // 벽에 막힌 동안은 옆으로 못 가지만, 높이가 되면 넘어간다
            }
        } else { catVx = 0 }
        // 지금 아래 바닥으로 갈아타기 (뚫고 떨어지는 중이면 원래 바닥은 무시)
        if dropping && crouchT <= 0 && v.catY > 0 && dropFrom == nil { dropFrom = v.catFloor }
        if let from = dropFrom {
            let gy = v.catFloor + v.catY
            if let r = ground(x: v.catX, y: gy, excluding: from, cat: true), abs(r.minY - v.catFloor) > 0.5 { v.catY = gy - r.minY; v.catFloor = r.minY }
            if gy < from - 2 { dropFrom = nil }                    // 원래 바닥 아래로 빠져나옴
        } else {
            let f0 = v.catFloor, h0 = v.catY
            // 올라가는 중엔 지나치는 발판에 서지 않는다 (내려오면서만 착지) — 단, 딛던 바닥이 사라졌으면 바로 다시 찾음
            let floorGone = ground(x: v.catX, y: v.catFloor + 1, cat: true).map { abs($0.minY - v.catFloor) > 0.5 } ?? true
            if catVy <= 0 || floorGone { settle(x: v.catX, floor: &v.catFloor, h: &v.catY, cat: true, from: catVy <= 0 ? prevCatGy : nil) }
            if abs(v.catFloor - f0) > 0.5 {
                climbLog(String(format: "바닥 바뀜 %.0f→%.0f (높이 %.1f→%.1f, 속도 %.0f, 발판 %d개, 딛던 발판 %@, climbing %@)",
                                f0, v.catFloor, h0, v.catY, catVy, ledges.count,
                                ledges.contains { abs($0.minY - f0) < 0.5 && v.catX >= $0.minX && v.catX <= $0.maxX } ? "있음" : "없음",
                                climbing ? "예" : "아니오"))
            }
        }
        if dropping { dropT += dt; if dropFrom != nil || dropT > 1 { dropping = false } }
        if v.catY <= 0 && !dropping && dropFrom == nil { v.catY = 0; if catVy < 0 { catVy = 0 } }
        if wasAir && v.catY <= 0 { landT = 0.12; hopTarget = nil; catTumble = false; climbLog(String(format: "착지: 바닥 %.0f", v.catFloor)) }   // 착지 충격
        // 딛고 선 발판 기억 + 따라가기 (스크롤·창 이동에 실려 가고, 없어지면 떨어짐)
        if v.catY <= 0, !onScreenFloor(v.catFloor), let i = ledges.indices.first(where: {
            abs(ledges[$0].minY - v.catFloor) < 0.5 && v.catX >= ledges[$0].minX && v.catX <= ledges[$0].maxX }) {
            if stand?.rect != ledges[i] { stand = (ledges[i], i < ledgeSrcs.count ? ledgeSrcs[i] : .none) }
            trackStand()
        } else if v.catY > 0 || onScreenFloor(v.catFloor) { stand = nil }
        landT -= dt

        // 보는 방향: 공중이면 날아가는 쪽, 뛰기 직전이면 뛸 쪽, 걸으면 걷는 쪽, 가만히 있으면 별 쪽
        if play != .carry {
            if v.catY > 0 && abs(catVx) > 15 { v.catFacing = catVx > 0 ? 1 : -1 }
            else if crouchT > 0 && abs(pendingVx) > 15 { v.catFacing = pendingVx > 0 ? 1 : -1 }
            else if abs(moved) > 0.5 { v.catFacing = moved > 0 ? 1 : -1 }
            else if v.catY <= 0 && crouchT <= 0 && abs(dxs) > 6 { v.catFacing = dxs > 0 ? 1 : -1 }
        }
        // 몸짓: 오를 땐 머리를 들고, 떨어질 땐 앞으로 숙임. 고개는 별을 바라봄(등지고 있으면 앞을 봄). 꼬리는 신나면 크게.
        let ease = min(1, 14 * step)
        v.catAir = v.catY > 0
        let pitchTarget = v.catAir ? min(max(catVy * 0.035, -30), 40) : 0
        v.catPitch += (pitchTarget - v.catPitch) * ease
        let crouchTarget: CGFloat = crouchT > 0 ? 1 : landT > 0 ? 0.6 : 0
        v.crouch += (crouchTarget - v.crouch) * min(1, 30 * step)
        let headY = v.catFloor + v.catY + 20
        let look = atan2(v.starCenter.y - headY, max(abs(dxs), 8)) * 180 / .pi
        let facesStar = v.catFacing * dxs >= 0
        let headTarget = play == .carry || !facesStar ? 0 : min(max(look - v.catPitch, -25), 55)
        v.headUp += (headTarget - v.headUp) * ease
        v.moving += ((abs(moved) > 0.5 ? 1 : 0) - v.moving) * ease
        v.excite += ((chasing ? 1 : 0.3) - v.excite) * min(1, 4 * step)

        let f = v.catFacing, pr = v.catPitch * .pi / 180         // 몸 기울기만큼 입도 돈다 (축: 허리 높이 12)
        let mouthLocal = v.catY + 12 + 22 * sin(pr) + 5 * cos(pr)
        let mouth = NSPoint(x: v.catX + f * (22 * cos(pr) - 5 * sin(pr)), y: v.catFloor + mouthLocal)
        if play == .carry {
            v.starX = mouth.x; v.starFloor = v.catFloor; v.starY = mouthLocal - 11; v.starAngle = 20
            if v.catY <= 0 { holdNow() }
            return
        }
        guard play != .reunite, chasing, hypot(mouth.x - v.starX, mouth.y - v.starCenter.y) < catchRadius else { return }
        if v.dragging {
            // 매달림: 그랩 자동 해제
            v.dragging = false; v.dragLock = true; wasDragging = false
            NSCursor.arrow.set()
            play = .hang; v.hanging = true; hangT = 0
            sv = CGVector(dx: dragV.dx * 0.3, dy: 0); catVy = 0; v.starAngle = 0
        } else if v.catY > 0 {
            play = .carry                                        // 공중에서 물고 내려옴
        } else {
            holdNow()
        }
    }

    /// 바닥에 선 별이 가까운 쪽으로 넘어가 두 끝으로 딛고 눕는다 (넘어갈수록 빨라지고, 닿으면 살짝 되튐)
    private var toppled = false
    private func topple(_ step: CGFloat) {
        let v = pets
        guard !toppled else { return }
        var a = v.starAngle.truncatingRemainder(dividingBy: 90)            // 90도마다 같은 모양
        if a > 45 { a -= 90 } else if a < -45 { a += 90 }
        let side: CGFloat = abs(a) > 0.5 ? (a > 0 ? 1 : -1) : (sv.dx >= 0 ? 1 : -1)
        let rest = side * Pets.restTilt
        spin += side * 1400 * step                                          // 중력처럼 점점 빨리
        a += spin * step
        if (a - rest) * side >= 0 {
            a = rest
            if abs(spin) > 80 { spin = -spin * 0.3 } else { spin = 0; toppled = true }
        }
        v.starAngle = a
    }

    /// 별을 입에 문 채 눕기
    private func holdNow() {
        let v = pets
        play = .none; v.hanging = false; v.catSway = 0; dropping = false; dropFrom = nil; climbing = false; hopTarget = nil
        v.catFloor = v.starFloor
        let r = screenRect(floor: v.catFloor, near: v.starX)
        v.catX = min(max(v.starX - v.catFacing * 18, r.minX + 30), r.maxX - 30)
        v.catY = 0; catVy = 0; catVx = 0; v.catMode = .sleep
        v.held = true; v.resetPose()   // 별은 update에서 입 위치·크기로 천천히 옮겨 간다
        v.starAngle = v.starAngle.truncatingRemainder(dividingBy: 90)
    }

    // MARK: 데스크톱 이동
    // 별이 먼저 통통 튀며 굴러 화면 밖으로 → 고양이가 뒤따라 깡충 뛰는 순간 데스크톱이 바뀜(go)
    // → 새 데스크톱의 반대쪽 끝에서 별이 굴러 들어오고, 고양이가 따라와 옆에 선다. (고양이가 있는 모니터에서)
    private struct Trip { var dir: CGFloat; var t = 0.0; var arriving = false; var go: (() -> Void)?; var area: NSRect }
    private var trip: Trip?
    var traveling: Bool { trip != nil }

    func travel(dir: CGFloat, go: @escaping () -> Void) {
        guard visible || simulate, trip == nil else { go(); return }
        let v = pets
        jump = nil; v.catMode = .run; v.held = false; v.dragging = false; v.draggingCat = false
        play = .none; wasDragging = false; wasCatDrag = false; dropping = false; dropFrom = nil
        v.hanging = false; v.resetPose(); v.catY = 0; catVy = 0
        let area = screenRect(floor: v.catFloor, near: v.catX)
        v.starFloor = v.catFloor; v.starY = 0                     // 별이 다른 모니터에 있었으면 고양이 쪽으로
        if v.starX < area.minX || v.starX > area.maxX { v.starX = v.catX + 38 * dir }
        trip = Trip(dir: dir, go: go, area: area)
    }

    private func stepTrip(_ dt: Double) {
        guard var p = trip else { return }
        let v = pets, a = p.area, d = p.dir, step = CGFloat(dt), off: CGFloat = 60
        let speed = max(600, a.width / 1.4)
        p.t += dt
        func roll(to limit: CGFloat) {
            let dx = min(abs(limit - v.starX), speed * step)
            v.starX += d * dx
            v.starAngle += d * dx / 11 * 180 / .pi            // 반지름 11인 바퀴처럼 굴러감
            v.starY = dx > 0.5 ? abs(sin(CGFloat(p.t) * 10)) * 18 : 0
        }
        func run(after delay: Double, stopAt limit: CGFloat = .infinity) -> Bool {
            guard p.t > delay else { return false }
            v.catFacing = d
            v.catX += d * min(speed * 1.1 * step, limit)
            v.catPhase += speed * step / 7
            v.catY = abs(sin(CGFloat(p.t - delay) * 9)) * 16
            return true
        }
        if !p.arriving {
            roll(to: d > 0 ? a.maxX + off : a.minX - off)
            if run(after: 0.45), let go = p.go { p.go = nil; go() }   // 고양이가 뛰는 순간 데스크톱 전환
            if (d > 0 ? v.catX > a.maxX + off : v.catX < a.minX - off) || p.t > 5 {
                if let go = p.go { p.go = nil; go() }
                p.arriving = true; p.t = 0
                v.starX = d > 0 ? a.minX - off : a.maxX + off
                v.catX = v.starX - d * 20
                v.starY = 0; v.catY = 0
            }
        } else {
            let home = a.midX + d * 20
            if p.t > 0.3 { roll(to: home) }
            let starHome = abs(v.starX - home) < 0.5
            if d * (v.starX - v.catX) > 38 { _ = run(after: 0.75, stopAt: d * (v.starX - v.catX) - 38) }
            else if starHome || p.t > 5 {
                v.catY = 0; v.starY = 0
                v.starAngle = v.starAngle.truncatingRemainder(dividingBy: 90)
                trip = nil
                return
            }
        }
        trip = p
    }

    // MARK: 그리기

    private(set) var lastDraw = 0.0
    private func flush() {
        guard dirty else { return }   // 바뀐 게 없으면 다시 그리지 않음
        dirty = false; lastDraw = CACurrentMediaTime()
        guard !simulate else { return }
        // 앱 창 안의 글자를 타고 오르거나, 공중에 있거나, 잡혀 있을 땐 앱 창들 앞으로. 평소엔 바탕화면 바로 위.
        let p = pets
        let catFront = climbing || p.catY > 0 || dropFrom != nil || catGrabbable || p.draggingCat || p.hanging
        let starFront = starGrabbable || p.dragging || p.starY > 0 || p.hanging || (p.held && catFront)
        let cl: NSWindow.Level = catFront ? .floating : baseLevel, sl: NSWindow.Level = starFront || catFront && p.held ? .floating : baseLevel
        if catWin.level != cl { catWin.level = cl }
        if starWin.level != sl { starWin.level = sl; starWin.order(.above, relativeTo: catWin.windowNumber) }
        // 각 창을 개체 위치로 옮기고 다시 그린다 (창은 작아서 매 프레임 그려도 싸다)
        let c = pets.catRect(), s = pets.starRect(), cs = Self.catSize, ss = Self.starSize
        catWin.setFrameOrigin(NSPoint(x: (c.midX - cs.width / 2).rounded(), y: (c.midY - cs.height / 2).rounded()))
        starWin.setFrameOrigin(NSPoint(x: (s.midX - ss.width / 2).rounded(), y: (s.midY - ss.height / 2).rounded()))
        catView.needsDisplay = true; starView.needsDisplay = true
    }
}

/// 확인용: 가짜 모니터 배열 위의 장면 전체를 그린다
final class SceneView: NSView {
    let stage: DesktopStage
    init(stage: DesktopStage, frame: NSRect) { self.stage = stage; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        let t = NSAffineTransform(); t.translateX(by: -frame.minX, yBy: -frame.minY); t.concat()
        for r in stage.screens {   // 모니터 영역(바닥 = 아래 변)
            NSColor(white: 0.93, alpha: 1).setFill(); r.fill()
            NSColor(white: 0.6, alpha: 1).setStroke(); NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        NSColor.systemBlue.setStroke()
        for l in stage.simLedges ?? [] { let p = NSBezierPath(); p.lineWidth = 2; p.move(to: NSPoint(x: l.minX, y: l.minY)); p.line(to: NSPoint(x: l.maxX, y: l.minY)); p.stroke() }
        stage.pets.drawCat(); stage.pets.drawStar()
    }
}

/// 확인용: 바탕화면 무대를 흉내 내서 장면들을 한 장의 PNG로 저장한다.
/// 사용법: ./ClaudeThinking --stage-frames 저장할파일.png   (모니터 한 대)
///        ./ClaudeThinking --multi-frames 저장할파일.png   (모니터 두 대: 위아래, 옆으로 계단)
func exportStage(to path: String, multi: Bool) {
    _ = NSApplication.shared
    let stage = DesktopStage()
    stage.simulate = true; stage.catWin.orderOut(nil); stage.starWin.orderOut(nil)
    let v = stage.pets
    var shots: [(String, NSBitmapImageRep)] = []
    var scene = SceneView(stage: stage, frame: .zero)
    func use(_ screens: [NSRect], pad: CGFloat) {
        stage.simScreens = screens
        let u = screens.reduce(screens[0]) { $0.union($1) }
        scene = SceneView(stage: stage, frame: NSRect(x: u.minX, y: u.minY - 4, width: u.width, height: u.height + pad))
        stage.place(on: screens[0])
    }
    func shot(_ name: String) {
        guard let rep = scene.bitmapImageRepForCachingDisplay(in: scene.bounds) else { return }
        scene.cacheDisplay(in: scene.bounds, to: rep); shots.append((name, rep))
    }
    func play(_ name: String, seconds: Double, every: Int, busy: Bool = false, _ each: ((Double) -> Void)? = nil) {
        var t = 0.0
        for i in 1...max(1, Int(seconds * 24)) {
            each?(t)
            stage.update(busy: busy, cpu: 15, dt: 1 / 24); t += 1 / 24
            if i % every == 0 { shot(String(format: "%@ %.2f초", name, t)) }
            if multi && i % 6 == 0 {
                print(String(format: "%@ %.2f  고양이 x%.0f 바닥%.0f 높이%.0f  별 x%.0f 바닥%.0f 높이%.0f  %@", name, t,
                             v.catX, v.catFloor, v.catY, v.starX, v.starFloor, v.starY, stage.debugState))
            }
        }
    }
    // 실제처럼: 누르기(물고 있던 것 놓음) → 끌기 → 한 프레임 이상 지난 뒤 놓기
    func drag(to p: NSPoint) { v.dragging = true; v.held = false; stage.mouseDragged(p); stage.update(busy: false, cpu: 0, dt: 1 / 24) }
    func release() { stage.update(busy: false, cpu: 0, dt: 1 / 24); stage.mouseUp() }

    if !multi {
        use([NSRect(x: 0, y: 0, width: 1800, height: 236)], pad: 0)
        shot("쉬는 중")
        play("바쁨", seconds: 14, every: 36, busy: true)
        play("끝남", seconds: 8, every: 48)
        stage.travel(dir: 1) { shots.append(("↑ 여기서 데스크톱 전환", shots.last!.1)) }
        play("이동", seconds: 3.5, every: 6)
        // 1) 닿는 높이로 오래 들고 있기 → 점프해서 매달림 → 같이 떨어져 물고 누움
        drag(to: NSPoint(x: v.catX + 60, y: 71))
        play("닿는 높이 그랩", seconds: 3, every: 3) { t in if v.dragging { stage.mouseDragged(NSPoint(x: v.starX + (t < 0.5 ? 2 : 0), y: 71)) } }
        release()
        // 2) 못 닿는 높이로 들고 있기 → 점프 시도만 → 놓기 → 떨어져 튀고 쓰러짐 → 달려가 물기
        drag(to: NSPoint(x: v.catX + 120, y: 200))
        play("높이 그랩", seconds: 2.2, every: 6)
        release()
        play("놓음", seconds: 2.5, every: 6)
        // 3) 고양이 목덜미 잡고 들어 올려 흔들기 → 놓기 → 착지
        v.draggingCat = true; v.grabPoint = NSPoint(x: v.catX, y: 60)
        play("고양이 잡기", seconds: 1.0, every: 6) { t in v.grabPoint.y = 60 + CGFloat(min(t, 0.4)) * 200; v.grabPoint.x += t < 0.5 ? 12 : 0 }
        release()
        play("고양이 놓음", seconds: 1.5, every: 6)
    } else {
        // 위아래: 아래 = 맥북(바닥 0), 위 = 외장 모니터(바닥 520). 둘이 위 모니터에 있다가 별만 아래로 옮긴다.
        let low = NSRect(x: 0, y: 0, width: 1500, height: 490), up = NSRect(x: 250, y: 520, width: 1200, height: 300)
        use([up, low], pad: 6)
        shot("위 모니터에서 쉬는 중")
        drag(to: NSPoint(x: 700, y: 650)); play("별을 잡음", seconds: 0.3, every: 7)
        for k in 1...8 { stage.mouseDragged(NSPoint(x: 700 + CGFloat(k) * 20, y: 650 - CGFloat(k) * 60)); play("별을 아래 모니터로", seconds: 1 / 24, every: 1) }
        release()
        play("별만 아래로 옮긴 뒤", seconds: 3.2, every: 5)
        // 다시 위 모니터로 올려 두면 → 고양이가 뛰어오른다
        drag(to: NSPoint(x: 1000, y: 560))
        release()
        play("별을 위 모니터에 놓은 뒤", seconds: 3.5, every: 5)
        // 발판 타고 오르기: 아래 모니터 안에 창·글자 윗변이 있으면 한 칸씩 밟고 위 모니터로
        drag(to: NSPoint(x: 700, y: 300)); release()                 // 별을 아래로 → 고양이도 내려옴
        play("발판 준비", seconds: 3.0, every: 999)
        stage.simLedges = [NSRect(x: 450, y: 140, width: 500, height: 0), NSRect(x: 650, y: 280, width: 450, height: 0),
                           NSRect(x: 520, y: 420, width: 380, height: 0)]
        drag(to: NSPoint(x: 820, y: 560)); release()                 // 별을 위 모니터로
        play("발판 타고 오르기", seconds: 4.0, every: 3)
        stage.simLedges = nil
        // 한 화면 안: 별을 앱 요소(발판) 위에 올려 두면 고양이가 타고 올라간다 → 그 요소가 사라지면 별이 떨어진다 → 고양이를 다른 요소 위에 놓기
        use([NSRect(x: 0, y: 0, width: 1500, height: 820)], pad: 6)
        stage.simLedges = [NSRect(x: 300, y: 150, width: 500, height: 0), NSRect(x: 500, y: 300, width: 450, height: 0),
                           NSRect(x: 380, y: 450, width: 420, height: 0), NSRect(x: 600, y: 600, width: 500, height: 0)]
        drag(to: NSPoint(x: 760, y: 680)); release()
        play("별을 요소 위에", seconds: 6.5, every: 6)
        stage.simLedges = [NSRect(x: 300, y: 150, width: 500, height: 0), NSRect(x: 500, y: 300, width: 450, height: 0),
                           NSRect(x: 380, y: 450, width: 420, height: 0)]   // 별이 있던 요소가 사라짐
        play("요소가 사라짐", seconds: 3.0, every: 6)
        v.draggingCat = true; v.grabPoint = NSPoint(x: 560, y: 520)
        play("고양이 잡기", seconds: 0.3, every: 99)
        v.draggingCat = false
        play("고양이를 요소 위에 놓음", seconds: 1.5, every: 6)
        // 좌우로 엇갈린 계단: 수직으로는 못 가고 대각선으로 뛰어야 닿는 발판들
        stage.place(on: NSRect(x: 0, y: 0, width: 1500, height: 820))
        stage.simLedges = [NSRect(x: 200, y: 140, width: 160, height: 0), NSRect(x: 520, y: 270, width: 160, height: 0),
                           NSRect(x: 220, y: 400, width: 160, height: 0), NSRect(x: 540, y: 530, width: 220, height: 0)]
        drag(to: NSPoint(x: 650, y: 600)); release()
        play("엇갈린 계단", seconds: 7.0, every: 6)
        // 높은 곳에서 빠르게 떨어진 별이 얇은 줄 하나(높이 300)에 걸리는지 (한 프레임에 50px 넘게 떨어져도 뚫지 않아야 함)
        stage.simLedges = [NSRect(x: 900, y: 300, width: 300, height: 0)]
        drag(to: NSPoint(x: 1050, y: 800)); release()
        play("높은 곳에서 얇은 줄로 떨어짐", seconds: 1.5, every: 9)
        stage.simLedges = [NSRect(x: 300, y: 190, width: 500, height: 0), NSRect(x: 500, y: 340, width: 450, height: 0),
                           NSRect(x: 380, y: 490, width: 420, height: 0)]
        // 고양이·별이 서 있는 요소가 스크롤로 40px 올라감 → 같이 가지 않고 바닥까지 떨어진다
        stage.simLedges = [NSRect(x: 300, y: 190, width: 500, height: 0), NSRect(x: 500, y: 340, width: 450, height: 0),
                           NSRect(x: 380, y: 490, width: 420, height: 0)]
        play("요소가 스크롤로 움직임", seconds: 1.5, every: 6)
        stage.simLedges = nil
        // 옆으로 계단: 오른쪽 모니터 바닥이 150 높다
        let a = NSRect(x: 0, y: 0, width: 900, height: 430), b = NSRect(x: 900, y: 150, width: 900, height: 430)
        use([a, b], pad: 6)
        drag(to: NSPoint(x: 1300, y: 300)); release()
        play("별을 높은 옆 모니터에", seconds: 3.2, every: 5)
        drag(to: NSPoint(x: 400, y: 100)); release()
        play("별을 낮은 옆 모니터에", seconds: 3.2, every: 5)
    }

    // 장면들을 한 장으로: 열 수에 맞춰 줄이기
    let size = shots.reduce(NSSize.zero) { NSSize(width: max($0.width, $1.1.size.width), height: max($0.height, $1.1.size.height)) }
    let cols = multi ? 3 : 1, scale: CGFloat = multi ? 0.5 : 1
    let cw = Int(size.width * scale), ch = Int(size.height * scale) + 18
    let rows = (shots.count + cols - 1) / cols
    guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cw * cols, pixelsHigh: ch * rows, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSColor(white: 0.32, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: cw * cols, height: ch * rows).fill()
    for (i, s) in shots.enumerated() {
        let x = CGFloat((i % cols) * cw), y = CGFloat(ch * (rows - 1 - i / cols))
        s.1.draw(in: NSRect(x: x, y: y, width: s.1.size.width * scale, height: s.1.size.height * scale))
        (s.0 as NSString).draw(at: NSPoint(x: x + 6, y: y + CGFloat(ch - 16)),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
    }
    NSGraphicsContext.restoreGraphicsState()
    try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

for flag in ["--stage-frames", "--multi-frames"] {
    if let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count {
        exportStage(to: CommandLine.arguments[i + 1], multi: flag == "--multi-frames")
        exit(0)
    }
}

/// 확인용: 지금 작업 중인 에이전트와 각 앱 창이 어느 쪽 데스크톱에 있는지 출력한다.
/// 사용법: ./ClaudeThinking --check
if CommandLine.arguments.contains("--check") {
    let w = AgentWatcher()
    _ = w.poll(takeDrops: false)
    print("작업 중:", w.busyKeys)
    _ = AppDelegate.readClaude(); Thread.sleep(forTimeInterval: 1)
    let (st, cpu) = AppDelegate.readClaude()
    print("Claude 상태:", st, String(format: "CPU %.1f%%", cpu))
    let drops = (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.claudethinking/done")) ?? []
    print("훅 신호 대기:", drops)
    for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
        let d = Spaces.direction(toAppPid: a.processIdentifier)
        print(a.localizedName ?? "?", d.map { $0 > 0 ? "→ 오른쪽 데스크톱" : "← 왼쪽 데스크톱" } ?? "지금 데스크톱(또는 창 없음)")
    }
    exit(0)
}

/// 확인용: 그 자리(전역 좌표, 아래가 0) 위쪽에서 고양이가 밟을 발판을 찾아 출력한다.
/// 사용법: ./ClaudeThinking --ledges x y
if let i = CommandLine.arguments.firstIndex(of: "--ledges"), i + 2 < CommandLine.arguments.count,
   let x = Double(CommandLine.arguments[i + 1]), let y = Double(CommandLine.arguments[i + 2]) {
    _ = NSApplication.shared
    let ax = AXIsProcessTrusted()
    print("손쉬운 사용 권한:", ax)
    let ls = DesktopStage.collectLedges(in: NSRect(x: x - 330, y: y - 40, width: 660, height: 280), primaryH: NSScreen.screens[0].frame.height, me: getpid(), useAX: ax).map(\.0)
    for l in ls.sorted(by: { $0.minY < $1.minY }) {
        print(String(format: "발판 y%.0f  x%.0f~%.0f%@", l.minY, l.minX, l.maxX, l.minY > y + 22 && l.minY <= y + 170 ? "  ← 한 번에 닿음" : ""))
    }
    exit(0)
}

/// 확인용: 그 자리(전역, 아래가 0) 위쪽을 화면 인식으로 훑어 발판을 출력한다 (시간 포함)
/// 사용법: ./ClaudeThinking --vision x y
if let i = CommandLine.arguments.firstIndex(of: "--vision"), i + 2 < CommandLine.arguments.count,
   let x = Double(CommandLine.arguments[i + 1]), let y = Double(CommandLine.arguments[i + 2]) {
    _ = NSApplication.shared
    print("화면 기록 권한:", LedgeVision.ready)
    let H = NSScreen.screens[0].frame.height
    for round in 1...3 {
        let sem = DispatchSemaphore(value: 0), t0 = CACurrentMediaTime()
        LedgeVision.detect(in: NSRect(x: x - 330, y: y - 40, width: 660, height: 280), primaryH: H) { r in
            let ms = (CACurrentMediaTime() - t0) * 1000
            print(String(format: "%d회째 %.0fms, 발판 %d개", round, ms, r?.count ?? -1))
            if round == 3 { for l in (r ?? []).sorted(by: { $0.minY < $1.minY }) { print(String(format: "  발판 y%.0f  x%.0f~%.0f", l.minY, l.minX, l.maxX)) } }
            sem.signal()
        }
        sem.wait()
    }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--roller-frames"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    MenuRoller.exportFrames(to: CommandLine.arguments[i + 1])
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--frames"), i + 1 < CommandLine.arguments.count {
    AppDelegate.exportFrames(to: CommandLine.arguments[i + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
