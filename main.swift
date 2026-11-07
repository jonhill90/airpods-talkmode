// TalkMode: keeps AirPods in headset (mic) mode while enabled by holding their mic open.
import AppKit
import CoreAudio
import Carbon.HIToolbox

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/TalkMode")
let desiredFile = supportDir.appendingPathComponent("desired")      // "on" / "off"
let statusFile  = supportDir.appendingPathComponent("status.json")
let noteName = Notification.Name("io.github.jonhill90.talkmode.changed")
let matchName = "AirPods"

func readDesired() -> Bool {
    (try? String(contentsOf: desiredFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "on"
}
func writeDesired(_ on: Bool) {
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try? (on ? "on" : "off").write(to: desiredFile, atomically: true, encoding: .utf8)
}

// ---- CLI mode: TalkMode --cmd on|off|toggle ----
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--cmd"), i + 1 < args.count {
    let c = args[i + 1]
    switch c {
    case "on": writeDesired(true)
    case "off": writeDesired(false)
    case "toggle": writeDesired(!readDesired())
    default: FileHandle.standardError.write("usage: --cmd on|off|toggle\n".data(using: .utf8)!); exit(2)
    }
    DistributedNotificationCenter.default().postNotificationName(noteName, object: nil, userInfo: nil, deliverImmediately: true)
    print(readDesired() ? "on" : "off")
    exit(0)
}

// ---- CoreAudio helpers ----
func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func u32(_ id: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32 {
    var a = addr(s); var v: UInt32 = 0; var sz = UInt32(4)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v) == noErr ? v : 0
}
func str(_ id: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = addr(s); var v: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v) == noErr, let r = v else { return "" }
    return r.takeRetainedValue() as String
}
func rate(_ id: AudioObjectID) -> Double {
    var a = addr(kAudioDevicePropertyNominalSampleRate); var v: Float64 = 0; var sz = UInt32(8)
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v); return v
}
func inputChannels(_ id: AudioObjectID) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput); var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
    let p = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16); defer { p.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, p) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(p.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}
func allDevices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids); return ids
}
func findAirPodsInput() -> AudioObjectID? {
    allDevices().first { id in
        u32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBluetooth
            && str(id, kAudioObjectPropertyName).contains(matchName)
            && inputChannels(id) > 0
            && u32(id, kAudioDevicePropertyDeviceIsAlive) == 1
    }
}

// ---- Mic holder ----
final class Holder {
    private(set) var device: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    var lastError = ""
    var holding: Bool { proc != nil }

    func start(_ id: AudioObjectID) {
        stop()
        var p: AudioDeviceIOProcID?
        var st = AudioDeviceCreateIOProcIDWithBlock(&p, id, nil) { _, _, _, _, _ in /* discard */ }
        guard st == noErr, let p else { lastError = "createIOProc \(st)"; return }
        st = AudioDeviceStart(id, p)
        guard st == noErr else { AudioDeviceDestroyIOProcID(id, p); lastError = "start \(st)"; return }
        device = id; proc = p; lastError = ""
    }
    func stop() {
        if let p = proc { AudioDeviceStop(device, p); AudioDeviceDestroyIOProcID(device, p) }
        proc = nil; device = 0
    }
}

// ---- App ----
final class App: NSObject, NSApplicationDelegate {
    let holder = Holder()
    var item: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?
    var enabled = false

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reload), name: noteName, object: nil, suspensionBehavior: .deliverImmediately)
        var a = addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in self?.reconcile() }
        registerHotKey()
        // Safety net: re-check every 5 s (covers sleep/wake and silent stream deaths).
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reconcile() }
        reload()
    }
    func applicationWillTerminate(_ n: Notification) { holder.stop() }

    @objc func reload() { enabled = readDesired(); reconcile() }

    func reconcile() {
        if enabled {
            let target = findAirPodsInput()
            let alive = holder.holding && u32(holder.device, kAudioDevicePropertyDeviceIsAlive) == 1
                && u32(holder.device, kAudioDevicePropertyDeviceIsRunning) == 1
            if let t = target, !(alive && holder.device == t) { holder.start(t) }
            else if target == nil && holder.holding { holder.stop() }
        } else if holder.holding { holder.stop() }
        render()
    }

    func render() {
        let state: String
        if !enabled { state = "off" } else if holder.holding { state = "on" } else { state = "waiting" }
        let sym = state == "on" ? "mic.fill" : state == "waiting" ? "mic.slash" : "headphones"
        item.button?.image = NSImage(systemSymbolName: sym, accessibilityDescription: "Talk mode \(state)")
        item.button?.toolTip = "Talk mode: \(state)"
        let m = NSMenu()
        let dev = holder.holding ? str(holder.device, kAudioObjectPropertyName) : "—"
        m.addItem(withTitle: "Talk mode: \(state.uppercased())", action: nil, keyEquivalent: "")
        m.addItem(withTitle: "Mic held: \(dev)", action: nil, keyEquivalent: "")
        if !holder.lastError.isEmpty { m.addItem(withTitle: "Error: \(holder.lastError)", action: nil, keyEquivalent: "") }
        m.addItem(.separator())
        let t = NSMenuItem(title: enabled ? "Turn off (⌃⌥⌘T)" : "Turn on (⌃⌥⌘T)", action: #selector(toggle), keyEquivalent: "")
        t.target = self; m.addItem(t)
        let q = NSMenuItem(title: "Quit TalkMode", action: #selector(quit), keyEquivalent: ""); q.target = self; m.addItem(q)
        item.menu = m
        writeStatus(state: state, device: dev)
    }

    func writeStatus(state: String, device: String) {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let r = holder.holding ? rate(holder.device) : 0
        let obj: [String: Any] = ["state": state, "device": device, "inputSampleRate": r,
                                  "error": holder.lastError, "pid": ProcessInfo.processInfo.processIdentifier,
                                  "updated": ISO8601DateFormatter().string(from: Date())]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) { try? d.write(to: statusFile) }
    }

    @objc func toggle() { writeDesired(!enabled); reload() }
    @objc func quit() { holder.stop(); writeStatus(state: "off", device: "—"); NSApp.terminate(nil) }

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ud in
            Unmanaged<App>.fromOpaque(ud!).takeUnretainedValue().toggle(); return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x544B4D44), id: 1) // 'TKMD'
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
