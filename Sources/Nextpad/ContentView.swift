import SwiftUI
import AppKit

func copyToClipboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

struct RootView: View {
    @ObservedObject var model: AppModel
    let controller: PanelController
    var body: some View {
        Group {
            if model.collapsed {
                BubbleView(model: model,
                           onExpand: { controller.setCollapsed(false) },
                           onMoved: { o in model.setPos(Double(o.x), Double(o.y)) })
            } else {
                PanelView(model: model, onCollapse: { controller.setCollapsed(true) })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: collapsed bubble

struct BubbleView: View {
    @ObservedObject var model: AppModel
    let onExpand: () -> Void
    let onMoved: (NSPoint) -> Void
    var body: some View {
        RoundedRectangle(cornerRadius: 14).fill(Theme.paper)
            .overlay { NextpadIcon().frame(width: 26, height: 26) }
            .overlay(alignment: .topTrailing) {
                if !model.drafts.isEmpty {
                    Text("\(model.drafts.count)")
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.muted)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(Theme.line2))
                        .padding(2)
                }
            }
            // AppKit-level drag+click: move on drag, expand only on a no-move click
            .overlay { DragClickCatcher(onClick: onExpand, onMoved: onMoved) }
            .contextMenu { Button("退出 Nextpad") { NSApp.terminate(nil) } }
    }
}

// Captures mouse on the bubble: a real drag moves the window; a click (no movement) = expand.
struct DragClickCatcher: NSViewRepresentable {
    let onClick: () -> Void
    let onMoved: (NSPoint) -> Void
    func makeNSView(context: Context) -> NSView { CatcherView(onClick: onClick, onMoved: onMoved) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class CatcherView: NSView {
        private let onClick: () -> Void
        private let onMoved: (NSPoint) -> Void
        private var startMouse: NSPoint = .zero
        private var startOrigin: NSPoint = .zero
        private var moved = false
        init(onClick: @escaping () -> Void, onMoved: @escaping (NSPoint) -> Void) {
            self.onClick = onClick; self.onMoved = onMoved
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            moved = false
            startMouse = NSEvent.mouseLocation
            startOrigin = window?.frame.origin ?? .zero
        }
        override func mouseDragged(with event: NSEvent) {
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x, dy = now.y - startMouse.y
            if !moved && (abs(dx) > 6 || abs(dy) > 6) { moved = true }  // ignore click jitter
            if moved { window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)) }
        }
        override func mouseUp(with event: NSEvent) {
            if moved { if let o = window?.frame.origin { onMoved(o) } } else { onClick() }
        }
    }
}

// MARK: expanded panel

struct PanelView: View {
    @ObservedObject var model: AppModel
    let onCollapse: () -> Void
    @State private var newText = ""
    @State private var renaming = false
    @State private var renameText = ""

    static let spectrum: [Color] = [Theme.purple, Theme.blue, Theme.green, Theme.orange, Theme.red]

    var body: some View {
        VStack(spacing: 0) {
            brand
            sessionBar
            Rectangle().fill(Theme.line).frame(height: 1)
            addRow
            listOrEmpty
        }
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t).font(.system(size: 11.5)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.ink.opacity(0.92)))
                    .padding(.bottom, 12)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
    }

    private var brand: some View {
        HStack(spacing: 7) {
            NextpadIcon().frame(width: 18, height: 18)
            Text("Nextpad").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            Button(action: onCollapse) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.faint).frame(width: 11, height: 2)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11).padding(.top, 9).padding(.bottom, 7)
        .contextMenu { Button("退出 Nextpad") { NSApp.terminate(nil) } }
    }

    private var sessionBar: some View {
        HStack(spacing: 7) {
            if model.isGeneral {
                Image(systemName: "note.text").font(.system(size: 10)).foregroundStyle(Theme.faint)
            } else {
                Circle().fill(model.connected ? Theme.green : Theme.faint).frame(width: 8, height: 8)
            }
            if renaming {
                TextField(model.shortId, text: $renameText)
                    .textFieldStyle(.plain).font(.system(size: 12, weight: .semibold))
                    .onSubmit { model.setNickname(renameText); renaming = false }
            } else {
                Text(model.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .contentShape(Rectangle())
                    .onTapGesture { if !model.isGeneral { renameText = model.nickname; renaming = true } }
                Spacer(minLength: 4)
                if !model.drafts.isEmpty {
                    Text("\(model.drafts.count) 条").font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 9)
    }

    private var addRow: some View {
        TextField(model.isGeneral ? "记点什么…  Enter 添加" : "写下一条待发指令…  Enter 添加", text: $newText, axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: 12.5)).lineLimit(1...6)
            .padding(8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line2, lineWidth: 1))
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 7)
            .onSubmit {
                let v = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !v.isEmpty else { return }
                model.add(v); newText = ""; model.flash("已添加")
            }
    }

    @ViewBuilder private var listOrEmpty: some View {
        if model.drafts.isEmpty {
            VStack(spacing: 8) {
                if model.isGeneral {
                    Text("还没有备忘。").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Text("随手记一条，随时能找到。").font(.system(size: 11)).foregroundStyle(Theme.faint)
                        .multilineTextAlignment(.center)
                } else {
                    Text("这个会话还没有备忘。").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Text("切到另一个会话，这里会自动跟着变。").font(.system(size: 11)).foregroundStyle(Theme.faint)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 16)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(Array(model.drafts.enumerated()), id: \.element.id) { idx, d in
                        DraftCard(model: model, draft: d, accent: PanelView.spectrum[idx % PanelView.spectrum.count])
                    }
                }
                .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 8)
            }
            .scrollDisabled(model.editingId != nil)  // freeze outer list while editing a card
        }
    }
}

// MARK: card

struct DraftCard: View {
    @ObservedObject var model: AppModel
    let draft: Draft
    let accent: Color
    @State private var hover = false
    @State private var editText = ""
    private var editing: Bool { model.editingId == draft.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editing {
                TextEditor(text: $editText)
                    .font(.system(size: 12.5)).scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 200)
                    .padding(6)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent, lineWidth: 1))
                HStack(spacing: 6) {
                    Spacer()
                    Button("取消") { model.editingId = nil }.buttonStyle(.plain)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    Button("保存") {
                        let v = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !v.isEmpty else { return }
                        model.update(draft.id, v); model.editingId = nil; model.flash("已保存")
                    }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.green, in: RoundedRectangle(cornerRadius: 7))
                }
            } else {
                Text(draft.text).font(.system(size: 12.5)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // weighted actions: copy heaviest (card color), edit medium, delete lightest
                HStack(spacing: 4) {
                    Spacer()
                    actButton("doc.on.doc", accent, 13) { copyToClipboard(draft.text); model.flash("已复制 · 去粘贴") }
                    actButton("pencil", Theme.muted, 12) { editText = draft.text; model.editingId = draft.id }
                    actButton("trash", Theme.faint, 11) { model.delete(draft.id); model.flash("已删除") }
                }
                .opacity(hover ? 1 : 0)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(hover ? Theme.line2 : Theme.line, lineWidth: 1))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(accent).frame(width: 3).padding(.vertical, 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !editing { copyToClipboard(draft.text); model.flash("已复制 · 去粘贴") } }
        .onHover { hover = $0 }
    }

    private func actButton(_ symbol: String, _ color: Color, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(color)
                .frame(width: 24, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
