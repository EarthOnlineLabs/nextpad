import Foundation
import CoreServices   // FSEvents

/// Reports the focused Claude session **ID only** by watching Claude's per-session metadata
/// files — never any conversation content. Replaces the old `main.log` tail, which was capped
/// at ~10MB and froze when full (stranding focus). Each session has a small file at
/// `~/Library/Application Support/Claude/claude-code-sessions/<ws>/<proj>/local_<uuid>.json`
/// with a dedicated `lastFocusedAt` epoch-ms field (distinct from `lastActivityAt`, so it
/// tracks *focus* not agent activity). The focused session = the file with the max
/// `lastFocusedAt`. These files are rewritten in place, so there is no size cap to freeze.
///
/// Updates are **FSEvents-driven** (fires ~instantly on a focus switch, ~0 idle CPU), with a
/// slow safety poll as a backstop and to (re)arm the stream if the dir appears after launch.
///
/// Privacy: we open each file but retain **only** `sessionId` + `lastFocusedAt`. Transcripts /
/// conversation content live elsewhere and are never read.
final class SessionFocusWatcher {
    private let dir = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    private let queue = DispatchQueue(label: "site.earthonline.nextpad.focuswatcher", qos: .utility)
    private var safety: DispatchSourceTimer?
    private var stream: FSEventStreamRef?
    /// Reports (sessionId, lastFocusedAt-in-seconds) so the coordinator can rank it against the log.
    private let onFocus: (String, Double) -> Void
    private let onConnected: (Bool) -> Void

    /// (sessionId, lastFocusedAt) for every file that carries the field. Keyed by filename
    /// (`local_<uuid>.json`) — unique per session, identical from the scan or from FSEvents.
    private var focusByName: [String: (sid: String, focus: Double)] = [:]
    /// Last-seen content-modification date per file, so we only re-parse files that changed.
    private var mtimeByName: [String: Date] = [:]
    private var lastEmittedSid: String?

    init(onFocus: @escaping (String, Double) -> Void, onConnected: @escaping (Bool) -> Void) {
        self.onFocus = onFocus
        self.onConnected = onConnected
    }

    func start() {
        queue.async { [weak self] in self?.scan(); self?.armStreamIfNeeded() }   // prime
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)   // backstop only; FSEvents is primary
        t.setEventHandler { [weak self] in self?.scan(); self?.armStreamIfNeeded() }
        t.resume()
        safety = t
    }

    func stop() {
        safety?.cancel(); safety = nil
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
    }

    // MARK: - FSEvents (primary, instant)

    private func armStreamIfNeeded() {
        guard stream == nil else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return }
        let callback: FSEventStreamCallback = { _, info, _, pathsPtr, _, _ in
            guard let info else { return }
            let me = Unmanaged<SessionFocusWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(pathsPtr, to: CFArray.self) as? [String]) ?? []
            me.handleEvents(paths)   // already on `queue` (set below)
        }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, [dir] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.05, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        vlog("focuswatcher FSEvents armed")
    }

    private func handleEvents(_ paths: [String]) {
        var touched = false
        for p in paths {
            let name = (p as NSString).lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
            if ingest(URL(fileURLWithPath: p), name: name) { touched = true }
        }
        if touched { recomputeAndEmit() }
    }

    // MARK: - Full scan (prime + safety backstop)

    private func scan() {
        guard let en = FileManager.default.enumerator(
            at: URL(fileURLWithPath: dir, isDirectory: true),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else {
            focusByName.removeAll(); mtimeByName.removeAll(); onConnected(false); return
        }
        var seen = Set<String>()
        for case let url as URL in en {
            let name = url.lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
            seen.insert(name)
            _ = ingest(url, name: name)
        }
        for name in mtimeByName.keys where !seen.contains(name) {   // sessions deleted
            mtimeByName[name] = nil; focusByName[name] = nil
        }
        recomputeAndEmit()
    }

    // MARK: - Shared

    /// Read/refresh one file. Returns true if `focusByName` may have changed.
    @discardableResult
    private func ingest(_ url: URL, name: String) -> Bool {
        guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            guard mtimeByName[name] != nil || focusByName[name] != nil else { return false }  // gone
            mtimeByName[name] = nil; focusByName[name] = nil; return true
        }
        if mtimeByName[name] == mtime { return false }   // unchanged since last good read
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false   // mid-write / unreadable: keep last good value, retry on next event/poll
        }
        mtimeByName[name] = mtime
        if let sid = obj["sessionId"] as? String,
           let focus = (obj["lastFocusedAt"] as? NSNumber)?.doubleValue {
            let changed = focusByName[name]?.sid != sid || focusByName[name]?.focus != focus
            focusByName[name] = (sid: sid, focus: focus)
            return changed
        } else {
            let had = focusByName[name] != nil
            focusByName[name] = nil   // valid JSON but no lastFocusedAt (old schema)
            return had
        }
    }

    private func recomputeAndEmit() {
        let best = focusByName.values.max { $0.focus < $1.focus }
        onConnected(best != nil)
        if let best, best.sid != lastEmittedSid {
            lastEmittedSid = best.sid
            vlog("focuswatcher emit \(best.sid) (files=\(mtimeByName.count) withFocus=\(focusByName.count))")
            onFocus(best.sid, best.focus / 1000.0)   // ms → s, comparable to wall clock
        }
    }
}
