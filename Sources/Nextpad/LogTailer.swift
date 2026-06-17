import Foundation

/// Tails Claude's local logs for the focused session ID — the **fast path** of the hybrid signal.
/// Claude logs `setFocusedSession: sessionId=local_<uuid>` ~instantly on a focus switch — roughly
/// 1s before the per-session JSON file is flushed to disk. So when a log is being written, this
/// beats the file signal and switching feels immediate.
///
/// The live log's *filename is version-dependent* (it was `main.log`; app 1.13576.0 moved it to
/// `main1.log`) and it rotates/freezes at ~10MB. So we don't hardcode a name: we tail **appends to
/// any `main*.log`**. Frozen/rotated logs simply stop growing and are ignored; if no log is being
/// written at all (old version / nothing focused), this stays silent and the file signal carries
/// focus on its own. Reads only `setFocusedSession` session IDs — never conversation content.
final class LogTailer {
    private let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Claude")
    private let queue = DispatchQueue(label: "site.earthonline.nextpad.logtailer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var offsets: [String: UInt64] = [:]
    /// Reports (sessionId, detectionWallTime). detectionWallTime ≈ the focus moment (log flushes
    /// per-line; we poll every 0.2s), on the same wall clock the file signal uses.
    private let onFocus: (String, Double) -> Void
    private static let re = try! NSRegularExpression(pattern: "setFocusedSession: sessionId=(local_[^\\s,]+)")

    init(onFocus: @escaping (String, Double) -> Void) { self.onFocus = onFocus }

    func start() {
        queue.async { [weak self] in self?.prime() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }
    func stop() { timer?.cancel(); timer = nil }

    private func mainLogs() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasPrefix("main") && $0.hasSuffix(".log") }
            .map { (dir as NSString).appendingPathComponent($0) }
    }
    private func size(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64
    }

    /// Skip all existing content at startup — only future appends are focus events worth acting on.
    /// (Initial focus comes from the file signal; the log only accelerates subsequent switches.)
    private func prime() { for p in mainLogs() { offsets[p] = size(p) ?? 0 } }

    private func poll() {
        for p in mainLogs() {
            guard let sz = size(p) else { continue }
            var off = offsets[p] ?? (sz > 8192 ? sz - 8192 : 0)   // first-seen file: only recent tail
            if sz < off { off = 0 }                                // truncated / recreated
            guard sz > off else { offsets[p] = sz; continue }
            guard let fh = FileHandle(forReadingAtPath: p) else { continue }
            try? fh.seek(toOffset: off)
            let data = (try? fh.readToEnd()) ?? Data()
            try? fh.close()
            offsets[p] = sz
            if let sid = lastFocus(in: String(decoding: data, as: UTF8.self)) {
                onFocus(sid, Date().timeIntervalSince1970)
            }
        }
    }

    private func lastFocus(in text: String) -> String? {
        let ns = text as NSString
        var sid: String?
        for m in LogTailer.re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            sid = ns.substring(with: m.range(at: 1))   // regex only matches local_ ids (skips null/cloud)
        }
        return sid
    }
}
