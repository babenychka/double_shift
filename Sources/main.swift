import Cocoa
import Carbon.HIToolbox
import ApplicationServices

// ─────────── настройки: defaults write com.local.layoutfixer KEY -float N ───────────
private let ud = UserDefaults.standard
private func cfg(_ k: String, _ def: Double) -> Double {
    ud.object(forKey: k) != nil ? ud.double(forKey: k) : def
}
let axTimeoutRead = Float(cfg("axTimeoutRead", 0.15))   // таймаут AX-чтения
let axTimeoutPing = Float(cfg("axTimeoutPing", 0.10))   // таймаут keep-alive пинга
let keepAlivePeriod = cfg("keepAlive", 1.5)             // период пинга, сек
let retryDelayUS  = UInt32(cfg("retryDelayMs", 60) * 1000)
let maxRetries    = Int(cfg("retries", 2))
let delayFast     = UInt32(cfg("delayFastUs", 3500))    // µs, нативные приложения
let delaySlow     = UInt32(cfg("delaySlowUs", 9000))    // µs, Chromium/Electron
let settleUS      = UInt32(cfg("settleUs", 30000))      // пауза перед синтетикой
let typingWindow  = cfg("typingWindow", 2.5)            // сек: «только что печатал» → AX не трогаем

let slowBundles = ["chrome", "chromium", "brave", "edge", "yandex", "opera", "vivaldi",
                   "arc", "safari", "electron", "slack", "discord", "code", "notion",
                   "telegram", "spotify", "figma", "obsidian", "whatsapp", "cursor"]

// ─────────────────────────── таблица раскладок ───────────────────────────

let enChars = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,./" +
                    "~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?")
let ruChars = Array("ёйцукенгшщзхъфывапролджэячсмитьбю." +
                    "ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,")

let enToRu: [Character: Character] = Dictionary(zip(enChars, ruChars).map { ($0, $1) },
                                               uniquingKeysWith: { a, _ in a })
let ruToEn: [Character: Character] = Dictionary(zip(ruChars, enChars).map { ($0, $1) },
                                               uniquingKeysWith: { a, _ in a })
let layoutChars: Set<Character> = Set(enChars).union(ruChars)

enum Direction { case toRu, toEn }

func languages(of src: TISInputSource) -> [String] {
    guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return [] }
    return Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String] ?? []
}

func currentLayoutIsRussian() -> Bool {
    guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return false }
    return languages(of: src).first?.hasPrefix("ru") ?? false
}

func direction(of s: String) -> Direction {
    var cyr = 0, lat = 0
    for u in s.unicodeScalars {
        if (0x0400...0x04FF).contains(u.value) { cyr += 1 }
        else if (0x41...0x5A).contains(u.value) || (0x61...0x7A).contains(u.value) { lat += 1 }
    }
    if cyr > 0 || lat > 0 { return cyr >= lat ? .toEn : .toRu }
    return currentLayoutIsRussian() ? .toEn : .toRu
}

func convert(_ s: String, _ dir: Direction) -> String {
    let primary = (dir == .toEn) ? ruToEn : enToRu
    let backup  = (dir == .toEn) ? enToRu : ruToEn
    return String(s.map { primary[$0] ?? backup[$0] ?? $0 })
}

func selectLanguage(_ code: String) {
    let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return }
    for src in list where languages(of: src).first?.hasPrefix(code) == true {
        TISSelectInputSource(src); return
    }
}

// ─────────────────────────── фронтовое приложение ────────────────────────

final class Front {
    static let shared = Front()
    private let lock = NSLock()
    private var _pid: pid_t = 0
    private var _bid = ""
    private var _name = ""

    func update(_ app: NSRunningApplication?) {
        guard let a = app ?? NSWorkspace.shared.frontmostApplication else { return }
        lock.lock()
        _pid = a.processIdentifier
        _bid = (a.bundleIdentifier ?? "").lowercased()
        _name = a.localizedName ?? ""
        lock.unlock()
    }
    var pid: pid_t  { lock.lock(); defer { lock.unlock() }; return _pid }
    var bundleID: String { lock.lock(); defer { lock.unlock() }; return _bid }
    var name: String { lock.lock(); defer { lock.unlock() }; return _name }
    var isSlow: Bool { let b = bundleID + " " + name.lowercased()
                       return slowBundles.contains { b.contains($0) } }
}
func synthDelay() -> UInt32 { Front.shared.isSlow ? delaySlow : delayFast }

// ─────────────────────────── AX-хелперы ─────────────────────────────────

let attrManual  = "AXManualAccessibility"      as CFString
let attrEnhance = "AXEnhancedUserInterface"    as CFString
let attrSelMarkerRange = "AXSelectedTextMarkerRange"  as CFString
let attrStringForMarkers = "AXStringForTextMarkerRange" as CFString

func axCopy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v
}
func axElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
    guard let v = axCopy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(v, to: AXUIElement.self)
}
func axString(_ el: AXUIElement, _ attr: String) -> String? {
    guard let s = axCopy(el, attr) as? String, !s.isEmpty else { return nil }
    return s
}
func role(_ el: AXUIElement) -> String { axCopy(el, kAXRoleAttribute as String) as? String ?? "" }

func settable(_ el: AXUIElement, _ attr: String) -> Bool {
    var b = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(el, attr as CFString, &b) == .success else { return false }
    return b.boolValue
}

// ────────── AXManualAccessibility + keep-alive ──────────

final class AXWaker {
    static let shared = AXWaker()
    private let q = DispatchQueue(label: "ax.wake", qos: .utility)
    private var timer: Timer?
    private var busy = false
    private let bl = NSLock()

    func start() {
        // глобальный дефолтный таймаут для всех AX-элементов процесса
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axTimeoutRead)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        Front.shared.update(nil)
        wake()
        timer = Timer.scheduledTimer(withTimeInterval: keepAlivePeriod, repeats: true) { [weak self] _ in
            Front.shared.update(nil)
            self?.wake()
        }
        timer?.tolerance = 0.4
    }

    @objc private func activated(_ n: Notification) {
        Front.shared.update(n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        wake()
        q.asyncAfter(deadline: .now() + 0.3) { _ = self.wakeSync() }   // renderer поднимается с задержкой
    }

    /// не копим очередь пингов, если приложение тупит
    func wake() {
        bl.lock(); if busy { bl.unlock(); return }; busy = true; bl.unlock()
        q.async {
            _ = self.wakeSync()
            self.bl.lock(); self.busy = false; self.bl.unlock()
        }
    }

    @discardableResult
    func wakeSync() -> AXError {
        let pid = Front.shared.pid
        guard pid > 0, pid != getpid() else { return .success }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeoutPing)
        let err = AXUIElementSetAttributeValue(app, attrManual, kCFBooleanTrue)
        if Front.shared.isSlow {                                    // только браузерам/Electron
            _ = AXUIElementSetAttributeValue(app, attrEnhance, kCFBooleanTrue)
        }
        var v: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &v)
        return err
    }
}

// ────────── чтение выделения (три способа + спуск к AXWebArea) ──────────

func textLikeDescendants(_ root: AXUIElement, maxDepth: Int = 6, limit: Int = 4) -> [AXUIElement] {
    let wanted: Set<String> = ["AXWebArea", "AXTextArea", AXRoleTextField, "AXComboBox"]
    var found: [AXUIElement] = []
    var frontier = [root], depth = 0
    while depth < maxDepth, !frontier.isEmpty, found.count < limit {
        var next: [AXUIElement] = []
        for el in frontier {
            if wanted.contains(role(el)) { found.append(el); if found.count >= limit { break } }
            if let kids = axCopy(el, kAXChildrenAttribute as String) as? [AXUIElement] {
                next.append(contentsOf: kids.prefix(24))
            }
        }
        frontier = next; depth += 1
    }
    return found
}
let AXRoleTextField = "AXTextField"

func selectionCandidates() -> [AXUIElement] {
    var list: [AXUIElement] = []
    let sys = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(sys, axTimeoutRead)
    if let f = axElement(sys, kAXFocusedUIElementAttribute as String) { list.append(f) }

    let pid = Front.shared.pid
    if pid > 0 {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeoutRead)
        if let f = axElement(app, kAXFocusedUIElementAttribute as String) { list.append(f) }
        if let w = axElement(app, kAXFocusedWindowAttribute as String), !role(w).isEmpty {
            list.append(contentsOf: textLikeDescendants(w))          // сюда попадает AXWebArea
        }
    }
    return list
}

func selectedText(_ el: AXUIElement) -> String? {
    // 1. обычный путь (нативные приложения, <input> в некоторых сборках)
    if let s = axString(el, kAXSelectedTextAttribute as String) { return s }

    // 2. range + AXStringForRange
    if let rv = axCopy(el, kAXSelectedTextRangeAttribute as String), CFGetTypeID(rv) == AXValueGetTypeID() {
        var r = CFRange()
        if AXValueGetValue(unsafeBitCast(rv, to: AXValue.self), .cfRange, &r), r.length > 0 {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                    el, kAXStringForRangeParameterizedAttribute as CFString, rv, &out) == .success,
               let s = out as? String, !s.isEmpty { return s }
        }
    }

    // 3. text markers — единственный рабочий способ в веб-контенте Chromium/WebKit
    if let mr = axCopy(el, attrSelMarkerRange as String) {
        var out: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(el, attrStringForMarkers, mr, &out) == .success,
           let s = out as? String, !s.isEmpty { return s }
    }
    return nil
}

func readSelection(retries: Int) -> (AXUIElement, String)? {
    for attempt in 0...max(0, retries) {
        if attempt > 0 { AXWaker.shared.wakeSync(); usleep(retryDelayUS) }
        for el in selectionCandidates() {
            if let s = selectedText(el), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (el, s)
            }
        }
    }
    return nil
}

func looksEditable(_ el: AXUIElement) -> Bool {
    let r = role(el)
    if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(r) { return true }
    if settable(el, kAXSelectedTextRangeAttribute as String) { return true }
    if settable(el, kAXSelectedTextAttribute as String) { return true }
    if axCopy(el, "AXEditableAncestor") != nil { return true }
    if axCopy(el, kAXInsertionPointLineNumberAttribute as String) != nil { return true }
    return false
}

// ─────────────────────────── эмуляция клавиатуры ─────────────────────────

let myMarker: Int64 = 0x4C_46_49_58

func postKey(_ code: CGKeyCode, _ d: UInt32) {
    let src = CGEventSource(stateID: .privateState)
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
        e.flags = []
        e.setIntegerValueField(.eventSourceUserData, value: myMarker)
        e.post(tap: .cghidEventTap)
        usleep(d / 2)
    }
    usleep(d)
}

func typeString(_ s: String, _ d: UInt32) {
    let src = CGEventSource(stateID: .privateState)
    for scalar in s.unicodeScalars {
        var u = UniChar(scalar.value)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
            e.flags = []
            e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            e.setIntegerValueField(.eventSourceUserData, value: myMarker)
            e.post(tap: .cghidEventTap)
            usleep(d / 2)
        }
        usleep(d)
    }
}

// ─────────────────────────── логика ─────────────────────────────────────

final class Switcher {
    static let shared = Switcher()
    var enabled = true

    private let lock = NSLock()
    private var typed = "", prevWord = ""
    private var spaces = 0
    private var lastKeyAt: CFTimeInterval = 0
    private var lastClickAt: CFTimeInterval = 0

    private var shiftDownAt: CFTimeInterval = 0
    private var lastTapAt: CFTimeInterval = 0
    private var otherKeyUsed = false
    private let queue = DispatchQueue(label: "fix", qos: .userInitiated)
    private let tapMax = 0.30, doubleMax = 0.40

    private func resetAll() { typed = ""; prevWord = ""; spaces = 0 }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        if event.getIntegerValueField(.eventSourceUserData) == myMarker { return }

        switch type {
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard code == 56 || code == 60 else { return }
            let now = CACurrentMediaTime()
            if event.flags.contains(.maskShift) {
                shiftDownAt = now; otherKeyUsed = false
            } else {
                let wasTap = !otherKeyUsed && (now - shiftDownAt) < tapMax
                if wasTap && (now - lastTapAt) < doubleMax {
                    lastTapAt = 0
                    if enabled { queue.async { self.fix() } }
                } else {
                    lastTapAt = wasTap ? now : 0
                }
            }

        case .keyDown:
            otherKeyUsed = true
            lock.lock(); lastKeyAt = CACurrentMediaTime(); lock.unlock()
            trackTyping(event)

        case .leftMouseDown, .rightMouseDown:
            lock.lock(); lastClickAt = CACurrentMediaTime(); resetAll(); lock.unlock()
            AXWaker.shared.wake()

        case .leftMouseUp:
            AXWaker.shared.wake()          // выделение мышью закончено — греем AX заранее

        default: break
        }
    }

    private func trackTyping(_ event: CGEvent) {
        let flags = event.flags
        lock.lock(); defer { lock.unlock() }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            resetAll(); return
        }
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        case 51:
            if !typed.isEmpty { typed.removeLast() }
            else if spaces > 0 { spaces -= 1; if spaces == 0 { typed = prevWord; prevWord = "" } }
            else { prevWord = "" }
            return
        case 49:
            if !typed.isEmpty { prevWord = typed; typed = ""; spaces = 1 }
            else if !prevWord.isEmpty { spaces += 1 }
            return
        case 36, 48, 76, 53, 123, 124, 125, 126:
            resetAll(); return
        default: break
        }

        var len = 0
        var buf = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
        guard len > 0 else { return }
        let s = String(utf16CodeUnits: buf, count: len)
        guard let first = s.first else { return }

        if s.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ||
           !(first.isLetter || layoutChars.contains(first)) {
            resetAll()
        } else {
            if typed.isEmpty && spaces > 0 { prevWord = ""; spaces = 0 }
            typed += s
            if typed.count > 64 { typed.removeFirst(typed.count - 64) }
        }
    }

    // MARK: fix

    private func fix() {
        let d = synthDelay()
        let slow = Front.shared.isSlow
        let now = CACurrentMediaTime()

        lock.lock()
        let t = typed, p = prevWord, sp = spaces
        let recentTyping = (now - lastKeyAt) < typingWindow && lastClickAt < lastKeyAt
        lock.unlock()

        let haveFallback = !t.isEmpty || (!p.isEmpty && sp > 0)

        // ── 1. выделение. Если только что печатали и есть что править — AX вообще не трогаем (мгновенно)
        if !(recentTyping && !t.isEmpty) {
            if slow { AXWaker.shared.wakeSync() }
            // повторы только когда без выделения нам всё равно останется только beep
            if let (el, sel) = readSelection(retries: haveFallback ? 0 : maxRetries) {
                let dir = direction(of: sel)
                let out = convert(sel, dir)

                // Chromium возвращает .success на запись AXSelectedText и игнорирует её →
                // в «медленных» приложениях сразу печатаем поверх выделения
                if !slow, settable(el, kAXSelectedTextAttribute as String),
                   AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString,
                                                out as CFString) == .success {
                    syncLayout(dir); clear(); return
                }
                if looksEditable(el) {
                    usleep(settleUS)
                    typeString(out, d)
                    syncLayout(dir); clear(); return
                }
                // выделение есть, но поле не редактируемое — молчим, чтобы не сыпать буквы в страницу
                NSSound.beep(); return
            }
        }

        // ── 2. слово, которое набирается сейчас
        if !t.isEmpty {
            let dir = direction(of: t), out = convert(t, dir)
            usleep(settleUS)
            for _ in 0..<t.count { postKey(51, d) }
            typeString(out, d)
            lock.lock(); typed = out; lock.unlock()
            syncLayout(dir); return
        }

        // ── 3. слово перед пробелами
        if !p.isEmpty && sp > 0 {
            let dir = direction(of: p), out = convert(p, dir)
            usleep(settleUS)
            for _ in 0..<(p.count + sp) { postKey(51, d) }
            typeString(out, d)
            for _ in 0..<sp { postKey(49, d) }
            lock.lock(); prevWord = out; lock.unlock()
            syncLayout(dir); return
        }

        NSSound.beep()
    }

    private func clear() { lock.lock(); resetAll(); lock.unlock() }
    private func syncLayout(_ dir: Direction) { selectLanguage(dir == .toEn ? "en" : "ru") }
}

// ─────────────────────────── event tap ──────────────────────────────────

var tapPort: CFMachPort?

func tapCallback(proxy: CGEventTapProxy, type: CGEventType,
                 event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let p = tapPort { CGEvent.tapEnable(tap: p, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    Switcher.shared.handle(type, event)
    return Unmanaged.passUnretained(event)
}

// ─────────────────────────── приложение ─────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⇧⇧"

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Включено", action: #selector(toggle(_:)), keyEquivalent: "")
        toggle.target = self; toggle.state = .on
        menu.addItem(toggle)
        let diag = NSMenuItem(title: "Диагностика активного окна…", action: #selector(diagnose), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { print("нет прав Accessibility") }

        AXWaker.shared.start()
        startTap()
    }

    @objc func toggle(_ item: NSMenuItem) {
        Switcher.shared.enabled.toggle()
        item.state = Switcher.shared.enabled ? .on : .off
        statusItem.button?.title = Switcher.shared.enabled ? "⇧⇧" : "⇧"
    }

    /// выделяешь слово в браузере → жмёшь пункт меню → видишь, что реально отдаёт AX
    @objc func diagnose() {
        let prev = NSWorkspace.shared.frontmostApplication
        Front.shared.update(prev)
        let manual = AXWaker.shared.wakeSync()
        var r = "app: \(Front.shared.name)  [\(Front.shared.bundleID)]  pid \(Front.shared.pid)\n"
        r += "slow-профиль: \(Front.shared.isSlow ? "да" : "нет")\n"
        r += "AXManualAccessibility: \(manual == .success ? "принят" : "ошибка \(manual.rawValue)")\n\n"
        let cands = selectionCandidates()
        r += "кандидатов: \(cands.count)\n"
        for (i, el) in cands.enumerated() {
            let s = selectedText(el)
            r += "\(i). role=\(role(el).isEmpty ? "<нет ответа>" : role(el))"
            r += "  editable=\(looksEditable(el) ? "да" : "нет")"
            r += "  sel=\(s == nil ? "—" : "«\(s!.prefix(40))»")\n"
        }
        if cands.isEmpty || cands.allSatisfy({ role($0).isEmpty }) {
            r += "\nAX не отвечает: включи в браузере chrome://accessibility → "
            r += "«Native accessibility API support», либо запусти его с --force-renderer-accessibility"
        }
        let a = NSAlert()
        a.messageText = "LayoutFixer: AX-диагностика"
        a.informativeText = r
        a.runModal()
    }

    func startTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.flagsChanged.rawValue) |
                   (1 << CGEventType.leftMouseDown.rawValue) |
                   (1 << CGEventType.leftMouseUp.rawValue) |
                   (1 << CGEventType.rightMouseDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                           callback: tapCallback, userInfo: nil) else {
            print("tapCreate failed — нет Accessibility"); return
        }
        tapPort = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        print("tap started")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
