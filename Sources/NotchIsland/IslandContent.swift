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

    var size: IslandSize { islandSize(view, expanded: expanded, tray: tray, notch: notch, trayH: trayH, trayW: trayW) }
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
                if model.expanded && !model.tray && !v.isRest {
                    detail(v)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
                if model.expanded && !model.tray && v.isRest {
                    // v0.2.0: the peek when nothing is running (runs, permissions and meetings bring their own lines)
                    Text("Nothing running")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.5))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                        .transition(.opacity)
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
        if v.isRest {
            Color.clear
        } else {
            HStack(spacing: 0) {
                GlyphView(glyph: v.glyph, working: v.endedAt == nil && v.mode == "deck")
                    .id(v.glyph ?? "")
                    .frame(width: Layout.wing - 8, alignment: .center)
                Spacer(minLength: model.notch.width)
                Group {
                    if let start = v.startedAt {
                        ClockView(startedAt: start, endedAt: v.endedAt)
                    } else if let w = v.word {
                        Text(w)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.78))
                            .lineLimit(1)
                    }
                }
                .frame(width: Layout.wing - 8, alignment: .center)
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    func detail(_ v: IslandView) -> some View {
        switch v.mode {
        case "ask":
            if let a = v.ask {
                VStack(alignment: .leading, spacing: 9) {
                    Text(a.question)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
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
        case "meeting":
            if let m = v.meeting {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(m.when)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if m.join == true {
                        Button("Join") { Emit.send("action", ["id": "join"]) }
                            .buttonStyle(PillButton(primary: true))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            VStack(alignment: .leading, spacing: 3) {
                if let last = v.last, !last.isEmpty {
                    Text(last)
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.48))
                        .lineLimit(1)
                }
                Text(v.now ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The first click lands even though the helper is never the active app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
