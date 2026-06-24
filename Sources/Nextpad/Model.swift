import Foundation
import Combine

struct Draft: Codable, Identifiable, Equatable {
    let id: String
    var text: String
    var ts: Double
    init(text: String) { id = UUID().uuidString; self.text = text; ts = Date().timeIntervalSince1970 }
}

struct Store: Codable {
    var stash: [String: [Draft]] = [:]   // keyed by session id
    var nicknames: [String: String] = [:]
    var collapsed: Bool = false
    var pos: [Double]? = nil             // [x, y] (AppKit screen coords)
    var panelSize: [Double]? = nil       // [w, h]
}

/// App-wide observable state. Drafts are derived from `store`; mutations call
/// `objectWillChange` since `store` isn't itself @Published.
final class AppModel: ObservableObject {
    @Published private(set) var currentSessionId = "general"
    @Published private(set) var connected = false
    @Published var collapsed = false
    @Published var toast: String?
    @Published var editingId: String?

    private var store = Store()
    private var toastSeq = 0
    private let fileURL: URL = {
        if ProcessInfo.processInfo.environment["NEXTPAD_SNAPSHOT"] != nil {
            return URL(fileURLWithPath: "/tmp/nextpad-snapshot-data.json")  // QA: never touch real data
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nextpad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nextpad-data.json")
    }()

    init() { load(); collapsed = store.collapsed }

    // Derived view state
    var drafts: [Draft] { store.stash[currentSessionId] ?? [] }
    var nickname: String { store.nicknames[currentSessionId] ?? "" }
    var isGeneral: Bool { currentSessionId == "general" }
    var shortId: String {
        guard currentSessionId != "general" else { return "备忘录" }
        var s = currentSessionId
        if s.hasPrefix("local_") { s.removeFirst(6) }
        if s.hasPrefix("ditto_") { s.removeFirst(6) }
        return String(s.prefix(8))
    }
    var label: String { nickname.isEmpty ? shortId : nickname }
    var savedPos: CGPoint? { store.pos.map { CGPoint(x: $0[0], y: $0[1]) } }
    var savedPanelSize: CGSize? { store.panelSize.map { CGSize(width: $0[0], height: $0[1]) } }

    // Mutations
    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !t.isEmpty else { return }
        store.stash[currentSessionId, default: []].append(Draft(text: t)); persistAndNotify()
    }
    func update(_ id: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !t.isEmpty else { return }
        guard var arr = store.stash[currentSessionId], let i = arr.firstIndex(where: { $0.id == id }) else { return }
        arr[i].text = t; store.stash[currentSessionId] = arr; persistAndNotify()
    }
    func delete(_ id: String) { store.stash[currentSessionId]?.removeAll { $0.id == id }; persistAndNotify() }
    func setNickname(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.nicknames[currentSessionId] = n.isEmpty ? nil : n; persistAndNotify()
    }
    func setCollapsed(_ c: Bool) { collapsed = c; store.collapsed = c; save() }
    func setPos(_ x: Double, _ y: Double) { store.pos = [x, y]; save() }
    func setPanelSize(_ w: Double, _ h: Double) { store.panelSize = [w, h]; save() }

    // Track last Claude session so we can restore it instantly on app-switch back.
    private var lastClaudeSessionId: String?

    // From SessionFocusWatcher (main thread)
    func focus(_ sid: String) {
        vlog("model.focus \(sid) was=\(currentSessionId)")
        if sid != "general" { lastClaudeSessionId = sid }
        if sid != currentSessionId { currentSessionId = sid }
    }
    func restoreClaudeSession() {
        if let sid = lastClaudeSessionId, sid != currentSessionId {
            vlog("model.restoreClaude → \(sid)")
            currentSessionId = sid
        }
    }
    func setConnected(_ c: Bool) { if c != connected { connected = c } }

    func flash(_ s: String) {
        toast = s; toastSeq += 1; let seq = toastSeq
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self, self.toastSeq == seq else { return }
            self.toast = nil
        }
    }

    private func persistAndNotify() { objectWillChange.send(); save() }
    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Store.self, from: data) else { return }
        store = s
    }
    private func save() {
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: fileURL) }
    }
}
