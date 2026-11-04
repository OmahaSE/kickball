import Cocoa

// Claude Code의 실제 상태
enum ClaudeState { case idle, thinking, working }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var state = ClaudeState.idle
    var cpu = 0.0
    var testMode = false
    var presence = 0.0        // 0 = 완전히 쉼, 1 = 완전히 생각 중 (부드럽게 전환)
    var clock = 0.0           // 갸웃 동작 시간
    var lastKey = ""          // 같은 그림이면 다시 그리지 않음
    let fps = 24.0
    let width: CGFloat = 24
    let label = NSMenuItem(title: "Claude Code: 대기 중", action: nil, keyEquivalent: "")
    var testItem: NSMenuItem!
    var stage: DesktopStage!
    var stageItem: NSMenuItem!, frontItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: width)
        let menu = NSMenu()
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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        render(angle: 0, spin: 0)
        stage = DesktopStage()
        RunLoop.main.add(Timer(timeInterval: 1/fps, repeats: true) { [weak self] _ in self?.tick() }, forMode: .common)
        RunLoop.main.add(Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }, forMode: .common)
        sample()
    }

    @objc func toggleStage() {
        stage.visible.toggle(); stageItem.state = stage.visible ? .on : .off
    }
    @objc func toggleFront() {
        stage.inFront.toggle(); frontItem.state = stage.inFront ? .on : .off
    }

    @objc func toggleTest() { testMode.toggle(); testItem.state = testMode ? .on : .off; updateLabel() }

    // MARK: - 상태 읽기

    func sample() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let s = Self.readTranscriptState()
            let c = Self.readCPU()
            DispatchQueue.main.async {
                guard let self else { return }
                self.state = s; self.cpu = c
                self.updateLabel()
            }
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
    static func readTranscriptState() -> ClaudeState {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return .idle }
        let now = Date()
        var best = ClaudeState.idle
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      now.timeIntervalSince(m) < 600 else { continue }   // 10분 넘게 조용하면 멈춘 것으로 본다
                let s = lastState(of: f)
                if s == .thinking { return .thinking }
                if s == .working { best = .working }
            }
        }
        return best
    }

    static func lastState(of url: URL) -> ClaudeState {
        guard let h = try? FileHandle(forReadingFrom: url) else { return .idle }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
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

    static func readCPU() -> Double {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "%cpu=,command="]
        let pipe = Pipe(); p.standardOutput = pipe
        guard (try? p.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var total = 0.0
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let sp = line.firstIndex(of: " ") else { continue }
            let cmd = line[sp...].trimmingCharacters(in: .whitespaces)
            if cmd.hasSuffix("/claude") || cmd.contains("/MacOS/claude ") || cmd.contains("claude-code/") {
                total += Double(line[..<sp]) ?? 0
            }
        }
        return total
    }

    // MARK: - 움직임

    static func smooth(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }

    func tick() {
        let s = testMode ? .thinking : state
        stage.update(busy: s != .idle, cpu: testMode ? max(cpu, 40) : cpu, dt: 1 / fps)
        let target = s == .idle ? 0.0 : 1.0
        presence += (target - presence) * 0.06
        if target == 0 && presence < 0.01 {
            presence = 0
            if lastKey != "idle" { render(angle: 0, spin: 0); lastKey = "idle" }
            clock = 0
            return   // 대기 중에는 다시 그리지 않는다
        }
        // 사람이 고민할 때처럼: 오른쪽으로 천천히 갸웃 → 머무름 → 왼쪽으로 갸웃 → 머무름
        // → 똑바로 돌아와 한 바퀴 빙글 → 잠깐 쉼. 한 주기 약 8초.
        // 작업 실행 중(CPU 사용)이면 조금 더 빨리 반복한다.
        let speed = s == .working ? 1.0 + min(cpu, 100) / 200 : 1.0
        clock += (1 / fps) * speed
        let (tilt, spin) = Self.pose(clock.truncatingRemainder(dividingBy: Self.cycle))
        let angle = tilt * 13 * presence
        let key = String(format: "%.1f|%.1f", angle, spin)
        if key == lastKey { return }
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

// MARK: - 바탕화면 무대: 고양이와 별

/// 규칙
/// - Claude가 쉬는 중: 고양이는 별 옆에서 웅크려 자고, 별은 옆에 앉아 있다. (다시 그리지 않음)
/// - Claude가 바쁨: 고양이가 깨어 별을 쫓고, 별은 도망간다. 고양이 속도 = Claude CPU 사용량.
///   별이 화면 끝에 몰리면 고양이를 뛰어넘어(한 바퀴 돌며) 반대쪽으로 도망간다.
/// - Claude가 일을 끝냄: 고양이가 별을 따라잡고, 둘이 나란히 쉰다.
/// - 마우스가 가까이 오면 둘 다 그 자리에서 멈춘다.
enum CatMode { case sleep, run }

final class StageView: NSView {
    var catX: CGFloat = 0, catFacing: CGFloat = 1, catPhase: CGFloat = 0, catMode = CatMode.sleep
    var starX: CGFloat = 0, starY: CGFloat = 0, starAngle: CGFloat = 0
    let floorY: CGFloat = 4

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        drawCat()
        drawStar()
    }

    private let outline = NSColor(white: 1, alpha: 0.9)
    private let fur = NSColor(white: 0.16, alpha: 1)

    func drawCat() {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: catX, yBy: floorY)
        t.scaleX(by: catFacing, yBy: 1)
        t.concat()
        let body = NSBezierPath(), extra = NSBezierPath()
        switch catMode {
        case .run:
            let s = sin(catPhase), c = cos(catPhase)
            let bob = abs(s) * 2.5
            // 다리 4개: 앞뒤로 엇갈리며 움직임
            let legs = NSBezierPath(); legs.lineWidth = 3.2; legs.lineCapStyle = .round
            for (hipX, off) in [(-10.0, 0.0), (-6.0, CGFloat.pi), (8.0, CGFloat.pi * 0.5), (12.0, CGFloat.pi * 1.5)] {
                let sw = sin(catPhase + off) * 5
                legs.move(to: NSPoint(x: hipX, y: 10 + bob))
                legs.line(to: NSPoint(x: hipX + sw, y: max(0, 1 + cos(catPhase + off) * 2)))
            }
            body.append(NSBezierPath(ovalIn: NSRect(x: -16, y: 8 + bob, width: 32, height: 14)))
            body.append(NSBezierPath(ovalIn: NSRect(x: 10, y: 14 + bob, width: 14, height: 13)))
            // 귀
            body.move(to: NSPoint(x: 12, y: 24 + bob)); body.line(to: NSPoint(x: 13.5, y: 31 + bob)); body.line(to: NSPoint(x: 17, y: 26 + bob)); body.close()
            body.move(to: NSPoint(x: 18, y: 26 + bob)); body.line(to: NSPoint(x: 21.5, y: 31 + bob)); body.line(to: NSPoint(x: 23, y: 23 + bob)); body.close()
            // 꼬리: 달릴 때 위아래로 흔들림
            extra.lineWidth = 3.2; extra.lineCapStyle = .round
            extra.move(to: NSPoint(x: -15, y: 17 + bob))
            extra.curve(to: NSPoint(x: -27, y: 22 + c * 5 + bob),
                        controlPoint1: NSPoint(x: -21, y: 17 + bob), controlPoint2: NSPoint(x: -25, y: 18 + c * 4 + bob))
            for p in [legs, extra] { outline.setStroke(); p.lineWidth += 2.4; p.stroke(); p.lineWidth -= 2.4 }
            outline.setStroke(); body.lineWidth = 2.4; body.stroke()
            fur.setFill(); body.fill()
            fur.setStroke(); legs.stroke(); extra.stroke()
            // 눈
            NSColor(calibratedRed: 1, green: 0.85, blue: 0.3, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 18.5, y: 20.5 + bob, width: 2.6, height: 2.6)).fill()
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
        t.translateX(by: starX, yBy: floorY + starY + 11)
        t.rotate(byDegrees: -starAngle)
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

final class DesktopStage {
    let window: NSWindow
    let view: StageView
    var visible = true { didSet { visible ? window.orderFrontRegardless() : window.orderOut(nil) } }
    var inFront = false { didSet { applyLevel() } }

    private var jump: (from: CGFloat, to: CGFloat, t: Double)?
    private var hop = 0.0
    private var dirty = true
    let height: CGFloat = 90

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true          // 클릭은 그대로 아래로 통과
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        view = StageView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = view
        applyLevel()
        layout()
        view.catX = view.bounds.width * 0.45
        view.starX = view.catX + 38
        view.catFacing = 1
        window.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layout() }
    }

    func applyLevel() {
        // 기본: 바탕화면 아이콘 바로 위(앱 창들 아래). 선택 시: 모든 창 위.
        window.level = inFront ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    func layout() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame   // Dock과 메뉴바를 뺀 영역 → 바닥은 Dock 바로 위
        window.setFrame(NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: height), display: false)
        view.frame = NSRect(origin: .zero, size: window.frame.size)
        let w = view.bounds.width
        view.catX = min(max(view.catX, 40), w - 40)
        view.starX = min(max(view.starX, 40), w - 40)
        dirty = true
    }

    var simulate = false   // 확인용 그림 저장 중에는 마우스를 무시

    func update(busy: Bool, cpu: Double, dt: Double) {
        guard visible || simulate else { return }
        let v = view, w = v.bounds.width, margin: CGFloat = 30

        // 마우스가 가까이 오면 그 자리에서 멈춘다
        let m = NSEvent.mouseLocation
        let local = NSPoint(x: m.x - window.frame.minX, y: m.y - window.frame.minY)
        let near = local.y < height + 40 && (abs(local.x - v.catX) < 90 || abs(local.x - v.starX) < 90)
        if near && !simulate && v.catMode == .run { flush(); return }

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
                if v.starX < margin || v.starX > w - margin {
                    v.starX = min(max(v.starX, margin), w - margin)
                    let to = min(max(v.catX - away * 180, margin), w - margin)
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
            v.catX = min(max(v.catX, margin), w - margin)
            dirty = true
        }
        flush()
    }

    private func flush() {
        if dirty { view.needsDisplay = true; dirty = false }   // 바뀐 게 없으면 다시 그리지 않음
    }
}

/// 확인용: 바탕화면 무대를 흉내 내서 장면들을 한 장의 PNG로 저장한다.
/// 사용법: ./ClaudeThinking --stage-frames 저장할파일.png
func exportStage(to path: String) {
    let stage = DesktopStage()
    stage.window.orderOut(nil); stage.simulate = true
    let v = stage.view
    var shots: [(String, NSBitmapImageRep)] = []
    func shot(_ name: String) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep); shots.append((name, rep))
    }
    shot("쉬는 중")
    var t = 0.0
    for i in 1...(24 * 14) {                       // 14초 동안 Claude가 바쁨
        stage.update(busy: true, cpu: 15, dt: 1 / 24); t += 1 / 24
        if i % 36 == 0 { shot(String(format: "바쁨 %.1f초", t)) }
    }
    for i in 1...(24 * 8) {                        // Claude가 일을 끝냄
        stage.update(busy: false, cpu: 0, dt: 1 / 24); t += 1 / 24
        if i % 48 == 0 { shot(String(format: "끝남 %.1f초", t)) }
    }
    let w = Int(v.bounds.width), rowH = Int(v.bounds.height) + 18
    guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: rowH * shots.count, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSColor(white: 0.32, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: rowH * shots.count).fill()
    for (i, s) in shots.enumerated() {
        let y = CGFloat(rowH * (shots.count - 1 - i))
        NSColor(white: 0.5, alpha: 1).setFill(); NSRect(x: 0, y: y, width: CGFloat(w), height: 1).fill()
        s.1.draw(in: NSRect(x: 0, y: y, width: v.bounds.width, height: v.bounds.height))
        (s.0 as NSString).draw(at: NSPoint(x: 6, y: y + v.bounds.height + 2),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
    }
    NSGraphicsContext.restoreGraphicsState()
    try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

if let i = CommandLine.arguments.firstIndex(of: "--stage-frames"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    exportStage(to: CommandLine.arguments[i + 1])
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
