import Foundation

/// The notch of a screen, in points. No notch → a slim fake one at the top centre.
public struct NotchMetrics: Equatable {
    public var width: Double
    public var height: Double
    public var hasNotch: Bool

    public init(width: Double, height: Double, hasNotch: Bool) {
        self.width = width
        self.height = height
        self.hasNotch = hasNotch
    }
}

public let fakeNotchWidth = 190.0

/// safeAreaInsets.top > 0 and menu-bar areas on both sides → a real notch whose width is what lies between them.
public func notchMetrics(screenWidth: Double, topInset: Double, leftAux: Double, rightAux: Double, menuBar: Double) -> NotchMetrics {
    let w = screenWidth - leftAux - rightAux
    if topInset > 0, leftAux > 0, rightAux > 0, w > 60, w < 400 {
        return NotchMetrics(width: w.rounded(), height: topInset.rounded(), hasNotch: true)
    }
    return NotchMetrics(width: fakeNotchWidth, height: max(22, menuBar.rounded()), hasNotch: false)
}

public struct IslandSize: Equatable {
    public var w: Double
    public var h: Double
    /// bottom corner radius
    public var r: Double

    public init(w: Double, h: Double, r: Double) {
        self.w = w
        self.h = h
        self.r = r
    }
}

public enum Layout {
    /// each compact wing beside the notch (glyph left, clock right)
    public static let wing = 64.0
    public static let deckW = 380.0
    public static let askW = 420.0
    public static let meetW = 360.0
    public static let trayW = 520.0
    /// the concave corner where the island meets the menu bar (Dynamic Island style)
    public static let shoulder = 12.0
    /// the helper's window: wide and tall enough for the biggest island (the host's tray) plus spring overshoot
    public static let canvasW = 580.0
    public static let canvasH = 480.0
    /// v0.2.0: the peek under a resting cursor when nothing is running ("Nothing running")
    public static let peekExtra = 24.0
    /// v0.2.0: bottom corner radius of the open tray
    public static let trayR = 24.0
    /// v0.2.0: the tallest tray the host may ask for (below the notch); notch + tray stays 40 pt inside the canvas
    /// for the open spring's overshoot, even under a tall (38 pt) notch
    public static let trayMaxH = canvasH - 80
    public static let deckExtra = 54.0
    public static let askExtra = 92.0
    public static let meetExtra = 58.0
}

/// The island's size for what it shows. Compact = the notch plus two wings; expanded grows below it.
/// v0.2.0: `trayH` = the host's tray is open and this tall below the notch → the black shape IS the tray (one shape that
/// springs from the notch, the host's transparent content fades in on top); `nil` keeps v0.1's flat tray edge. A rest
/// view that is hovered (`expanded`) peeks: the notch plus wings and a short line ("Nothing running").
public func islandSize(_ v: IslandView, expanded: Bool, tray: Bool, notch: NotchMetrics, trayH: Double? = nil, trayW: Double = Layout.trayW) -> IslandSize {
    let nw = notch.width
    let nh = notch.height
    let compactW = min(Layout.trayW, nw + 2 * Layout.wing)
    if tray {
        if let th = trayH, th > 0 { return IslandSize(w: max(compactW, min(Layout.canvasW - 2 * Layout.shoulder - 8, trayW)), h: nh + min(Layout.trayMaxH, th), r: Layout.trayR) }
        return IslandSize(w: Layout.trayW, h: nh, r: 0)
    }
    if v.isRest {
        if expanded { return IslandSize(w: compactW, h: nh + Layout.peekExtra, r: 16) }
        return IslandSize(w: nw, h: nh, r: notch.hasNotch ? 9 : nh / 2)
    }
    if !expanded { return IslandSize(w: compactW, h: nh, r: min(12, nh / 2)) }
    switch v.mode {
    case "ask":
        return IslandSize(w: min(Layout.trayW, max(compactW, Layout.askW)), h: nh + Layout.askExtra, r: 22)
    case "meeting":
        return IslandSize(w: min(Layout.trayW, max(compactW, Layout.meetW)), h: nh + Layout.meetExtra, r: 20)
    default:
        return IslandSize(w: min(Layout.trayW, max(compactW, Layout.deckW)), h: nh + Layout.deckExtra, r: 20)
    }
}

/// Path elements in points, y up (AppKit), the island's top edge at canvasH. Curves: (c1x, c1y, c2x, c2y, x, y).
public enum PathOp: Equatable {
    case move(Double, Double)
    case line(Double, Double)
    case curve(Double, Double, Double, Double, Double, Double)
    case close
}

/// The island outline: concave shoulders into the menu bar, straight sides, rounded bottom corners. Always the same 9
/// elements in the same order, so Core Animation can interpolate any state into any other.
public func islandPath(_ s: IslandSize, canvasW: Double, canvasH: Double, shoulder: Double = Layout.shoulder) -> [PathOp] {
    let k = 0.5522847498
    let cx = canvasW / 2
    let w = max(2, s.w)
    let h = max(2, min(s.h, canvasH))
    let l = cx - w / 2
    let rt = cx + w / 2
    let top = canvasH
    let bot = canvasH - h
    let r = max(0, min(s.r, h / 2, w / 2))
    let sh = max(0, min(shoulder, h - r))
    return [
        .move(l - sh, top),
        .curve(l - sh + k * sh, top, l, top - sh + k * sh, l, top - sh),
        .line(l, bot + r),
        .curve(l, bot + r - k * r, l + r - k * r, bot, l + r, bot),
        .line(rt - r, bot),
        .curve(rt - r + k * r, bot, rt, bot + r - k * r, rt, bot + r),
        .line(rt, top - sh),
        .curve(rt, top - sh + k * sh, rt + sh - k * sh, top, rt + sh, top),
        .close,
    ]
}

public struct Rect: Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public func contains(_ px: Double, _ py: Double, pad: Double = 0) -> Bool {
        px >= x - pad && px <= x + w + pad && py >= y - pad && py <= y + h + pad
    }
}

/// The island's box in canvas points (y up), without the shoulders.
public func islandRect(_ s: IslandSize, canvasW: Double, canvasH: Double) -> Rect {
    Rect(x: canvasW / 2 - s.w / 2, y: canvasH - s.h, w: s.w, h: s.h)
}

/// The notch's own box in canvas points.
public func notchRect(_ n: NotchMetrics, canvasW: Double, canvasH: Double) -> Rect {
    Rect(x: canvasW / 2 - n.width / 2, y: canvasH - n.height, w: n.width, h: n.height)
}

/// "0:42", "12:05", "1:02:03".
public func elapsedText(_ seconds: Double) -> String {
    let t = max(0, Int(seconds.rounded(.down)))
    let h = t / 3600
    let m = (t % 3600) / 60
    let s = t % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
