// SoundSlide: hold Control and slide a finger up or down the right edge of the
// trackpad to change the volume.
//
// Idle cost is one event tap that only hears modifier keys. The trackpad is
// read only while Control is held, and scroll events are intercepted only
// while a finger is on the edge.

import AppKit
import AudioToolbox
import QuartzCore

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

private let radiantGreenBright = NSColor(calibratedRed: 0.35, green: 1.0, blue: 0.55, alpha: 1)
private let radiantGreenCore = NSColor(calibratedRed: 0.15, green: 0.95, blue: 0.42, alpha: 1)
private let radiantGreenDeep = NSColor(calibratedRed: 0.05, green: 0.72, blue: 0.28, alpha: 1)

final class VolumeBarView: NSView {
    /// Level the fluid fill springs toward (0–1). The fill is a gently
    /// underdamped spring; its leading edge is a liquid meniscus that lags and
    /// sloshes with the motion, shedding droplets on fast slides.
    var target: CGFloat = 0 {
        didSet { wake() }
    }

    private let fill = CAGradientLayer()       // gradient, masked into a liquid shape
    private let liquidMask = CAShapeLayer()    // liquid body: flat left, sloshing right edge
    private let glow = CALayer()
    private var level: CGFloat = 0
    private var velocity: CGFloat = 0
    private var smoothV: CGFloat = 0           // low-passed velocity, drives the slosh
    private var waveT: CGFloat = 0             // running time for the surface wave
    private var lagPx: CGFloat = 0             // current meniscus lag, px
    private var ampPx: CGFloat = 0             // current wave amplitude, px
    private var lastBeat: CFTimeInterval = 0
    private var timer: Timer?
    private var droplets: [Droplet] = []
    private var pending: [Droplet] = []     // queued by add() during a physics step

    /// Where droplets that escape the bar go: a layer spanning from the HUD
    /// down to the bottom of the screen, plus the bar's origin in its coordinates.
    struct DropletOutlet {
        weak var layer: CALayer?
        var offset: CGPoint
    }

    var dropletOutlet: DropletOutlet?

    /// True once every droplet has landed, faded, or left the screen.
    var dropletsDone: Bool { droplets.isEmpty }

    /// Live droplet count, for diagnostics.
    var dropletCount: Int { droplets.count }

    // The original gently fluid spring: ~2.2 Hz with a damping ratio of 0.74,
    // so a step in target glides across and just barely overshoots before
    // resting.
    private let stiffness: CGFloat = 200
    private let damping: CGFloat = 21

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor

        fill.colors = [
            radiantGreenDeep.cgColor,
            radiantGreenCore.cgColor,
            radiantGreenBright.cgColor,
            radiantGreenCore.cgColor,
        ]
        fill.locations = [0, 0.35, 0.55, 1]
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.cornerRadius = 3

        glow.backgroundColor = radiantGreenCore.withAlphaComponent(0.35).cgColor
        glow.cornerRadius = 4
        glow.shadowColor = radiantGreenBright.cgColor
        glow.shadowOpacity = 1
        glow.shadowRadius = 8
        glow.shadowOffset = .zero

        liquidMask.fillColor = .black
        liquidMask.actions = ["path": NSNull()]
        fill.mask = liquidMask

        // Geometry is updated every frame by the simulation; implicit CA
        // animations would fight it.
        let still = ["position": NSNull(), "bounds": NSNull()]
        fill.actions = still
        glow.actions = still

        layer?.addSublayer(glow)
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        timer?.invalidate()
    }

    override func layout() {
        super.layout()
        layoutFill()
    }

    private func wake() {
        lastBeat = 0
        if timer != nil { return }   // already beating
        let timer = Timer(timeInterval: 1 / 120, target: WeakProxy(self), selector: #selector(WeakProxy.beat), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops the per-frame simulation once the fill has caught up.
    func sleep() {
        timer?.invalidate()
        timer = nil
    }

    @objc func beat(_ sender: Any) {
        let now = CACurrentMediaTime()
        var dt = lastBeat == 0 ? 1 / 120 : now - lastBeat
        lastBeat = now
        dt = min(dt, 0.05)   // a stall should not launch the fill
        waveT += dt

        velocity += (stiffness * (target - level) - damping * velocity) * dt
        level += velocity * dt
        if level < 0 { level = 0; velocity = 0 }        // walls absorb, no bouncing
        if level > 1 { level = 1; velocity = 0 }

        // Liquid surface: a low-passed fill velocity tilts the meniscus (the
        // liquid piles up in the direction of travel) and drives a ripple.
        smoothV += (velocity - smoothV) * min(1, dt * 18)
        let vPx = smoothV * bounds.width
        lagPx = max(-6, min(6, vPx * 0.004))
        ampPx = min(3.5, abs(vPx) * 0.006)

        splash(with: vPx)
        stepDroplets(dt: dt)
        layoutFill()
        let speed = min(1, abs(velocity) * 3)
        glow.shadowRadius = CGFloat(8 + 10 * speed)      // the glow trails motion
        glow.shadowOpacity = Float(0.75 + 0.25 * speed)

        if abs(target - level) < 0.0005, abs(velocity) < 0.002,
           abs(smoothV) < 0.01, droplets.isEmpty, pending.isEmpty {
            level = target
            velocity = 0
            layoutFill()
            sleep()
        }
    }

    /// Throws droplets off the meniscus when the fill moves fast enough; some
    /// escape the HUD entirely and fall to the bottom of the screen.
    private func splash(with vPx: CGFloat) {
        guard abs(vPx) > 150 else { return }
        let inset: CGFloat = 1
        let track = bounds.insetBy(dx: inset, dy: inset)
        while droplets.count + pending.count < 60, drand48() < min(0.9, abs(vPx) / 700) {
            let escape = dropletOutlet?.layer != nil && drand48() < 0.35
            let droplet = Droplet(
                x: track.minX + track.width * level + lagPx,
                y: track.minY + 1 + CGFloat(drand48()) * (track.height - 2),
                vx: vPx * (0.2 + 0.35 * CGFloat(drand48())),
                vy: (escape ? 90 : 40) + (escape ? 170 : 110) * CGFloat(drand48()),
                escaped: escape)
            if escape, let outlet = dropletOutlet {
                droplet.x += outlet.offset.x     // escaped droplets live in host coordinates
                droplet.y += outlet.offset.y
            }
            add(droplet)
        }
    }

    /// Attaches a droplet to the layer matching its coordinate space.
    private func add(_ droplet: Droplet) {
        if droplet.escaped, let outlet = dropletOutlet, outlet.layer != nil {
            outlet.layer!.addSublayer(droplet.layer)
        } else {
            layer?.addSublayer(droplet.layer)
        }
        // Queue instead of appending straight to `droplets`: splashes are spawned
        // while stepDroplets is looping over a snapshot of that array, and an
        // in-loop append would be wiped out by the `droplets = alive` rebuild.
        pending.append(droplet)
    }

    /// Free flight, a bounce on the track floor, then a quick fade — unless the
    /// droplet escaped, in which case it just falls until it leaves the screen.
    private func stepDroplets(dt: CGFloat) {
        droplets.append(contentsOf: pending)   // spawned since the last merge
        pending.removeAll()
        guard !droplets.isEmpty else { return }
        let floorY = CGFloat(1)
        var alive: [Droplet] = []
        for droplet in droplets {
            droplet.age += dt
            droplet.vy -= 1500 * dt            // droplet-scale gravity
            droplet.x += droplet.vx * dt
            droplet.y += droplet.vy * dt
            var alpha = max(0, 1 - droplet.age / droplet.life)
            if droplet.escaped {
                droplet.vx *= 1 - min(1, 0.8 * dt)   // air drag, keeps most inside the screen
                if droplet.y < 0 {             // off the bottom of the screen
                    droplet.layer.removeFromSuperlayer()
                    if droplet.canSplash { splashAtBottom(of: droplet) }
                    continue
                }
            } else {
                if droplet.y < floorY + droplet.radius, droplet.vy < 0 {
                    droplet.y = floorY + droplet.radius
                    let impact = -droplet.vy
                    droplet.vy = impact * 0.38
                    droplet.vx *= 0.7
                    droplet.bounces += 1
                    if droplet.canSplash, impact > 280 { kickUpFlecks(from: droplet, impact: impact) }
                }
                if droplet.bounces >= 2 { alpha = min(alpha, 0.4) }
            }
            if alpha <= 0.01 {
                droplet.layer.removeFromSuperlayer()
            } else {
                droplet.layer.opacity = Float(alpha)
                droplet.layer.position = CGPoint(x: droplet.x, y: droplet.y)
                alive.append(droplet)
            }
        }
        droplets = alive
        droplets.append(contentsOf: pending)   // flecks kicked up this frame step next frame
        pending.removeAll()
    }

    /// A hard landing on the track floor kicks up tiny flecks.
    private func kickUpFlecks(from droplet: Droplet, impact: CGFloat) {
        let count = 3 + Int(drand48() * 2 + Double(min(3, impact / 250)))   // 3–6, more for harder hits
        for _ in 0..<count where droplets.count + pending.count < 90 {
            let fleck = Droplet(
                x: droplet.x + (CGFloat(drand48()) - 0.5) * 6,
                y: droplet.y + droplet.radius,
                vx: droplet.vx * 0.4 + (CGFloat(drand48()) - 0.5) * 170,
                vy: 70 + 170 * CGFloat(drand48()),
                escaped: droplet.escaped,
                micro: true)
            add(fleck)
        }
    }

    /// A droplet reaching the bottom of the screen splashes a hop of flecks
    /// right at the edge before everything fades.
    private func splashAtBottom(of droplet: Droplet) {
        let count = 5 + Int(drand48() * 3)   // 5–7
        for _ in 0..<count where droplets.count + pending.count < 90 {
            let fleck = Droplet(
                x: droplet.x + (CGFloat(drand48()) - 0.5) * 8,
                y: 1 + CGFloat(drand48()) * 3,
                vx: droplet.vx * 0.3 + (CGFloat(drand48()) - 0.5) * 130,
                vy: 130 + 230 * CGFloat(drand48()),
                escaped: true,
                micro: true)
            add(fleck)
        }
    }

    /// The liquid body: rounded left edge, top and bottom edges, and a sloshing
    /// meniscus on the right. Coordinates are the fill layer's bounds.
    private func liquidPath(base: CGFloat, lag: CGFloat, amp: CGFloat, height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard base > 0.01 else { return path }
        let r: CGFloat = 3
        let top = max(base + lag, r + 0.5)
        path.move(to: CGPoint(x: r, y: 0))
        path.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: height - r))
        path.addQuadCurve(to: CGPoint(x: r, y: height), control: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: top, y: height))
        let points = 9
        for i in 1..<points {
            let frac = CGFloat(i) / CGFloat(points)
            let y = height * (1 - frac)
            let wave = amp * sin(waveT * 7 + frac * 5.5 + 1.3 * sin(waveT * 3.1))
            path.addLine(to: CGPoint(x: max(1.5, top + wave), y: y))
        }
        path.addLine(to: CGPoint(x: top, y: 0))
        path.closeSubpath()
        return path
    }

    private func layoutFill() {
        let inset: CGFloat = 1
        let track = bounds.insetBy(dx: inset, dy: inset)
        let base = track.width * level
        let frameWidth = max(2, base + max(lagPx, 0) + ampPx + 6)
        fill.frame = CGRect(x: track.minX, y: track.minY, width: frameWidth, height: track.height)
        liquidMask.frame = fill.bounds
        liquidMask.path = liquidPath(base: base, lag: lagPx, amp: ampPx, height: track.height)
        glow.frame = CGRect(x: track.minX - 1.5, y: track.minY - 1.5, width: frameWidth + 3, height: track.height + 3)
        glow.isHidden = base <= 0.01
    }
}

/// A fleck of liquid thrown off the meniscus. Escaped droplets live in the
/// overlay's fall-to-the-bottom layer and are positioned in its coordinates.
private final class Droplet {
    let layer = CALayer()
    let radius: CGFloat
    let life: CGFloat
    let escaped: Bool
    let canSplash: Bool   // micro flecks from a landing splash no longer splash
    var x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat
    var age: CGFloat = 0
    var bounces = 0

    init(x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat, escaped: Bool, micro: Bool = false) {
        self.x = x
        self.y = y
        self.vx = vx
        self.vy = vy
        self.escaped = escaped
        canSplash = !micro
        radius = micro ? 2.0 + CGFloat(drand48()) * 1.6 : 1.2 + CGFloat(drand48()) * 1.8
        life = micro ? 0.35 + CGFloat(drand48()) * 0.25
            : escaped ? 1.5 : 0.55 + CGFloat(drand48()) * 0.5
        layer.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        layer.cornerRadius = radius
        layer.backgroundColor = (micro || drand48() < 0.3 ? radiantGreenBright : radiantGreenCore).cgColor
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
    }
}

// Timer/CADisplayLink targets are retained by their run loop; a weak proxy
// lets the bar deallocate without keeping the run loop holding a dead view.
private final class WeakProxy: NSObject {
    private weak var target: VolumeBarView?
    init(_ target: VolumeBarView) { self.target = target }

    @objc func beat(_ sender: Any) { target?.beat(sender) }
}

// A wide on-screen level bar with a fluid, spring-driven fill, since setting
// the volume directly shows no system overlay. The panel is rebuilt fresh
// every time it is brought back: one left sitting unused can lose its window
// surface (observed on macOS 26 as a window that exists but renders nothing),
// and a fresh panel is the reliable cure. The panel stretches from the pill
// down to the bottom of the screen so escaped droplets have somewhere to fall.
final class LevelOverlay {
    private var panel: NSPanel?
    private var background: NSVisualEffectView?
    private var bar: VolumeBarView?
    private var dropletHost: NSView?
    private var hides = 0

    private func makePanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 300))
        container.wantsLayer = true
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 300 - 96, width: 720, height: 36))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        let icon = NSImageView(frame: NSRect(x: 14, y: 9, width: 18, height: 18))
        let symbol = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume")
        symbol?.isTemplate = true
        icon.image = symbol
        icon.contentTintColor = radiantGreenBright
        background.addSubview(icon)
        let bar = VolumeBarView(frame: NSRect(x: 44, y: 13, width: 662, height: 10))
        background.addSubview(bar)
        let dropletHost = NSView(frame: container.bounds)
        dropletHost.wantsLayer = true
        container.addSubview(background)
        container.addSubview(dropletHost)          // above the pill: droplets fly in front
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.panel = panel
        self.background = background
        self.bar = bar
        self.dropletHost = dropletHost
    }

    func show(_ level: Float32) {
        hides += 1
        if panel?.isVisible != true {
            panel?.orderOut(nil)   // drop any stale surface before replacing it
            makePanel()
        }
        guard let panel, let bar, let background, let dropletHost else { return }
        if !panel.isVisible, let screen = NSScreen.main {
            // Stretch the panel across the whole screen, from above the pill
            // down to the bottom edge; the pill keeps its usual spot, the rest
            // stays transparent, and escaped droplets can fall anywhere.
            let slack: CGFloat = 60
            let height = (screen.visibleFrame.minY + 120 + 36 + slack) - screen.frame.minY
            panel.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.minY,
                                  width: screen.frame.width, height: height), display: false)
            background.setFrameOrigin(NSPoint(x: (screen.frame.width - background.frame.width) / 2,
                                              y: height - 36 - slack))
            dropletHost.frame = NSRect(x: 0, y: 0, width: screen.frame.width, height: height)
        }
        let origin = background.frame.origin
        bar.dropletOutlet = .init(layer: dropletHost.layer,
                                  offset: CGPoint(x: origin.x + bar.frame.origin.x,
                                                  y: origin.y + bar.frame.origin.y))
        bar.target = CGFloat(level)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hideSoon() {
        hides += 1
        let hide = hides
        func hideIfQuiet() {
            guard hide == hides else { return }
            if let bar, !bar.dropletsDone {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: hideIfQuiet)
            } else {
                bar?.sleep()
                panel?.orderOut(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: hideIfQuiet)
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
        freopen("/tmp/soundslide-debug.log", "w", stderr)   // DEBUG
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
