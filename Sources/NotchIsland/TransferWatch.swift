import AppKit
import CoreServices
import IslandCore

struct TransferEvent {
    var transfer: Transfer
    var quiet: Bool
}

/// Watches the folders Brain names. Ticks stay in this process. Brain hears start and done.
final class TransferWatch {
    private(set) var dirs: [String] = []
    private var items: [String: Transfer] = [:]
    private var stillSince: [String: Date] = [:]
    private var stream: FSEventStreamRef?
    private var query: NSMetadataQuery?
    private var queryObserver: NSObjectProtocol?
    private var timer: Timer?
    private var subscribers: [String: Any] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]
    private var warming = true
    var shelfDirectory: String?
    var onChange: (([Transfer], TransferEvent?) -> Void)?

    func setDirs(_ incoming: [String]) {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        dirs = resolveWatchDirs(incoming, downloads: downloads)
        restart()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        query?.stop()
        query = nil
        if let queryObserver { NotificationCenter.default.removeObserver(queryObserver) }
        queryObserver = nil
        for (_, token) in subscribers { NSProgress.removeSubscriber(token) }
        subscribers.removeAll()
        observations.removeAll()
    }

    func revealPath(id: String) -> String? { items.values.first { $0.id == id }?.path }

    func mark(id: String, state: String) {
        guard let key = items.first(where: { $0.value.id == id })?.key else { return }
        items[key]?.state = state
        publish(nil)
    }

    func dismiss(id: String) {
        guard let key = items.first(where: { $0.value.id == id })?.key else { return }
        items.removeValue(forKey: key)
        stillSince.removeValue(forKey: key)
        dropProgress(key)
        publish(nil)
    }

    private func restart() {
        stop()
        warming = true
        guard !dirs.isEmpty else { publish(nil); return }
        startStream()
        startTimer()
        catchUp()
    }

    private func startStream() {
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watch = Unmanaged<TransferWatch>.fromOpaque(info).takeUnretainedValue()
            let list = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray) as? [String] ?? []
            let copy = list
            DispatchQueue.main.async { watch.ingest(copy, quiet: false) }
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags: FSEventStreamCreateFlags = [.fileEvents, .useCFTypes]
        guard let stream = FSEventStreamCreate(nil, callback, &context, dirs as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func catchUp() {
        let q = NSMetadataQuery()
        q.searchScopes = dirs
        let since = Date().addingTimeInterval(-15 * 60)
        q.predicate = NSPredicate(format: "%K >= %@", NSMetadataItemFSContentChangeDateKey, since as NSDate)
        queryObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            guard let self else { return }
            var paths: [String] = []
            for case let item as NSMetadataItem in q.results {
                if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String { paths.append(path) }
            }
            q.stop()
            self.ingest(paths, quiet: true)
            self.warming = false
        }
        query = q
        if !q.start() { warming = false }
    }

    private func tick() {
        let paths = Array(items.keys)
        ingest(paths, quiet: warming)
    }

    private func ingest(_ paths: [String], quiet: Bool) {
        let apps = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        var events: [TransferEvent] = []
        for path in paths {
            if let shelfDirectory, pathIsInside(path, directory: shelfDirectory) { continue }
            if URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            if !exists {
                if var row = items[path], row.state == "active" {
                    if hasTempSuffix(row.label) {
                        // Chrome/Safari rename the temp file when the download finishes. The final name arrives on its own.
                        items.removeValue(forKey: path)
                        stillSince.removeValue(forKey: path)
                        dropProgress(path)
                    } else {
                        row.state = "missing"
                        items[path] = row
                        events.append(TransferEvent(transfer: row, quiet: true))
                    }
                }
                continue
            }
            if isDir.boolValue && !path.lowercased().hasSuffix(".download") { continue }
            if let ev = note(path: path, apps: apps, quiet: quiet) { events.append(ev) }
        }
        if events.isEmpty {
            publish(nil)
        } else {
            for ev in events { publish(ev) }
        }
    }

    private func note(path: String, apps: [String], quiet: Bool) -> TransferEvent? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let bytes = fileBytes(path)
        let role = roleForFile(path, dirs: dirs)
        let previous = items[path]
        let changed = previous == nil || previous?.bytes != bytes
        let sample = GrowthSample(name: name, bytes: bytes, role: role, quarantine: quarantine(path), apps: apps, changed: changed)
        let kind = previous?.kind ?? classifyGrowth(sample)
        guard let kind else { return nil }
        if previous == nil { subscribe(path) }
        if previous == nil {
            stillSince[path] = (quiet && !hasTempSuffix(name)) ? Date().addingTimeInterval(-10) : Date()
        } else if changed {
            stillSince[path] = Date()
        }
        let since = stillSince[path] ?? Date()
        let still = Date().timeIntervalSince(since)
        let media = isMediaName(name)
        var row = previous ?? Transfer(id: freshID(), label: name, path: path, kind: kind, state: "active", bytes: bytes, updatedAt: Date().timeIntervalSince1970)
        row.bytes = bytes
        row.label = name
        row.kind = kind
        if changed { row.updatedAt = Date().timeIntervalSince1970 }
        let was = row.state
        if row.publishedComplete || isSettled(name: name, bytes: bytes, stillSeconds: still, media: media) {
            row.state = "done"
        } else {
            row.state = "active"
        }
        items[path] = row
        if was != row.state {
            return TransferEvent(transfer: row, quiet: quiet || warming)
        }
        if previous == nil {
            return TransferEvent(transfer: row, quiet: true)
        }
        return nil
    }

    private func subscribe(_ path: String) {
        guard subscribers[path] == nil else { return }
        let url = URL(fileURLWithPath: path)
        let token = NSProgress.addSubscriber(forFileURL: url) { [weak self] progress in
            DispatchQueue.main.async {
                self?.observe(progress, path: path)
            }
        }
        subscribers[path] = token
    }

    private func observe(_ progress: NSProgress, path: String) {
        observations[path] = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] prog, _ in
            DispatchQueue.main.async {
                self?.applyFraction(path: path, fraction: prog.fractionCompleted, finished: prog.isFinished, total: prog.totalUnitCount, completed: prog.completedUnitCount)
            }
        }
    }

    private func applyFraction(path: String, fraction: Double, finished: Bool, total: Int64, completed: Int64) {
        guard var row = items[path] else { return }
        row.fraction = fraction
        if total > 0, completed >= 0, Double(total) >= row.bytes, Double(total) < 1e15 {
            row.total = Double(total)
        }
        if finished {
            row.publishedComplete = true
            row.state = "done"
            row.fraction = 1
        }
        row.updatedAt = Date().timeIntervalSince1970
        let wasDone = items[path]?.state == "done"
        items[path] = row
        let ev = (!wasDone && row.state == "done") ? TransferEvent(transfer: row, quiet: warming) : nil
        publish(ev)
    }

    private func dropProgress(_ path: String) {
        observations[path] = nil
        if let token = subscribers.removeValue(forKey: path) { NSProgress.removeSubscriber(token) }
    }

    private func publish(_ event: TransferEvent?) {
        onChange?(Array(items.values), event)
    }

    private func fileBytes(_ path: String) -> Double {
        let n = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.doubleValue
        return n ?? 0
    }

    private func quarantine(_ path: String) -> String? {
        let key = "com.apple.quarantine"
        let size = getxattr(path, key, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size + 1)
        let n = getxattr(path, key, &buf, size, 0, 0)
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    private func freshID() -> String { "p" + String(UUID().uuidString.prefix(8)).lowercased() }
}
