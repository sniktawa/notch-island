import Foundation

// v0.3.1: what counts as a transfer, how long a finished one stays on screen, and when the list really changed.

/// What the watcher should do with a file it just looked at.
public enum GrowthVerdict: Equatable {
    /// part of the quiet baseline (already there, moved, renamed, or touched without growing): never a row
    case ignore
    /// new, not grown yet: keep polling it for a little while
    case watch
    /// it grew (or a publisher reported progress): show it as a transfer
    case promote
}

/// Only a file that actually grows after the helper started is a transfer. Files already sitting in a watched folder
/// at warm-up form a silent baseline (path → bytes). A file that appears later whole (a Finder move or rename of a
/// finished file, a sync that lands in one go) is watched for a few seconds and then joins the baseline without a row.
public struct GrowthGate {
    public private(set) var baseline: [String: Double] = [:]
    public private(set) var candidates: [String: (bytes: Double, since: Double)] = [:]
    /// final names a finished browser download is about to take (its temp file just vanished)
    public private(set) var expected: [String: Double] = [:]
    /// a new non-temp file that has not grown within this many seconds joins the baseline
    public var watchFor: Double
    /// a temp-suffix file (.crdownload, .download, .part, .tmp) may stall longer before it is let go
    public var watchTempFor: Double
    public var baselineCap: Int
    public var candidateCap: Int

    public init(watchFor: Double = 8, watchTempFor: Double = 60, baselineCap: Int = 20_000, candidateCap: Int = 200) {
        self.watchFor = watchFor
        self.watchTempFor = watchTempFor
        self.baselineCap = baselineCap
        self.candidateCap = candidateCap
    }

    public var candidatePaths: [String] { Array(candidates.keys) }
    public var isWatching: Bool { !candidates.isEmpty }

    /// One look at a file that is not a row yet. `warming` = the first scan after (re)start.
    public mutating func observe(path: String, name: String, bytes: Double, now: Double, warming: Bool) -> GrowthVerdict {
        if let at = expected.removeValue(forKey: path), now - at < 30, bytes > 0 {
            candidates.removeValue(forKey: path)
            baseline.removeValue(forKey: path)
            return .promote
        }
        if let old = baseline[path] {
            if old == bytes { return .ignore }
            baseline.removeValue(forKey: path)
            return .promote
        }
        if let c = candidates[path] {
            if c.bytes != bytes && bytes > 0 {
                candidates.removeValue(forKey: path)
                return .promote
            }
            let limit = hasTempSuffix(name) ? watchTempFor : watchFor
            if now - c.since >= limit {
                candidates.removeValue(forKey: path)
                remember(path, bytes)
                return .ignore
            }
            return .watch
        }
        // first sighting
        if warming && !hasTempSuffix(name) {
            remember(path, bytes)
            return .ignore
        }
        if candidates.count >= candidateCap {
            remember(path, bytes)
            return .ignore
        }
        candidates[path] = (bytes, now)
        return .watch
    }

    /// A temp-suffix row vanished: its final name is coming. "a.zip.crdownload" → "a.zip".
    public mutating func expect(finalPath: String, now: Double) {
        expected = expected.filter { now - $0.value < 30 }
        if expected.count < 50 { expected[finalPath] = now }
    }

    /// A file that is a row (or was dismissed) goes back to the baseline at its current size.
    public mutating func settle(path: String, bytes: Double) {
        candidates.removeValue(forKey: path)
        remember(path, bytes)
    }

    public mutating func forget(path: String) {
        candidates.removeValue(forKey: path)
        baseline.removeValue(forKey: path)
    }

    /// Promoted by something other than growth (an NSProgress publisher).
    public mutating func promote(path: String) {
        candidates.removeValue(forKey: path)
        baseline.removeValue(forKey: path)
    }

    public mutating func reset() {
        baseline.removeAll()
        candidates.removeAll()
        expected.removeAll()
    }

    private mutating func remember(_ path: String, _ bytes: Double) {
        if baseline.count >= baselineCap { baseline.removeAll() }
        baseline[path] = bytes
    }
}

/// The wing shows a finished transfer for this long, then goes back to its normal content.
public let wingDoneSeconds = 6.0
/// A finished or missing row stays in the open tray this long. Reveal or × removes it at once.
public let trayDoneSeconds = 120.0

public func wingShowsTransfer(_ t: Transfer, now: Double) -> Bool {
    if t.state == "active" { return true }
    if t.state == "done", let at = t.doneAt { return now - at < wingDoneSeconds }
    return false
}

public func trayKeepsTransfer(_ t: Transfer, now: Double) -> Bool {
    if t.state == "active" { return true }
    let at = t.doneAt ?? t.updatedAt
    return now - at < trayDoneSeconds
}

public struct TransferDisplay: Equatable {
    /// rows for the open tray, at most three (active first)
    public var tray: [Transfer]
    /// the row the compact wing shows, or nil (the wing shows its normal content)
    public var wing: Transfer?
    /// when this answer next changes on its own (a done window ends), seconds since 1970
    public var nextChange: Double?

    public init(tray: [Transfer], wing: Transfer?, nextChange: Double?) {
        self.tray = tray
        self.wing = wing
        self.nextChange = nextChange
    }
}

public func transferDisplay(_ all: [Transfer], now: Double) -> TransferDisplay {
    let kept = all.filter { trayKeepsTransfer($0, now: now) }
    let tray = visibleTransfers(kept)
    let wingRows = kept.filter { wingShowsTransfer($0, now: now) }
    let wing = visibleTransfers(wingRows).first
    var next: Double?
    func consider(_ t: Double) {
        guard t > now else { return }
        next = min(next ?? t, t)
    }
    for t in kept where t.state != "active" {
        let at = t.doneAt ?? t.updatedAt
        if t.state == "done", t.doneAt != nil { consider(at + wingDoneSeconds) }
        consider(at + trayDoneSeconds)
    }
    return TransferDisplay(tray: tray, wing: wing, nextChange: next)
}

/// Rows in a stable order, so two lists can be compared regardless of dictionary order.
public func transferSnapshot(_ list: [Transfer]) -> [Transfer] {
    list.sorted { $0.id < $1.id }
}

/// The watcher publishes only when this is true (or an event goes with it).
public func transfersChanged(_ old: [Transfer], _ new: [Transfer]) -> Bool {
    transferSnapshot(old) != transferSnapshot(new)
}

/// "a.zip.crdownload" → "a.zip"; nil when the name has no temp suffix.
public func finalNameForTemp(_ path: String) -> String? {
    guard hasTempSuffix(URL(fileURLWithPath: path).lastPathComponent) else { return nil }
    let url = URL(fileURLWithPath: path)
    let stripped = url.deletingPathExtension()
    guard !stripped.lastPathComponent.isEmpty else { return nil }
    return stripped.path
}
