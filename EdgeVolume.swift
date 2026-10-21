// EdgeVolume: hold Control and slide a finger up or down the right edge of the
// trackpad to change the volume.
//
// Idle cost is one event tap that only hears modifier keys. The trackpad is
// read only while Control is held, and scroll events are intercepted only
// while a finger is on the edge.

import AppKit
import AudioToolbox

// MARK: - Tuning

let zoneWidth: Float = 0.2     // right-hand share of the trackpad that responds
let sensitivity: Float = 1.5   // volume change for a full-height slide (1.0 = the whole range)
let deadZone: Float = 0.02     // vertical travel, as a share of the height, before the slide takes over

// MARK: - Volume of the default output device

func audioAddress(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func defaultOutput() -> AudioDeviceID? {
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = audioAddress(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr && device != kAudioObjectUnknown ? device : nil
}

func getOutputProperty<T: BitwiseCopyable>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
    var address = audioAddress(selector, kAudioDevicePropertyScopeOutput)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
}

func setOutputProperty<T: BitwiseCopyable>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: T) {
    var address = audioAddress(selector, kAudioDevicePropertyScopeOutput)
    var value = value
    AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
}

// MARK: - Gesture (all state lives on the main thread)

struct Finger {
    let id: Int32
    let x, y: Float
}

var trackpads: CFMutableArray?   // non-nil while Control is held
var seen = Set<Int32>()          // fingers already on the trackpad in the previous frame
var anchorID: Int32?             // the finger that touched down on the right edge
var anchorPad: UInt = 0
var startX: Float = 0, startY: Float = 0, lastY: Float = 0
var adjusting = false            // the anchor has moved far enough to be a volume slide
var slides = 0
var debugFrames = 0

var output = AudioDeviceID(kAudioObjectUnknown)
var volume: Float32 = 0
var muted = false

var flagsTap: CFMachPort?
var scrollTap: CFMachPort?

func eachTrackpad(_ body: (MTDeviceRef) -> Void) {
    guard let trackpads else { return }
    for index in 0..<CFArrayGetCount(trackpads) {
        body(UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(trackpads, index)))
    }
}

// Runs on MultitouchSupport's own thread, once per trackpad frame.
let touchCallback: MTContactCallback = { device, touches, count, _, _ in
    var fingers: [Finger] = []
    if let touches {
        for touch in UnsafeBufferPointer(start: touches, count: Int(count)) where touch.state == 3 || touch.state == 4 {
            fingers.append(Finger(id: touch.identifier, x: touch.normalized.position.x, y: touch.normalized.position.y))
        }
    }
    let pad = UInt(bitPattern: device)
    DispatchQueue.main.async { handleFrame(pad: pad, fingers: fingers) }
    return 0
}

func controlChanged(_ held: Bool) {
    guard held != (trackpads != nil) else { return }
    NSLog("DEBUG control held=%d", held ? 1 : 0)
    if held {
        // A fresh list each time picks up trackpads connected since the last press.
        trackpads = MTDeviceCreateList()
        NSLog("DEBUG trackpads=%ld", trackpads.map { CFArrayGetCount($0) } ?? -1)
        eachTrackpad {
            MTRegisterContactFrameCallback($0, touchCallback)
            MTDeviceStart($0, 0)
        }
    } else {
        eachTrackpad {
            MTUnregisterContactFrameCallback($0, touchCallback)
            MTDeviceStop($0)
        }
        trackpads = nil
        seen.removeAll()
        endSlide()
    }
}

func handleFrame(pad: UInt, fingers: [Finger]) {
    debugFrames += 1
    if debugFrames % 50 == 1 { NSLog("DEBUG frame #%ld fingers=%@", debugFrames, fingers.map { String(format: "%.2f,%.2f", $0.x, $0.y) }.joined(separator: " ")) }
    guard trackpads != nil else { return }   // a frame that was already queued when Control went up
    guard CGEventSource.flagsState(.combinedSessionState).contains(.maskControl) else {
        return controlChanged(false)         // the key-up never reached the tap (e.g. a password field had focus)
    }

    if let id = anchorID {
        guard pad == anchorPad else { return }
        if !fingers.contains(where: { $0.id == id }) { endSlide() }
    }
    // Only a finger that touches down inside the zone counts; one that wanders in does not.
    if anchorID == nil, let finger = fingers.first(where: { !seen.contains($0.id) && $0.x >= 1 - zoneWidth }) {
        anchorID = finger.id
        NSLog("DEBUG anchor x=%.2f y=%.2f", finger.x, finger.y)
        anchorPad = pad
        startX = finger.x
        startY = finger.y
        if let scrollTap { CGEvent.tapEnable(tap: scrollTap, enable: true) }
    }
    seen = Set(fingers.map(\.id))

    guard let id = anchorID, let finger = fingers.first(where: { $0.id == id }) else { return }

    if !adjusting {
        let dx = abs(finger.x - startX), dy = abs(finger.y - startY)
        if dx > deadZone && dx > dy { return endSlide() }   // sideways: an ordinary pointer move
        guard dy > deadZone else { return }
        guard let device = defaultOutput(),
              getOutputProperty(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, &volume) else {
            return endSlide()                               // this output has no volume control
        }
        var mute = UInt32(0)
        muted = getOutputProperty(device, kAudioDevicePropertyMute, &mute) && mute != 0
        output = device
        NSLog("DEBUG adjusting from volume %.2f", volume)
        adjusting = true
        lastY = finger.y
        CGAssociateMouseAndMouseCursorPosition(0)           // hold the pointer still during the slide
        showLevel(volume)
        return
    }

    let target = min(1, max(0, volume + (finger.y - lastY) * sensitivity))
    lastY = finger.y
    guard target != volume else { return }
    if muted && target > volume {
        setOutputProperty(output, kAudioDevicePropertyMute, UInt32(0))
        muted = false
    }
    volume = target
    setOutputProperty(output, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, volume)
    showLevel(volume)
}

func endSlide() {
    guard anchorID != nil else { return }
    anchorID = nil
    if adjusting {
        adjusting = false
        CGAssociateMouseAndMouseCursorPosition(1)
        showLevel(nil)
    }
    // A two-finger slide is followed by momentum scrolling, so keep the scroll
    // tap on for a moment to swallow it.
    slides += 1
    let slide = slides
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        if slide == slides, anchorID == nil, let scrollTap { CGEvent.tapEnable(tap: scrollTap, enable: false) }
    }
}

// MARK: - Event taps

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .flagsChanged:
        let modifiers = event.flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift])
        let held = modifiers == .maskControl
        DispatchQueue.main.async { controlChanged(held) }   // don't hold the key event up
    case .scrollWheel:
        if anchorID != nil { return nil }
        if event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return nil }
        // Phase 1 is "began": a new scroll, whose momentum should get through.
        if event.getIntegerValueField(.scrollWheelEventScrollPhase) == 1, let scrollTap {
            CGEvent.tapEnable(tap: scrollTap, enable: false)
        }
    case .tapDisabledByTimeout:
        // Not .tapDisabledByUserInput: that one is sent for our own tapEnable(false)
        // calls, and answering it with another tapEnable loops forever.
        if let flagsTap { CGEvent.tapEnable(tap: flagsTap, enable: true) }
        if anchorID != nil, let scrollTap { CGEvent.tapEnable(tap: scrollTap, enable: true) }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

// Returns false until the app has been granted Accessibility access.
func installTaps() -> Bool {
    func makeTap(_ type: CGEventType) -> CFMachPort? {
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1) << type.rawValue,
                                          callback: tapCallback, userInfo: nil) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        return tap
    }
    guard flagsTap == nil else { return true }
    guard let scroll = makeTap(.scrollWheel) else { return false }
    CGEvent.tapEnable(tap: scroll, enable: false)
    scrollTap = scroll
    flagsTap = makeTap(.flagsChanged)
    return flagsTap != nil
}

// A small on-screen level bar, since setting the volume directly shows no system overlay.
final class LevelOverlay {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let bar = NSProgressIndicator(frame: NSRect(x: 48, y: 12, width: 156, height: 20))
    private var hides = 0

    init() {
        let background = NSVisualEffectView(frame: panel.contentLayoutRect)
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        let icon = NSImageView(frame: NSRect(x: 14, y: 10, width: 24, height: 24))
        icon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume")
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        background.addSubview(icon)
        background.addSubview(bar)
        panel.contentView = background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    func show(_ level: Float32) {
        hides += 1
        bar.doubleValue = Double(level)
        guard !panel.isVisible, let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.minY + 120))
        panel.orderFrontRegardless()
    }

    func hideSoon() {
        hides += 1
        let hide = hides
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            if hide == hides { panel.orderOut(nil) }
        }
    }
}

let overlay = LevelOverlay()

// Shows the volume during a slide; nil ends the slide.
func showLevel(_ level: Float32?) {
    if let level { overlay.show(level) } else { overlay.hideSoon() }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        freopen("/tmp/edgevolume-debug.log", "w", stderr)   // DEBUG
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("DEBUG launch: AXTrusted=%d taps=%d", AXIsProcessTrusted() ? 1 : 0, installTaps() ? 1 : 0)
        if !installTaps() {
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(prompt)
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
                if installTaps() { timer.invalidate() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
