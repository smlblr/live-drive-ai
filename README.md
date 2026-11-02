# live-drive-ai

**English** · [Türkçe](README.tr.md)

Lets [Claude Code](https://claude.com/claude-code) test the app you are building **on your live
desktop**. Claude opens the app in a separate test window, uses the keyboard and mouse, takes
screenshots and reads the result itself. You can keep using your machine meanwhile: as soon as you
touch the keyboard or mouse, the test pauses and waits for your go-ahead.

- **macOS 14+** — uses a small helper app (`LiveDrive.app`) that is built during installation. Public
  Apple APIs only: CGEvent, ScreenCaptureKit, Accessibility.
- **Linux, GNOME Wayland** — uses GNOME's own remote desktop interface (Mutter RemoteDesktop/ScreenCast
  over D-Bus); nothing to build. KDE and X11 are not supported.

The menus and notifications of the helper are in Turkish; this README gives the English meaning next
to each label.

## Safety measures

A tool that sends real input can do damage if it types into the wrong window. So:

- **Focus gate.** Before every key press and click, it checks that the window in front belongs to the
  test app Claude opened. If not, the batch stops and reports the window it found. Input never goes to
  Claude's own chat window.
- **You come first.** If you start using the keyboard or mouse during a test, the test pauses
  ("Sen kullanıyorsun", *you are using it*) and waits until you resume it with the shortcut. A single
  click or a bumped mouse does not count; input repeated over a few short moments does.
- **One driver.** Only one Claude session can drive the screen at a time; a second one is refused.
- **You can stop it at any time** (shortcuts or menu below).
- **Manual invocation only.** Claude never starts this skill on its own; you type `/live-drive-desktop`.

## Installation

[Claude Code](https://docs.claude.com/en/docs/claude-code) must be installed first (CLI or desktop app).

```bash
git clone https://github.com/smlblr/live-drive-ai.git ~/live-drive-ai
```

```bash
~/live-drive-ai/install.sh
```

You can clone the repository anywhere; the skill is linked from there, so do not delete or move the
folder afterwards (if you move it, run `install.sh` again from the new place).

`install.sh` does the following; running it twice is harmless:

1. Links the `skill/` folder as `~/.claude/skills/live-drive-desktop`.
2. **macOS:** checks for the Xcode Command Line Tools (otherwise `xcode-select --install`), creates a
   one-time self-signed code signing certificate (`live-drive-codesign`), builds `LiveDrive.app` and
   puts it in `~/Applications`.
   **Linux:** checks the required packages and, if any are missing, asks and installs them with
   `apt-get`; adds the stop/pause shortcuts to GNOME.
3. Adds a permission rule to `~/.claude/settings.json`; without it Claude asks for approval at every
   step. If you do not want that: `./install.sh --no-settings`.
4. Runs a final check and reports anything still missing.

### macOS: two permissions

At the end of the first installation, macOS shows its own permission prompts and adds LiveDrive to
both lists:

- **Accessibility** (keyboard and mouse)
- **Screen & System Audio Recording** (screenshots)

In each prompt press **Open System Settings**, turn on LiveDrive's switch in the list, then press Enter
in the terminal. `install.sh` checks again; if something is still missing, it opens that settings pane
itself. The check should end with `all granted`; if it does not, run `./install.sh` again. On the first
test macOS may also ask "LiveDrive is requesting to bypass the system private window picker": choose
**Allow**. The first session also asks for notification permission (for the pause notices).

Permissions are tied to the signing certificate, so rebuilding on updates does not drop them. If you
delete the certificate or move to another machine, you grant both permissions again.

### Linux: requirements

A GNOME Wayland session (not "Ubuntu on Xorg" on the login screen). With Ubuntu package names:
`python3-gi gir1.2-gstreamer-1.0 gir1.2-atspi-2.0 gstreamer1.0-pipewire gstreamer1.0-plugins-good`.
Most Ubuntu desktops already have them. On distributions that are not Debian-based, `install.sh` does
not install packages; install the equivalents yourself.

The LiveDrive icon in the top bar needs AppIndicator support (the `ubuntu-appindicators` extension that
ships with Ubuntu; elsewhere the "AppIndicator and KStatusNotifierItem Support" extension). Tests work
without the icon; the shortcut is enough to stop them.

## Usage

Open Claude Code in the folder of the project you want to test and type:

```
/live-drive-desktop test switching to the dark theme on the settings screen
```

Optional parameters: `out=DIR` (where screenshots go; Claude asks if the project defines no place),
`width=45%` (width of the test window), `margin=20` (gap from the right screen edge, in pixels).

Before starting, Claude tells you what it will test, how many steps it takes and which windows it will
open. It then places the test window on the right side of the screen, sends the steps in short
batches and reports progress in between. When done it says "test bitti" (*test finished*), where the
screenshots are and what passed or failed, and closes the windows it opened.

### Stopping and pausing

| | macOS | Linux |
|---|---|---|
| Stop | ⌃⌥⇧S or menu bar → LiveDrive → Durdur (*Stop*) | Ctrl+Alt+Shift+S, top-bar menu → Durdur, or ■ on the orange indicator |
| Pause / resume | ⌃⌥⇧P or menu → Duraklat/Sürdür (*Pause/Resume*) | Ctrl+Alt+Shift+P or the top-bar menu |

The menu label shows the state: **Sürüyor** (*driving*: Claude is sending input right now),
**Bekliyor** (*waiting*: between batches; touching the machine stops nothing), **Duraklatıldı**
(*paused*) or **Sen kullanıyorsun** (*you are using it*) — ⏸, waiting for you to resume. If you are
using the machine when a test starts, it shows **Onayını bekliyor** (*waiting for your approval*), a
"Claude ekranı sürmek istiyor" (*Claude wants to drive the screen*) notification appears, and it waits
for Başlat (*Start*) in the menu or the resume shortcut.

### How it notices you

While a test is open, the last keyboard/mouse input is checked 10 times a second (every 0.1 s): not
only before steps, but also between batches and during wait steps. Claude's own input is told apart:
on Linux, input newer than Claude's last input is yours; on macOS, every event carries the process it
came from.

Time is split into 0.1 s slices; inputs in the same slice count once. If your input fell into **at
least 3 different slices within the last 2 seconds**, you are using the machine:

| What you did | Slices | Result |
|---|---|---|
| Bumped the mouse (~40 ms) | 1–2 | ignored |
| Single click (press–release, ~0.1 s) | 1–2 | ignored |
| Moved the mouse somewhere, typed a few letters, scrolled | 3+ | pauses |

A single short click does not stop the test; if the click moved focus to another window, the focus
gate still stops the next input. If it pauses wrongly, the `user input: N events over X s, last Y s
ago` line in `~/.cache/live-drive.out` shows what triggered it.

## Updating

```bash
cd ~/live-drive-ai && git pull && ./install.sh
```

## Uninstalling

```bash
~/live-drive-ai/uninstall.sh
```

Removes the skill link, `LiveDrive.app`, the permission rule and, on Linux, the shortcuts it added. It
does not delete the signing certificate; it prints the command for that at the end. You can delete the
repository folder yourself afterwards.

## Known limits and risks

- **Managed (MDM) devices.** If your device is managed by an organization (Intune, Jamf, Kandji, etc.),
  its privacy policy may block the Accessibility or Screen Recording permission, or lock them so that
  only an administrator can grant them. LiveDrive then does not work on that device. To check:

  ```bash
  plutil -p "/Library/Managed Preferences/com.apple.TCC.configuration-profile-policy.plist"
  ```

  If you see `"Allowed" => 0` under `Accessibility` or `ScreenCapture`, the policy blocks it. If the
  file does not exist or these services are not listed, the policy does not interfere. A non-admin
  account may also be unable to turn the permissions on.
- **Endpoint security tools** (EDR, endpoint protection) may flag an app that is not notarized by Apple
  (it is self-signed) and generates synthetic keyboard/mouse input or records the screen. Ask your
  administrator before installing on a managed device if needed.
- **Local access while running.** While a test session is open, any process running under your user
  account can write to the session's command channel and send input. The channel is private to your
  account, exists only during the test, and the focus gate limits input to the test window; still, do
  not start a test while untrusted software is running.
- **macOS:** main display only. Text is sent as text, so every character (ğüşıöç, emoji) is typed; apps
  that read key codes may see something different. Text editors may capitalize sentence starts or
  apply system text replacements.
- **Linux:** primary monitor only; with fractional scaling, coordinates may drift. A character missing
  from the active keyboard layout (e.g. 漢) is dropped without an error. A window that suddenly comes to
  the front while typing may receive a character or two; Claude splits long text into short pieces.
- Tested with Claude Code only.

## Troubleshooting

Run the check first; each missing line says what is missing and how to fix it:

```bash
/usr/bin/python3 -I ~/.claude/skills/live-drive-desktop/scripts/live-drive.py check
```

- **"another session is driving the screen"** — another Claude session is driving the screen. Try again
  when its test ends.
- **"live-drive.stop exists"** — the stop shortcut was pressed while no session was running.
  `rm ~/.cache/live-drive.stop`
- **macOS: I granted it but it still shows as missing** — remove LiveDrive from the list (−), run
  `./install.sh` again and turn it on in the prompt.
- **LiveDrive does not appear in the Screen Recording list** — quit System Settings and run
  `./install.sh` again; an entry added while the list is open may not show until the pane is reopened.
  If a LiveDrive with a different bundle identifier was installed at the same path before, log out and
  back in.
- **If the first build asks for keychain access**, choose "Always Allow".

Why things are done this way, with measurements: [`docs/decisions.md`](docs/decisions.md) (in Turkish).

## License

[MIT](LICENSE)
