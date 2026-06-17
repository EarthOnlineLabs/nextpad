import Foundation

/// Merges the two focus signals into one authoritative session ID.
///
/// - `LogTailer` (fast path): reports ~instantly on a switch, but only while a log is being written.
/// - `SessionFocusWatcher` (fallback): always available, but ~1s behind (Claude debounces the file).
///
/// Each reports `(sid, logicalTime)` where `logicalTime` is ~the focus moment on the shared wall
/// clock (log: detection time; file: `lastFocusedAt`). We keep the highest logical time seen
/// (high-water mark): a fresh log event wins instantly; if the log freezes or Claude changes its
/// format, the file's newer events overtake the stale mark within ~1s. This is **only-up** — worst
/// case is the file-only ~1s, and the old "stuck focus / wrong session" bug cannot recur (a frozen
/// log emits nothing, so it can never hold focus against the live file).
final class FocusCoordinator {
    private let queue = DispatchQueue(label: "site.earthonline.nextpad.coordinator")
    private var hwm: Double = 0
    private var currentSid: String?
    private let onFocus: (String) -> Void

    init(onFocus: @escaping (String) -> Void) { self.onFocus = onFocus }

    func report(_ sid: String, at logicalTime: Double, source: String) {
        queue.async { [weak self] in
            guard let self else { return }
            // Reject future-dated events (clock skew / corrupt file) — they'd poison the high-water
            // mark and freeze focus until wall-clock catches up.
            guard logicalTime <= Date().timeIntervalSince1970 + 5 else { return }
            guard logicalTime > self.hwm else { return }
            self.hwm = logicalTime
            guard sid != self.currentSid else { return }
            self.currentSid = sid
            vlog("coordinator focus=\(sid) via \(source)")
            self.onFocus(sid)
        }
    }
}
