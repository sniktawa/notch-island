import Foundation

/// "in 4 min", "now", "started". The wing ticks this locally so Brain does not push a view every second.
public func countdownLabel(startsAt: Double, now: Double) -> String {
    let sec = (startsAt - now) / 1000
    if sec <= -60 { return "started" }
    if sec <= 0 { return "now" }
    if sec < 45 { return "in \(max(1, Int(sec.rounded(.down))))s" }
    let min = Int((sec / 60).rounded())
    if min < 60 { return "in \(min) min" }
    let h = min / 60
    let m = min % 60
    if m == 0 { return "in \(h)h" }
    return "in \(h)h \(m)m"
}

/// Resting hover line. A badge wins over the hardcoded "Nothing running".
public func restPeekText(peek: String?, badge: Int?) -> String {
    let cleaned = redactMoney(peek ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleaned.isEmpty { return cleaned }
    if let b = badge, b > 0 { return b == 1 ? "1 move" : "\(b) moves" }
    return "Nothing running"
}

/// Compact wing and peek stay free of revenue figures. The open confirm question is left alone by the caller.
public func redactMoney(_ s: String) -> String {
    guard let re = try? NSRegularExpression(pattern: #"\$\s?\d[\d,]*(?:\.\d+)?|\bUSD\s*\d[\d,]*(?:\.\d+)?"#, options: [.caseInsensitive]) else { return s }
    let range = NSRange(s.startIndex..., in: s)
    var out = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
    out = out.replacingOccurrences(of: " ·", with: "")
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// True when the black shape has to spring. A text-only update (a capture partial, a new "now" line) does not.
public func shouldSpring(from old: IslandSize, to new: IslandSize) -> Bool {
    old != new
}
