import Foundation

// v0.3.2: the resting rule, the shelf's place, and the hit test. Pure, so they are unit tested.

/// Wings (the black beside the notch) appear only for something live: a transfer in flight or just done
/// (`transferLive`, the wing's own 6 s done window), Brain working (deck), Brain asking (ask), a meeting countdown.
/// Nothing else widens the resting notch: not a badge, not parked files, not the morning moves after their intro.
/// The moves (and capture) show wings only while the host holds them open (the once-a-day intro, the shortcut).
public func wingsLive(_ v: IslandView, transferLive: Bool) -> Bool {
    if transferLive { return true }
    if v.isRest { return false }
    switch v.mode {
    case "moves", "capture":
        return v.open == true
    default:
        // deck, ask, meeting, and any mode this build does not know (a newer host must not look idle)
        return true
    }
}

/// Where the shelf thumbnails are drawn right now.
public enum ShelfPlace: Equatable {
    case none
    /// at the top of the helper's own open body (rest, moves, or deck)
    case top
    /// a band under the host's sized tray (the host's page owns the tray body above it)
    case trayBottom
}

public func shelfPlace(_ v: IslandView, expanded: Bool, tray: Bool, trayH: Double?, count: Int) -> ShelfPlace {
    guard count > 0 else { return .none }
    if tray { return (trayH ?? 0) > 0 ? .trayBottom : .none }
    guard expanded else { return .none }
    // rest, the moves, and Brain working get the band; an approve card, a meeting, and capture stay focused
    if v.isRest || v.mode == "moves" || v.mode == "deck" { return .top }
    return .none
}

/// One shelf band: a header line ("Shelf · 2" and Show in Finder), the thumbnail row, a gap under it.
public enum ShelfBand {
    public static let header = 16.0
    public static let gap = 6.0
    public static let height = header + gap + RestBody.shelfRow + gap
}

public struct IslandHit: Equatable {
    /// the panel takes the click (not click-through)
    public var take: Bool
    /// counts as resting on the island for the hover gate
    public var inHot: Bool
    /// inside the drawn shape (with the gate's tolerance), for staying open
    public var inShape: Bool
    /// inside the host's tray body (its window above takes those clicks)
    public var trayBody: Bool

    public init(take: Bool, inHot: Bool, inShape: Bool, trayBody: Bool) {
        self.take = take
        self.inHot = inHot
        self.inShape = inShape
        self.trayBody = trayBody
    }
}

/// The host's tray body in canvas points (y up): under the notch strip, `trayH` tall, as wide as the shape.
public func trayBodyRect(_ s: IslandSize, notch: NotchMetrics, trayH: Double, canvasW: Double, canvasH: Double) -> Rect {
    let h = max(0, min(Layout.trayMaxH, trayH))
    return Rect(x: canvasW / 2 - s.w / 2, y: canvasH - notch.height - h, w: s.w, h: h)
}

/// Every visible piece takes clicks: the notch, the wings, the strip across the top of an open tray, the shelf band.
/// Only the host's tray body passes them on (the host's window above draws and answers there). Everything outside
/// the drawn shape is click-through, so the menu bar behind it keeps working.
public func islandHit(x: Double, y: Double, size: IslandSize, notch: NotchMetrics, wings: Bool, tray: Bool, trayH: Double?, accepting: Bool, buttonDown: Bool, canvasW: Double = Layout.canvasW, canvasH: Double = Layout.canvasH) -> IslandHit {
    let yy = min(y, canvasH - 0.01)
    let isl = islandRect(size, canvasW: canvasW, canvasH: canvasH)
    let nr = notchRect(notch, canvasW: canvasW, canvasH: canvasH)
    let inShape = isl.contains(x, yy, pad: accepting ? 4 : 0)
    let inNotch = nr.contains(x, yy)
    var trayBody = false
    if tray, let th = trayH, th > 0, inShape {
        let body = trayBodyRect(size, notch: notch, trayH: th, canvasW: canvasW, canvasH: canvasH)
        trayBody = body.contains(x, yy) && yy < canvasH - notch.height
    }
    let inHot = inNotch || ((wings || tray) && inShape && !trayBody)
    var take = (inShape || inNotch) && !trayBody
    if buttonDown && inNotch { take = true }
    let tolerant = isl.contains(x, yy, pad: 6) || inNotch
    return IslandHit(take: take, inHot: inHot, inShape: tolerant, trayBody: trayBody)
}
