import Foundation

public struct Transfer: Equatable, Identifiable {
    public var id: String
    public var label: String
    public var path: String
    public var kind: String
    public var state: String
    public var bytes: Double
    public var total: Double?
    public var fraction: Double?
    public var updatedAt: Double
    /// true when NSProgress (not a guess) said the write finished
    public var publishedComplete: Bool
    /// v0.3.1: when the row became done (or missing), seconds since 1970. The wing shows it for a few seconds only.
    public var doneAt: Double?

    public init(id: String, label: String, path: String, kind: String, state: String, bytes: Double, total: Double? = nil, fraction: Double? = nil, updatedAt: Double = 0, publishedComplete: Bool = false, doneAt: Double? = nil) {
        self.id = id
        self.label = label
        self.path = path
        self.kind = kind
        self.state = state
        self.bytes = bytes
        self.total = total
        self.fraction = fraction
        self.updatedAt = updatedAt
        self.publishedComplete = publishedComplete
        self.doneAt = doneAt
    }
}

public struct GrowthSample: Equatable {
    public var name: String
    public var bytes: Double
    /// downloads | export | drive | other
    public var role: String
    public var quarantine: String?
    public var apps: [String]
    public var changed: Bool

    public init(name: String, bytes: Double, role: String, quarantine: String? = nil, apps: [String] = [], changed: Bool = true) {
        self.name = name
        self.bytes = bytes
        self.role = role
        self.quarantine = quarantine
        self.apps = apps
        self.changed = changed
    }
}

public func hasTempSuffix(_ name: String) -> Bool {
    let l = name.lowercased()
    return l.hasSuffix(".crdownload") || l.hasSuffix(".download") || l.hasSuffix(".part") || l.hasSuffix(".tmp")
}

public func isMediaName(_ name: String) -> Bool {
    let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
    return ext == "mov" || ext == "mp4" || ext == "mxf" || ext == "m4v"
}

public func exportAppIsRunning(_ names: [String]) -> Bool {
    names.contains { n in
        let l = n.lowercased()
        return l.contains("final cut") || l.contains("premiere") || l.contains("compressor")
    }
}

public func roleOfDir(_ dir: String) -> String {
    let l = dir.lowercased()
    if l.hasSuffix("/downloads") || l.hasSuffix("downloads") { return "downloads" }
    if l.contains("drive") || l.contains("cloudstorage") { return "drive" }
    return "export"
}

/// Mail and Messages stay unwatched. The root of the disk stays unwatched.
public func allowedWatchDir(_ path: String) -> Bool {
    let l = path.lowercased()
    if l.isEmpty || l == "/" || l == "/users" || l == "/home" { return false }
    if l.contains("/library/messages") || l.contains("/library/mail") { return false }
    return true
}

public func resolveWatchDirs(_ dirs: [String], downloads: String) -> [String] {
    let given = dirs.filter { allowedWatchDir($0) }
    if given.isEmpty { return allowedWatchDir(downloads) ? [downloads] : [] }
    return given
}

/// Longest configured directory that contains the file, then that directory's role.
public func roleForFile(_ path: String, dirs: [String]) -> String {
    let file = standardizePath(path)
    var best = ""
    var role = "other"
    for dir in dirs where allowedWatchDir(dir) {
        let d = standardizePath(dir)
        let prefix = d.hasSuffix("/") ? d : d + "/"
        if (file == d || file.hasPrefix(prefix)), d.count > best.count {
            best = d
            role = roleOfDir(d)
        }
    }
    return role
}

/// What a growing file is. Nil means it is not a transfer we show.
public func classifyGrowth(_ s: GrowthSample) -> String? {
    let temp = hasTempSuffix(s.name)
    let media = isMediaName(s.name)
    let q = (s.quarantine ?? "").lowercased()
    let airdrop = q.contains("sharingd")
    switch s.role {
    case "downloads":
        if !s.changed && !temp { return nil }
        if airdrop { return "airdrop" }
        return "download"
    case "export":
        if media && (s.changed || temp) { return "export" }
        return nil
    case "drive":
        if s.changed || temp { return "drive" }
        return nil
    default:
        if media && s.changed && exportAppIsRunning(s.apps) { return "export" }
        return nil
    }
}

/// A temp suffix is never done, even when the size sits still (a stalled export stays active).
/// Large media waits five seconds. Everything else waits three. The total is never invented.
public func isSettled(name: String, bytes: Double, stillSeconds: Double, media: Bool) -> Bool {
    if bytes <= 0 { return false }
    if hasTempSuffix(name) { return false }
    let need = (media && bytes > 3_000_000_000) ? 5.0 : 3.0
    return stillSeconds >= need
}

/// Active rows first, newest first, then done rows, three at most. A fourth waits.
public func visibleTransfers(_ all: [Transfer]) -> [Transfer] {
    let active = all.filter { $0.state == "active" }.sorted { $0.updatedAt > $1.updatedAt }
    let done = all.filter { $0.state == "done" }.sorted { $0.updatedAt > $1.updatedAt }
    return Array((active + done).prefix(3))
}

public func formatBytes(_ n: Double) -> String {
    if n < 0 { return "0 B" }
    if n < 1024 { return "\(Int(n)) B" }
    if n < 1024 * 1024 { return String(format: "%.0f KB", n / 1024) }
    if n < 1024 * 1024 * 1024 { return String(format: "%.1f MB", n / (1024 * 1024)) }
    return String(format: "%.1f GB", n / (1024 * 1024 * 1024))
}

/// Drive rows say "copied" unless a publisher actually reported completion.
public func doneWord(kind: String, publishedComplete: Bool) -> String {
    if kind == "drive" && !publishedComplete { return "copied" }
    return "done"
}
