---
name: live-drive-desktop
description: Test the app this project builds by driving the user's live GNOME Wayland or macOS session (keyboard, pointer, screenshots) while they keep using the machine. Invoke with /live-drive-desktop.
argument-hint: "[what to test] [out=DIR]"
disable-model-invocation: true
---

# Live drive desktop

You drive the user's real desktop: every key and click lands wherever focus is, including their own windows and this chat. Each rule below exists because something went wrong or the user asked for it; the dated ones happened.

## Parameters

Read it from the arguments; otherwise use the default.

| Parameter | Default |
|---|---|
| Output directory for screenshots | Where the project keeps evidence (its CLAUDE.md or docs say; e.g. `verification-archive/<date>_<task>/`). If the project has no such place, ask the user. |

## Before you start

1. Check the platform.
   - Linux: run `/usr/bin/python3 -I ~/.claude/skills/live-drive-desktop/scripts/live-drive.py check`. It must end with `all ok`; a `MISS` line names what is missing and how to fix it, `warn` lines do not block. KDE and X11 are not supported yet; stop and say so.
   - macOS: run `/usr/bin/python3 -I ~/.claude/skills/live-drive-desktop/scripts/live-drive.py check`. It must end with `all granted`. If `~/Applications/LiveDrive.app` is missing, ask the user to run `install.sh` in their live-drive-ai checkout (it also creates the signing certificate); if a grant is missing, `check` opens the prompt and the user turns LiveDrive on in System Settings. Granting is the user's job, not yours.
2. Plan the whole test as batches and tell the user, before the first input: what you will test, how many steps it has, which windows you will open, and how to stop it.
   - Linux: the top-bar item shows "Live drive · Sürüyor" while a batch runs and "Live drive · Bekliyor" between batches, when touching the machine pauses nothing. Its menu → Durdur, the ■ on the orange indicator, or Ctrl+Alt+Shift+S stops; the same menu's Duraklat/Sürdür or Ctrl+Alt+Shift+P pauses and resumes (the icon then shows ⏸). A notice stays on screen while paused, and stop and resume show a short one.
   - macOS: "● LiveDrive" in the menu bar → Durdur, or ⌃⌥⇧S stops; ⌃⌥⇧P pauses and resumes (the item then shows ⏸).
3. Start one session for the whole test, with the Bash tool's `run_in_background`:

   ```bash
   /usr/bin/python3 -I ~/.claude/skills/live-drive-desktop/scripts/live-drive.py serve OUT_DIR
   ```

   Always this exact form: on Linux the system python is the one with `gi`, and the permission rule matches this path on both platforms. Do not end and restart the session between batches: the indicator would vanish mid-test and the user takes that as the end.

   **The session is yours only when a first `send shot:start` succeeds.** Do not take a `READY` in `~/.cache/live-drive.out` as yours: every session writes to that file, and a refused `serve` leaves the previous session's `READY` there (on 2026-11-02 a session read another's line as its own). On Linux, serve's own output prints `READY claude:<pid> serve <pid>` or the refusal. `no serving session` from that first `send` means serve is still starting (it takes about a second): resend, at most five times.

   The lock covers only what goes through `send`. Launching or closing apps, D-Bus calls into the app (e.g. toggling its window), and changing its settings also change the screen the user sees. Do none of them before that first `send` succeeds.

   One session drives the screen at a time. If `serve` (or `send`) answers `another session is driving the screen`, a different Claude session holds it: tell the user which (the message names it) and stop. Do not retry in a loop, do not touch `~/.cache/live-drive.lock`, and never send to a session you did not start.

## Driving

```bash
/usr/bin/python3 -I ~/.claude/skills/live-drive-desktop/scripts/live-drive.py send STEP...
```

Steps: `focus:PID[,PID]`, `key:ctrl+s`, `down:alt`, `up:alt`, `type:text`, `sleep:2`, `shot:name`, `move:x,y`, `click` (`click:right`, `click:middle`), `dclick`, `scroll:down,3` (up, left, right), `drag:x1,y1,x2,y2`. A batch prints each finished step and exits 0, or non-zero with the reason.

- `type:` reads `\n` as Return, `\t` as Tab, `\\` as a backslash. Check typed text with a `shot:`.
  - Linux: sends what the active keyboard layout can produce (ğ, ş, İ, € on the Turkish layout). Mutter drops a character the layout lacks (漢, emoji) without an error.
  - macOS: the text travels in the event, so any character works regardless of layout (ğüşıöç, €, 漢 and emoji tested in TextEdit and VS Code, 2026-11-01). An app that reads key codes instead of the text would see `a`.
- `key:` names: `ctrl`, `alt`, `shift`, `return`, `escape`, `tab`, `space`, `backspace`, `delete`, `home`, `end`, `pgup`, `pgdn`, arrows, `F1`–`F12`, and single characters (`ctrl+s`).
  - Linux also takes X key names (`Delete`, `Menu`, `Print`).
  - macOS: Command is `cmd` (`super` also works), Option is `alt` or `opt`. `insert`, `menu` and `print` do not exist and fail the batch. Characters are looked up in the active layout, so `cmd+a` is the key that types `a` on Turkish layouts too.
- **Send `focus:PID` before the first input, with the PIDs of the test windows.** From then on every `key`, `type`, `click`, `dclick`, `scroll` and `drag` checks the active window first, and clicks check it again after; if it belongs to another process, the batch stops and reports that window. On 2026-10-20 a batch typed `exit` + Return into the Claude chat because focus had moved; this gate is the fix. When it stops a batch, bring the test window back to the front and resend; do not widen `focus:`. `focus:any` turns off the test-app match: use it only for an app that exposes no accessibility tree (the gate then reports "focus unknown"), and confirm focus with a `shot:` before every input batch instead. The chat's own app is refused even under `focus:any`.
  - Linux: keys go to whatever window is in front, not to a process, so a long `type:` or `drag` checks focus again every 0.2 s and stops; a window that appears mid-step can still get one or two characters (1 measured, 2026-11-02). Keep `type:` text short when other windows may open.
- **Measure before you point.** Take a fresh `shot:` and read the target window's bounds from it before any click or drag. Never reuse coordinates from an earlier batch or run: a relaunched editor reopened at a different size and the drags landed on another window. `shot:NAME` logs the frame size in `live-drive.out`; that is also the coordinate space of `move` and `drag` (on macOS: points of the main display, e.g. 1470x956 on a Retina 2940x1912).
- **The user comes first.** "Using" means keyboard or mouse input in at least three 0.1 s slices within 2 s; a single burst (one click, a bumped mouse) does not count. If they are using it at the session's first input, it waits with "Claude ekranı sürmek istiyor"; if they start during the test, it pauses with "Sen kullanıyorsun" and logs the evidence (`user input: N events over X s`) in `live-drive.out`. Either way it goes on only when they press Ctrl+Alt+Shift+P (macOS: ⌃⌥⇧P), or Başlat/Sürdür in the top-bar (menu-bar) menu, then continues the batch where it stopped. A `drag` they interrupt is released and fails; redo it after they resume.
- **Keep input batches to a few seconds.** Waits go in `sleep:N` steps, which the stop and pause checks interrupt every 0.1 s; never use a shell `sleep` between batches as the wait.
- **Report progress between batches:** "test devam ediyor, N adım kaldı" (exact if known, otherwise an estimate marked as such).

## Windows

- Open separate test instances (`--standalone` or the app's equivalent where it has one) and record each PID when you launch it; these are the PIDs for `focus:`. If the gate reports a different PID for the test window (single-instance apps hand the window to a running process), check in a `shot:` that the window is the test one before adding that PID.
  - macOS: `open -n -a App file` starts a new instance whose parent is launchd, not your shell, so it is outside your shell's process tree; take its PID right after with `pgrep -nx <process name>`, and give that PID itself to `focus:`. Electron apps need their own data directory to get a separate instance (VS Code: `--args --user-data-dir ~/.cache/<short>`; a long path breaks its socket).
- Leave each window where the app opens it unless the test needs another size or position; then use the app's own geometry option if it has one, otherwise drag the title bar and the corner, measured from a screenshot (GNOME Wayland lets no client position itself).
- Type into, click in and close only windows this test opened. The user may have their own windows of the same app, so close by PID (`kill PID`), never by name (`pkill app`).

## Ending

1. `send quit` (or `.../live-drive.py quit`), then close every PID the test opened and confirm they are gone.
2. Say "test bitti", where the screenshots are, and what passed or failed.

## Gotchas

- A `send` that ends with `stopped by user` or `session ended` means the user stopped the test. Do not start a new session; close the test windows, report what ran, and ask.
- `serve` refuses to start while `~/.cache/live-drive.stop` exists (a stop pressed while nothing was running). Tell the user; do not delete it yourself.
- While the session is paused, a `send` waits; after 120 s it exits with `batch <id> is waiting`. The batch is not lost and runs when the user resumes: do not resend it. Tell the user the test is waiting for Ctrl+Alt+Shift+P, then watch `~/.cache/live-drive.out` for `END <id>`.
- Held keys and buttons are released on every exit, but a `down:` without its `up:` in the same batch stays held until then; keep each pair in one batch.
- Linux: the stream records the primary monitor only. With fractional scaling on, compare the logged frame size against the monitor's resolution before trusting coordinates.
- macOS: the first `shot:` of a session can raise a system prompt ("LiveDrive is requesting to bypass the system private window picker…") over the screen. Only the user answers it; stop and ask them to choose Allow.
- macOS: while the user reads your messages the chat is in front, so the gate refuses input and a click on the test window is refused too. Ask the user to click the test window, or launch it again; `open -a` does not pick between two instances of one app.
- macOS: a new instance (`open -n`) may reopen the app's previous windows, including the user's unsaved documents (TextEdit did, 2026-11-02). Before `kill PID`, take a `shot:`: if it shows windows this test did not open, close only the test's windows (`key:cmd+w`) and leave the app running.
- macOS: TextEdit and other text views capitalize the start of a sentence and may substitute characters (system text replacements). Compare a `shot:` against that, not against the literal input.
