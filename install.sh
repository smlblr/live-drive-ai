#!/bin/bash
# Installs or updates live-drive-ai. Running it twice changes nothing the second time.
#
#   ./install.sh                 install or update (also after git pull)
#   ./install.sh --no-settings   do not add the permission rule to ~/.claude/settings.json
#
# What it does:
#   1. skill/ → ~/.claude/skills/live-drive-desktop (a symlink: git pull updates it)
#   2. macOS: the signing certificate (if missing) and the LiveDrive.app build
#      Linux: reports missing packages (installs them if you agree), stop/pause shortcuts
#   3. the Claude Code permission rule (so live-drive.py does not ask for approval every time)
#   4. live-drive.py check: reports any permission or package still missing
#
# Exit code: 0 ready; 2 installed but check reports something missing (grant it, run again); 1 error.
# macOS runs this with /bin/bash 3.2: no bash 4+ syntax.

REPO="$(cd "$(dirname "$0")" && pwd)"
SKILL="$REPO/skill"
DEST="$HOME/.claude/skills/live-drive-desktop"
PY=/usr/bin/python3
SIGN_ID="${LIVEDRIVE_SIGN_ID:-live-drive-codesign}"
# Linux: what live-drive.py check looks for (gi + Gst + Atspi, pipewiresrc, xkbcommon).
LINUX_PKGS="python3-gi gir1.2-gstreamer-1.0 gir1.2-atspi-2.0 gstreamer1.0-pipewire gstreamer1.0-plugins-good libxkbcommon0"

settings=1
for a in "$@"; do
  case "$a" in
    --no-settings) settings=0 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

say()  { printf '==> %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { printf '  ✗ %s\n' "$*" >&2; exit 1; }

link_skill() {
  say "skill: $DEST"
  mkdir -p "$HOME/.claude/skills" || die "could not create $HOME/.claude/skills"
  if [ -L "$DEST" ]; then
    cur="$(readlink "$DEST")"
    if [ "$cur" = "$SKILL" ]; then
      ok "link already in place"
      return
    fi
    rm "$DEST" || die "could not remove the old link"
    warn "replaced the old link (it pointed at $cur)"
  elif [ -e "$DEST" ]; then
    die "$DEST is not a symlink; check what is in it, remove it, then run again"
  fi
  ln -s "$SKILL" "$DEST" || die "could not create the link"
  ok "linked → $SKILL"
}

mac_prereqs() {
  say "Xcode Command Line Tools"
  xcode-select -p >/dev/null 2>&1 || die "missing: install them with xcode-select --install, then run again"
  command -v swiftc >/dev/null || die "no swiftc: xcode-select --install"
  ok "$(xcode-select -p)"
}

mac_cert() {
  say "signing certificate: $SIGN_ID"
  if security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
    ok "present"
    return
  fi
  # Why a certificate: TCC grants are tied to the signature; with ad-hoc signing every build drops both.
  # /usr/bin/openssl (LibreSSL), not Homebrew's: `security import` cannot read OpenSSL 3's default
  # .p12 encryption. Not marked trusted: codesign does not need it, and marking it asks for a
  # password (docs/decisions.md § "Signing certificate from a script, not marked trusted").
  tmp="$(mktemp -d)" || die "could not create a temporary directory"
  pass="$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 24)"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$SIGN_ID" \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
      -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null \
    && /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$SIGN_ID" \
      -out "$tmp/id.p12" -passout "pass:$pass" \
    && security import "$tmp/id.p12" -P "$pass" -T /usr/bin/codesign >/dev/null
  rc=$?
  rm -rf "$tmp"
  [ "$rc" = 0 ] || die "could not create the certificate"
  ok "created (login keychain, valid for 10 years)"
}

mac_build() {
  say "LiveDrive.app"
  LIVEDRIVE_SIGN_ID="$SIGN_ID" "$SKILL/macos/build.sh" || die "build failed"
}

linux_prereqs() {
  say "session"
  case "${XDG_SESSION_TYPE:-}/${XDG_CURRENT_DESKTOP:-}" in
    wayland/*GNOME*) ok "GNOME Wayland" ;;
    *) warn "not a GNOME Wayland session (${XDG_SESSION_TYPE:-?}, ${XDG_CURRENT_DESKTOP:-?}); live-drive works only there" ;;
  esac
  [ -x "$PY" ] || die "no $PY"
  say "packages"
  if ! command -v dpkg-query >/dev/null; then
    warn "no dpkg; install the equivalents of these yourself: $LINUX_PKGS"
    return
  fi
  missing=""
  for p in $LINUX_PKGS; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing="$missing $p"
  done
  if [ -z "$missing" ]; then
    ok "all installed"
    return
  fi
  warn "missing:$missing"
  if [ -t 0 ]; then
    printf '    Install them with sudo apt-get install? [y/N] '
    read -r ans
    case "$ans" in
      y|Y) sudo apt-get install -y $missing || die "installation failed" ;;
      *) warn "not installed; by hand: sudo apt-get install$missing" ;;
    esac
  else
    warn "to install: sudo apt-get install$missing"
  fi
}

linux_shortcuts() {
  say "stop/pause shortcuts (Ctrl+Alt+Shift+S / P)"
  MK=org.gnome.settings-daemon.plugins.media-keys
  BASE=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
  if ! command -v gsettings >/dev/null || ! gsettings list-keys "$MK" >/dev/null 2>&1; then
    warn "no GNOME settings, skipped"
    return
  fi
  # Matched by command, not by path: another installer may define the same shortcut under another path.
  list="$(gsettings get "$MK" custom-keybindings)"
  have=""
  for p in $(printf '%s' "$list" | sed -e 's/^@as //' -e "s/[][,']/ /g"); do
    have="$have $(gsettings get "$MK.custom-keybinding:$p" command)"
  done
  add=""
  case "$have" in *live-drive.stop*) ;; *) add="$add stop" ;; esac
  case "$have" in *live-drive.pause*) ;; *) add="$add pause" ;; esac
  if [ -z "$add" ]; then
    ok "already defined"
    return
  fi
  for k in $add; do
    path="$BASE/live-drive-$k/"
    schema="$MK.custom-keybinding:$path"
    if [ "$k" = stop ]; then
      gsettings set "$schema" name "Live drive: stop"
      gsettings set "$schema" command "sh -c 'touch \$HOME/.cache/live-drive.stop'"
      gsettings set "$schema" binding "<Primary><Alt><Shift>s"
    else
      gsettings set "$schema" name "Live drive: pause or resume"
      gsettings set "$schema" command "sh -c 'f=\$HOME/.cache/live-drive.pause; if [ -e \$f ]; then rm \$f; else touch \$f; fi'"
      gsettings set "$schema" binding "<Primary><Alt><Shift>p"
    fi
    case "$list" in
      *"'$path'"*) ;;
      "@as []"|"[]") list="['$path']" ;;
      *) list="${list%]}, '$path']" ;;
    esac
  done
  gsettings set "$MK" custom-keybindings "$list" || die "could not write the shortcut list"
  ok "added:$add"
}

add_rule() {
  if [ "$settings" = 0 ]; then
    warn "--no-settings: permission rule not added"
    return
  fi
  say "Claude Code permission rule"
  "$PY" -I - "$HOME/.claude/settings.json" "Bash($PY -I $DEST/scripts/live-drive.py:*)" <<'EOF'
import json, os, sys, tempfile
path, rule = sys.argv[1:]

def manual(why):
    print(f'  ! {why}; add it by hand: {path} → permissions.allow: "{rule}"')
    sys.exit(0)

# The file behind a symlink may belong to another repository; do not write there.
if os.path.islink(path):
    manual('a symlink, left alone')
data, mode = {}, 0o600
if os.path.exists(path):
    mode = os.stat(path).st_mode & 0o777
    try:
        with open(path) as f:
            data = json.load(f)
    except ValueError as e:
        manual(f'could not read it ({e})')
perms = data.get('permissions', {}) if isinstance(data, dict) else None
allow = perms.get('allow', []) if isinstance(perms, dict) else None
if not isinstance(allow, list):
    manual('unexpected format')
if rule in allow:
    print('  ✓ already present')
    sys.exit(0)
allow.append(rule)
perms['allow'] = allow
data['permissions'] = perms
os.makedirs(os.path.dirname(path), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
os.chmod(tmp, mode)
os.replace(tmp, path)
print(f'  ✓ added: {rule}')
EOF
}

# If check printed "<name>...: missing", opens that System Settings pane and waits for the user.
# check must have run first: LiveDrive joins the list only when it asks for the permission.
mac_grant() {
  printf '%s\n' "$out" | grep -q "^$1.*: missing$" || return 1
  open "x-apple.systempreferences:com.apple.preference.security?$2"
  printf '    Opened System Settings → Privacy & Security → %s.\n' "$3"
  printf '    Turn LiveDrive on (close any system prompt), then press Enter: '
  read -r _
}

run_check() {
  say "check"
  out="$("$PY" -I "$DEST/scripts/live-drive.py" check)"
  rc=$?
  printf '%s\n' "$out"
  # check shows macOS's own prompts for missing permissions and adds LiveDrive to the lists; the
  # user turns the switch on from there. As a fallback we open the pane of whatever is still missing.
  if [ "$rc" != 0 ] && [ "$(uname -s)" = Darwin ] && [ -t 0 ]; then
    echo
    echo "    macOS opened its permission prompts. In each, press \"Open System Settings\" and"
    echo "    turn on LiveDrive's switch in the list (Accessibility, Screen & System Audio Recording)."
    printf '    When both are on, press Enter: '
    read -r _
    say "check again"
    out="$("$PY" -I "$DEST/scripts/live-drive.py" check)"
    rc=$?
    printf '%s\n' "$out"
    if [ "$rc" != 0 ]; then
      asked=0
      mac_grant "Accessibility" Privacy_Accessibility "Accessibility" && asked=1
      mac_grant "Screen & System Audio Recording" Privacy_ScreenCapture "Screen & System Audio Recording" && asked=1
      if [ "$asked" = 1 ]; then
        say "final check"
        "$PY" -I "$DEST/scripts/live-drive.py" check
        rc=$?
      fi
    fi
  fi
  if [ "$rc" = 0 ]; then
    echo
    echo "Ready. In Claude Code: /live-drive-desktop <what to test>"
    exit 0
  fi
  echo
  if [ "$(uname -s)" = Darwin ]; then
    echo "If a permission is missing: turn LiveDrive on under System Settings → Privacy & Security →"
    echo "Accessibility and Screen & System Audio Recording, then run ./install.sh again."
  else
    echo "Fix the MISS lines, then run ./install.sh again."
  fi
  exit 2
}

case "$(uname -s)" in
  Darwin) mac_prereqs; link_skill; mac_cert; mac_build; add_rule ;;
  Linux)  linux_prereqs; link_skill; linux_shortcuts; add_rule ;;
  *) die "unsupported system: $(uname -s)" ;;
esac
run_check
