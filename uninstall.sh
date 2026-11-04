#!/bin/bash
# Removes live-drive-ai: the skill link, LiveDrive.app, the permission rule and, on Linux, the
# shortcuts install.sh added. Leaves the repository and the signing certificate alone; prints the
# command to delete the certificate at the end.
#
#   ./uninstall.sh
#
# macOS runs this with /bin/bash 3.2: no bash 4+ syntax.

REPO="$(cd "$(dirname "$0")" && pwd)"
SKILL="$REPO/skill"
DEST="$HOME/.claude/skills/live-drive-desktop"
PY=/usr/bin/python3
SIGN_ID="${LIVEDRIVE_SIGN_ID:-live-drive-codesign}"
BUNDLE_ID=io.github.smlblr.LiveDrive

say()  { printf '==> %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }

say "skill: $DEST"
if [ -L "$DEST" ] && [ "$(readlink "$DEST")" = "$SKILL" ]; then
  rm "$DEST" && ok "link removed"
elif [ -e "$DEST" ] || [ -L "$DEST" ]; then
  warn "not linked to this repository, left alone"
else
  ok "already gone"
fi

if [ "$(uname -s)" = Darwin ]; then
  say "LiveDrive.app"
  rm -rf "$HOME/Applications/LiveDrive.app" "$HOME/.cache/live-drive.build" && ok "deleted"
  say "macOS permission entries"
  for svc in Accessibility ScreenCapture; do
    if tccutil reset "$svc" "$BUNDLE_ID" >/dev/null 2>&1; then
      ok "$svc reset"
    else
      warn "could not reset $svc; remove LiveDrive in System Settings → Privacy & Security"
    fi
  done
fi

if [ "$(uname -s)" = Linux ] && command -v gsettings >/dev/null; then
  say "shortcuts"
  MK=org.gnome.settings-daemon.plugins.media-keys
  BASE=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
  list="$(gsettings get "$MK" custom-keybindings 2>/dev/null)"
  new="$list"
  for k in stop pause; do
    path="$BASE/live-drive-$k/"
    new="$(printf '%s' "$new" | sed -e "s|, '$path'||" -e "s|'$path', ||" -e "s|'$path'||")"
    command -v dconf >/dev/null && dconf reset -f "$path"
  done
  case "$new" in "[]") new="@as []" ;; esac
  if [ "$new" != "$list" ]; then
    gsettings set "$MK" custom-keybindings "$new" && ok "removed the shortcuts install.sh added"
  else
    ok "no shortcuts added by install.sh (ones defined elsewhere are left alone)"
  fi
fi

say "Claude Code permission rule"
"$PY" -I - "$HOME/.claude/settings.json" "Bash($PY -I $DEST/scripts/live-drive.py:*)" <<'EOF'
import json, os, sys, tempfile
path, rule = sys.argv[1:]
try:
    if os.path.islink(path):
        raise ValueError('symlink')
    with open(path) as f:
        data = json.load(f)
    allow = data['permissions']['allow']
    if rule not in allow:
        print('  ✓ already gone')
        sys.exit(0)
    allow.remove(rule)
except (OSError, ValueError, KeyError, TypeError, AttributeError):
    print(f'  ! rule not found in {path}, or the file was left alone: "{rule}"')
    sys.exit(0)
mode = os.stat(path).st_mode & 0o777
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
os.chmod(tmp, mode)
os.replace(tmp, path)
print('  ✓ removed')
EOF

if [ "$(uname -s)" = Darwin ] && security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  echo
  echo "The signing certificate is still there. If you will not reinstall, delete it:"
  echo "  security delete-identity -c $SIGN_ID"
fi
echo
echo "The repository is still at $REPO (delete it if you like)."
