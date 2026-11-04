import Foundation

public let shelfCap = 20
/// Files larger than this are parked by their original path. Copying a camera magazine would fill the disk.
public let shelfByteLimit: Double = 2_000_000_000

public enum ParkDecision: Equatable {
    case copy
    case link
    case refuse(String)
}

/// A folder or a package is one chip and is not walked. A huge file is linked, not copied. The shelf stops at 20.
public func decidePark(isDirectory: Bool, isPackage: Bool, bytes: Double, count: Int, aliasBroken: Bool = false) -> ParkDecision {
    if aliasBroken { return .refuse("broken alias") }
    if count >= shelfCap { return .refuse("shelf is full") }
    if isDirectory || isPackage { return .link }
    if bytes > shelfByteLimit { return .link }
    return .copy
}

public func uniqueShelfName(_ wanted: String, taken: Set<String>) -> String {
    if !taken.contains(wanted) { return wanted }
    let url = URL(fileURLWithPath: wanted)
    let ext = url.pathExtension
    let base = url.deletingPathExtension().lastPathComponent
    var n = 2
    while true {
        let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        if !taken.contains(candidate) { return candidate }
        n += 1
        if n > 10_000 { return "\(base) \(UUID().uuidString)" }
    }
}

/// True when `path` is a file inside `directory`, after resolving `.` and `..`. The directory itself does not count.
public func pathIsInside(_ path: String, directory: String) -> Bool {
    let dir = standardizePath(directory)
    let file = standardizePath(path)
    guard !dir.isEmpty, !file.isEmpty, file != dir else { return false }
    let prefix = dir.hasSuffix("/") ? dir : dir + "/"
    return file.hasPrefix(prefix)
}

public func standardizePath(_ path: String) -> String {
    let abs = path.hasPrefix("/")
    var parts: [String] = []
    for raw in path.split(separator: "/", omittingEmptySubsequences: true) {
        let p = String(raw)
        if p == "." { continue }
        if p == ".." {
            if !parts.isEmpty { parts.removeLast() }
            continue
        }
        parts.append(p)
    }
    let joined = parts.joined(separator: "/")
    return abs ? "/" + joined : joined
}

/// Brain may restore chips only for files that live in the shelf directory. Anything else is dropped.
public func shelfItemsInside(_ items: [ShelfItem], directory: String) -> [ShelfItem] {
    items.filter { pathIsInside($0.path, directory: directory) }
}
