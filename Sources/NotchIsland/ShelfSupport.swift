import AppKit
import IslandCore
import UniformTypeIdentifiers

/// Parked files. The helper copies (or links) them. Brain decides what a sentence about a file means.
final class ShelfStore {
    private(set) var directory: String?
    private(set) var items: [ShelfItem] = []

    var directoryURL: URL? {
        guard let directory else { return nil }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }

    func setDirectory(_ path: String) {
        directory = path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// Brain's restore list. Paths outside the shelf directory are ignored.
    func restore(_ incoming: [ShelfItem]) {
        guard let directory else { items = []; return }
        items = shelfItemsInside(incoming, directory: directory).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    struct AcceptResult {
        var added: [ShelfItem]
        var message: String?
    }

    func accept(urls: [URL]) -> AcceptResult {
        guard directory != nil else { return AcceptResult(added: [], message: "No shelf folder yet") }
        var added: [ShelfItem] = []
        var message: String?
        for url in urls {
            if items.count >= shelfCap {
                message = "shelf is full"
                break
            }
            guard let item = park(url) else { continue }
            if case .refuse(let why) = item { message = why; continue }
            if case .item(let shelf) = item {
                items.append(shelf)
                added.append(shelf)
            }
        }
        return AcceptResult(added: added, message: message)
    }

    private enum Parked {
        case item(ShelfItem)
        case refuse(String)
    }

    private func park(_ url: URL) -> Parked? {
        guard let directory else { return nil }
        let resolved = resolve(url)
        if resolved.broken { return .refuse("broken alias") }
        guard let source = resolved.url else { return .refuse("broken alias") }
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey])
        let isDir = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        let bytes = Double(values?.fileSize ?? 0)
        switch decidePark(isDirectory: isDir, isPackage: isPackage, bytes: bytes, count: items.count) {
        case .refuse(let why):
            return .refuse(why)
        case .link:
            let name = source.lastPathComponent
            return .item(ShelfItem(id: freshID(), name: name, path: source.path, bytes: bytes, linked: true))
        case .copy:
            let taken = Set(items.map(\.name))
            let name = uniqueShelfName(source.lastPathComponent, taken: taken)
            let dest = URL(fileURLWithPath: directory).appendingPathComponent(name)
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: source, to: dest)
                let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? bytes
                return .item(ShelfItem(id: freshID(), name: name, path: dest.path, bytes: size, linked: false))
            } catch {
                return .refuse("couldn't park \(source.lastPathComponent)")
            }
        }
    }

    /// A file the promise receiver already wrote into the shelf directory.
    func adopt(copied url: URL) -> ShelfItem? {
        guard let directory, pathIsInside(url.path, directory: directory) else { return nil }
        if items.count >= shelfCap {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let taken = Set(items.map(\.name))
        var finalURL = url
        if taken.contains(url.lastPathComponent) {
            let name = uniqueShelfName(url.lastPathComponent, taken: taken)
            let dest = URL(fileURLWithPath: directory).appendingPathComponent(name)
            try? FileManager.default.moveItem(at: url, to: dest)
            finalURL = dest
        }
        let size = Double((try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let item = ShelfItem(id: freshID(), name: finalURL.lastPathComponent, path: finalURL.path, bytes: size, linked: false)
        items.append(item)
        return item
    }

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

/// One shelf chip. A small move starts a copy-drag. A click opens capture for this file.
final class ShelfChipView: NSView {
    var item = ShelfItem(id: "", name: "", path: "") { didSet { needsLayout = true } }
    var onRemove: () -> Void = {}
    var onDragged: () -> Void = {}
    var onClick: () -> Void = {}
    private let label = NSTextField(labelWithString: "")
    private let remove = NSButton(title: "×", target: nil, action: nil)
    private var down: NSPoint?
    private var promise: ShelfPromise?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.textColor = .white
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.isBordered = false
        remove.font = .systemFont(ofSize: 13, weight: .medium)
        remove.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        remove.target = self
        remove.action = #selector(removeTapped)
        addSubview(label)
        addSubview(remove)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let title = item.missing ? "\(item.name) · missing" : (item.linked ? "\(item.name) · linked" : item.name)
        if label.stringValue != title { label.stringValue = title }
        label.textColor = item.missing ? NSColor.white.withAlphaComponent(0.4) : .white
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
        dragging.setDraggingFrame(bounds, contents: nil)
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

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: item.path), to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnd?()
    }
}
