# Nextpad — Spec

> A privacy-clean, per-session prompt stash that floats over the Claude desktop app
> and **auto-follows your current session**. By Earth Online Lab. Working logo
> family: rainbow pill.

Status: native rewrite (Swift / macOS). UX + exact visual design were validated against an
earlier Electron prototype.

---

## 1. What it is (one line)

While your AI coding agent works, you stash the follow-up instructions you think of —
**each Claude session has its own stash, bound automatically**. Switch sessions, the stash
switches with you. Zero clicks, zero config. It never reads a word of your conversations.

## 2. The three values it must convey (north stars)

1. **有用 (Useful)** — solves the real pain: ideas burst while the agent works; with many
   parallel sessions/projects you lose track of which follow-up belongs where. (Validated:
   the user currently hand-rolls this in a Feishu self-chat and mixes them up.)
2. **小巧 (Small)** — a real "pill": ~2–3MB native app, tiny RAM, installs/uninstalls in
   seconds, leaves nothing behind. (This is WHY we left Electron — 150MB contradicts the pill.)
3. **可信赖 / 善意 (Trustworthy / benevolent)** — "一个字都不读，为了让你心里舒服."
   Reads only an **anonymous session-focus signal (a session ID)** from Claude's own local log;
   never conversation content. No app patching, no injection, fully local, open-source/auditable.

## 3. How the magic works (the hybrid signal)

Two independent signals from the Claude desktop app (Electron, `com.anthropic.claudefordesktop`),
merged into one authoritative focused-session ID. Both expose **only a session ID** (`local_<uuid>`)
— never transcripts, never conversation text. That ID is the entire binding mechanism + the
privacy story.

1. **Fast path — the log.** Claude logs `setFocusedSession: sessionId=local_<uuid>` ~instantly on
   a focus switch. Nextpad tails it and follows in ≤0.2s. The live log's filename is
   version-dependent (it was `~/Library/Logs/Claude/main.log`; app 1.13576.0 moved it to
   `main1.log`) and it freezes at ~10MB — so Nextpad tails **appends to any `main*.log`** and never
   relies on a single name. Reads only `setFocusedSession` IDs.
2. **Fallback — the file.** Each session has `…/claude-code-sessions/<ws>/<proj>/local_<uuid>.json`
   with a dedicated **`lastFocusedAt`** field (epoch ms), *separate from* `lastActivityAt` (agent
   activity). The focused session = the file with the max `lastFocusedAt`. This is **non-capped**
   (per-file, rewritten in place) so it can never freeze — but Claude debounces the write, so it
   lands ~1s after the switch. Reads only `sessionId` + `lastFocusedAt`.

A coordinator keeps the most-recent focus event by timestamp: a fresh **log** event wins instantly;
if the log freezes or Claude moves/renames it, the **file's** newer events overtake within ~1s.
This is **only-up** — best case ~instant (log), worst case ~1s (file), and the old "stuck
focus / every session shows the same pad" bug cannot recur (a frozen log emits nothing, so it can
never hold focus against the live file).

> ✅ ROOT-FIXED (2026-06, see HANDOVER.md). The original version tailed only `main.log`, which
> **caps at ~10MB and freezes when full** → focus sticks → all sessions show the same pad. We added
> the non-capped `lastFocusedAt` file as a robust baseline (the idle-switch experiment proved it's
> focus-specific: a background agent bumped `lastActivityAt` for 4.5h while `lastFocusedAt` stayed
> put), then kept the log as a measured ~1s-faster accelerator. `.sessionId` == the log's
> `local_<uuid>` == the old key, so existing stashes stay bound with zero migration. Honest
> degradation: no signal at all (Claude not installed / both unavailable) → grey `● 未连接`, focus
> stops updating — never the wrong session. (Other signals stay ruled out: AX title static; file
> mtime is "active" not "focused"; bridge-state stale; IndexedDB opaque; CDP too heavy.)

## 4. Form factor

- **Notarized, NON-sandboxed, LSUIElement** macOS app (no Dock icon; lives as a floating
  panel + a minimal menubar item). Non-sandboxed because it must read another app's log;
  trust is preserved by being open-source + only reading the ID + transparent README.
- A floating **NSPanel** with two states:
  - **Expanded panel** (~344×500): brand bar · session bar (● dot + editable session label +
    count) · add field (auto-grow) · list of draft cards (copy / edit / delete on hover).
  - **Collapsed bubble** (~44×44): rainbow icon + count badge. Unobtrusive.
- **Always-on-top**, visible on all Spaces, ideally over fullscreen.
- **Freely draggable** in both states (drag anywhere non-interactive; no movement = click).
- **Collapse anchors the top-right corner** (shrinks rightward); **expand grows leftward**.
- Position / size / collapsed state persisted.

## 5. Features (v1 scope)

DO:
- Per-session stash, auto-bound via log tail (ID only).
- Add / edit / delete drafts; auto-grow input; Enter to add.
- Click a draft (or copy icon) → copy to clipboard (manual paste to send).
- Inline session **nickname** (local, manual — we never read the real name/content).
- `● connected / disconnected` indicator.
- Local JSON persistence, keyed by session ID.

EXPLICITLY NOT (keeps the highlight sharp — per design review):
- No auto-merge-all (user composes/combines freely by editing).
- No auto-send / auto-fill the input box (human stays in control = a trust feature).
- No global/shared prompt library (that's Raycast Snippets; would dilute per-session).
- No cloud / account / login. No rich-text editor. No cross-IDE. No settings page.

## 6. Architecture (native mapping)

| Concern | macOS API |
|---|---|
| Floating panel | `NSPanel` subclass, `styleMask:[.nonactivatingPanel,.borderless]`, `canBecomeKey=true`, `level=.floating`, `collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]`, clear bg + rounded layer + shadow |
| UI | SwiftUI via `NSHostingView` (fallback: AppKit if SwiftUI is problematic) |
| Focus signal | Hybrid: **log** `LogTailer` (0.2s poll over `main*.log`, ≤0.2s) + **file** `SessionFocusWatcher` (`FSEventStreamCreate` over `claude-code-sessions/**/local_*.json`, ~15ms but file lands ~1s late) → `FocusCoordinator` merges by latest timestamp (log wins live; file overtakes if log freezes) |
| Store | `Codable` structs → JSON in `~/Library/Application Support/Nextpad/nextpad-data.json` |
| Clipboard | `NSPasteboard.general` |
| Drag | NSView `mouseDown/Dragged/Up`; move window by delta; no-move = click |
| Collapse anchor | keep `frame.maxX/maxY` fixed, change width/height (AppKit bottom-left origin) |
| Menubar | minimal `NSStatusItem` (toggle panel / quit) |
| No Dock icon | `LSUIElement=true` in Info.plist (or `NSApp.setActivationPolicy(.accessory)`) |
| Self-QA | debug: render panel NSView → PNG (`bitmapImageRepForCachingDisplay`+`cacheDisplay`) so the build can be screenshot-verified headlessly |

## 7. Design tokens (Earth Online Lab — 五段神经光谱, flat, no gradients/highlights)

Spectrum (vivid): purple `#8A43E6` · blue `#4FA8F0` · green `#1FA45D` · orange `#F4811E` · red `#E8482A`
Warm neutrals: paper `#FBF8F3` · paper2 `#F4EEE3` · card `#FFFEFB` · ink `#1A1A1F` ·
muted `#6B6258` · faint `#A79D8E` · line `#EBE3D5` · line2 `#DED5C4`
Icon: rainbow **stacked bars** (3 rounded bars purple/blue/green + an orange accent block) — a
"pad of stacked next-prompts", member of the rainbow-pill suite family.
Single edge only (no double border — let the window's own rounded edge be the outline).

## 8. Phases

- **P0** Scaffold: build.sh + Info.plist + minimal NSPanel hosting a SwiftUI view + snapshot-QA helper.
- **P1** UI: expanded panel + collapsed bubble + state toggle + top-right-anchored resize.
- **P2** Engine: log tailer (ID only) + Codable store + connected state → live model.
- **P3** Window behavior: free drag (no-move=click) + collapse/expand anchor + persistence.
- **P4** Parity + self-QA: match the Electron visual; verify each state via NSView→PNG.
- **P5** Ship: ✅ rainbow `.icns`; ✅ open-source (EarthOnlineLabs/nextpad, MIT); ✅ landing page
  (`docs/index.html`). Distribution = Claude-driven local build (no Apple Developer account needed).
  Optional later: codesign (Developer ID) + notarize + `.dmg` for non-Claude users.

## 9. Build (no Xcode; CLT + swiftc)

`./build.sh` compiles all `Sources/Nextpad/*.swift` with `swiftc`, assembles `Nextpad.app`
(Info.plist with `LSUIElement`), ad-hoc signs for local dev, and `open`s it.
Signing/notarization (P5) needs the user's Developer ID cert (their Apple Developer account).

### Toolchain prerequisite (current blocker)
CLT 6.2 ships a duplicate `SwiftBridging` modulemap that breaks all Foundation/AppKit compiles.
Fix once (one of):
- `sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap{,.disabled}`
  (removes the stale duplicate; `bridging.modulemap` remains), **or**
- install full **Xcode** from the App Store (recommended long-term; needed alongside the
  Developer ID cert for the P5 notarization workflow anyway).
