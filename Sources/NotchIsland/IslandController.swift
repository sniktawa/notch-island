import AppKit
import IslandCore
import QuartzCore
import SwiftUI

/// A borderless, non-activating panel that never becomes key or main: clicks never pull focus from the user's app.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
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
    var panel: IslandPanel!
    var shapeView: ShapeView!
    var contentView: NSView!
    let maskLayer = CAShapeLayer()
    var gate = HoverGate()
    var hz: Int = 60
    var accepting = false
    var lastSize: IslandSize?
    var recheckGen = 0
    var observers: [NSObjectProtocol] = []
    var wsObservers: [NSObjectProtocol] = []
    var monitors: [Any] = []
    var readBuffer = LineBuffer()
    let canvas = NSSize(width: Layout.canvasW, height: Layout.canvasH)

    func start() {
        let frame = NSRect(origin: .zero, size: canvas)
        panel = IslandPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

        contentView = NSView(frame: frame)
        contentView.wantsLayer = true
        contentView.autoresizingMask = [.width, .height]
        maskLayer.fillColor = NSColor.black.cgColor
        maskLayer.frame = CGRect(origin: .zero, size: canvas)
        maskLayer.actions = ["path": NSNull()]
        contentView.layer?.mask = maskLayer
        let host = FirstMouseHostingView(rootView: IslandContent(model: model))
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        contentView.addSubview(host)
        root.addSubview(contentView)
        panel.contentView = root

        anchor(force: true)
        apply(animated: false)
        panel.orderFrontRegardless()
        watchScreens()
        watchMouse()
        readStdin()
        Emit.send("ready", ["v": protocolVersion, "notch": notchJSON(), "hz": hz])
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

    func notchJSON() -> [String: Any] {
        ["w": model.notch.width, "h": model.notch.height, "has": model.notch.hasNotch]
    }

    /// Keep the canvas centred on the notch, flush with the top of the notched (else main) screen.
    func anchor(force: Bool = false) {
        guard let s = pickScreen() else { return }
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
                Emit.send("screen", ["notch": notchJSON(), "hz": hz])
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
    }

    // MARK: shape

    /// Morph the island to the current state with a spring (interruptible: it starts from wherever it is now).
    func apply(animated: Bool) {
        let size = model.size
        let path = cgPath(islandPath(size, canvasW: Double(canvas.width), canvasH: Double(canvas.height)))
        let hide = model.view.isRest && !model.tray && !model.notch.hasNotch && !gate.hovering
        let opening = (lastSize.map { size.w * size.h >= $0.w * $0.h } ?? true)
        lastSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [shapeView.shapeLayer, maskLayer] {
            let from = layer.presentation()?.path ?? layer.path
            layer.path = path
            if animated, let from = from {
                let a = CASpringAnimation(keyPath: "path")
                a.mass = 1
                // open: response ≈ 0.41 s, damping ratio ≈ 0.79 (about 2 % overshoot); close: critically damped
                a.stiffness = opening ? 230 : 320
                a.damping = opening ? 24 : 36
                a.initialVelocity = 0
                a.fromValue = from
                a.toValue = path
                a.duration = a.settlingDuration
                a.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: Float(hz), preferred: Float(hz))
                layer.add(a, forKey: "morph")
            } else {
                layer.removeAnimation(forKey: "morph")
            }
        }
        CATransaction.commit()
        shapeView.alphaValue = hide ? 0 : 1
        contentView.alphaValue = hide ? 0 : 1
        updateMouse()
    }

    func setView(_ v: IslandView) {
        let wasRest = model.view.isRest
        model.view = v
        if v.isRest != wasRest && v.isRest { gate.reset() }
        model.expanded = gate.hovering || (v.open ?? false)
        apply(animated: true)
    }

    func setTray(_ open: Bool) {
        guard model.tray != open else { return }
        model.tray = open
        if !open { gate.reset() }
        model.expanded = gate.hovering || (model.view.open ?? false)
        apply(animated: true)
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

    /// Where the cursor is → click-through or not, and the hover rules. Called on every mouse event and on timers.
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
        // y can sit exactly on the top edge (the topmost pixel row): count it as inside
        let inShape = isl.contains(x, min(y, ch - 0.01), pad: accepting ? 4 : 0)
        let inNotch = notch.contains(x, min(y, ch - 0.01))
        let compactVisible = !model.view.isRest || model.tray
        let inHot = inNotch || (compactVisible && inShape)
        let take = inShape || inNotch
        if take != accepting {
            accepting = take
            panel.ignoresMouseEvents = !take
        }
        let now = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.pressedMouseButtons != 0
        if let change = gate.update(x: x, y: y, t: now, inHot: inHot, inShape: isl.contains(x, min(y, ch - 0.01), pad: 6), buttonDown: down) {
            switch change {
            case .enter: Emit.send("hover")
            case .leave: Emit.send("leave")
            }
            let want = gate.hovering || (model.view.open ?? false)
            if want != model.expanded && !model.view.isRest {
                model.expanded = want
                apply(animated: true)
            }
        }
        if let at = gate.nextCheck() {
            recheckGen += 1
            let gen = recheckGen
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, at - now + 0.005)) { [weak self] in
                guard let self = self, gen == self.recheckGen else { return }
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
            case .ping: Emit.send("pong")
            case .quit: NSApp.terminate(nil)
            }
        }
    }
}
