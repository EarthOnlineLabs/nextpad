// Nextpad — native macOS app entry. Floating per-session prompt stash.

import AppKit
import SwiftUI

// MARK: - Panel (becomes key so input/rename fields accept typing without activating the app)

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Responds to the FIRST click even when the window isn't active, so the bubble/buttons
/// don't swallow the first click while Claude is the frontmost app.
final class KeyHostingView: NSHostingView<RootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Theme

extension Color {
    init(_ hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0)
    }
}

enum Theme {
    static let purple = Color(0x8A43E6), blue = Color(0x4FA8F0), green = Color(0x1FA45D)
    static let orange = Color(0xF4811E), red = Color(0xE8482A)
    static let paper = Color(0xFBF8F3), paper2 = Color(0xF4EEE3), card = Color(0xFFFEFB)
    static let ink = Color(0x1A1A1F), muted = Color(0x6B6258), faint = Color(0xA79D8E)
    static let line = Color(0xEBE3D5), line2 = Color(0xDED5C4)
}

struct NextpadIcon: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.23).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: s * 0.23).stroke(Theme.line2, lineWidth: 1))
                VStack(alignment: .leading, spacing: s * 0.07) {
                    Capsule().fill(Theme.purple).frame(width: s * 0.53, height: s * 0.10)
                    Capsule().fill(Theme.blue).frame(width: s * 0.53, height: s * 0.10)
                    HStack(spacing: s * 0.06) {
                        Capsule().fill(Theme.green).frame(width: s * 0.37, height: s * 0.10)
                        RoundedRectangle(cornerRadius: s * 0.03).fill(Theme.orange)
                            .frame(width: s * 0.10, height: s * 0.10)
                    }
                }
            }
        }
    }
}

// MARK: - Window sizing / collapse (top-right anchored)

final class PanelController {
    weak var panel: NSPanel?
    let model: AppModel
    static let expanded = NSSize(width: 344, height: 500)
    static let bubble = NSSize(width: 44, height: 44)
    init(model: AppModel) { self.model = model }

    func setCollapsed(_ c: Bool) {
        model.setCollapsed(c)
        guard let p = panel else { return }
        let target = c ? PanelController.bubble : (model.savedPanelSize ?? PanelController.expanded)
        let f = p.frame
        let newX = f.maxX - target.width   // keep top-right corner fixed
        let newY = f.maxY - target.height
        if c { p.minSize = PanelController.bubble; p.maxSize = PanelController.bubble; p.styleMask.remove(.resizable) }
        else { p.minSize = NSSize(width: 280, height: 220); p.maxSize = NSSize(width: 720, height: 1400); p.styleMask.insert(.resizable) }
        p.setFrame(NSRect(x: newX, y: newY, width: target.width, height: target.height), display: true)
        p.isMovableByWindowBackground = !c   // bubble drags via the catcher, not the window bg
        model.setPos(Double(newX), Double(newY))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var controller: PanelController!
    var panel: FloatingPanel?
    var coordinator: FocusCoordinator?
    var watcher: SessionFocusWatcher?
    var tailer: LogTailer?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu() // enables Cmd+C/V/X/A (paste!) + Cmd+Q via the responder chain
        controller = PanelController(model: model)

        let snapshotting = ProcessInfo.processInfo.environment["NEXTPAD_SNAPSHOT"] != nil
        if snapshotting { seedDemo() }

        let size = model.collapsed ? PanelController.bubble : (model.savedPanelSize ?? PanelController.expanded)
        let host = KeyHostingView(rootView: RootView(model: model, controller: controller))
        host.frame = NSRect(origin: .zero, size: size)

        let panel = FloatingPanel(contentRect: host.frame,
                                  styleMask: [.nonactivatingPanel, .borderless],
                                  backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = !model.collapsed   // expanded: drag bg; bubble: handled by catcher
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        if model.collapsed { panel.minSize = PanelController.bubble; panel.maxSize = PanelController.bubble }
        else { panel.minSize = NSSize(width: 280, height: 220); panel.maxSize = NSSize(width: 720, height: 1400); panel.styleMask.insert(.resizable) }
        panel.delegate = self
        let savedOnScreen = model.savedPos.map { p in
            NSScreen.screens.contains { $0.frame.intersects(NSRect(origin: p, size: size)) }
        } ?? false
        if let pos = model.savedPos, savedOnScreen {
            panel.setFrameOrigin(pos)
        } else if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 24, y: vf.maxY - size.height - 28))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        controller.panel = panel

        // Hybrid focus signal: log (fast) + file (robust fallback), merged by the coordinator.
        let coordinator = FocusCoordinator(
            onFocus: { [weak self] sid in DispatchQueue.main.async { self?.model.focus(sid) } })
        let watcher = SessionFocusWatcher(
            onFocus: { sid, t in coordinator.report(sid, at: t, source: "file") },
            onConnected: { [weak self] c in DispatchQueue.main.async { self?.model.setConnected(c) } })
        let tailer = LogTailer(onFocus: { sid, t in coordinator.report(sid, at: t, source: "log") })
        if !snapshotting { watcher.start(); tailer.start() }  // snapshot keeps the seeded demo session
        self.coordinator = coordinator; self.watcher = watcher; self.tailer = tailer

        if !snapshotting { setupActivationFollowing() }

        if snapshotting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                Snapshot.write(view: host, to: "/tmp/nextpad-shot.png")
                NSApp.terminate(nil)
            }
        }
    }

    // Poll frontmost app: Claude → track session; other apps → switch to general memo.
    // Re-order panel to front on every switch so it stays above all windows.
    private var lastFront: String?
    private func setupActivationFollowing() {
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if front == self.lastFront { return }
            self.lastFront = front
            let isClaude = front == "com.anthropic.claudefordesktop"
            let isSelf = front == Bundle.main.bundleIdentifier
            vlog("poll front=\(front ?? "nil") isClaude=\(isClaude)")
            if isClaude {
                self.model.restoreClaudeSession()
            } else if !isSelf {
                self.model.focus("general")
            }
            if !isSelf { self.panel?.orderFrontRegardless() }
        }
        RunLoop.main.add(timer, forMode: .common)
        vlog("setupActivationFollowing started")
    }

    // Standard Edit menu so text fields get Cut/Copy/Paste/Select-All/Undo via key equivalents.
    // (An accessory app has no menu bar shown, but NSApp still routes these key equivalents.)
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Nextpad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = main
    }

    private func seedDemo() {
        model.focus("local_demo89ad8823")
        model.add("把 token 刷新逻辑抽成独立 service")
        model.add("补 401 和网络超时两个分支的错误处理")
        model.add("等上面跑完，review 一遍命名统一成 camelCase，然后更新 README 的 API 章节")
    }
}

// Diagnostic logging — OFF by default (no writes for end users). Set NEXTPAD_DEBUG=1 to enable.
func vlog(_ s: String) {
    guard ProcessInfo.processInfo.environment["NEXTPAD_DEBUG"] != nil else { return }
    let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, s)
    guard let d = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/nextpad-vis.log")
    if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
    else { try? d.write(to: url) }
}

enum Snapshot {
    static func write(view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        guard !model.collapsed, let w = notification.object as? NSWindow else { return }
        model.setPanelSize(Double(w.frame.width), Double(w.frame.height))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
