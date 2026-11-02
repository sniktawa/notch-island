import Foundation

// The line protocol: one JSON object per line on stdin (host → helper) and stdout (helper → host).
//
// Host → helper:
//   {"t":"view","view":{...IslandView...}}   what the island should show
//   {"t":"tray","open":true}                 the host's own panel is open below the island: become its top edge
//   {"t":"tray","open":true,"w":520,"h":236} v0.2.0: become the tray itself (w × notch+h, rounded), springing open;
//                                             the host's transparent content sits on top and fades in after
//   {"t":"tray","open":false}                close (the host takes its content out first)
//   {"t":"ping"}                             → {"ev":"pong"}
//   {"t":"quit"}                             exit
// Helper → host:
//   {"ev":"ready","v":1,"notch":{"w":185,"h":32,"has":true},"hz":120,"caps":["traySize","peek"],"version":"0.2.0"}
//   {"ev":"screen","notch":{...}}            re-anchored (display, Space or wake change)
//   {"ev":"hover"} / {"ev":"leave"}          the cursor rested on the island / left it
//   {"ev":"click"}                           a click on the island (not on a button)
//   {"ev":"action","id":"allow|deny|always|join","ask":"<id>"}
//   {"ev":"pong"} / {"ev":"log","msg":"..."}
// Closing stdin (the host quit or crashed) makes the helper exit.

public let protocolVersion = 1
public let helperVersion = "0.2.0"
/// what this build can do beyond protocol 1 (the host checks these before relying on them)
public let capabilities = ["traySize", "peek"]

public struct AskInfo: Codable, Equatable {
    public var id: String
    public var question: String
    public var allow: String
    public var deny: String
    public var always: String?
    public var keys: String?

    public init(id: String, question: String, allow: String = "Allow", deny: String = "Deny", always: String? = nil, keys: String? = nil) {
        self.id = id
        self.question = question
        self.allow = allow
        self.deny = deny
        self.always = always
        self.keys = keys
    }
}

public struct MeetingInfo: Codable, Equatable {
    public var title: String
    public var when: String
    public var join: Bool?

    public init(title: String, when: String, join: Bool? = nil) {
        self.title = title
        self.when = when
        self.join = join
    }
}

/// What the island shows. `mode`: rest | deck | ask | meeting. Compact unless `open` (or the cursor rests on it).
public struct IslandView: Codable, Equatable {
    public var mode: String
    /// kind of work: read | edit | run | search | web | plan | think | done | error | ask | meet
    public var glyph: String?
    /// short word in the compact right wing when there is no clock ("Allow?", "4 min")
    public var word: String?
    /// grey line: what it just did
    public var last: String?
    /// white line: what it is doing now ("Done · 0:42" when finished)
    public var now: String?
    /// epoch milliseconds; the compact wing shows the live elapsed time from here
    public var startedAt: Double?
    /// epoch milliseconds; set when the work finished (the clock stops)
    public var endedAt: Double?
    public var open: Bool?
    public var ask: AskInfo?
    public var meeting: MeetingInfo?

    public init(mode: String = "rest", glyph: String? = nil, word: String? = nil, last: String? = nil, now: String? = nil, startedAt: Double? = nil, endedAt: Double? = nil, open: Bool? = nil, ask: AskInfo? = nil, meeting: MeetingInfo? = nil) {
        self.mode = mode
        self.glyph = glyph
        self.word = word
        self.last = last
        self.now = now
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.open = open
        self.ask = ask
        self.meeting = meeting
    }

    public static let rest = IslandView(mode: "rest")
    public var isRest: Bool { mode != "deck" && mode != "ask" && mode != "meeting" }
}

public enum Inbound: Equatable {
    case view(IslandView)
    case tray(Bool)
    /// v0.2.0: open as the tray itself, w × h below the notch
    case traySized(w: Double, h: Double)
    case ping
    case quit
}

private struct Envelope: Decodable {
    let t: String
    let view: IslandView?
    let open: Bool?
    let w: Double?
    let h: Double?
}

/// One line from the host → a message, or nil when it isn't one (ignored, never fatal).
public func decodeInbound(_ line: String) -> Inbound? {
    let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty, let data = s.data(using: .utf8) else { return nil }
    guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
    switch env.t {
    case "view":
        guard let v = env.view else { return nil }
        return .view(v)
    case "tray":
        if env.open == true, let h = env.h, h > 0 { return .traySized(w: env.w ?? Layout.trayW, h: h) }
        return .tray(env.open ?? false)
    case "ping":
        return .ping
    case "quit":
        return .quit
    default:
        return nil
    }
}

/// One event → one JSON line (no trailing newline). Keys sorted so output is stable.
public func encodeEvent(_ ev: String, _ fields: [String: Any] = [:]) -> String {
    var o = fields
    o["ev"] = ev
    guard JSONSerialization.isValidJSONObject(o),
          let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
          let s = String(data: d, encoding: .utf8)
    else { return "{\"ev\":\"\(ev)\"}" }
    return s
}

/// Splits a byte stream into lines (LF), keeping a partial last line until it is complete.
public struct LineBuffer {
    private var pending = Data()
    public let maxLine: Int

    public init(maxLine: Int = 1 << 20) { self.maxLine = maxLine }

    public mutating func feed(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var out: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<nl]
            if let s = String(data: lineData, encoding: .utf8) { out.append(s) }
            pending.removeSubrange(pending.startIndex...nl)
        }
        if pending.count > maxLine { pending.removeAll() } // a runaway line is dropped, not buffered forever
        return out
    }
}
