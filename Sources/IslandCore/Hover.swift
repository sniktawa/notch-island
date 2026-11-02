import Foundation

public enum HoverChange: Equatable {
    case enter
    case leave
}

/// Hover rules (pure): rest on the hot zone `restDelay` seconds to open; moving faster than `fastSpeed` (points per
/// second) restarts the rest, so flying past to the menu bar never opens it; leaving the shape for `leaveDelay`
/// closes it. A pressed mouse button that started on the island never opens it by hover (that's a click).
public struct HoverGate {
    public var restDelay: Double
    public var leaveDelay: Double
    public var fastSpeed: Double
    public private(set) var hovering = false
    private var enterAt: Double?
    private var leftAt: Double?
    private var last: (x: Double, y: Double, t: Double)?

    public init(restDelay: Double = 0.3, leaveDelay: Double = 0.35, fastSpeed: Double = 800) {
        self.restDelay = restDelay
        self.leaveDelay = leaveDelay
        self.fastSpeed = fastSpeed
    }

    /// One cursor sample. inHot: on the notch / compact island; inShape: on the (possibly open) island + tolerance.
    public mutating func update(x: Double, y: Double, t: Double, inHot: Bool, inShape: Bool, buttonDown: Bool = false) -> HoverChange? {
        var speed = 0.0
        if let p = last, t > p.t { speed = hypot(x - p.x, y - p.y) / (t - p.t) }
        last = (x, y, t)
        if !hovering {
            leftAt = nil
            guard inHot, !buttonDown else {
                enterAt = nil
                return nil
            }
            if speed > fastSpeed || enterAt == nil { enterAt = t }
            if let e = enterAt, t - e >= restDelay {
                hovering = true
                enterAt = nil
                return .enter
            }
            return nil
        }
        enterAt = nil
        if inShape || inHot {
            leftAt = nil
            return nil
        }
        if leftAt == nil { leftAt = t }
        if let l = leftAt, t - l >= leaveDelay {
            hovering = false
            leftAt = nil
            return .leave
        }
        return nil
    }

    /// When to look again with no new mouse event (the rest or the leave timer), or nil.
    public func nextCheck() -> Double? {
        if !hovering, let e = enterAt { return e + restDelay }
        if hovering, let l = leftAt { return l + leaveDelay }
        return nil
    }

    /// Closed from outside (Esc, a click elsewhere): forget the hover.
    public mutating func reset() {
        hovering = false
        enterAt = nil
        leftAt = nil
    }
}
