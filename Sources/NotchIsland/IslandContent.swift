import AppKit
import IslandCore
import SwiftUI

/// What the SwiftUI content reads. Owned by the controller; changes animate.
final class IslandModel: ObservableObject {
    @Published var view: IslandView = .rest
    @Published var expanded = false
    @Published var tray = false
    /// v0.2.0: the host's tray height below the notch (nil = v0.1 flat edge)
    @Published var trayH: Double?
    @Published var trayW: Double = Layout.trayW
    @Published var notch = NotchMetrics(width: fakeNotchWidth, height: 32, hasNotch: false)
    @Published var shelf: [ShelfItem] = []
    /// v0.3.1: rows for the open rest body (active, then done for two minutes), at most three
    @Published var transfers: [Transfer] = []
    /// v0.3.1: the transfer the compact wing shows (active, or done for a few seconds), else nil
    @Published var wingTransfer: Transfer?
    @Published var dropHover = false
    /// a drag is over the island, or a drop just landed: hold the body open
    @Published var dropActive = false
    @Published var shelfMessage: String?
    @Published var captureDraft = ""
    @Published var focusCapture = false
    @Published var speechOn = false
    /// a finished transfer wants the body, and an approve card is in the way
    @Published var pingProgress = false

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onSpeech: ((Bool) -> Void)?
    var onOpenCapture: ((String?) -> Void)?
    var onReveal: ((String, String) -> Void)?
    var onRemoveShelf: ((String) -> Void)?
    var onDragShelf: ((String) -> Void)?
    var onShelfClick: ((String) -> Void)?
    var onDismissTransfer: ((String) -> Void)?

    var shownTransfers: [Transfer] { Array(transfers.prefix(RestBody.maxTransfers)) }

    var showsMessage: Bool { !(shelfMessage ?? "").isEmpty }

    /// Shelf thumbnails (one row) and transfer rows that are actually in the body. Only the rest body has them.
    var bodyExtras: (shelf: Int, transfers: Int) {
        guard expanded, !tray, view.isRest else { return (0, 0) }
        return (shelf.isEmpty ? 0 : 1, shownTransfers.count)
    }

    var size: IslandSize {
        let e = bodyExtras
        let message = expanded && !tray && view.isRest && showsMessage
        return islandSize(view, expanded: expanded, tray: tray, notch: notch, trayH: trayH, trayW: trayW, shelfRows: e.shelf, transferRows: e.transfers, dropHover: dropHover, forceWing: !shelf.isEmpty || wingTransfer != nil, messageRow: message)
    }

    var showsWings: Bool {
        !view.isRest || (view.badge ?? 0) > 0 || !shelf.isEmpty || wingTransfer != nil
    }
}

enum Emit {
    static func send(_ ev: String, _ fields: [String: Any] = [:]) {
        let line = encodeEvent(ev, fields) + "\n"
        if let d = line.data(using: .utf8) { FileHandle.standardOutput.write(d) }
    }
}

/// SF Symbol + colour for a kind of work.
func glyphStyle(_ g: String?) -> (String, Color) {
    switch g ?? "" {
    case "read": return ("doc.text", Color(red: 0.45, green: 0.68, blue: 1.0))
    case "edit": return ("pencil", Color(red: 1.0, green: 0.62, blue: 0.3))
    case "run": return ("terminal", Color(red: 0.4, green: 0.86, blue: 0.5))
    case "search": return ("magnifyingglass", Color(red: 0.74, green: 0.55, blue: 1.0))
    case "web": return ("globe", Color(red: 0.35, green: 0.82, blue: 0.86))
    case "plan": return ("list.bullet", Color(red: 1.0, green: 0.84, blue: 0.35))
    case "done": return ("checkmark", Color(red: 0.4, green: 0.86, blue: 0.5))
    case "error": return ("exclamationmark.triangle.fill", Color(red: 1.0, green: 0.42, blue: 0.4))
    case "ask": return ("hand.raised.fill", Color(red: 1.0, green: 0.62, blue: 0.3))
    case "meet": return ("video.fill", Color(red: 0.4, green: 0.86, blue: 0.5))
    case "money": return ("banknote", Color(red: 0.4, green: 0.86, blue: 0.5))
    case "text": return ("bubble.left.fill", Color(red: 0.45, green: 0.68, blue: 1.0))
    case "shelf": return ("tray.full", Color(red: 1.0, green: 0.62, blue: 0.3))
    case "capture": return ("square.and.pencil", Color(red: 1.0, green: 0.84, blue: 0.35))
    case "export": return ("film", Color(red: 0.74, green: 0.55, blue: 1.0))
    case "think": return ("brain", Color.white)
    default: return ("sparkle", Color.white)
    }
}

struct GlyphView: View {
    let glyph: String?
    let working: Bool
    @State private var dim = false

    var body: some View {
        let (name, color) = glyphStyle(glyph)
        Image(systemName: name)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(color)
            .opacity(working && dim ? 0.4 : 1)
            .onAppear {
                guard working else { return }
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

struct ClockView: View {
    let startedAt: Double
    let endedAt: Double?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1.0)) { ctx in
            let end = endedAt ?? ctx.date.timeIntervalSince1970 * 1000
            Text(elapsedText((end - startedAt) / 1000))
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Color.white.opacity(0.78))
        }
    }
}

struct CountdownView: View {
    let startsAt: Double

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1.0)) { ctx in
            Text(countdownLabel(startsAt: startsAt, now: ctx.date.timeIntervalSince1970 * 1000))
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Color.white.opacity(0.78))
                .lineLimit(1)
        }
    }
}

struct PillButton: ButtonStyle {
    var primary = false
    var outline = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 24)
            .foregroundColor(primary ? .black : .white)
            .background(
                Capsule().fill(primary ? Color.white : (outline ? Color.clear : Color.white.opacity(0.16)))
            )
            .overlay(Capsule().stroke(Color.white.opacity(outline ? 0.35 : 0), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct IslandContent: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let s = model.size
        let v = model.view
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                topRow(v)
                    .frame(height: model.notch.height)
                if model.expanded && !model.tray {
                    detail(v)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
                Spacer(minLength: 0)
            }
            .frame(width: s.w, height: s.h, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { Emit.send("click") }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: model.expanded)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: v.mode)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    func topRow(_ v: IslandView) -> some View {
        if !model.showsWings {
            Color.clear
        } else {
            HStack(spacing: 0) {
                GlyphView(glyph: wingGlyph(v), working: v.endedAt == nil && v.mode == "deck")
                    .id(wingGlyph(v) ?? "")
                    .frame(width: Layout.wing - 8, alignment: .center)
                Spacer(minLength: model.notch.width)
                rightWing(v)
                    .frame(width: Layout.wing - 8, alignment: .center)
            }
            .padding(.horizontal, 4)
        }
    }

    func wingGlyph(_ v: IslandView) -> String? {
        if let g = v.glyph, !g.isEmpty { return g }
        if v.mode == "meeting" { return "meet" }
        if v.mode == "ask" { return "ask" }
        if v.mode == "moves" { return "plan" }
        if v.mode == "capture" { return "capture" }
        if model.wingTransfer != nil { return "export" }
        if !model.shelf.isEmpty { return "shelf" }
        return nil
    }

    /// Meeting countdown, then a transfer bar, then the shelf count, then the move count, then the host's word.
    @ViewBuilder
    func rightWing(_ v: IslandView) -> some View {
        if v.mode == "meeting", let start = v.meeting?.startsAt {
            CountdownView(startsAt: start)
        } else if let t = model.wingTransfer {
            VStack(spacing: 2) {
                Text(t.state == "done" ? doneWord(kind: t.kind, publishedComplete: t.publishedComplete) : t.label)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.78))
                    .lineLimit(1)
                TransferBar(fraction: t.state == "done" ? 1 : t.fraction)
                    .frame(height: 2)
            }
        } else if !model.shelf.isEmpty {
            Text("\(model.shelf.count)")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Color.white.opacity(0.78))
        } else if v.isRest, let b = v.badge, b > 0 {
            Text("\(b)")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Color.white.opacity(0.78))
        } else if let start = v.startedAt {
            ClockView(startedAt: start, endedAt: v.endedAt)
        } else if let w = v.word {
            let clean = redactMoney(w)
            Text(clean.isEmpty ? "" : clean)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundColor(Color.white.opacity(0.78))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    func detail(_ v: IslandView) -> some View {
        switch v.mode {
        case "ask":
            askDetail(v)
        case "meeting":
            meetingDetail(v)
        case "moves":
            movesDetail(v)
        case "capture":
            captureDetail(v)
        case "rest":
            restDetail(v)
        default:
            if v.isKnown {
                deckDetail(v)
            } else {
                Text("Can't show \(v.mode)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.7))
                    .lineLimit(1)
                    .padding(.horizontal, 20)
                    .padding(.top, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    func askDetail(_ v: IslandView) -> some View {
        if let a = v.ask {
            VStack(alignment: .leading, spacing: 8) {
                Text(a.question)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let preview = a.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
                HStack(spacing: 7) {
                    Button(a.allow) { Emit.send("action", ["id": "allow", "ask": a.id]) }
                        .buttonStyle(PillButton(primary: true))
                    Button(a.deny) { Emit.send("action", ["id": "deny", "ask": a.id]) }
                        .buttonStyle(PillButton())
                    if let al = a.always {
                        Button(al) { Emit.send("action", ["id": "always", "ask": a.id]) }
                            .buttonStyle(PillButton(outline: true))
                    }
                    Spacer(minLength: 4)
                    if let k = a.keys {
                        Text(k)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    func meetingDetail(_ v: IslandView) -> some View {
        if let m = v.meeting {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if let start = m.startsAt {
                            CountdownView(startsAt: start)
                        } else {
                            Text(redactMoney(m.when))
                                .font(.system(size: 11.5))
                                .foregroundColor(Color.white.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    if m.join == true {
                        Button("Join") {
                            var fields: [String: Any] = ["id": "join"]
                            if let id = m.id, !id.isEmpty { fields["ask"] = id }
                            Emit.send("action", fields)
                        }
                        .buttonStyle(PillButton(primary: true))
                    }
                }
                if let brief = m.brief {
                    let clean = redactMoney(brief)
                    if !clean.isEmpty {
                        Text(clean)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color.white.opacity(0.62))
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    func movesDetail(_ v: IslandView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array((v.moves ?? []).prefix(3).enumerated()), id: \.element.id) { _, m in
                Button {
                    Emit.send("action", ["id": "open", "ask": m.id])
                } label: {
                    HStack(spacing: 8) {
                        GlyphView(glyph: m.kind ?? "plan", working: false)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(redactMoney(m.title))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            if let sub = m.sub {
                                let clean = redactMoney(sub)
                                if !clean.isEmpty {
                                    Text(clean)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.white.opacity(0.5))
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: Layout.moveRow - 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func captureDetail(_ v: IslandView) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let id = v.capture?.shelf, let item = model.shelf.first(where: { $0.id == id }) {
                ShelfChip(item: item, showsName: false, onRemove: {}, onDragged: { model.onDragShelf?(item.id) }, onClick: {})
                    .frame(width: RestBody.tile, height: RestBody.tile)
            }
            captureFields(v)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func captureFields(_ v: IslandView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(v.capture?.prompt ?? "Note, to-do, or reminder")
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.45))
                .lineLimit(1)
            HStack(spacing: 8) {
                CaptureField(text: $model.captureDraft, focused: model.focusCapture, onSubmit: {
                    model.onSubmit?(model.captureDraft)
                }, onCancel: {
                    model.onCancel?()
                })
                .frame(height: 22)
                MicButton(on: model.speechOn) { down in
                    model.onSpeech?(down)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every piece has the height `restBodyHeight` counts, so the shape always fits what is drawn.
    @ViewBuilder
    func restDetail(_ v: IslandView) -> some View {
        VStack(alignment: .leading, spacing: RestBody.gap) {
            Text(restPeekText(peek: v.peek, badge: v.badge))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Color.white.opacity(0.5))
                .lineLimit(1)
                .frame(height: RestBody.line)
            if let msg = model.shelfMessage, !msg.isEmpty {
                Text(msg)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.7))
                    .lineLimit(1)
                    .frame(height: RestBody.line)
            }
            transferRows
            shelfStrip
            Button("Note") { model.onOpenCapture?(nil) }
                .buttonStyle(PillButton())
                .frame(height: RestBody.button)
        }
        .padding(.horizontal, 16)
        .padding(.top, RestBody.topPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func deckDetail(_ v: IslandView) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let last = v.last, !last.isEmpty {
                Text(redactMoney(last))
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.48))
                    .lineLimit(1)
            }
            Text(redactMoney(v.now ?? ""))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    var transferRows: some View {
        ForEach(model.shownTransfers) { t in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(transferCaption(t))
                        .font(.system(size: 10.5))
                        .foregroundColor(Color.white.opacity(0.5))
                        .lineLimit(1)
                    TransferBar(fraction: t.state == "done" ? 1 : t.fraction)
                        .frame(height: 3)
                }
                if t.state == "done" || t.state == "missing" {
                    Button(t.state == "missing" ? "Missing" : "Reveal") {
                        model.onReveal?(t.id, t.path)
                    }
                    .buttonStyle(PillButton(primary: t.state == "done"))
                    .disabled(t.state == "missing")
                    Button {
                        model.onDismissTransfer?(t.id)
                    } label: {
                        Text("×")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.6))
                            .frame(width: 16, height: 24)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: RestBody.transferRow)
            .clipped()
        }
    }

    func transferCaption(_ t: Transfer) -> String {
        let amount = formatBytes(t.bytes)
        if t.state == "missing" { return "missing" }
        if t.state == "done" { return "\(doneWord(kind: t.kind, publishedComplete: t.publishedComplete)) · \(amount)" }
        if let total = t.total, total > 0 { return "\(amount) / \(formatBytes(total))" }
        return "\(t.kind) · \(amount)"
    }

    /// v0.3.1: one row of thumbnails (images and videos show a real frame), the name under each, × on hover.
    @ViewBuilder
    var shelfStrip: some View {
        if !model.shelf.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(model.shelf.suffix(RestBody.maxTiles).reversed().enumerated()), id: \.element.id) { _, item in
                    ShelfChip(item: item, showsName: true, onRemove: { model.onRemoveShelf?(item.id) }, onDragged: { model.onDragShelf?(item.id) }, onClick: { model.onShelfClick?(item.id) })
                        .frame(width: RestBody.tileW, height: RestBody.shelfRow)
                }
                if model.shelf.count > RestBody.maxTiles {
                    Text("+\(model.shelf.count - RestBody.maxTiles)")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundColor(Color.white.opacity(0.6))
                        .frame(height: RestBody.tile)
                }
                Spacer(minLength: 0)
            }
            .frame(height: RestBody.shelfRow)
        }
    }
}

struct TransferBar: View {
    var fraction: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                if let fraction {
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
                } else {
                    Capsule().fill(Color.white.opacity(0.45))
                        .frame(width: geo.size.width * 0.35)
                }
            }
        }
    }
}

/// AppKit field so the panel can become key for one sentence and then give focus back.
struct CaptureField: NSViewRepresentable {
    @Binding var text: String
    var focused: Bool
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.placeholderString = "Type, then Return"
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Capture")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
        if field.stringValue != text { field.stringValue = text }
        guard focused, let window = field.window else { return }
        if window.firstResponder !== field && window.firstResponder !== field.currentEditor() {
            window.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onSubmit: () -> Void
        var onCancel: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                return true
            }
            return false
        }
    }
}

struct MicButton: NSViewRepresentable {
    var on: Bool
    var press: (Bool) -> Void

    func makeNSView(context: Context) -> MicHoldView {
        let v = MicHoldView()
        v.press = press
        v.on = on
        return v
    }

    func updateNSView(_ view: MicHoldView, context: Context) {
        view.press = press
        view.on = on
    }
}

/// Hold to talk. Mouse down starts, mouse up stops. Brain owns the microphone.
final class MicHoldView: NSView {
    var press: (Bool) -> Void = { _ in }
    var on = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let color = on ? NSColor.systemYellow : NSColor.white.withAlphaComponent(0.85)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color,
        ]
        let s = "Mic" as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        press(true)
        window?.trackEvents(matching: [.leftMouseUp, .leftMouseDragged], timeout: .infinity, mode: .eventTracking) { ev, stop in
            if ev?.type == .leftMouseUp {
                self.press(false)
                stop.pointee = true
            }
        }
    }
}

struct ShelfChip: NSViewRepresentable {
    var item: ShelfItem
    var showsName = true
    var onRemove: () -> Void
    var onDragged: () -> Void
    var onClick: () -> Void

    func makeNSView(context: Context) -> ShelfChipView {
        let v = ShelfChipView()
        v.onRemove = onRemove
        v.onDragged = onDragged
        v.onClick = onClick
        v.showsName = showsName
        v.item = item
        return v
    }

    func updateNSView(_ view: ShelfChipView, context: Context) {
        view.onRemove = onRemove
        view.onDragged = onDragged
        view.onClick = onClick
        view.showsName = showsName
        view.item = item
    }
}

/// The first click lands even though the helper is not the active app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
