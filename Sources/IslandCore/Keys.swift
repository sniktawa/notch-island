import Foundation

/// One chord parsed from an ask card's `keys` caption. Order is allow, then deny, then always.
public struct KeyChord: Equatable {
    public var action: String
    public var key: String
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public var command: Bool

    public init(action: String, key: String, control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false) {
        self.action = action
        self.key = key
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }
}

/// "⌃⌥Y · ⌃⌥N" → allow on control-option-Y, deny on control-option-N.
/// The caption used to be paint. The helper registers these chords only while that ask card is showing.
public func parseKeyCaption(_ caption: String) -> [KeyChord] {
    let parts = caption.split { ch in
        ch == "·" || ch == "," || ch == "|" || ch == "/"
    }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    let actions = ["allow", "deny", "always"]
    var out: [KeyChord] = []
    for (i, part) in parts.enumerated() {
        guard i < actions.count, let key = lastKeyCharacter(in: part) else { continue }
        let lower = part.lowercased()
        out.append(KeyChord(
            action: actions[i],
            key: key,
            control: part.contains("⌃") || lower.contains("ctrl") || lower.contains("control"),
            option: part.contains("⌥") || lower.contains("opt") || lower.contains("alt"),
            shift: part.contains("⇧") || lower.contains("shift"),
            command: part.contains("⌘") || lower.contains("cmd") || lower.contains("command")
        ))
    }
    return out
}

func lastKeyCharacter(in part: String) -> String? {
    let letters = part.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    guard let last = letters.last else { return nil }
    return String(Character(last)).lowercased()
}
