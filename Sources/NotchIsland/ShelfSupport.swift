import AppKit
import IslandCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Parked files. The helper copies (or links) them. Brain decides what a sentence about a file means.
final class ShelfStore {
    private(set) var directory: String?
    private(set) var items: [ShelfItem] = []
    /// names reserved by copies still being written (off the main thread)
    private var pendingNames: Set<String> = []
    private let copyQueue = DispatchQueue(label: "notch.shelf.copy", qos: .userInitiated)

    var directoryURL: URL? {
        guard let directory else { return nil }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }

    /// False when the folder is not a dedicated one (the home folder, Desktop, the disk root…). The old folder stays.
    @discardableResult
    func setDirectory(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard allowedShelfDir(path, home: home) else { return false }
        directory = standardizePath(path)
        try? FileManager.default.createDirectory(atPath: directory!, withIntermediateDirectories: true)
        return true
    }

    /// Brain's restore list. Paths outside the shelf directory are ignored.
    func restore(_ incoming: [ShelfItem]) {
        guard let directory else { items = []; return }
        items = Array(shelfItemsInside(incoming, directory: directory).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }.prefix(shelfCap))
    }

    struct AcceptResult {
        var added: [ShelfItem]
        var message: String?
    }

    private func taken() -> Set<String> {
        let onDisk = directory.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0) } ?? []
        return takenShelfNames(chips: items.map(\.name), pending: pendingNames, onDisk: onDisk)
    }

    /// Links are added at once. Copies are written on a background queue (a 2 GB file must not freeze the notch),
    /// always to a fresh name, so nothing already in the shelf folder is replaced. `completion` runs on main.
    func accept(urls: [URL], completion: @escaping (AcceptResult) -> Void) {
        guard let directory else {
            completion(AcceptResult(added: [], message: "No shelf folder yet"))
            return
        }
        var message: String?
        var ready: [ShelfItem] = []
        var copies: [(source: URL, item: ShelfItem)] = []
        var reserved = taken()
        for url in urls {
            let count = items.count + pendingNames.count + ready.count
            if count >= shelfCap {
                message = "shelf is full"
                break
            }
            let resolved = resolve(url)
            guard !resolved.broken, let source = resolved.url else {
                message = "broken alias"
                continue
            }
            let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey])
            let isDir = values?.isDirectory ?? false
            let isPackage = values?.isPackage ?? false
            let bytes = Double(values?.fileSize ?? 0)
            switch decidePark(isDirectory: isDir, isPackage: isPackage, bytes: bytes, count: count) {
            case .refuse(let why):
                message = why
            case .link:
                ready.append(ShelfItem(id: freshID(), name: source.lastPathComponent, path: source.path, bytes: bytes, linked: true))
            case .copy:
                let name = uniqueShelfName(source.lastPathComponent, taken: reserved)
                reserved.insert(name)
                pendingNames.insert(name)
                let dest = URL(fileURLWithPath: directory).appendingPathComponent(name)
                copies.append((source, ShelfItem(id: freshID(), name: name, path: dest.path, bytes: bytes, linked: false)))
            }
        }
        items.append(contentsOf: ready)
        if copies.isEmpty {
            completion(AcceptResult(added: ready, message: message))
            return
        }
        let jobs = copies
        let linked = ready
        let note = message
        copyQueue.async { [weak self] in
            var results: [(item: ShelfItem, ok: Bool)] = []
            for job in jobs {
                let dest = URL(fileURLWithPath: job.item.path)
                do {
                    // copyItem refuses an existing destination: an older file is never replaced
                    try FileManager.default.copyItem(at: job.source, to: dest)
                    var item = job.item
                    if let size = try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize { item.bytes = Double(size) }
                    results.append((item, true))
                } catch {
                    results.append((job.item, false))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                var added = linked
                var msg = note
                for r in results {
                    self.pendingNames.remove(r.item.name)
                    if r.ok {
                        self.items.append(r.item)
                        added.append(r.item)
                    } else {
                        msg = "couldn't park \(r.item.name)"
                    }
                }
                completion(AcceptResult(added: added, message: msg))
            }
        }
    }

    /// A promised file was written into a private `.incoming-…` folder inside the shelf directory. Move it to a fresh
    /// name in the shelf directory. Nothing that was already there is replaced.
    func adopt(copied url: URL) -> ShelfItem? {
        guard let directory, pathIsInside(url.path, directory: directory) else { return nil }
        if items.count + pendingNames.count >= shelfCap {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let name = uniqueShelfName(url.lastPathComponent, taken: taken())
        let dest = URL(fileURLWithPath: directory).appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let size = Double((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let item = ShelfItem(id: freshID(), name: name, path: dest.path, bytes: size, linked: false)
        items.append(item)
        return item
    }

    /// Deleting a chip deletes only the copy this shelf made. A linked chip (his original file) is never deleted.
    func remove(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: idx)
        if !item.linked, let directory, pathIsInside(item.path, directory: directory) {
            try? FileManager.default.removeItem(atPath: item.path)
        }
    }

    func item(_ id: String) -> ShelfItem? { items.first { $0.id == id } }

    /// Linked files can vanish. Copied files live in the shelf directory until removed.
    func refreshMissing() -> [ShelfItem] {
        var gone: [ShelfItem] = []
        for i in items.indices {
            let exists = FileManager.default.fileExists(atPath: items[i].path)
            if items[i].missing != !exists {
                items[i].missing = !exists
                if !exists { gone.append(items[i]) }
            }
        }
        return gone
    }

    private func resolve(_ url: URL) -> (url: URL?, broken: Bool) {
        let values = try? url.resourceValues(forKeys: [.isAliasFileKey])
        if values?.isAliasFile == true {
            guard let dest = try? URL(resolvingAliasFileAt: url), FileManager.default.fileExists(atPath: dest.path) else {
                return (nil, true)
            }
            return (dest, false)
        }
        if !FileManager.default.fileExists(atPath: url.path) { return (nil, true) }
        return (url, false)
    }

    private func freshID() -> String { "s" + String(UUID().uuidString.prefix(8)).lowercased() }
}

/// Receives drops on the island. A drag into the notch copies. It never moves the original.
final class DragHostView: NSView {
    var directory: (() -> URL?)?
    var entered: (() -> Void)?
    var exited: (() -> Void)?
    var droppedFiles: (([URL]) -> Void)?
    var droppedPromises: (([NSFilePromiseReceiver]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        var types: [NSPasteboard.PasteboardType] = [.fileURL]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        entered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) { exited?() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            droppedPromises?(receivers)
            return true
        }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        droppedFiles?(urls)
        return true
    }
}

/// v0.3.1: thumbnails for shelf tiles. Quick Look renders off the main thread; results are cached per file.
/// Images and videos get a real frame. Anything Quick Look cannot draw gets the file's Finder icon.
final class ThumbCache {
    static let shared = ThumbCache()
    struct Thumb {
        var image: NSImage
        /// true for a real thumbnail (fill the tile), false for an icon (fit it)
        var isPreview: Bool
    }
    private var cache: [String: Thumb] = [:]
    private var order: [String] = []
    private var waiting: [String: [(Thumb) -> Void]] = [:]

    private func key(_ path: String) -> String {
        let mod = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return path + "|" + String(mod)
    }

    /// Calls `done` on the main thread, at once when cached.
    func thumb(for path: String, side: CGFloat, scale: CGFloat, done: @escaping (Thumb) -> Void) {
        let k = key(path)
        if let hit = cache[k] {
            done(hit)
            return
        }
        if waiting[k] != nil {
            waiting[k]?.append(done)
            return
        }
        waiting[k] = [done]
        let url = URL(fileURLWithPath: path)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            let image = rep?.nsImage
            DispatchQueue.main.async {
                guard let self else { return }
                let thumb: Thumb
                if let image {
                    thumb = Thumb(image: image, isPreview: true)
                } else {
                    thumb = Thumb(image: NSWorkspace.shared.icon(forFile: path), isPreview: false)
                }
                self.store(k, thumb)
                let calls = self.waiting.removeValue(forKey: k) ?? []
                for c in calls { c(thumb) }
            }
        }
    }

    private func store(_ k: String, _ t: Thumb) {
        cache[k] = t
        order.append(k)
        if order.count > 60 {
            let old = order.removeFirst()
            cache.removeValue(forKey: old)
        }
    }
}

/// One shelf tile: a rounded thumbnail, the name under it, × on hover. A small move starts a copy-drag (the
/// thumbnail is the drag image). A click opens capture for this file.
final class ShelfChipView: NSView {
    var item = ShelfItem(id: "", name: "", path: "") {
        didSet {
            if oldValue.path != item.path || oldValue.missing != item.missing || currentThumb == nil { loadThumb() }
            needsLayout = true
        }
    }
    var showsName = true { didSet { needsLayout = true } }
    var onRemove: () -> Void = {}
    var onDragged: () -> Void = {}
    var onClick: () -> Void = {}
    private let tileView = NSView()
    private let thumbLayer = CALayer()
    private let label = NSTextField(labelWithString: "")
    private let remove = NSButton(title: "×", target: nil, action: nil)
    private var down: NSPoint?
    private var promise: ShelfPromise?
    private var currentThumb: ThumbCache.Thumb?
    private var loadingPath: String?
    private var hovering = false { didSet { remove.isHidden = !hovering || !showsName } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        tileView.wantsLayer = true
        tileView.layer?.cornerRadius = 8
        tileView.layer?.masksToBounds = true
        tileView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        thumbLayer.contentsGravity = .resizeAspectFill
        thumbLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        tileView.layer?.addSublayer(thumbLayer)
        addSubview(tileView)
        label.textColor = NSColor.white.withAlphaComponent(0.75)
        label.font = .systemFont(ofSize: 9.5, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        remove.isBordered = false
        remove.font = .systemFont(ofSize: 11, weight: .bold)
        remove.contentTintColor = .white
        remove.wantsLayer = true
        remove.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        remove.layer?.cornerRadius = 8
        remove.target = self
        remove.action = #selector(removeTapped)
        remove.isHidden = true
        remove.setAccessibilityLabel("Remove from shelf")
        addSubview(remove)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private var tileRect: NSRect {
        let side = min(bounds.width, RestBody.tile)
        return NSRect(x: (bounds.width - side) / 2, y: 0, width: side, height: side)
    }

    override func layout() {
        super.layout()
        let tile = tileRect
        tileView.frame = tile
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.frame = tileView.bounds.insetBy(dx: currentThumb?.isPreview == false ? 6 : 0, dy: currentThumb?.isPreview == false ? 6 : 0)
        CATransaction.commit()
        label.isHidden = !showsName
        label.frame = NSRect(x: 0, y: tile.maxY + 3, width: bounds.width, height: 13)
        let title = item.missing ? "missing" : item.name
        if label.stringValue != title { label.stringValue = title }
        remove.frame = NSRect(x: min(bounds.width - 16, tile.maxX - 10), y: max(0, tile.minY - 2), width: 16, height: 16)
        remove.isHidden = !hovering || !showsName
        alphaValue = item.missing ? 0.4 : 1
        toolTip = item.linked ? "\(item.name) · linked" : item.name
    }

    private func loadThumb() {
        let path = item.path
        guard !path.isEmpty else { return }
        loadingPath = path
        guard FileManager.default.fileExists(atPath: path) else {
            apply(ThumbCache.Thumb(image: NSWorkspace.shared.icon(forFile: path), isPreview: false))
            return
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        ThumbCache.shared.thumb(for: path, side: RestBody.tile, scale: scale) { [weak self] thumb in
            guard let self, self.loadingPath == path else { return }
            self.apply(thumb)
        }
    }

    private func apply(_ thumb: ThumbCache.Thumb) {
        currentThumb = thumb
        let scale = window?.backingScaleFactor ?? 2
        thumbLayer.contentsScale = scale
        thumbLayer.contentsGravity = thumb.isPreview ? .resizeAspectFill : .resizeAspect
        var rect = NSRect(origin: .zero, size: thumb.image.size)
        if let cg = thumb.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            thumbLayer.contents = cg
        } else {
            thumbLayer.contents = thumb.image
        }
        needsLayout = true
    }

    @objc private func removeTapped() { onRemove() }

    override func mouseDown(with event: NSEvent) {
        down = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down, !item.missing, FileManager.default.fileExists(atPath: item.path) else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - down.x, p.y - down.y) < 4 { return }
        self.down = nil
        let uti = UTType(filenameExtension: URL(fileURLWithPath: item.name).pathExtension)?.identifier ?? UTType.data.identifier
        let source = ShelfPromise(item: item)
        source.onEnd = { [weak self] in self?.onDragged() }
        promise = source
        let provider = NSFilePromiseProvider(fileType: uti, delegate: source)
        let dragging = NSDraggingItem(pasteboardWriter: provider)
        let image = currentThumb?.image ?? NSWorkspace.shared.icon(forFile: item.path)
        dragging.setDraggingFrame(tileRect, contents: image)
        let session = beginDraggingSession(with: [dragging], event: event, source: source)
        session.draggingPasteboard.setString(URL(fileURLWithPath: item.path).absoluteString, forType: .fileURL)
    }

    override func mouseUp(with event: NSEvent) {
        if down != nil { onClick() }
        down = nil
    }
}

/// Writes a copy at the drop destination. The shelf item stays put.
final class ShelfPromise: NSObject, NSFilePromiseProviderDelegate, NSDraggingSource {
    let item: ShelfItem
    var onEnd: (() -> Void)?

    init(item: ShelfItem) { self.item = item }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        item.name
    }

    /// Never deletes what is already at the drop target: a name clash gets "name 2.ext" next to it.
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do {
            var target = url
            if FileManager.default.fileExists(atPath: url.path) {
                let parent = url.deletingLastPathComponent()
                let names = Set((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
                target = parent.appendingPathComponent(uniqueShelfName(url.lastPathComponent, taken: names))
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: item.path), to: target)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    /// Copies run off the main thread so a big file does not freeze the notch.
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { ShelfPromise.queue }

    static let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 1
        return q
    }()

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnd?()
    }
}
