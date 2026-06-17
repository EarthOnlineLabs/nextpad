# Nextpad

A privacy-clean, per-session prompt stash that floats over the Claude desktop app and
**auto-follows your current session** — switch sessions, the stash switches with you. Zero clicks.
It reads only an anonymous session-focus signal (the session **ID** from Claude's own local log,
plus the `lastFocusedAt` timestamp from each session's metadata file) and **never opens your
transcripts or reads a word of your conversations.** Native macOS, tiny, runs without any Apple
account.

By Earth Online Lab · open source (MIT). Full design in **[SPEC.md](SPEC.md)**.

## Install — let Claude do it

Nextpad compiles locally on your Mac, so there are **no Gatekeeper warnings and no Apple Developer
account needed**. If you use Claude, just **copy the block below and paste it to Claude** — it does
everything (you only click "agree" for the dev tools and may type your Mac password once):

```
帮我在这台 Mac 上安装并运行 Nextpad —— 一个浮在屏幕角落、自动跟随我当前 Claude 会话的便签小工具
（开源，只读「当前会话编号」，不读任何对话内容）。请全自动完成，遇到下面的已知情况自行处理，
装好后用一句话告诉我怎么用：

1. 确认有 Swift 编译环境（命令 swiftc）；没有就先装：xcode-select --install（会弹安装窗，我点同意）。
2. 克隆源码并编译运行：
   git clone https://github.com/EarthOnlineLabs/nextpad ~/.nextpad   （已存在就 cd ~/.nextpad && git pull）
   cd ~/.nextpad && ./build.sh run
3. 若编译报错提到 SwiftBridging 或重复的 module.modulemap（某些 Command Line Tools 版本的已知 bug）：
   按 build.sh 打印的提示执行那条 sudo mv 命令（会让我输一次 Mac 登录密码），再重新 ./build.sh run。
4. 确认 Nextpad 浮窗出现在屏幕右上角（它不在程序坞里）。
5. 复制 ~/.nextpad/build/Nextpad.app 到「应用程序」，并设为登录时自动启动。

全程本地编译，不需要任何 Apple 账号或证书。
```

To update later, paste: *"更新一下 Nextpad：cd ~/.nextpad && git pull && ./build.sh，然后重新复制到应用程序。"*

## Build from source (manual)

```bash
git clone https://github.com/EarthOnlineLabs/nextpad ~/.nextpad
cd ~/.nextpad
./build.sh run        # compile → Nextpad.app → launch
./build.sh snapshot   # render the panel to /tmp/nextpad-shot.png (headless QA)
```

Requires Apple Command Line Tools (`xcode-select --install`) — no full Xcode needed.

### If build.sh complains about `SwiftBridging` / `module.modulemap`
Some Command Line Tools versions ship a duplicate modulemap that breaks AppKit compiles. Fix once:

```bash
sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap{,.disabled}
```

(or install full Xcode from the App Store).

## Privacy

Reads only the focused session **ID** — from Claude's local log (`setFocusedSession`) and each
session's `lastFocusedAt` metadata — never transcripts, never conversation text. Fully local,
open source, leaves nothing behind on uninstall (drag to Trash). Diagnostic logging is **off by
default**; set `NEXTPAD_DEBUG=1` to enable it (writes only session IDs to `/tmp/nextpad-vis.log`).
