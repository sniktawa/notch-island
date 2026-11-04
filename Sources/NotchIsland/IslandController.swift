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
    let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()
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
    /// v0.3.1: every row the watcher holds; the model gets only what is on screen now
    var allTransfers: [Transfer] = []
    var transferGen = 0
    var pingGen = 0
    var dropGen = 0
    var dropHeld = false
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
            let fields: [String: Any] = ["op": "dragged", "id": id, "name": item.name, "path": item.path, "bytes": item.bytes]
            Emit.send("shelf", fields)
        }
        model.onShelfClick = { [weak self] id in self?.openCapture(shelf: id) }
        model.onDismissTransfer = { [weak self] id in self?.watch.dismiss(id: id) }
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
            })
        }
        // FSEvents can miss events across sleep: restart the watcher on wake only (not on every Space switch)
        wsObservers.append(wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.watch.setDirs(self.watch.dirs)
        })
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
        model.expanded = wantExpanded()
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
        model.expanded = wantExpanded()
        relayout(animated: true)
    }

    /// v0.3.1: the one rule for open or closed. Nothing sets `model.expanded` any other way.
    func wantExpanded() -> Bool {
        wantsExpanded(hovering: gate.hovering, hostOpen: model.view.open ?? false, ping: model.pingProgress && model.view.isRest, drop: model.dropActive)
    }

    func recomputeExpanded() {
        let want = wantExpanded()
        if want != model.expanded { model.expanded = want }
        relayout(animated: true)
    }

    /// Entering opens and holds the body for the drop. Exits shorter than `dragExitGrace` (the drag crossing between
    /// subviews) are ignored, so the shape does not flicker.
    func setDropHover(_ on: Bool) {
        dropGen += 1
        if on {
            if !model.dropHover { model.dropHover = true }
            model.dropActive = true
            recomputeExpanded()
            return
        }
        let gen = dropGen
        DispatchQueue.main.asyncAfter(deadline: .now() + dragExitGrace) { [weak self] in
            guard let self, gen == self.dropGen else { return }
            self.model.dropHover = false
            self.model.dropActive = self.dropHeld
            self.recomputeExpanded()
        }
    }

    /// After a drop the body stays open a moment so the new thumbnail is seen, then closes unless hovered.
    func holdAfterDrop() {
        dropGen += 1
        let gen = dropGen
        dropHeld = true
        model.dropHover = false
        model.dropActive = true
        recomputeExpanded()
        DispatchQueue.main.asyncAfter(deadline: .now() + dropHoldSeconds) { [weak self] in
            guard let self, gen == self.dropGen else { return }
            self.dropHeld = false
            self.model.dropActive = false
            self.recomputeExpanded()
        }
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
        var view = IslandView(mode: "capture", glyph: "capture", open: true, peek: model.view.peek, badge: model.view.badge, capture: CaptureInfo(id: id, prompt: prompt, text: model.captureDraft, shelf: shelf))
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
                _ = app.activate()
            } else {
                _ = app.activate(options: [])
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
        if model.view.mode != "capture" { openCapture(shelf: nil) }
        model.speechOn = on
        let id = model.view.capture?.id ?? "c"
        Emit.send("capture", ["op": "speech", "id": id, "on": on])
    }

    // MARK: shelf

    /// v0.3.1: a drop parks the file and shows its thumbnail. It no longer jumps into capture (and no longer takes
    /// keyboard focus from Finder); a click on the thumbnail opens capture for it.
    func receiveFiles(_ urls: [URL]) {
        holdAfterDrop()
        shelf.accept(urls: urls) { [weak self] result in
            guard let self else { return }
            self.model.shelf = self.shelf.items
            self.model.shelfMessage = result.message
            for item in result.added { self.emitShelf("add", item) }
            self.holdAfterDrop()
            self.clearShelfMessageLater()
        }
    }

    func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        holdAfterDrop()
        guard let dir = shelf.directoryURL else {
            model.shelfMessage = "No shelf folder yet"
            relayout(animated: true)
            clearShelfMessageLater()
            return
        }
        if shelf.items.count >= shelfCap {
            model.shelfMessage = "shelf is full"
            relayout(animated: true)
            clearShelfMessageLater()
            return
        }
        for receiver in receivers {
            // each promise lands in its own hidden folder first, so it can never overwrite a parked file
            let incoming = dir.appendingPathComponent(".incoming-" + UUID().uuidString, isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)) != nil else { continue }
            receiver.receivePromisedFiles(atDestination: incoming, options: [:], operationQueue: promiseQueue) { [weak self] url, error in
                DispatchQueue.main.async {
                    defer {
                        if ((try? FileManager.default.contentsOfDirectory(atPath: incoming.path)) ?? []).isEmpty {
                            try? FileManager.default.removeItem(at: incoming)
                        }
                    }
                    guard let self else { return }
                    if error != nil {
                        try? FileManager.default.removeItem(at: url)
                        return
                    }
                    if let item = self.shelf.adopt(copied: url) {
                        self.model.shelf = self.shelf.items
                        self.emitShelf("add", item)
                        self.holdAfterDrop()
                    } else {
                        self.model.shelfMessage = "shelf is full"
                        self.relayout(animated: true)
                        self.clearShelfMessageLater()
                    }
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
            guard let self, self.model.shelfMessage != nil else { return }
            self.model.shelfMessage = nil
            self.relayout(animated: true)
        }
    }

    // MARK: progress

    func transfersChanged(_ list: [Transfer], _ event: TransferEvent?) {
        allTransfers = list
        refreshTransferDisplay()
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

    /// Push only what is on screen now into the model (the wing's done window, the tray's two minutes), and look
    /// again when that answer next changes on its own. Equal values are not re-assigned, so nothing re-renders.
    func refreshTransferDisplay() {
        let now = Date().timeIntervalSince1970
        let d = transferDisplay(allTransfers, now: now)
        if model.transfers != d.tray { model.transfers = d.tray }
        if model.wingTransfer != d.wing { model.wingTransfer = d.wing }
        relayout(animated: true)
        transferGen += 1
        guard let next = d.nextChange else { return }
        let gen = transferGen
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, next - now + 0.05)) { [weak self] in
            guard let self, gen == self.transferGen else { return }
            self.refreshTransferDisplay()
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

    /// A finished transfer opens the rest body for a few seconds, then it closes unless the cursor is on it.
    func pingDone(_ row: Transfer) {
        NSSound(named: NSSound.Name("Glass"))?.play()
        model.pingProgress = true
        recomputeExpanded()
        pingGen += 1
        let gen = pingGen
        DispatchQueue.main.asyncAfter(deadline: .now() + pingSeconds) { [weak self] in
            guard let self, gen == self.pingGen else { return }
            self.endPing()
        }
    }

    func endPing() {
        pingGen += 1
        guard model.pingProgress else { return }
        model.pingProgress = false
        recomputeExpanded()
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
        endPing()
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
                // leaving always ends the done ping, so it can never hold the island open
                pingGen += 1
                model.pingProgress = false
                if model.focusCapture && model.captureDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cancelCapture()
                }
            }
            let want = wantExpanded()
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
                if shelf.setDirectory(path) {
                    watch.shelfDirectory = shelf.directory
                } else {
                    Emit.send("log", ["msg": "shelfDir refused (not a dedicated folder)"])
                }
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
