#!/bin/bash
# live-drive-ai'yi kaldırır: skill bağı, LiveDrive.app, izin kuralı, Linux'ta install.sh'nin
# eklediği kısayollar. Repoya ve imza sertifikasına dokunmaz; sertifikayı silme komutunu sonda yazar.
#
#   ./uninstall.sh
#
# macOS /bin/bash 3.2 ile çalışır: bash 4+ sözdizimi yok.

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
  rm "$DEST" && ok "bağ kaldırıldı"
elif [ -e "$DEST" ] || [ -L "$DEST" ]; then
  warn "bu repoya bağlı değil, dokunulmadı"
else
  ok "zaten yok"
fi

if [ "$(uname -s)" = Darwin ]; then
  say "LiveDrive.app"
  rm -rf "$HOME/Applications/LiveDrive.app" "$HOME/.cache/live-drive.build" && ok "silindi"
  say "macOS izin kayıtları"
  for svc in Accessibility ScreenCapture; do
    if tccutil reset "$svc" "$BUNDLE_ID" >/dev/null 2>&1; then
      ok "$svc sıfırlandı"
    else
      warn "$svc sıfırlanamadı; Sistem Ayarları → Gizlilik ve Güvenlik'ten LiveDrive'ı kaldır"
    fi
  done
fi

if [ "$(uname -s)" = Linux ] && command -v gsettings >/dev/null; then
  say "kısayollar"
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
    gsettings set "$MK" custom-keybindings "$new" && ok "install.sh'nin eklediği kısayollar kaldırıldı"
  else
    ok "install.sh'nin eklediği kısayol yok (başka yoldan tanımlıysa dokunulmadı)"
  fi
fi

say "Claude Code izin kuralı"
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
        print('  ✓ zaten yok')
        sys.exit(0)
    allow.remove(rule)
except (OSError, ValueError, KeyError, TypeError, AttributeError):
    print(f'  ! {path} içinde kural bulunamadı ya da dosyaya dokunulmadı: "{rule}"')
    sys.exit(0)
mode = os.stat(path).st_mode & 0o777
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
os.chmod(tmp, mode)
os.replace(tmp, path)
print('  ✓ kaldırıldı')
EOF

if [ "$(uname -s)" = Darwin ] && security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  echo
  echo "İmza sertifikası duruyor. Tekrar kurmayacaksan sil:"
  echo "  security delete-identity -c $SIGN_ID"
fi
echo
echo "Repo yerinde: $REPO (istersen sil)."
