import Foundation
import SwiftUI
import UIKit

// MARK: - Pure touch state (also compiled by the host regression test)
struct GamepadSample: Equatable, Sendable {
    var buttons: UInt16 = 0
    var lt: UInt8 = 0, rt: UInt8 = 0
    var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0

    static func axis(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let v = max(-1, min(1, value))
        return Int16((v * (v < 0 ? 32768 : 32767)).rounded())
    }

    /// Same arbitration as the fork: a physical stick outside its XInput
    /// dead zone wins; otherwise use a deflected touch stick. A resting touch
    /// stick must not erase a small physical deflection.
    static func merge(physical p: Self, touch t: Self) -> Self {
        var result = p
        result.buttons |= t.buttons
        result.lt = max(p.lt, t.lt); result.rt = max(p.rt, t.rt)
        if hypot(Double(p.lx), Double(p.ly)) <= 7849 && (t.lx != 0 || t.ly != 0) {
            result.lx = t.lx; result.ly = t.ly
        }
        if hypot(Double(p.rx), Double(p.ry)) <= 8689 && (t.rx != 0 || t.ry != 0) {
            result.rx = t.rx; result.ry = t.ry
        }
        return result
    }
}

enum TouchPadAction {
    static let buttons: [String: UInt16] = [
        "A": 0x1000, "B": 0x2000, "X": 0x4000, "Y": 0x8000,
        "D↑": 1, "D↓": 2, "D←": 4, "D→": 8,
        "LB": 0x0100, "RB": 0x0200, "L3": 0x0040, "R3": 0x0080,
        "Menu": 0x0010, "View": 0x0020, "Guide": 0x0400
    ]
    static func supported(_ name: String) -> Bool {
        buttons[name] != nil || ["LT", "RT", "LS", "RS"].contains(name)
    }
    static func vector(x: Double, y: Double) -> (Double, Double) {
        guard x.isFinite && y.isFinite else { return (0, 0) }
        let length = max(1, hypot(x, y))
        return (x / length, y / length)
    }
    static func sample(_ name: String, x: Double = 0, y: Double = 0) -> GamepadSample {
        var result = GamepadSample()
        result.buttons = buttons[name] ?? 0
        if name == "LT" { result.lt = 255 }
        if name == "RT" { result.rt = 255 }
        let (x, y) = vector(x: x, y: y)
        if name == "LS" { result.lx = GamepadSample.axis(x); result.ly = GamepadSample.axis(y) }
        if name == "RS" { result.rx = GamepadSample.axis(x); result.ry = GamepadSample.axis(y) }
        return result
    }
}

struct TouchGamepadState {
    private struct Hold { var control: UUID; var value: GamepadSample }
    private var allowed = Set<UUID>()
    private var holds: [UUID: Hold] = [:]
    private var suspendedConnection = false
    private(set) var acceptingInput = true
    /// Player 1 stays connected at rest for the whole session, even with no
    /// visible touch control (GamepadInput.reserveSessionSlot). Layout changes
    /// and lifecycle clearing release holds but keep the reservation.
    var reserved = false
    var connected: Bool { reserved || (!allowed.isEmpty && (acceptingInput || suspendedConnection)) }

    mutating func configure(_ controls: Set<UUID>, acceptingInput: Bool = true) {
        // Menus temporarily suppress controls, not the controller identity.
        // Preserve an already exposed pad, without connecting one early while
        // the session is still launching. Hiding/removing all controls disconnects.
        suspendedConnection = connected && !controls.isEmpty && !acceptingInput
        self.acceptingInput = acceptingInput
        allowed = controls
        // Layout changes invalidate all in-flight gestures, including remaps
        // which preserve the control's ID.
        clear()
    }
    mutating func update(owner: UUID, control: UUID, value: GamepadSample?) {
        guard acceptingInput, allowed.contains(control), let value else { holds[owner] = nil; return }
        holds[owner] = Hold(control: control, value: value)
    }
    mutating func clear() { holds.removeAll() }
    var sample: GamepadSample {
        var result = GamepadSample()
        for hold in holds.values {
            let s = hold.value
            result.buttons |= s.buttons
            result.lt = max(result.lt, s.lt); result.rt = max(result.rt, s.rt)
            // Duplicate stick controls choose the stronger vector; lexical
            // tie-breaking makes equal opposite inputs deterministic.
            func stronger(_ x: Int16, _ y: Int16, _ a: Int16, _ b: Int16) -> Bool {
                let n = Int64(x) * Int64(x) + Int64(y) * Int64(y)
                let m = Int64(a) * Int64(a) + Int64(b) * Int64(b)
                return n > m || (n == m && (x > a || (x == a && y > b)))
            }
            if stronger(s.lx, s.ly, result.lx, result.ly) { result.lx = s.lx; result.ly = s.ly }
            if stronger(s.rx, s.ry, result.rx, result.ry) { result.rx = s.rx; result.ry = s.ry }
        }
        return result
    }
}
// MARK: - UIKit touch lifetime

/// UIKit supplies explicit cancellation and independent finger identities;
/// SwiftUI's DragGesture.onEnded alone cannot release every interrupted press.
struct TouchPadSurface: UIViewRepresentable {
    let control: UUID
    let action: String
    let changed: (CGSize, Bool) -> Void
    func makeUIView(context: Context) -> TouchPadView { TouchPadView() }
    func updateUIView(_ view: TouchPadView, context: Context) {
        view.configure(control: control, action: action, changed: changed)
    }
    static func dismantleUIView(_ view: TouchPadView, coordinator: ()) { view.releaseAll() }
}

final class TouchPadView: UIView {
    private struct Finger { var owner: UUID; var start: CGPoint }
    private var fingers: [ObjectIdentifier: Finger] = [:]
    private var control = UUID()
    private var action = ""
    private var changed: ((CGSize, Bool) -> Void)?
    private var previousSize = CGSize.zero

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
            name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    func configure(control: UUID, action: String, changed: @escaping (CGSize, Bool) -> Void) {
        if self.control != control || self.action != action { releaseAll() }
        self.control = control; self.action = action; self.changed = changed
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size { releaseAll(); previousSize = bounds.size }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { releaseAll() } }
    @objc private func interrupted() { releaseAll(); changed?(.zero, false) }
    func releaseAll() {
        for finger in fingers.values {
            GamepadInput.shared.touch(owner: finger.owner, control: control, value: nil)
        }
        fingers.removeAll()
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            fingers[ObjectIdentifier(touch)] = Finger(owner: UUID(), start: touch.location(in: self))
        }
        update(touches)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches) }
    private func update(_ touches: Set<UITouch>) {
        guard UIApplication.shared.applicationState == .active else { interrupted(); return }
        for touch in touches {
            guard let finger = fingers[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self), radius = max(1, bounds.width * 0.35)
            let (x, y) = TouchPadAction.vector(x: Double((point.x - finger.start.x) / radius),
                                              y: Double((finger.start.y - point.y) / radius))
            GamepadInput.shared.touch(owner: finger.owner, control: control,
                value: TouchPadAction.sample(action, x: x, y: y))
            changed?(CGSize(width: x, height: -y), true)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    private func finish(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let finger = fingers.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            GamepadInput.shared.touch(owner: finger.owner, control: control, value: nil)
        }
        if fingers.isEmpty { changed?(.zero, false) }
    }
}

// MARK: - Key, mouse and key-stick controls (UIKit)

/// What one finger on a key, mouse, keyboard or key-stick control sends, from
/// touch-down to lift. TouchKeyView feeds it; a lift, a cancelled touch, the app
/// leaving the foreground and the control leaving the screen all end it, so
/// nothing stays held.
@MainActor final class TouchKeyPress {
    private(set) var action: ControlAction
    var diameter: CGFloat
    private(set) var down = false
    private(set) var direction = -1
    /// The drawn state changed: pressed, and a key stick's direction.
    var changed: ((Bool, Int) -> Void)?

    init(action: ControlAction, diameter: CGFloat) {
        self.action = action
        self.diameter = diameter
    }

    func begin() {
        guard !down else { return }
        down = true
        if action.stickKeys == nil {
            // Haptic on the DOWN edge only: a held key must not buzz.
            if TouchControlsModel.shared.hapticsEnabled {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            send(true)
        }
        changed?(down, direction)
    }

    func move(dx: CGFloat, dy: CGFloat) {
        guard down, let keys = action.stickKeys else { return }
        let next = Self.direction(dx: dx, dy: dy, diameter: diameter)
        guard next != direction else { return }
        Self.stickChange(from: direction, to: next, keys: keys)
        if direction == -1, next != -1, TouchControlsModel.shared.hapticsEnabled {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        direction = next
        changed?(down, direction)
    }

    func end() {
        guard down else { return }
        if let keys = action.stickKeys {
            Self.stickChange(from: direction, to: -1, keys: keys)
            direction = -1
        } else {
            send(false)
        }
        down = false
        changed?(down, direction)
    }

    /// A different action ends the old one's press first.
    func rebind(_ action: ControlAction) {
        guard action != self.action else { return }
        end()
        self.action = action
    }

    private func send(_ down: Bool) {
        switch action {
        case .key(let vk):    winios_post_key(vk, down ? 1 : 0)
        case .mouseLeft:      winios_pointer(0, 0, down ? 0x0002 : 0x0004, 0)   // LEFTDOWN / LEFTUP
        case .mouseRight:     winios_pointer(0, 0, down ? 0x0008 : 0x0010, 0)   // RIGHTDOWN / RIGHTUP
        case .keyboardToggle: if down { MetalBackedView.toggleKeyboard() }
        case .none, .joystickWASD, .joystickArrows, .pad: break
        }
    }

    /// 8-way snap: -1 inside the dead zone (22 % of the diameter), else 0 for up
    /// and on clockwise. Screen y grows downward.
    static func direction(dx: CGFloat, dy: CGFloat, diameter: CGFloat) -> Int {
        if (dx * dx + dy * dy).squareRoot() < diameter * 0.22 { return -1 }
        var a = atan2(dx, -dy) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    /// The keys held in a direction (diagonals hold two); keys are up, right, down, left
    /// in ControlAction.stickKeys order.
    static func held(_ d: Int, _ q: [Int32]) -> [Int32] {
        guard q.count == 4 else { return [] }
        switch d {
        case 0: return [q[0]]
        case 1: return [q[0], q[1]]
        case 2: return [q[1]]
        case 3: return [q[2], q[1]]
        case 4: return [q[2]]
        case 5: return [q[2], q[3]]
        case 6: return [q[3]]
        case 7: return [q[0], q[3]]
        default: return []
        }
    }

    /// Release what is no longer held, then press what newly is: a held direction
    /// never stutters while the thumb wanders inside one sector.
    private static func stickChange(from old: Int, to new: Int, keys: [Int32]) {
        guard old != new else { return }
        let before = held(old, keys), after = held(new, keys)
        for vk in before where !after.contains(vk) { winios_post_key(vk, 0) }
        for vk in after where !before.contains(vk) { winios_post_key(vk, 1) }
    }
}

/// The touch area of a key, mouse, keyboard or key-stick control: the circle it is
/// drawn in. It follows the first finger down until that finger lifts (or is
/// cancelled, or the app leaves the foreground, or the control leaves the screen);
/// other fingers on it are held and ignored, so they never reach the game as a mouse.
/// UIKit, not a SwiftUI DragGesture: every finger is its own touch, independent of
/// the other controls, and cancellation always arrives.
struct TouchKeySurface: UIViewRepresentable {
    let action: ControlAction
    let diameter: CGFloat
    /// Pressed, and a key stick's direction.
    let changed: (Bool, Int) -> Void
    func makeUIView(context: Context) -> TouchKeyView { TouchKeyView() }
    func updateUIView(_ view: TouchKeyView, context: Context) {
        view.configure(action: action, diameter: diameter, changed: changed)
    }
    static func dismantleUIView(_ view: TouchKeyView, coordinator: ()) { view.finish(notify: false) }
}

final class TouchKeyView: UIView {
    private var press: TouchKeyPress?
    /// The finger this control follows (UIKit reuses touch objects, so it is kept by identity).
    private var finger: ObjectIdentifier?
    private var start = CGPoint.zero
    private var diameter: CGFloat = 64

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
            name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(action: ControlAction, diameter: CGFloat, changed: @escaping (Bool, Int) -> Void) {
        self.diameter = diameter
        if let press {
            press.rebind(action)
            press.diameter = diameter
            press.changed = changed
        } else {
            let p = TouchKeyPress(action: action, diameter: diameter)
            p.changed = changed
            press = p
        }
    }

    /// A circle of the control's diameter around its centre.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hypot(point.x - bounds.midX, point.y - bounds.midY) <= diameter / 2
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard UIApplication.shared.applicationState == .active else { interrupted(); return }
        guard finger == nil, let touch = touches.first else { return }
        finger = ObjectIdentifier(touch)
        start = touch.location(in: self)
        press?.begin()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard UIApplication.shared.applicationState == .active else { interrupted(); return }
        guard let finger, let touch = touches.first(where: { ObjectIdentifier($0) == finger }) else { return }
        let p = touch.location(in: self)
        press?.move(dx: p.x - start.x, dy: p.y - start.y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        guard let finger, touches.contains(where: { ObjectIdentifier($0) == finger }) else { return }
        finish()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finish(notify: false) }
    }

    @objc private func interrupted() { finish() }

    /// Lets go of whatever this control holds. `notify: false` while SwiftUI is
    /// taking the control down: its face is reset by the view itself (rest()), and
    /// state must not change during that update.
    func finish(notify: Bool = true) {
        finger = nil
        if !notify { press?.changed = nil }
        press?.end()
    }
}
