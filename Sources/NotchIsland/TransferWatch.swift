import AppKit
import CoreServices
import IslandCore

struct TransferEvent {
    var transfer: Transfer
    var quiet: Bool
}

/// Watches the folders Brain names. Ticks stay in this process. Brain hears start and done.
/// v0.3.1: only a file that grows after the helper started (or that a publisher reports progress for) is a transfer.
/// Files already there at start, and files moved or renamed in Finder, form a silent baseline. The one-second tick
/// runs only while something is active or being watched, and the list is published only when it changed.
final class TransferWatch {
    private(set) var dirs: [String] = []
    private var items: [String: Transfer] = [:]
    private var stillSince: [String: Date] = [:]
    private var gate = GrowthGate()
    private var stream: FSEventStreamRef?
    private var query: NSMetadataQuery?
    private var queryObserver: NSObjectProtocol?
    private var timer: Timer?
    private var subscribers: [String: Any] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]
    private var warming = true
    private var warmGen = 0
    private var lastPublished: [Transfer] = []
    var shelfDirectory: String?
    var onChange: (([Transfer], TransferEvent?) -> Void)?

    func setDirs(_ incoming: [String]) {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        dirs = resolveWatchDirs(incoming, downloads: downloads)
        restart()
    }

    func stop() {
        stopTimer()
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
        for (_, token) in subscribers { Progress.removeSubscriber(token) }
        subscribers.removeAll()
        observations.removeAll()
    }

    func revealPath(id: String) -> String? { items.values.first { $0.id == id }?.path }

    func mark(id: String, state: String) {
        guard let key = items.first(where: { $0.value.id == id })?.key else { return }
        items[key]?.state = state
        if items[key]?.doneAt == nil { items[key]?.doneAt = Date().timeIntervalSince1970 }
        publish(nil)
    }

    func dismiss(id: String) {
        guard let key = items.first(where: { $0.value.id == id })?.key else { return }
        let row = items.removeValue(forKey: key)
        stillSince.removeValue(forKey: key)
        dropProgress(key)
        gate.settle(path: key, bytes: row?.bytes ?? 0)
        publish(nil)
    }

    private func restart() {
        stop()
        warming = true
        gate.reset()
        // rows that were still being written survive a restart; finished ones do not come back
        items = items.filter { $0.value.state == "active" }
        for key in items.keys { subscribe(key) }
        guard !dirs.isEmpty else { publish(nil); return }
        startStream()
        if !items.isEmpty { ensureTimer() }
        catchUp()
        // warm-up never lasts more than a few seconds, even if Spotlight is slow or off
        warmGen += 1
        let gen = warmGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, gen == self.warmGen else { return }
            self.warming = false
        }
        publish(nil)
    }

    private func startStream() {
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watch = Unmanaged<TransferWatch>.fromOpaque(info).takeUnretainedValue()
            let list = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray) as? [String] ?? []
            let copy = list
            DispatchQueue.main.async { watch.ingest(copy) }
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, dirs as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Files written in the last 15 minutes become the quiet baseline. A temp-suffix file is watched instead, so a
    /// download still running at launch shows up as soon as it grows.
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
            self.warming = true
            self.ingest(paths)
            self.warming = false
        }
        query = q
        if !q.start() { warming = false }
    }

    private func tick() {
        let paths = items.filter { $0.value.state == "active" }.map { $0.key } + gate.candidatePaths
        ingest(paths)
        if !items.values.contains(where: { $0.state == "active" }) && !gate.isWatching {
            stopTimer()
        }
    }

    /// Finished and missing rows leave two minutes after they finished, and at most 40 rows are kept.
    private func prune() {
        let now = Date().timeIntervalSince1970
        var drop = items.filter { !trayKeepsTransfer($0.value, now: now) }.map { $0.key }
        let keep = 40
        if items.count - drop.count > keep {
            let rest = items.filter { !drop.contains($0.key) }.sorted { a, b in
                if (a.value.state == "active") != (b.value.state == "active") { return a.value.state != "active" }
                return a.value.updatedAt < b.value.updatedAt
            }
            drop += rest.prefix(items.count - drop.count - keep).map { $0.key }
        }
        for key in drop {
            let row = items.removeValue(forKey: key)
            stillSince.removeValue(forKey: key)
            dropProgress(key)
            gate.settle(path: key, bytes: row?.bytes ?? 0)
        }
    }

    private func ingest(_ paths: [String]) {
        prune()
        let apps = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        let now = Date().timeIntervalSince1970
        var events: [TransferEvent] = []
        for path in Set(paths) {
            if let shelfDirectory, pathIsInside(path, directory: shelfDirectory) { continue }
            if URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            if !exists {
                if var row = items[path], row.state == "active" {
                    if let final = finalNameForTemp(path) {
                        // Chrome/Safari/Firefox rename the temp file when the download finishes. The final name is a
                        // transfer even though it never grows under that name.
                        items.removeValue(forKey: path)
                        stillSince.removeValue(forKey: path)
                        dropProgress(path)
                        gate.expect(finalPath: final, now: now)
                        if FileManager.default.fileExists(atPath: final), let ev = sight(final, apps: apps, now: now) { events.append(ev) }
                    } else {
                        row.state = "missing"
                        row.doneAt = now
                        items[path] = row
                        events.append(TransferEvent(transfer: row, quiet: true))
                    }
                } else if items[path] != nil {
                    // a finished row whose file was moved or deleted in Finder just leaves
                    let row = items.removeValue(forKey: path)
                    stillSince.removeValue(forKey: path)
                    dropProgress(path)
                    _ = row
                    gate.forget(path: path)
                } else {
                    if let final = finalNameForTemp(path), gate.candidates[path] != nil {
                        gate.expect(finalPath: final, now: now)
                        if FileManager.default.fileExists(atPath: final), let ev = sight(final, apps: apps, now: now) { events.append(ev) }
                    }
                    gate.forget(path: path)
                    dropProgress(path)
                }
                continue
            }
            if isDir.boolValue && !path.lowercased().hasSuffix(".download") { continue }
            if items[path] != nil {
                if let ev = update(path: path) { events.append(ev) }
            } else if let ev = sight(path, apps: apps, now: now) {
                events.append(ev)
            }
        }
        if items.values.contains(where: { $0.state == "active" }) || gate.isWatching { ensureTimer() }
        if events.isEmpty {
            publish(nil)
        } else {
            for ev in events { publish(ev) }
        }
    }

    /// A file that is not a row yet: baseline, watch, or promote.
    private func sight(_ path: String, apps: [String], now: Double) -> TransferEvent? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let bytes = fileBytes(path)
        let role = roleForFile(path, dirs: dirs)
        let sample = GrowthSample(name: name, bytes: bytes, role: role, quarantine: quarantine(path), apps: apps, changed: true)
        guard let kind = classifyGrowth(sample) else { return nil }
        switch gate.observe(path: path, name: name, bytes: bytes, now: now, warming: warming) {
        case .ignore:
            dropProgress(path)
            return nil
        case .watch:
            subscribe(path)
            return nil
        case .promote:
            return promote(path: path, name: name, kind: kind, bytes: bytes)
        }
    }

    private func promote(path: String, name: String, kind: String, bytes: Double) -> TransferEvent? {
        let row = Transfer(id: freshID(), label: name, path: path, kind: kind, state: "active", bytes: bytes, updatedAt: Date().timeIntervalSince1970)
        items[path] = row
        stillSince[path] = Date()
        subscribe(path)
        ensureTimer()
        return TransferEvent(transfer: row, quiet: true)
    }

    /// A row we already show: still growing, or settled.
    private func update(path: String) -> TransferEvent? {
        guard let previous = items[path] else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let bytes = fileBytes(path)
        let changed = previous.bytes != bytes
        if changed { stillSince[path] = Date() }
        let since = stillSince[path] ?? Date()
        let still = Date().timeIntervalSince(since)
        var row = previous
        row.bytes = bytes
        row.label = name
        if changed { row.updatedAt = Date().timeIntervalSince1970 }
        let was = row.state
        if row.publishedComplete && !changed || isSettled(name: name, bytes: bytes, stillSeconds: still, media: isMediaName(name)) {
            row.state = "done"
        } else if changed || was == "active" {
            row.state = "active"
        }
        if row.state == "done" && was != "done" { row.doneAt = Date().timeIntervalSince1970 }
        if row.state == "active" { row.doneAt = nil }
        items[path] = row
        if was != row.state {
            return TransferEvent(transfer: row, quiet: false)
        }
        return nil
    }

    private func subscribe(_ path: String) {
        guard subscribers[path] == nil else { return }
        let url = URL(fileURLWithPath: path)
        let token = Progress.addSubscriber(forFileURL: url) { [weak self] progress in
            DispatchQueue.main.async {
                self?.observe(progress, path: path)
            }
            return nil
        }
        subscribers[path] = token
    }

    private func observe(_ progress: Progress, path: String) {
        observations[path] = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] prog, _ in
            DispatchQueue.main.async {
                self?.applyFraction(path: path, fraction: prog.fractionCompleted, finished: prog.isFinished, total: prog.totalUnitCount, completed: prog.completedUnitCount)
            }
        }
    }

    private func applyFraction(path: String, fraction: Double, finished: Bool, total: Int64, completed: Int64) {
        if items[path] == nil {
            // a publisher reporting progress on a file we were only watching makes it a transfer
            guard subscribers[path] != nil, !finished, fraction < 1, FileManager.default.fileExists(atPath: path) else { return }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let role = roleForFile(path, dirs: dirs)
            let kind = classifyGrowth(GrowthSample(name: name, bytes: fileBytes(path), role: role, quarantine: quarantine(path), changed: true)) ?? (role == "drive" ? "drive" : "download")
            gate.promote(path: path)
            if let ev = promote(path: path, name: name, kind: kind, bytes: fileBytes(path)) { publish(ev) }
        }
        guard var row = items[path] else { return }
        row.fraction = (fraction * 100).rounded() / 100
        if total > 0, completed >= 0, Double(total) >= row.bytes, Double(total) < 1e15 {
            row.total = Double(total)
        }
        let wasDone = row.state == "done"
        if finished {
            row.publishedComplete = true
            row.state = "done"
            row.fraction = 1
            if row.doneAt == nil { row.doneAt = Date().timeIntervalSince1970 }
        }
        if row != items[path] { row.updatedAt = Date().timeIntervalSince1970 }
        items[path] = row
        let ev = (!wasDone && row.state == "done") ? TransferEvent(transfer: row, quiet: false) : nil
        publish(ev)
    }

    private func dropProgress(_ path: String) {
        observations[path] = nil
        if let token = subscribers.removeValue(forKey: path) { Progress.removeSubscriber(token) }
    }

    /// Only a real change (or an event) reaches the controller, so an idle tick never re-lays out the island.
    private func publish(_ event: TransferEvent?) {
        let list = Array(items.values)
        if event == nil && !transfersChanged(lastPublished, list) { return }
        lastPublished = list
        onChange?(list, event)
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
