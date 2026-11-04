import AppKit
import IslandCore
import QuartzCore
import SwiftUI

/// A borderless panel. It becomes key only while the capture field is open, then it gives focus back.
final class IslandPanel: NSPanel {
    var allowsKey: () -> Bool = { false }
    override var canBecomeKey: Bool { allowsKey() }
    override var canBecomeMain: Bool { false }
}

/// The black island itself: a CAShapeLayer-backed view that never takes clicks.
final class ShapeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shapeLayer.fillColor = NSColor.black.cgColor
        shapeLayer.actions = ["path": NSNull()]
    }

    required init?(coder: NSCoder) { nil }
    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
    var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The panel's root view: a tracking area reports moves / exits while the island takes clicks (while it is
/// click-through, the global mouse monitor does the same job).
final class TrackingView: NSView {
    var onMouse: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onMouse?() }
    override func mouseExited(with event: NSEvent) { onMouse?() }
    override func mouseMoved(with event: NSEvent) { onMouse?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

func cgPath(_ ops: [PathOp]) -> CGPath {
    let p = CGMutablePath()
    for op in ops {
        switch op {
        case let .move(x, y):
            p.move(to: CGPoint(x: x, y: y))
        case let .line(x, y):
            p.addLine(to: CGPoint(x: x, y: y))
        case let .curve(c1x, c1y, c2x, c2y, x, y):
            p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
        case .close:
            p.closeSubpath()
        }
    }
    return p
}

final class IslandController {
    let model = IslandModel()
    let shelf = ShelfStore()
    let watch = TransferWatch()
    let hotkeys = AskHotKeys()
    var panel: IslandPanel!
    var shapeView: ShapeView!
    var dragHost: DragHostView!
    var contentView: NSView!
    let maskLayer = CAShapeLayer()
    var gate = HoverGate()
    var hz: Int = 60
    var accepting = false
    var lastSize: IslandSize?
    var recheckGen = 0
    var settleGen = 0
    var observers: [NSObjectProtocol] = []
    var wsObservers: [NSObjectProtocol] = []
    var monitors: [Any] = []
    var readBuffer = LineBuffer()
    var deferred: IslandView?
    var heldDone: [String] = []
    var previousApp: NSRunningApplication?
    var screen: NSScreen?
    let canvas = NSSize(width: Layout.canvasW, height: Layout.canvasH)

    func start() {
        let frame = NSRect(origin: .zero, size: canvas)
        panel = IslandPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.allowsKey = { [weak self] in
            guard let self else { return false }
            return self.model.focusCapture && self.model.view.mode == "capture"
        }
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        let root = TrackingView(frame: frame)
        root.wantsLayer = true
        root.onMouse = { [weak self] in self?.updateMouse() }
        shapeView = ShapeView(frame: frame)
        shapeView.autoresizingMask = [.width, .height]
        root.addSubview(shapeView)

        dragHost = DragHostView(frame: frame)
        dragHost.autoresizingMask = [.width, .height]
        dragHost.wantsLayer = true
        dragHost.entered = { [weak self] in self?.setDropHover(true) }
        dragHost.exited = { [weak self] in self?.setDropHover(false) }
        dragHost.droppedFiles = { [weak self] urls in self?.receiveFiles(urls) }
        dragHost.droppedPromises = { [weak self] receivers in self?.receivePromises(receivers) }
        maskLayer.fillColor = NSColor.black.cgColor
        maskLayer.frame = CGRect(origin: .zero, size: canvas)
        maskLayer.actions = ["path": NSNull()]
        dragHost.layer?.mask = maskLayer
        let host = FirstMouseHostingView(rootView: IslandContent(model: model))
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        dragHost.addSubview(host)
        contentView = dragHost
        root.addSubview(dragHost)
        panel.contentView = root

        wireModel()
        watch.onChange = { [weak self] list, event in self?.transfersChanged(list, event) }
        hotkeys.onFire = { [weak self] action, ask in
            self?.EmitAction(action, ask: ask)
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Brain/shelf").path
        shelf.setDirectory(fallback)
        watch.shelfDirectory = fallback
        anchor(force: true)
        apply(animated: false)
        panel.orderFrontRegardless()
        watchScreens()
        watchMouse()
        readStdin()
        var ready = screenPayload()
        ready["v"] = protocolVersion
        ready["caps"] = capabilities
        ready["version"] = helperVersion
        Emit.send("ready", ready)
        // Downloads until Brain sends a watch list.
        watch.setDirs([])
    }

    func wireModel() {
        model.onSubmit = { [weak self] text in self?.submitCapture(text) }
        model.onCancel = { [weak self] in self?.cancelCapture() }
        model.onSpeech = { [weak self] on in self?.toggleSpeech(on) }
        model.onOpenCapture = { [weak self] shelf in self?.openCapture(shelf: shelf) }
        model.onReveal = { [weak self] id, path in self?.reveal(id: id, path: path) }
        model.onRemoveShelf = { [weak self] id in self?.removeShelf(id) }
        model.onDragShelf = { [weak self] id in
            guard let self, let item = self.shelf.item(id) else { return }
            var fields: [String: Any] = ["op": "dragged", "id": id, "name": item.name, "path": item.path, "bytes": item.bytes]
            Emit.send("shelf", fields)
        }
        model.onShelfClick = { [weak self] id in self?.openCapture(shelf: id) }
    }

    func EmitAction(_ id: String, ask: String) {
        Emit.send("action", ["id": id, "ask": ask])
    }

    // MARK: screens

    func pickScreen() -> NSScreen? {
        if let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }

    func metrics(_ s: NSScreen) -> NotchMetrics {
        let top = Double(s.safeAreaInsets.top)
        let lw = Double(s.auxiliaryTopLeftArea?.width ?? 0)
        let rw = Double(s.auxiliaryTopRightArea?.width ?? 0)
        let menuBar = Double(s.frame.maxY - s.visibleFrame.maxY)
        return notchMetrics(screenWidth: Double(s.frame.width), topInset: top, leftAux: lw, rightAux: rw, menuBar: menuBar)
    }

    func screenPayload() -> [String: Any] {
        let s = screen ?? pickScreen()
        let f = panel?.frame ?? .zero
        let d = s?.frame ?? .zero
        let id = (s?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let scale = s.map { Double($0.backingScaleFactor) } ?? 1
        return screenFields(notch: model.notch, hz: hz, frameX: Double(f.minX), frameY: Double(f.minY), frameW: Double(f.width), frameH: Double(f.height), display: id, scale: scale, displayX: Double(d.minX), displayY: Double(d.minY), displayW: Double(d.width), displayH: Double(d.height))
    }

    /// Keep the canvas centred on the notch, flush with the top of the notched (else main) screen.
    func anchor(force: Bool = false) {
        guard let s = pickScreen() else { return }
        screen = s
        let m = metrics(s)
        hz = max(60, s.maximumFramesPerSecond)
        let want = NSRect(x: (s.frame.midX - canvas.width / 2).rounded(), y: s.frame.maxY - canvas.height, width: canvas.width, height: canvas.height)
        let moved = panel.frame != want
        if moved { panel.setFrame(want, display: true) }
        let changed = m != model.notch
        if changed { model.notch = m }
        if changed || moved || force {
            if !force {
                apply(animated: false)
                Emit.send("screen", screenPayload())
            }
        }
        panel.orderFrontRegardless()
    }

    func watchScreens() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.anchor()
        })
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wsObservers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.anchor()
                self?.watch.setDirs(self?.watch.dirs ?? [])
            })
        }
    }

    // MARK: shape

    /// Morph the island to the current state with a spring (interruptible: it starts from wherever it is now).
    func apply(animated: Bool) {
        let size = model.size
        guard shapeView != nil else { return }
        if animated, let last = lastSize, !shouldSpring(from: last, to: size) {
            updateMouse()
            return
        }
        let path = cgPath(islandPath(size, canvasW: Double(canvas.width), canvasH: Double(canvas.height)))
        let hide = model.view.isRest && !model.tray && !model.notch.hasNotch && !gate.hovering && !model.showsWings
        let opening = (lastSize.map { size.w * size.h >= $0.w * $0.h } ?? true)
        lastSize = size
        var settleAfter: Double?
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [shapeView.shapeLayer, maskLayer] {
            let from = layer.presentation()?.path ?? layer.path
            layer.path = path
            if animated, let from = from {
                let a = CASpringAnimation(keyPath: "path")
                a.mass = 1
                a.stiffness = opening ? 230 : 320
                a.damping = opening ? 24 : 36
                a.initialVelocity = 0
                a.fromValue = from
                a.toValue = path
                a.duration = a.settlingDuration
                a.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: Float(hz), preferred: Float(hz))
                layer.add(a, forKey: "morph")
                if opening { settleAfter = a.settlingDuration }
            } else {
                layer.removeAnimation(forKey: "morph")
            }
        }
        CATransaction.commit()
        shapeView.alphaValue = hide ? 0 : 1
        contentView.alphaValue = hide ? 0 : 1
        if let settleAfter, animated, opening {
            scheduleSettled(size, after: settleAfter)
        } else {
            settleGen += 1
        }
        updateMouse()
        syncHotKeys()
    }

    func scheduleSettled(_ size: IslandSize, after: Double) {
        settleGen += 1
        let gen = settleGen
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self, gen == self.settleGen else { return }
            Emit.send("settled", ["w": size.w, "h": size.h])
        }
    }

    func relayout(animated: Bool) {
        let old = lastSize
        let new = model.size
        if let old, !shouldSpring(from: old, to: new) {
            updateMouse()
            return
        }
        apply(animated: animated)
    }

    func setView(_ v: IslandView) {
        if model.focusCapture && model.view.mode == "capture" && v.mode != "capture" {
            deferred = v
            return
        }
        if v.mode == "capture", let text = v.capture?.text, !text.isEmpty, model.captureDraft != text {
            model.captureDraft = text
        }
        let focus = v.mode == "capture" && (v.open ?? false)
        applyView(v, focus: focus)
    }

    func applyView(_ v: IslandView, focus: Bool) {
        let wasRest = model.view.isRest
        model.view = v
        if v.isRest != wasRest && v.isRest { gate.reset() }
        model.expanded = gate.hovering || (v.open ?? false) || model.pingProgress
        if focus { beginCaptureFocus() }
        relayout(animated: true)
        syncHotKeys()
        flushHeldDone()
    }

    func setTray(_ open: Bool, w: Double? = nil, h: Double? = nil) {
        let newH = open ? h : nil
        guard model.tray != open || model.trayH != newH || (w != nil && model.trayW != w!) else { return }
        model.tray = open
        model.trayH = newH
        if let w = w { model.trayW = w }
        if !open { gate.reset() }
        model.expanded = gate.hovering || (model.view.open ?? false) || model.pingProgress
        relayout(animated: true)
    }

    func setDropHover(_ on: Bool) {
        guard model.dropHover != on else { return }
        model.dropHover = on
        relayout(animated: true)
    }

    func syncHotKeys() {
        let ask = model.view.ask
        let enabled = model.view.mode == "ask" && (model.expanded || (model.view.open ?? false)) && !model.focusCapture
        hotkeys.sync(chords: parseKeyCaption(ask?.keys ?? ""), ask: ask?.id ?? "", enabled: enabled)
    }

    // MARK: capture

    func openCapture(shelf: String?) {
        let id = model.view.capture?.id ?? ("c" + String(UUID().uuidString.prefix(8)).lowercased())
        let prompt = shelf == nil ? "Note, to-do, or reminder" : "Send, file, or leave parked"
        var view = IslandView(mode: "capture", glyph: "capture", open: true, badge: model.view.badge, peek: model.view.peek, capture: CaptureInfo(id: id, prompt: prompt, text: model.captureDraft, shelf: shelf))
        if model.view.mode == "moves" { view.moves = model.view.moves }
        applyView(view, focus: true)
        var fields: [String: Any] = ["op": "open", "id": id]
        if let shelf { fields["shelf"] = shelf }
        Emit.send("capture", fields)
    }

    func beginCaptureFocus() {
        model.focusCapture = true
        if previousApp == nil {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.focusCapture else { return }
            self.panel.makeKey()
        }
    }

    func endCaptureFocus() {
        model.focusCapture = false
        model.speechOn = false
        panel.resignKey()
        if let app = previousApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            if #available(macOS 14.0, *) {
                app.activate(from: NSApp, options: [.activateAllWindows])
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        previousApp = nil
    }

    func submitCapture(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = model.view.capture?.id ?? "c"
        let shelfID = model.view.capture?.shelf
        if text.isEmpty {
            cancelCapture()
            return
        }
        var fields: [String: Any] = ["op": "submit", "id": id, "text": text]
        if let shelfID { fields["shelf"] = shelfID }
        Emit.send("capture", fields)
        model.captureDraft = ""
        endCaptureFocus()
        if let next = deferred {
            deferred = nil
            applyView(next, focus: next.mode == "capture" && (next.open ?? false))
        } else {
            var rest = IslandView(mode: "rest", peek: "Noted", badge: model.view.badge)
            rest.moves = nil
            applyView(rest, focus: false)
        }
    }

    func cancelCapture() {
        let id = model.view.capture?.id ?? "c"
        Emit.send("capture", ["op": "cancel", "id": id])
        model.captureDraft = ""
        endCaptureFocus()
        if let next = deferred {
            deferred = nil
            applyView(next, focus: false)
        } else {
            applyView(IslandView(mode: "rest", badge: model.view.badge), focus: false)
        }
    }

    func toggleSpeech(_ on: Bool) {
        model.speechOn = on
        let id = model.view.capture?.id ?? "c"
        if model.view.mode != "capture" { openCapture(shelf: nil) }
        Emit.send("capture", ["op": "speech", "id": id, "on": on])
    }

    // MARK: shelf

    func receiveFiles(_ urls: [URL]) {
        setDropHover(false)
        let result = shelf.accept(urls: urls)
        model.shelf = shelf.items
        model.shelfMessage = result.message
        for item in result.added { emitShelf("add", item) }
        relayout(animated: true)
        if let first = result.added.first { openCapture(shelf: first.id) }
        clearShelfMessageLater()
    }

    func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        setDropHover(false)
        guard let dir = shelf.directoryURL else {
            model.shelfMessage = "No shelf folder yet"
            return
        }
        if shelf.items.count >= shelfCap {
            model.shelfMessage = "shelf is full"
            return
        }
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { [weak self] url, error in
                guard let self, error == nil else { return }
                if let item = self.shelf.adopt(copied: url) {
                    self.model.shelf = self.shelf.items
                    self.emitShelf("add", item)
                    self.relayout(animated: true)
                    self.openCapture(shelf: item.id)
                } else {
                    self.model.shelfMessage = "shelf is full"
                }
            }
        }
    }

    func removeShelf(_ id: String) {
        guard let item = shelf.item(id) else { return }
        shelf.remove(id: id)
        model.shelf = shelf.items
        emitShelf("remove", item)
        relayout(animated: true)
    }

    func emitShelf(_ op: String, _ item: ShelfItem) {
        Emit.send("shelf", ["op": op, "id": item.id, "name": item.name, "path": item.path, "bytes": item.bytes, "linked": item.linked])
    }

    func clearShelfMessageLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.model.shelfMessage = nil
        }
    }

    // MARK: progress

    func transfersChanged(_ list: [Transfer], _ event: TransferEvent?) {
        model.transfers = list
        relayout(animated: true)
        guard let event else { return }
        if event.transfer.state == "active" || event.transfer.state == "done" || event.transfer.state == "missing" {
            emitProgress(event.transfer)
        }
        if event.transfer.state == "done" && !event.quiet {
            if bodyBlocksPing {
                heldDone.append(event.transfer.id)
            } else {
                pingDone(event.transfer)
            }
        }
    }

    var bodyBlocksPing: Bool {
        if model.focusCapture { return true }
        if model.view.mode == "ask" && (model.view.open ?? false) { return true }
        if model.view.mode == "meeting" && (model.view.open ?? false) { return true }
        return false
    }

    func flushHeldDone() {
        guard !bodyBlocksPing, !heldDone.isEmpty else { return }
        let ids = heldDone
        heldDone.removeAll()
        for id in ids {
            if let row = model.transfers.first(where: { $0.id == id && $0.state == "done" }) {
                pingDone(row)
                break
            }
        }
    }

    func pingDone(_ row: Transfer) {
        NSSound(named: NSSound.Name("Glass"))?.play()
        model.pingProgress = true
        if model.view.isRest || model.view.mode == "moves" {
            model.expanded = true
        }
        relayout(animated: true)
    }

    func reveal(id: String, path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            watch.mark(id: id, state: "missing")
            Emit.send("progress", ["id": id, "state": "missing", "path": path])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        Emit.send("action", ["id": "reveal", "ask": id, "path": path])
        watch.dismiss(id: id)
        model.pingProgress = model.transfers.contains { $0.state == "done" }
    }

    func emitProgress(_ t: Transfer) {
        var fields: [String: Any] = [
            "id": t.id,
            "state": t.state,
            "kind": t.kind,
            "label": t.label,
            "path": t.path,
            "bytes": t.bytes,
        ]
        if let total = t.total { fields["total"] = total }
        else { fields["total"] = NSNull() }
        Emit.send("progress", fields)
    }

    // MARK: mouse

    func watchMouse() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.updateMouse() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            self?.updateMouse()
            return e
        }) { monitors.append(l) }
    }

    /// Where the cursor is → click-through or not, and the hover rules.
    /// A sized tray's body passes clicks through so Brain's window, stacked under this one, can take them.
    /// The notch itself still takes the hover and the file drop.
    func updateMouse() {
        guard panel != nil else { return }
        let p = NSEvent.mouseLocation
        let x = Double(p.x - panel.frame.minX)
        let y = Double(p.y - panel.frame.minY)
        let cw = Double(canvas.width)
        let ch = Double(canvas.height)
        let size = model.size
        let isl = islandRect(size, canvasW: cw, canvasH: ch)
        let notch = notchRect(model.notch, canvasW: cw, canvasH: ch)
        let inShape = isl.contains(x, min(y, ch - 0.01), pad: accepting ? 4 : 0)
        let inNotch = notch.contains(x, min(y, ch - 0.01))
        let trayBody = model.tray && (model.trayH ?? 0) > 0 && inShape && !inNotch
        let compactVisible = model.showsWings || model.tray
        let inHot = inNotch || (compactVisible && inShape && !trayBody)
        let down = NSEvent.pressedMouseButtons != 0
        var take = (inShape || inNotch) && !trayBody
        if down && inNotch { take = true }
        if take != accepting {
            accepting = take
            panel.ignoresMouseEvents = !take
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let change = gate.update(x: x, y: y, t: now, inHot: inHot, inShape: isl.contains(x, min(y, ch - 0.01), pad: 6) || inNotch, buttonDown: down) {
            switch change {
            case .enter: Emit.send("hover")
            case .leave:
                Emit.send("leave")
                if model.focusCapture && model.captureDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cancelCapture()
                }
            }
            let want = gate.hovering || (model.view.open ?? false) || model.pingProgress
            if want != model.expanded {
                model.expanded = want
                relayout(animated: true)
            }
        }
        if let at = gate.nextCheck() {
            recheckGen += 1
            let gen = recheckGen
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, at - now + 0.005)) { [weak self] in
                guard let self, gen == self.recheckGen else { return }
                self.updateMouse()
            }
        }
    }

    // MARK: stdin

    func readStdin() {
        FileHandle.standardInput.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }
            DispatchQueue.main.async { self?.consume(d) }
        }
    }

    func consume(_ d: Data) {
        for line in readBuffer.feed(d) {
            guard let msg = decodeInbound(line) else { continue }
            switch msg {
            case let .view(v): setView(v)
            case let .tray(open): setTray(open)
            case let .traySized(w, h): setTray(true, w: w, h: h)
            case .ping: Emit.send("pong")
            case .quit: NSApp.terminate(nil)
            case let .shelfDir(path):
                shelf.setDirectory(path)
                watch.shelfDirectory = path
                model.shelf = shelf.items
            case let .shelf(items):
                shelf.restore(items)
                model.shelf = shelf.items
                relayout(animated: true)
            case let .captureText(id, text, _):
                guard model.view.capture?.id == id || model.view.mode == "capture" else { continue }
                if model.speechOn || model.captureDraft.isEmpty { model.captureDraft = text }
            case let .watch(dirs):
                watch.setDirs(dirs)
            }
        }
    }
}
