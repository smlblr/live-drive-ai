// LiveDrive: the macOS side of live-drive.py (same FIFO protocol, steps and focus gate).
//
//   LiveDrive check                                   report the three TCC grants, prompt for missing ones
//   LiveDrive serve OUT_DIR --deny PID,... --parent PID
//
// Start it only through `open` (live-drive.py does): TCC charges a binary run from a terminal
// to that terminal, not to this app. Public APIs only: CGEvent, ScreenCaptureKit, AXUIElement,
// sysctl, Carbon hot keys, NSStatusItem, a listen-only event tap (user priority) and
// UserNotifications. Rationale: docs/decisions.md, live-drive-desktop.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import UserNotifications

let CACHE = NSHomeDirectory() + "/.cache"
let FIFO = CACHE + "/live-drive.fifo"
let OUT = CACHE + "/live-drive.out"
let STOP = CACHE + "/live-drive.stop"
let PAUSE = CACHE + "/live-drive.pause"

enum StepError: Error {
    case stopped(String)   // ends the session, like SystemExit in live-drive.py
    case failed(String)    // ends the batch
}

func exists(_ path: String) -> Bool { access(path, F_OK) == 0 }
func touch(_ path: String) { FileManager.default.createFile(atPath: path, contents: nil) }
func pause(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }

// The clock lets a pause, or a pause that seemed not to stop anything, be matched to what ran
// then (Linux, 2026-11-02); live-drive.py strips it again where it compares lines.
func stamp() -> String {
    var now = time(nil)
    var parts = tm()
    localtime_r(&now, &parts)
    var buffer = [Int8](repeating: 0, count: 16)
    strftime(&buffer, buffer.count, "%H:%M:%S ", &parts)
    return String(cString: buffer)
}

func log(_ line: String) {
    if let f = fopen(OUT, "a") {
        fputs(stamp() + line + "\n", f)
        fclose(f)
    }
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// ---- permissions: without them CGEvent posting does nothing and reports nothing

func permissions() -> [(String, Bool)] {
    [("Accessibility", AXIsProcessTrusted()),
     ("Accessibility (post events)", CGPreflightPostEventAccess()),
     ("Screen & System Audio Recording", CGPreflightScreenCaptureAccess())]
}

func check() -> Never {
    let perms = permissions()
    for (name, granted) in perms { print("\(name): \(granted ? "granted" : "missing")") }
    if perms.allSatisfy({ $0.1 }) {
        print("all granted")
        exit(0)
    }
    if !AXIsProcessTrusted() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
    if !CGPreflightScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
        // macOS 27.2: tccd adds the list entry only on the app's second request, so CGRequest alone
        // needed a second check. The ScreenCaptureKit query is that second request (docs/decisions.md).
        let done = DispatchSemaphore(value: 0)
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
    }
    print("missing: turn LiveDrive on in System Settings > Privacy & Security (Accessibility, "
          + "Screen & System Audio Recording), then run check again; a grant may only count after LiveDrive restarts")
    pause(1)
    exit(1)
}

// ---- process tree (no /proc on macOS)

func parentPid(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

func ancestors(_ pid: pid_t) -> Set<pid_t> {
    var seen = Set<pid_t>()
    var p = pid
    while p > 1 && seen.count < 64 {
        seen.insert(p)
        guard let next = parentPid(p) else { break }
        p = next
    }
    return seen
}

// ---- focus gate (docs/decisions.md, "Odak kapısı kodda")

struct Win: CustomStringConvertible {
    let pid: pid_t, app: String, title: String
    var description: String { "(\(pid), '\(app)', '\(title)')" }
}

let systemWide = AXUIElementCreateSystemWide()

func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

func appName(_ pid: pid_t) -> String {
    NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
}

// Two live sources, AX focus and the frontmost normal window; when they disagree both are
// candidates. NSWorkspace.frontmostApplication is not used: it only updates while the main
// run loop turns, and steps run on another thread.
func activeWindows() -> [Win] {
    var wins: [Win] = []
    if let app = axValue(systemWide, "AXFocusedApplication") {
        let element = app as! AXUIElement
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success {
            var title = ""
            if let win = axValue(element, "AXFocusedWindow"),
               let t = axValue(win as! AXUIElement, "AXTitle") as? String {
                title = t
            }
            wins.append(Win(pid: pid, app: appName(pid), title: title))
        }
    }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    if let front = list.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }),
       let owner = front[kCGWindowOwnerPID as String] as? Int,
       !wins.contains(where: { $0.pid == pid_t(owner) }) {
        wins.append(Win(pid: pid_t(owner), app: front[kCGWindowOwnerName as String] as? String ?? "?",
                        title: front[kCGWindowName as String] as? String ?? ""))
    }
    return wins
}

var allowed: Set<pid_t>? = nil   // nil = no focus: step yet
var allowAny = false
var deny = Set<pid_t>()          // the chat's processes, from --deny

// Returns the pid that keyboard events go to, nil under focus:any.
func checkFocus(_ when: String) throws -> pid_t? {
    let acts = activeWindows()
    // The chat window is never a target, not even under focus:any: launchd is this app's
    // parent, so its own ancestors cannot tell it which process the chat is.
    for w in acts where deny.contains(w.pid) {
        throw StepError.failed("focus is \(w.app) pid \(w.pid) \"\(w.title)\" \(when), which runs this chat; "
                               + "bring the test window to the front")
    }
    if allowAny { return nil }
    guard let allowed = allowed else {
        throw StepError.failed("no focus: step yet; send focus:PID of the test window first (or focus:any)")
    }
    if acts.isEmpty {
        throw StepError.failed("focus unknown \(when): no active window; "
                               + "verify with shot: and use focus:any if the app has no accessibility tree")
    }
    // Descendants of an allowed pid are fine (launchers fork), ancestors never.
    for w in acts where allowed.isDisjoint(with: ancestors(w.pid)) {
        throw StepError.failed("focus is \(w.app) pid \(w.pid) \"\(w.title)\" \(when), expected pid "
                               + allowed.sorted().map(String.init).joined(separator: ","))
    }
    return acts[0].pid
}

// ---- keyboard

let MODIFIERS: [String: (Int, CGEventFlags)] = [
    "ctrl": (kVK_Control, .maskControl), "control": (kVK_Control, .maskControl),
    "alt": (kVK_Option, .maskAlternate), "opt": (kVK_Option, .maskAlternate), "option": (kVK_Option, .maskAlternate),
    "shift": (kVK_Shift, .maskShift),
    "cmd": (kVK_Command, .maskCommand), "command": (kVK_Command, .maskCommand), "super": (kVK_Command, .maskCommand),
]
let NAMED: [String: Int] = [
    "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
    "escape": kVK_Escape, "esc": kVK_Escape, "backspace": kVK_Delete, "delete": kVK_ForwardDelete,
    "home": kVK_Home, "end": kVK_End, "pgup": kVK_PageUp, "page_up": kVK_PageUp, "prior": kVK_PageUp,
    "pgdn": kVK_PageDown, "page_down": kVK_PageDown, "next": kVK_PageDown,
    "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
    "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
    "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
]

struct Key { let code: CGKeyCode; let modifier: CGEventFlags; let extra: CGEventFlags }

// Letters sit elsewhere on the Turkish F layout than on US, so kVK_ANSI_* would press the
// wrong key: look the character up in the active layout. TIS asserts the main thread.
func layoutKey(_ ch: String) -> (CGKeyCode, Bool)? {
    if !Thread.isMainThread { return DispatchQueue.main.sync { layoutKey(ch) } }
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
    let layout = UnsafeRawPointer(CFDataGetBytePtr(data)!).assumingMemoryBound(to: UCKeyboardLayout.self)
    for shift in [false, true] {
        let state: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        for code in 0..<128 {
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), state,
                                        UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                        &dead, 4, &length, &chars)
            if status == noErr && length > 0 && String(utf16CodeUnits: chars, count: length) == ch {
                return (CGKeyCode(code), shift)
            }
        }
    }
    return nil
}

func resolve(_ name: String) throws -> Key {
    if let (code, flag) = MODIFIERS[name] { return Key(code: CGKeyCode(code), modifier: flag, extra: []) }
    if let code = NAMED[name] { return Key(code: CGKeyCode(code), modifier: [], extra: []) }
    if ["insert", "menu", "print"].contains(name) { throw StepError.failed("no \(name) key on macOS") }
    if name.count == 1, let (code, shift) = layoutKey(name) {
        return Key(code: code, modifier: [], extra: shift ? .maskShift : [])
    }
    throw StepError.failed("unknown key \(name)")
}

// One lock around every posted event and the held state, so a cleanup from the main thread
// (SIGTERM, parent gone) releases keys without a step posting after it.
let ioLock = NSLock()
let source = CGEventSource(stateID: .hidSystemState)
var heldKeys: [CGKeyCode: CGEventFlags] = [:]
var heldButtons: [CGMouseButton: CGEventType] = [:]   // button -> its up event type
// Keys go to the process the gate just passed instead of whatever is frontmost a moment
// later; --keys hid posts them through the HID tap like the pointer.
var keysToPid = true

// Flags are always set explicitly: a Shift the user holds must not leak into our events.
func heldFlags() -> CGEventFlags { heldKeys.values.reduce(CGEventFlags()) { $0.union($1) } }

func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, unicode: [UniChar]? = nil, to pid: pid_t?) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
    event.flags = flags
    if let unicode = unicode { event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
    if keysToPid, let pid = pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
    sentInput = true
}

func keyEvent(_ key: Key, down: Bool, to pid: pid_t?) {
    ioLock.lock(); defer { ioLock.unlock() }
    if down { heldKeys[key.code] = key.modifier } else { heldKeys[key.code] = nil }
    postKey(key.code, down: down, flags: heldFlags().union(key.extra), to: pid)
}

func combo(_ spec: String, to pid: pid_t?) throws {
    let keys = try spec.lowercased().split(separator: "+").map { try resolve(String($0)) }
    for key in keys { keyEvent(key, down: true, to: pid); pause(0.03) }
    for key in keys.reversed() { keyEvent(key, down: false, to: pid); pause(0.03) }
}

func unescape(_ text: String) -> [Character] {
    var out: [Character] = []
    var it = text.makeIterator()
    while let ch = it.next() {
        if ch == "\\" {
            let next = it.next()
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\\": out.append("\\")
            case nil: out.append("\\")
            case let other?: out.append("\\"); out.append(other)
            }
        } else {
            out.append(ch)
        }
    }
    return out
}

// The string travels in the event, so the layout does not matter (Mutter dropped what the
// layout lacked). An app that reads the key code instead sees virtual key 0, an "a".
func typeText(_ text: String, to pid: pid_t?) throws {
    for ch in unescape(text) {
        try gate()
        try yieldToUser()
        ioLock.lock()
        if ch == "\n" || ch == "\t" {
            let code = CGKeyCode(ch == "\n" ? kVK_Return : kVK_Tab)
            postKey(code, down: true, flags: [], to: pid)
            postKey(code, down: false, flags: [], to: pid)
        } else {
            let units = Array(String(ch).utf16)
            postKey(0, down: true, flags: [], unicode: units, to: pid)
            postKey(0, down: false, flags: [], unicode: units, to: pid)
        }
        ioLock.unlock()
        pause(0.04)
    }
}

// ---- pointer: coordinates are points from the top left of the main display, the size
// shot: logs.

let BUTTONS: [String: (CGEventType, CGEventType, CGMouseButton)] = [
    "": (.leftMouseDown, .leftMouseUp, .left), "left": (.leftMouseDown, .leftMouseUp, .left),
    "right": (.rightMouseDown, .rightMouseUp, .right), "middle": (.otherMouseDown, .otherMouseUp, .center),
]

func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left,
           clicks: Int64 = 1, delta: CGPoint? = nil) {
    ioLock.lock(); defer { ioLock.unlock() }
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                              mouseButton: button) else { return }
    event.flags = heldFlags()
    event.setIntegerValueField(.mouseEventClickState, value: clicks)
    // macOS only treats a drag as one when every dragged event carries its delta.
    if let delta = delta {
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
    }
    switch type {
    case .leftMouseDown: heldButtons[.left] = .leftMouseUp
    case .rightMouseDown: heldButtons[.right] = .rightMouseUp
    case .otherMouseDown: heldButtons[.center] = .otherMouseUp
    case .leftMouseUp, .rightMouseUp, .otherMouseUp: heldButtons[button] = nil
    default: break
    }
    event.post(tap: .cghidEventTap)
    sentInput = true
}

func click(_ arg: String, count: Int) throws {
    guard let (down, up, button) = BUTTONS[arg] else { throw StepError.failed("unknown button \(arg)") }
    let at = cursor()
    // The second pair must say click 2, or the app sees two single clicks and selects nothing.
    for n in 1...count {
        mouse(down, at: at, button: button, clicks: Int64(n))
        mouse(up, at: at, button: button, clicks: Int64(n))
        pause(0.08)
    }
}

func scroll(_ arg: String) throws {
    let parts = arg.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    let n = parts.count > 1 ? Int32(parts[1]) ?? 1 : 1
    let (vertical, horizontal): (Int32, Int32)
    switch parts[0] {
    case "down": (vertical, horizontal) = (-n, 0)    // positive wheel values scroll up / left
    case "up": (vertical, horizontal) = (n, 0)
    case "right": (vertical, horizontal) = (0, -n)
    case "left": (vertical, horizontal) = (0, n)
    default: throw StepError.failed("unknown scroll direction \(parts[0])")
    }
    ioLock.lock(); defer { ioLock.unlock() }
    guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                              wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return }
    event.location = cursor()
    event.flags = heldFlags()
    event.post(tap: .cghidEventTap)
    sentInput = true
}

func drag(_ arg: String) throws {
    let v = arg.split(separator: ",").compactMap { Double($0) }
    guard v.count == 4 else { throw StepError.failed("drag needs x1,y1,x2,y2") }
    let start = CGPoint(x: v[0], y: v[1])
    var last = start
    mouse(.mouseMoved, at: start)
    pause(0.1)
    mouse(.leftMouseDown, at: start)
    for i in 1...20 {
        try gate()
        if userActive() {
            // Pausing with the button held would drag wherever the user moves the mouse.
            pendingReason = "user"
            logTheirs()
            touch(PAUSE)
            throw StepError.failed("the user took the mouse during drag; button released, session paused; "
                                   + "redo the drag after they resume")
        }
        let p = CGPoint(x: v[0] + (v[2] - v[0]) * Double(i) / 20, y: v[1] + (v[3] - v[1]) * Double(i) / 20)
        mouse(.leftMouseDragged, at: p, delta: CGPoint(x: p.x - last.x, y: p.y - last.y))
        last = p
        pause(0.03)
    }
    pause(0.1)
    mouse(.leftMouseUp, at: last)
}

func releaseAll() {
    for (code, _) in heldKeys { postKey(code, down: false, flags: [], to: nil) }
    heldKeys.removeAll()
    for (button, up) in heldButtons {
        if let event = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: cursor(),
                               mouseButton: button) {
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }
    heldButtons.removeAll()
}

// ---- screenshot: captured at point size, so the frame is the move/drag coordinate space

var outDir = ""

func shot(_ name: String) throws {
    let path = outDir + "/" + name + ".png"
    var result: Result<CGImage, Error>?
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else { throw StepError.failed("no display") }
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
            result = .success(image)
        } catch {
            result = .failure(error)
        }
        done.signal()
    }
    if done.wait(timeout: .now() + 10) == .timedOut { throw StepError.failed("no frame captured for \(name)") }
    let image: CGImage
    switch result! {
    case .success(let i): image = i
    case .failure(let e): throw StepError.failed("no frame captured for \(name): \(e.localizedDescription)")
    }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        throw StepError.failed("cannot write \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw StepError.failed("cannot write \(path)") }
    log("shot \(path) \(image.width)x\(image.height)")
}

// ---- user priority (docs/decisions.md, live-drive-desktop: "Tek sürücü ve kullanıcı önceliği")

// Why the session waits: menu status, menu button, notice title, notice body (as on Linux).
let PAUSED: [String: (String, String, String, String)] = [
    "pause": ("Duraklatıldı", "Sürdür", "Test duraklatıldı", "Sürdürmek için ⌃⌥⇧P"),
    "start": ("Onayını bekliyor", "Başlat", "Claude ekranı sürmek istiyor",
              "Ekranı kullanıyordun. Hazır olunca başlatmak için ⌃⌥⇧P"),
    "user": ("Sen kullanıyorsun", "Sürdür", "Sen kullanıyorsun, test duraklatıldı",
             "Hazır olunca sürdürmek için ⌃⌥⇧P"),
]
var pausedReason: String? = nil   // shown by the menu bar item
var busy = false                  // a batch is running
// Claude's tests mix batches with commands of its own in the gaps; falling back to "Bekliyor"
// between batches showed "Sürüyor" for 12 % of a real Linux run (2026-11-02). Same 5 s as there.
var busyUntil = Date.distantPast
var driving: Bool { busy || Date() < busyUntil }
var pendingReason: String? = nil
var sentInput = false
let theirsLock = NSLock()
var theirs: [Double] = []         // uptime of input that was not ours, oldest first
var grace = 0.0

func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

// Linux compares Mutter's idle time with our last event. The macOS idle counter takes our
// events up to 0.5 s late and dates them up to 0.4 s early (measured 2026-11-02), so it
// cannot tell them apart; a tap can: our events carry this pid, the user's do not.
var inputTap: CFMachPort?
var sampler: DispatchSourceTimer?
var lastTheirs = 0.0              // uptime of the latest input that was not ours
var theirKinds: [(Double, String)] = []

func startInputTap() -> Bool {
    let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .scrollWheel,
                                .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                .otherMouseDown, .otherMouseUp, .otherMouseDragged]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = inputTap { CGEvent.tapEnable(tap: tap, enable: true) }
        } else if event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) {
            let t = uptime()
            let kind = [.keyDown, .keyUp, .flagsChanged].contains(type) ? "key"
                : [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) ? "move"
                : type == .scrollWheel ? "scroll" : "click"
            theirsLock.lock()
            lastTheirs = t
            // Only for the log line: a trackpad click also moves the pointer a little.
            theirKinds.append((t, kind))
            while let first = theirKinds.first, t - first.0 > 2.0 { theirKinds.removeFirst() }
            theirsLock.unlock()
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil) else { return false }
    inputTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    // Sampled every 0.1 s like Linux's idle time, not every event: counted per event, a 0.16 s
    // nudge of the mouse paused a test (measured), and Linux's thresholds assume sampling.
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: 0.1)
    timer.setEventHandler {
        let now = uptime()
        theirsLock.lock()
        if lastTheirs > grace && lastTheirs > (theirs.last ?? 0) + 0.005 { theirs.append(lastTheirs) }
        while let first = theirs.first, now - first > 2.0 { theirs.removeFirst() }
        theirsLock.unlock()
    }
    timer.resume()
    sampler = timer
    return true
}

// Driving while the user types or moves the mouse fights them for the input (user,
// 2026-11-02). One burst (a bumped mouse, one click) is not use: 3 separate 0.1 s slices in 2 s.
func userActive() -> Bool {
    let now = uptime()
    theirsLock.lock(); defer { theirsLock.unlock() }
    theirs.removeAll { now - $0 > 2.0 }
    return Set(theirs.map { Int($0 * 10) }).count >= 3
}

func logTheirs() {
    theirsLock.lock(); let t = theirs; let kinds = theirKinds; theirsLock.unlock()
    guard let first = t.first, let last = t.last else { return }
    var count: [String: Int] = [:]
    for (_, k) in kinds { count[k, default: 0] += 1 }
    let detail = count.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    log(String(format: "user input: %d events over %.2f s, last %.2f s ago (%@)",
               t.count, last - first, uptime() - last, detail))
}

// The user asked for an explicit go-ahead rather than a wait for them to stop: the session
// pauses and asks for ⌃⌥⇧P, like a pause they pressed themselves.
func yieldToUser() throws {
    if userActive() {
        pendingReason = sentInput ? "user" : "start"
        logTheirs()
        touch(PAUSE)
        try gate()
    }
}

func notify(_ title: String, _ body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: ["live-drive"])
    center.add(UNNotificationRequest(identifier: "live-drive", content: content, trigger: nil))
}

// ---- stop, pause, steps

func gate() throws {
    if exists(STOP) { throw StepError.stopped("stopped by user") }
    guard exists(PAUSE) else { return }
    let reason = pendingReason ?? "pause"
    pendingReason = nil
    log("paused (\(reason))")
    ioLock.lock(); releaseAll(); ioLock.unlock()   // a held synthetic Shift would leak into their typing
    pausedReason = reason
    notify(PAUSED[reason]!.2, PAUSED[reason]!.3)
    while exists(PAUSE) {
        pause(0.3)
        if exists(STOP) { pausedReason = nil; throw StepError.stopped("stopped by user") }
    }
    pausedReason = nil
    notify("Test sürdürüldü", "")
    log("resumed")
    // Pressing the shortcut (or the menu) is input too; do not take it for the user again.
    theirsLock.lock(); grace = uptime() + 1.0; theirs.removeAll(); theirsLock.unlock()
}

func sleepStep(_ seconds: Double) throws {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        try gate()
        pause(0.1)
    }
}

let INPUT: Set<String> = ["key", "down", "up", "type", "click", "dclick", "scroll", "drag"]

func run(_ step: String) throws {
    let kind = step.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let arg = step.count > kind.count ? String(step.dropFirst(kind.count + 1)) : ""
    var target: pid_t? = nil
    if INPUT.contains(kind) || kind == "move" { try yieldToUser() }
    if INPUT.contains(kind) { target = try checkFocus("before \(kind)") }
    switch kind {
    case "focus":
        if arg == "any" {
            allowAny = true
            allowed = nil
        } else {
            let parts = arg.split(separator: ",").map { pid_t($0) }
            guard !parts.isEmpty, !parts.contains(nil) else { throw StepError.failed("bad focus:\(arg)") }
            let pids = Set(parts.compactMap { $0 })
            if !pids.isDisjoint(with: deny) {
                throw StepError.failed("focus:\(arg) includes a process of this chat; give the PID of the test app")
            }
            allowAny = false
            allowed = pids
        }
        log("focus allowed=\(arg) active=\(activeWindows())")
    case "key": try combo(arg, to: target)
    case "down": keyEvent(try resolve(arg.lowercased()), down: true, to: target)
    case "up": keyEvent(try resolve(arg.lowercased()), down: false, to: target)
    case "type": try typeText(arg, to: target)
    case "sleep":
        guard let s = Double(arg) else { throw StepError.failed("bad sleep:\(arg)") }
        try sleepStep(s)
    case "shot": try shot(arg)
    case "move":
        let v = arg.split(separator: ",").compactMap { Double($0) }
        guard v.count == 2 else { throw StepError.failed("move needs x,y") }
        mouse(.mouseMoved, at: CGPoint(x: v[0], y: v[1]))
    case "click": try click(arg, count: 1)
    case "dclick": try click(arg, count: 2)
    case "scroll": try scroll(arg)
    case "drag": try drag(arg)
    default: throw StepError.failed("unknown step \(step)")
    }
    pause(0.05)
    // A click can focus another window; stop here instead of typing into it next.
    if ["click", "dclick", "drag"].contains(kind) {
        pause(0.15)
        _ = try checkFocus("after \(kind)")
    }
}

var cleaned = false

func cleanupAndExit(_ code: Int32) -> Never {
    ioLock.lock()   // never unlocked: no event may follow the release
    if !cleaned {
        cleaned = true
        releaseAll()
        unlink(FIFO)
        unlink(STOP)
        unlink(PAUSE)   // a pause belongs to this session; left behind, the next would start paused
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["live-drive"])
    }
    exit(code)
}

func serveLoop() {
    do {
        while true {
            try gate()
            let fd = open(FIFO, O_RDONLY | O_NONBLOCK)
            if fd < 0 { cleanupAndExit(1) }
            var buffer = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while buffer.last != 10 {
                try gate()
                let n = read(fd, &chunk, chunk.count)
                if n > 0 { buffer.append(contentsOf: chunk[0..<n]) } else { pause(0.1) }
            }
            close(fd)
            for line in String(decoding: buffer, as: UTF8.self).split(separator: "\n") {
                guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = request["id"] as? String, let steps = request["steps"] as? [String] else { continue }
                if steps == ["quit"] {
                    log("END \(id) ok")
                    cleanupAndExit(0)
                }
                var status = "ok"
                busy = true
                defer { busy = false; busyUntil = Date().addingTimeInterval(5) }
                do {
                    for step in steps {
                        try gate()
                        try run(step)
                        log("done \(step)")
                    }
                } catch StepError.stopped(let reason) {
                    log("END \(id) \(reason)")
                    cleanupAndExit(0)
                } catch StepError.failed(let reason) {
                    status = "error \(reason)"
                    ioLock.lock(); releaseAll(); ioLock.unlock()
                } catch {
                    status = "error \(error)"
                    ioLock.lock(); releaseAll(); ioLock.unlock()
                }
                log("END \(id) \(status)")
            }
        }
    } catch {
        cleanupAndExit(0)
    }
}

// ---- menu bar item and hot keys: the stop and pause controls of the GNOME indicator

final class Controller: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")

    override init() {
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        let stop = NSMenuItem(title: "Durdur  ⌃⌥⇧S", action: #selector(stopSession), keyEquivalent: "")
        stop.target = self
        pauseItem.target = self
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(stop)
        item.menu = menu
        refresh()
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // An open session that sends nothing while Claude thinks looked like it was driving, so
    // the user took a missing pause for a missed one (Linux, 2026-11-02): say which it is.
    func refresh() {
        let reason = pausedReason ?? (exists(PAUSE) ? "pause" : nil)
        let status = reason.map { PAUSED[$0]!.0 } ?? (driving ? "Sürüyor" : "Bekliyor")
        let symbol = reason != nil ? "pause.circle" : driving ? "record.circle" : "clock"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status)
        item.button?.imagePosition = .imageLeading
        item.button?.title = " LiveDrive · \(status)"
        statusLine.title = status
        pauseItem.title = (reason.map { PAUSED[$0]!.1 } ?? "Duraklat") + "  ⌃⌥⇧P"
    }

    @objc func stopSession() { touch(STOP) }

    @objc func togglePause() {
        if exists(PAUSE) { unlink(PAUSE) } else { touch(PAUSE) }
        refresh()
    }
}

var controller: Controller!

func registerHotKeys() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        if id.id == 1 { controller.stopSession() } else if id.id == 2 { controller.togglePause() }
        return noErr
    }, 1, &spec, nil, nil)
    // By character, like the GNOME bindings: on Turkish F the S and P keys are not the ANSI ones.
    for (id, ch, fallback) in [(UInt32(1), "s", kVK_ANSI_S), (UInt32(2), "p", kVK_ANSI_P)] {
        var ref: EventHotKeyRef?
        let code = layoutKey(ch).map { Int($0.0) } ?? fallback
        RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey | shiftKey),
                            EventHotKeyID(signature: OSType(0x4C44_5256), id: id),   // 'LDRV'
                            GetApplicationEventTarget(), 0, &ref)
    }
}

// ---- main

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "check" { check() }
guard args.count >= 2, args[0] == "serve" else {
    die("usage: LiveDrive check | LiveDrive serve OUT_DIR --deny PID,... --parent PID --owner ID [--keys hid]")
}
outDir = args[1]
var parent: pid_t = 0
var owner = "?"
var i = 2
while i < args.count {
    let value = i + 1 < args.count ? args[i + 1] : ""
    switch args[i] {
    case "--deny": deny = Set(value.split(separator: ",").compactMap { pid_t($0) })
    case "--parent": parent = pid_t(value) ?? 0
    case "--owner": owner = value
    case "--keys": keysToPid = value != "hid"
    default: die("unknown option \(args[i])")
    }
    i += 2
}
if parent <= 1 || kill(parent, 0) != 0 { die("--parent PID of the live-drive.py that started this is required") }
if deny.isEmpty { die("--deny is required: the chat's processes") }
if exists(STOP) { die("\(STOP) exists: a stop was requested; remove it to start a new session") }
let missing = permissions().filter { !$0.1 }.map { $0.0 }
if !missing.isEmpty { die("LiveDrive lacks: \(missing.joined(separator: ", ")); run live-drive.py check") }
// Without it the user could not take the machine back by using it.
if !startInputTap() { die("cannot watch user input (event tap refused); run live-drive.py check") }

try? FileManager.default.createDirectory(atPath: CACHE, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
unlink(FIFO)
guard mkfifo(FIFO, 0o600) == 0 else { die("mkfifo \(FIFO) failed") }
// Any process of this user that can write the FIFO drives input with this app's grants:
// make sure it is the FIFO we just made, ours and private.
var st = stat()
guard lstat(FIFO, &st) == 0, (st.st_mode & S_IFMT) == S_IFIFO, st.st_uid == getuid(), (st.st_mode & 0o077) == 0 else {
    die("\(FIFO) is not a private FIFO of this user")
}

// When live-drive.py goes (Claude ended the background task), `open -W` dies but this app
// would not; follow it, like serve ending on Linux.
let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
parentWatch.setEventHandler { cleanupAndExit(0) }
parentWatch.resume()
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { cleanupAndExit(0) }
    s.resume()
    signalSources.append(s)
}
if kill(parent, 0) != 0 { cleanupAndExit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
controller = Controller()
registerHotKeys()
UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
// live-drive.out is shared by every session; a bare READY was taken by another one (Linux,
// 2026-11-02). Name the owner: live-drive.py prints this line as serve's own output.
log("READY \(owner) serve \(parent)")
Thread { serveLoop() }.start()
app.run()
