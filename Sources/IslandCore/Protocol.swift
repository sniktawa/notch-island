import Foundation

// The line protocol: one JSON object per line on stdin (host → helper) and stdout (helper → host).
//
// Host → helper:
//   {"t":"view","view":{...IslandView...}}   what the island should show
//   {"t":"tray","open":true}                 the host's own panel is open below the island: become its top edge
//   {"t":"tray","open":true,"w":520,"h":236} v0.2.0: become the tray itself (w × notch+h, rounded)
//   {"t":"tray","open":false}                close (the host takes its content out first)
//   {"t":"shelfDir","path":"..."}            v0.3.0: where parked files are copied
//   {"t":"shelf","items":[...]}              v0.3.0: restore chips (paths must sit inside shelfDir)
//   {"t":"captureText","id":"c1","text":"...","partial":true}
//   {"t":"watch","dirs":["..."]}             v0.3.0: export / download / drive folders. Empty → Downloads.
//   {"t":"ping"}                             → {"ev":"pong"}
//   {"t":"quit"}                             exit
// Helper → host:
//   {"ev":"ready",...,"caps":[...],"version":"0.3.0","frame":{...},"display":1,"scale":2}
//   {"ev":"screen",...}                      re-anchored, same frame fields (AppKit points, origin bottom-left)
//   {"ev":"settled","w":520,"h":268}         the open spring finished
//   {"ev":"hover"} / {"ev":"leave"} / {"ev":"click"}
//   {"ev":"action","id":"allow|deny|always|join|open|reveal","ask":"<id>"}
//   {"ev":"shelf","op":"add|remove|dragged|missing","id":"...","name":"...","path":"...","bytes":1,"origin":"..."}
//                                            (0.3.3: `origin` = where a copied drop came from; absent for links/restores)
//   {"ev":"capture","op":"open|submit|speech|cancel","id":"...","text":"...","shelf":"...","on":true}
//   {"ev":"progress","id":"...","state":"active|done|missing","kind":"export|download|drive|airdrop",...}
//   {"ev":"pong"}
// Closing stdin (the host quit or crashed) makes the helper exit.
//
// Brain keeps the mail, the ledger, and the microphone. A tap on Allow is the only approve signal this
// process emits. It never sends, books, or pays.

public let protocolVersion = 1
public let helperVersion = "0.3.3"
/// what this build can do beyond protocol 1 (the host checks these before relying on them)
public let capabilities = ["traySize", "peek", "peekText", "countdown", "screenFrame", "settled", "moves", "shelf", "capture", "progress"]

public let knownModes = ["rest", "deck", "ask", "meeting", "moves", "capture"]

public struct AskInfo: Codable, Equatable {
    public var id: String
    public var question: String
    public var allow: String
    public var deny: String
    public var always: String?
    public var keys: String?
    /// one line of a drafted reply, shown above the buttons. The question stays the thing he approves.
    public var preview: String?

    public init(id: String, question: String, allow: String = "Allow", deny: String = "Deny", always: String? = nil, keys: String? = nil, preview: String? = nil) {
        self.id = id
        self.question = question
        self.allow = allow
        self.deny = deny
        self.always = always
        self.keys = keys
        self.preview = preview
    }
}

public struct MeetingInfo: Codable, Equatable {
    public var title: String
    public var when: String
    public var join: Bool?
    /// carried back on the join action so Brain opens this meeting
    public var id: String?
    /// epoch milliseconds. The wing counts down from here. `when` is the fallback string.
    public var startsAt: Double?
    /// the deal and the open promise. Revenue figures are stripped before display.
    public var brief: String?

    public init(title: String, when: String = "", join: Bool? = nil, id: String? = nil, startsAt: Double? = nil, brief: String? = nil) {
        self.title = title
        self.when = when
        self.join = join
        self.id = id
        self.startsAt = startsAt
        self.brief = brief
    }
}

public struct MoveInfo: Codable, Equatable {
    public var id: String
    public var title: String
    public var sub: String?
    /// email | text | money | meet | plan | note
    public var kind: String?

    public init(id: String, title: String, sub: String? = nil, kind: String? = nil) {
        self.id = id
        self.title = title
        self.sub = sub
        self.kind = kind
    }
}

public struct CaptureInfo: Codable, Equatable {
    public var id: String
    public var prompt: String?
    public var text: String?
    /// set when the sentence is about a parked file
    public var shelf: String?

    public init(id: String, prompt: String? = nil, text: String? = nil, shelf: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.text = text
        self.shelf = shelf
    }
}

public struct ShelfItem: Equatable {
    public var id: String
    public var name: String
    public var path: String
    public var bytes: Double
    public var linked: Bool
    public var missing: Bool
    /// 0.3.3: the dropped file's original path (copies only). Sent with `add` so the host can offer "Move instead"
    /// (trash the original after a verified copy). Not persisted: a restored shelf has no origin.
    public var origin: String?

    public init(id: String, name: String, path: String, bytes: Double = 0, linked: Bool = false, missing: Bool = false, origin: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.bytes = bytes
        self.linked = linked
        self.missing = missing
        self.origin = origin
    }

    /// The `shelf` event fields; `origin` only when known (older hosts ignore unknown keys).
    public func eventFields(_ op: String) -> [String: Any] {
        var f: [String: Any] = ["op": op, "id": id, "name": name, "path": path, "bytes": bytes, "linked": linked]
        if let origin, !origin.isEmpty { f["origin"] = origin }
        return f
    }
}

extension ShelfItem: Codable {
    enum CodingKeys: String, CodingKey { case id, name, path, bytes, linked, missing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        bytes = try c.decodeIfPresent(Double.self, forKey: .bytes) ?? 0
        linked = try c.decodeIfPresent(Bool.self, forKey: .linked) ?? false
        missing = try c.decodeIfPresent(Bool.self, forKey: .missing) ?? false
    }
}

/// What the island shows. `mode`: rest | deck | ask | meeting | moves | capture.
/// An unknown mode is not rest: it gets a deck-sized body that names the mode, so a newer host does not look idle.
/// Compact unless `open` (or the cursor rests on it).
public struct IslandView: Codable, Equatable {
    public var mode: String
    /// kind of work: read | edit | run | search | web | plan | think | done | error | ask | meet | money | text | shelf | capture | export
    public var glyph: String?
    /// short word in the compact right wing when there is no clock ("Allow?", "Paid?"). Currency amounts are stripped.
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
    /// v0.3.0: up to three morning rows
    public var moves: [MoveInfo]?
    /// v0.3.0: replaces "Nothing running" when the host sets it
    public var peek: String?
    /// v0.3.0: count drawn on the resting notch. A number of cards, never a dollar total.
    public var badge: Int?
    /// v0.3.0: the one-line capture field
    public var capture: CaptureInfo?

    public init(mode: String = "rest", glyph: String? = nil, word: String? = nil, last: String? = nil, now: String? = nil, startedAt: Double? = nil, endedAt: Double? = nil, open: Bool? = nil, ask: AskInfo? = nil, meeting: MeetingInfo? = nil, moves: [MoveInfo]? = nil, peek: String? = nil, badge: Int? = nil, capture: CaptureInfo? = nil) {
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
        self.moves = moves
        self.peek = peek
        self.badge = badge
        self.capture = capture
    }

    public static let rest = IslandView(mode: "rest")
    public var isKnown: Bool { knownModes.contains(mode) }
    /// Only a real rest. Unknown modes used to fall through here and say "Nothing running".
    public var isRest: Bool { mode == "rest" || mode.isEmpty }
}

public enum Inbound: Equatable {
    case view(IslandView)
    case tray(Bool)
    /// v0.2.0: open as the tray itself, w × h below the notch
    case traySized(w: Double, h: Double)
    case ping
    case quit
    case shelfDir(String)
    case shelf([ShelfItem])
    case captureText(id: String, text: String, partial: Bool)
    case watch([String])
}

private struct Envelope: Decodable {
    let t: String
    let view: IslandView?
    let open: Bool?
    let w: Double?
    let h: Double?
    let path: String?
    let items: [ShelfItem]?
    let dirs: [String]?
    let id: String?
    let text: String?
    let partial: Bool?
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
    case "shelfDir":
        guard let p = env.path, !p.isEmpty else { return nil }
        return .shelfDir(p)
    case "shelf":
        return .shelf(env.items ?? [])
    case "captureText":
        guard let id = env.id, let text = env.text else { return nil }
        return .captureText(id: id, text: text, partial: env.partial ?? false)
    case "watch":
        return .watch(env.dirs ?? [])
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

/// Fields for `ready` and `screen`. Coordinates are AppKit points, origin at the bottom left of the global desktop.
public func screenFields(notch: NotchMetrics, hz: Int, frameX: Double, frameY: Double, frameW: Double, frameH: Double, display: UInt32, scale: Double, displayX: Double, displayY: Double, displayW: Double, displayH: Double) -> [String: Any] {
    [
        "notch": ["w": notch.width, "h": notch.height, "has": notch.hasNotch] as [String: Any],
        "hz": hz,
        "frame": ["x": frameX, "y": frameY, "w": frameW, "h": frameH] as [String: Any],
        "display": display,
        "scale": scale,
        "displayFrame": ["x": displayX, "y": displayY, "w": displayW, "h": displayH] as [String: Any],
        "origin": "appkit-bottom-left",
    ]
}
