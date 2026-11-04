# Contributing

- **English everywhere:** code comments, interface strings (menus, notifications, script output),
  `docs/` and commit messages. The one exception is `README.tr.md`, the Turkish twin of `README.md`:
  a change to one goes into the other in the same commit. Why: `docs/decisions.md` § "English only".
- **Comments say why, not what.** Dated notes record an incident or a measurement; keep the date.
- **Measure before you change a decision** in `docs/decisions.md`, and update it in the same commit.
- **Commit messages:** a short subject line, then the reason for the change; the diff already shows
  what changed.
- **Check before committing:** `bash -n` (with `/bin/bash` 3.2 on macOS) for the shell scripts,
  `python3 -m py_compile skill/scripts/live-drive.py`, and on macOS `./install.sh` builds the helper.
