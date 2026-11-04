# Decisions

Read the reason here before changing something. Dated items rest on an incident or a measurement;
do not undo them without measuring.

## Distribution

### One-command install: `install.sh` (2026-11-02)

The skill link, the signing certificate, the build and the permission rule are in one script; the only
manual step left is turning on the macOS permission switches. Every manual step can be forgotten, and a
test only notices halfway through.

- **The skill is symlinked, not copied:** `git pull` + `./install.sh` is the whole update. This is why
  the paths in `SKILL.md` (`~/.claude/skills/live-drive-desktop/...`) never changed.
- **Not a Claude Code plugin:** a plugin's directory changes with its version; the Bash permission rule
  and the fixed path in SKILL.md would break on every update. Building LiveDrive.app would still need
  a separate script.
- **An existing symlink is replaced, a real directory is not:** removing a symlink deletes nothing,
  while a directory may be a copy someone put there by hand.

### `install.sh` adds the permission rule, by merging (2026-11-02)

`Bash(/usr/bin/python3 -I <home>/.claude/skills/live-drive-desktop/scripts/live-drive.py:*)`. Without
the rule every `send` asks for approval and the test does not flow. `~/.claude/settings.json` is read
and the rule appended to the list; other keys are left alone. If the file is a symlink or cannot be
read, nothing is written and the rule is printed instead (the file behind a symlink may belong to
another repository). `--no-settings` skips this step.

### Signing certificate from a script, not marked trusted (2026-11-02, measured)

A TCC grant is tied to the bundle id and the signature's designated requirement. With ad-hoc signing
the requirement is the cdhash: every rebuild drops both grants. With a self-signed certificate the
requirement is `identifier "..." and certificate leaf = H"<fingerprint>"`, the same from build to build.

There is no need to create the certificate by hand in Keychain Access and mark it "Always Trust".
Measured (macOS 27.2): with a certificate made by `openssl`, imported with
`security import -T /usr/bin/codesign` and not marked trusted (`CSSMERR_TP_NOT_TRUSTED`), `codesign`
signs, the signature passes `codesign --verify` and its own requirement, and no keychain prompt appears.
Marking it trusted (`security add-trusted-cert`) opens a password prompt, so it is not done. That is why
`security find-identity` is searched **without `-v`**: `-v` lists trusted identities only.

- `/usr/bin/openssl` (LibreSSL): Homebrew's OpenSSL 3 writes the `.p12` with an encryption
  `security import` cannot read.
- If the certificate is lost or recreated, its fingerprint changes and both permissions are granted once
  more.

### Permissions at install time, through macOS's own prompts (2026-11-02, measured)

`install.sh` runs `check` as its last step; for a missing permission macOS shows its own prompt ("Open
System Settings") and LiveDrive is added to the list, so the user only turns the switch on. It then waits
for Enter and checks again; as a fallback `install.sh` opens the pane of whatever is still missing.

- *The Screen Recording entry appears on the second request (macOS 27.2, `tccd` log).* The first
  `CGRequestScreenCaptureAccess` only notifies ("does not allow prompting") and adds no entry to the
  list; the same app's second request creates it. In the version that used
  `CGRequestScreenCaptureAccess` alone, the entry therefore appeared only on the second `check`. `check`
  now follows it with a ScreenCaptureKit query: the second request comes in the same run and the entry
  exists after the first install (tried from a fresh path; the user saw it in the list).
- *An app whose bundle id changed but whose path did not gets its entry under the old id.* After the bundle
  id changed, the Screen Recording request of `~/Applications/LiveDrive.app` was recorded in `tccd` under
  the old id; since that id no longer resolves, the Settings list did not show it. `tccutil reset`
  removed the old entry, but the new one was again created under the old id, so there is a per-path
  cache. Run from another path, the same app got its entry under the right id; since a grant is tied to
  id + signature, it also covered the app at the original path. This only happens on an update that
  changes the bundle id; logging out and back in should clear the cache too (not tried).
- *An entry added while Settings is open may not show in the list right away* (assumption, not
  measured); during the trials Settings was quit and reopened each time.
- *An app in a temporary directory does not show in the list:* LaunchServices does not resolve it
  (`tccutil` "No such bundle identifier"). Put a trial app under `~/Applications`.

### Bundle id `io.github.smlblr.LiveDrive` (2026-11-02)

TCC grants are tied to this id. If it changes, TCC treats the app as new: everyone grants both permissions
again, and the old id at the same path can hide the Screen Recording entry (above). Do not change it.

### English only: interface, code, documents and commits (2026-11-04)

The repository is public. Menu labels, notifications, script output, comments, `docs/` and commit
messages are in English. Only `README.tr.md` is Turkish, as the twin of `README.md`; it changes in the
same commit. One interface language, not a localised one: two string sets on two platforms would have to
be kept equal, and the audience reads English.

## Skill

### Claude Code only, manual invocation only (2026-10-20)

Formerly `live-desktop-test`; renamed `live-drive-desktop` on 2026-11-01.

- **Claude Code only.** The skill relies on a Bash permission rule and on a loop that reads screenshots
  and verifies focus; it was not measured with other agents.
- **`disable-model-invocation: true`.** It sends real keyboard and mouse input: the model must not start
  it on its own, and a project that does not want it should not even carry its description in context.
  `/live-drive-desktop`.
- **The focus gate is in code (2026-11-01).** Before every input step, the PID of the active window is
  checked against the subtree of the test process given with `focus:`; after a click, once more. The
  rule "verify focus with a screenshot before every batch" did not prevent `exit` being typed into the
  chat on 2026-10-20. One direction only: ANCESTORS of an allowed process are not accepted, and the
  ancestors of `serve` are refused as `focus:` — the test app's ancestor is the chat itself. If more
  than one window reports ACTIVE (a closed browser window had not cleared its state), all of them must
  be allowed; looking only at the first could open the gate to the wrong window.

### One driver and user priority (2026-11-02, tried live)

- *Lock (`~/.cache/live-drive.lock`, `flock`):* without a lock, a second `serve` deleted and reopened
  the first one's FIFO; since the first reopened the file for every request, both read the same request
  and one session's key could be checked against the other's `focus:` list. Now a second `serve` is
  refused, and `send`/`quit` are accepted only from the session that holds the lock. Session = the
  nearest `claude` ancestor process (all Bash calls of a session run under it). Refusal rather than a
  queue: a session that waits silently for hours is worse than one refused openly. The lock is in the
  Python front end, and macOS goes through the same path.
- *User priority:* "using it" = keyboard or mouse input in at least three separate 0.1 s slices within
  2 s. The first version (only before steps, "one input in the last 3 s") was wrong both ways in a live
  test: during fast consecutive steps the window it looked at shrank to ~0 and the user was not seen;
  a single short input at the start of a batch (a click, a bumped mouse) stopped the test. Measured with
  a fake user: the old code stopped on a burst of two events 40 ms apart and missed 0.6 s of use in the
  middle of a busy batch; the new one ignores the first and catches the second in 0.16 s. Explicit
  approval instead of waiting for idle: the session pauses and asks for Ctrl+Alt+Shift+P (macOS ⌃⌥⇧P)
  ("Claude wants to drive the screen" at the start, "You're using it" in the middle). Pressing the
  shortcut is input too, so the check is off for 1 s after resuming. Held synthetic keys are released on
  a pause; an interrupted `drag` fails. During a long pause `send` says "batch is waiting" after 120 s:
  the batch is not lost, and sending it again would run it twice.
- *No pause without input; the indicator says "Idle".* A session left open without sending any step
  showed "Test running"; the user touched the machine, nothing paused, and took detection for broken.
  Pausing on every touch while a session is open was rejected: between batches the user reads and
  writes in the chat, would need the shortcut after every message, and there was no input to protect.
  Instead the indicator says "Driving" during a batch and "Idle" in between.
  - *Five-second delay and timestamped log (2026-11-02, measured on Linux; the same code written for
    macOS, not tried on a Mac).* In a clipboard test (53 batches, ~18 min) the indicator said "Driving"
    for only 12 % of the computed time: Claude ran most of the test outside `send` (opening and closing
    windows with the `coppy` command, `systemctl restart`, a screen recording script). The indicator now
    turns "Idle" 5 s after the last batch. Pausing likewise stops only serve's steps; this is the same on
    both platforms (in Swift `gate()` checks in the same place), and the reason it was not seen on a Mac
    is not the code but that those tests did everything through `send`. A step that also stopped
    Claude's own commands would give serve the power to run arbitrary commands; instead SKILL.md says to
    look at `~/.cache/live-drive.pause` (`check` reports a pause only as a `warn` line, its last line
    is still `all ok`) and to keep work that touches the screen in short batches (compliance, not
    enforcement). Lines in `live-drive.out` start with `HH:MM:SS `, so a pause can be matched to what
    was running at the time; the parsing code (`send`, the READY wait on macOS) strips the time.
  - *A decision in wait steps too (2026-11-02, caught by the user in a joint trial).* The "is the user
    using it" decision was made only at the start of input steps; `sleep` only sampled. A mouse moved
    during a wait was forgotten after 2 s and no pause came until the next key (while the user watched
    "Driving" and saw no reaction). `sleep` now also decides every 0.1 s (`yield_to_user` / in Swift
    `yieldToUser`). Measured on Linux with a fake user: continuous input during a wait pauses within
    0.4 s, a short bump is ignored.
- *Ready signal.* `live-drive.out` is shared by all sessions; a refused `serve` leaves the previous
  session's `READY` there and another session took it for its own. The line now carries its owner
  (`READY claude:<pid> serve <pid>`) and is also written to `serve`'s own output. The real check is the
  first `send`: it verifies the owner. The lock covers only what goes through `send`; opening an app or
  having D-Bus open a window is outside it, so SKILL.md forbids those until the first `send` succeeds.

## macOS: the Swift helper LiveDrive.app (2026-11-01, tried live)

- *Why public APIs only:* CGEvent, ScreenCaptureKit, AXUIElement, sysctl, Carbon hot keys,
  NSStatusItem, UserNotifications. Private APIs such as SkyLight (background input) can break silently
  with any macOS update; background input and a virtual display are out of scope.
- *Why an `.app` started with `open`:* a TCC grant is recorded for the "responsible process"; a binary
  run directly from a terminal or from Claude has its grants charged to the app that started it. Since
  macOS 26.1 a command line binary cannot be added to the Accessibility list. `live-drive.py` stays the
  front end (one permission rule, one command form).
- *`--deny`:* an app started with `open` has launchd as its parent; the helper cannot find the chat
  among its own ancestors. The front end passes its own ancestor chain (the Claude app included,
  measured); these processes are refused as `focus:`, and when one is in front no input goes even under
  `focus:any`. `--parent`: when the front end dies the helper exits too (if `open -W` died, the app
  would live on).
- *Keys with `postToPid`, to the process that passed the gate:* even if focus changes in the millisecond
  between the gate check and the event, the key goes to the allowed process; the system's global key
  state is not touched (a held `down:shift` did not leak into the user's keyboard, measured). TextEdit and
  VS Code (Electron) type. Text travels with `keyboardSetUnicodeString`: layout independent, nothing
  dropped, €/漢/emoji included.
- *User priority: an event tap, not a counter (2026-11-02).*
  `CGEventSource.secondsSinceLastEventType` is reset by our own mouse/scroll events too, but shows up
  0.1–0.5 s late and dates the event 0.02–0.42 s early (7/7 measurements); a "newer than our last event"
  comparison would be wrong with it. Instead a listen-only `CGEvent` tap: every event carries
  `eventSourceUnixProcessID`, ours carry LiveDrive's pid (11/11), and the Accessibility grant is enough.
  The tap keeps only "the user's last input time", and the list is sampled every 0.1 s: counting per
  event took a 0.16 s nudge for use.
- *Security:* while the helper runs, any process of the user can write to the FIFO and send input with
  the helper's grants. On Linux Mutter's D-Bus is open to everyone already; on macOS this is a new power.
  Limits: it runs only during a test (no daemon), the FIFO is 0600 and checked with `lstat` when opened,
  and the focus gate limits input to the `focus:` processes.
- *Measured (macOS 27.2, Apple Silicon):* the image is read at point resolution (1470x956); natural
  scrolling does not invert synthetic scrolling; 0.15 s after a click is enough for the focus check; the
  first screenshot also asks for the "private window picker" permission; Carbon hot keys register by
  character (s/p) on a Turkish layout.

## Linux: GNOME Wayland

- *Mutter RemoteDesktop + ScreenCast over D-Bus.* No extra permission prompt and nothing to build.
- *Characters go through `xkb_utf32_to_keysym` (2026-11-01, tried live).* Mutter looks the key up in the
  active layout, and the layout defines ğ/ş/ı by their legacy keysyms (`gbreve` 0x2bb); the Unicode form
  (0x100011f) was dropped silently. A character missing from the layout (漢) is still dropped; no error
  comes back.
- *`focus:any` still refuses the chat (2026-11-02):* if the active window's PID is in `serve`'s ancestor
  chain (the Claude app is there), no input goes; the same rule as `--deny` on macOS.
- *A recheck every 0.2 s during a long `type:` or `drag`:* Mutter has no way to send a key to a process;
  the key goes to the window in front. Asking on every character is costly (an AT-SPI query takes ~56 ms);
  asking every 0.2 s brought the measured leak to a window that comes to the front mid-typing down to 1
  character. The leak is not zero; `SKILL.md` says so.
- *User priority:* Mutter's IdleMonitor gives the time since the last input; our synthetic input resets
  it too (11 s → 0.1 s), even before the D-Bus call returns (at most +0.1 ms in 40 tries). So input newer
  than our last event, with the time taken *before* the query, is the user's. The counter is sampled every
  0.1 s.
- *Pause/stop notices:* GNOME's built-in indicator has no pause state; `serve` shows a notification:
  critical while paused (it stays until closed), short on resume and stop. The `.pause` file is removed
  when a session ends; if it stayed, the next session started paused.
- *Top-bar icon: StatusNotifierItem + DBusMenu, by hand with Gio, no package:*
  - Not a GNOME Shell extension: extensions break with GNOME versions (all of them at 45), and on Wayland
    a new extension does not load without logging in again.
  - Not a library: `libayatana-appindicator` prints "deprecated" and pulls in GTK3; its successor
    `libayatana-appindicator-glib` publishes the menu as `org.gtk.Menus`, while Ubuntu's
    `ubuntu-appindicators` extension reads only `com.canonical.dbusmenu` — the menu never appeared.
  - The protocols themselves (SNI, DBusMenu) take ~150 lines and no dependency. Without a watcher (the
    extension off) there is no icon and the test runs on. The `Activate` method is left out on purpose:
    with it the extension opens the menu on left click.
- *Stop/pause shortcuts are matched by command (2026-11-02).* GNOME custom shortcuts are a list plus
  settings per path. Another setup script that rewrites the list from scratch drops the paths
  `install.sh` added; that script should put the shortcuts in its own list. When `install.sh` finds a
  shortcut with the same command (whatever its path), it adds none, so there is no duplicate.
- *KDE and X11 are out of scope.* 2026-11-01 research: the KDE portal works with a single approval using
  `persist_mode=2` and a fixed app id; the work is open.
