#!/bin/bash
# live-drive-ai kurulumu ve güncellemesi. İki kez çalışınca ikincisi bir şey değiştirmez.
#
#   ./install.sh                 kur ya da güncelle (git pull'dan sonra da bu)
#   ./install.sh --no-settings   ~/.claude/settings.json'a izin kuralı ekleme
#
# Yaptıkları:
#   1. skill/ → ~/.claude/skills/live-drive-desktop (symlink: git pull ile güncellenir)
#   2. macOS: imza sertifikası (yoksa) ve LiveDrive.app derlemesi
#      Linux: eksik paketleri söyler (onay verirsen kurar), durdur/duraklat kısayolları
#   3. Claude Code izin kuralı (live-drive.py komutu her seferinde onay istemesin)
#   4. live-drive.py check: eksik izin ya da paket kaldıysa söyler
#
# Çıkış kodu: 0 hazır; 2 kuruldu ama check eksik gösteriyor (izni ver, yeniden çalıştır); 1 hata.
# macOS /bin/bash 3.2 ile çalışır: bash 4+ sözdizimi yok.

REPO="$(cd "$(dirname "$0")" && pwd)"
SKILL="$REPO/skill"
DEST="$HOME/.claude/skills/live-drive-desktop"
PY=/usr/bin/python3
SIGN_ID="${LIVEDRIVE_SIGN_ID:-live-drive-codesign}"
# Linux: live-drive.py check'in aradıkları (gi + Gst + Atspi, pipewiresrc, xkbcommon).
LINUX_PKGS="python3-gi gir1.2-gstreamer-1.0 gir1.2-atspi-2.0 gstreamer1.0-pipewire gstreamer1.0-plugins-good libxkbcommon0"

settings=1
for a in "$@"; do
  case "$a" in
    --no-settings) settings=0 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bilinmeyen seçenek: $a" >&2; exit 1 ;;
  esac
done

say()  { printf '==> %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { printf '  ✗ %s\n' "$*" >&2; exit 1; }

link_skill() {
  say "skill: $DEST"
  mkdir -p "$HOME/.claude/skills" || die "$HOME/.claude/skills oluşturulamadı"
  if [ -L "$DEST" ]; then
    cur="$(readlink "$DEST")"
    if [ "$cur" = "$SKILL" ]; then
      ok "bağ zaten yerinde"
      return
    fi
    rm "$DEST" || die "eski bağ kaldırılamadı"
    warn "eski bağ değiştirildi (önceki hedef: $cur)"
  elif [ -e "$DEST" ]; then
    die "$DEST bir symlink değil; içine bakıp kaldır, sonra yeniden çalıştır"
  fi
  ln -s "$SKILL" "$DEST" || die "bağ kurulamadı"
  ok "bağlandı → $SKILL"
}

mac_prereqs() {
  say "Xcode Command Line Tools"
  xcode-select -p >/dev/null 2>&1 || die "yok: xcode-select --install ile kur, sonra yeniden çalıştır"
  command -v swiftc >/dev/null || die "swiftc yok: xcode-select --install"
  ok "$(xcode-select -p)"
}

mac_cert() {
  say "imza sertifikası: $SIGN_ID"
  if security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
    ok "var"
    return
  fi
  # Neden sertifika: TCC izni imzaya bağlı; geçici imzada her derleme iki izni düşürür.
  # /usr/bin/openssl (LibreSSL), Homebrew'unki değil: OpenSSL 3'ün varsayılan .p12 şifrelemesini
  # `security import` okuyamıyor. "Güvenilir" işaretlenmiyor: codesign için gerekmiyor, işaretlemek
  # parola ister (docs/decisions.md § "İmza sertifikası betikle").
  tmp="$(mktemp -d)" || die "geçici dizin oluşturulamadı"
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
  [ "$rc" = 0 ] || die "sertifika oluşturulamadı"
  ok "oluşturuldu (giriş anahtar zinciri, 10 yıl geçerli)"
}

mac_build() {
  say "LiveDrive.app"
  LIVEDRIVE_SIGN_ID="$SIGN_ID" "$SKILL/macos/build.sh" || die "derleme başarısız"
}

linux_prereqs() {
  say "oturum"
  case "${XDG_SESSION_TYPE:-}/${XDG_CURRENT_DESKTOP:-}" in
    wayland/*GNOME*) ok "GNOME Wayland" ;;
    *) warn "GNOME Wayland oturumu değil (${XDG_SESSION_TYPE:-?}, ${XDG_CURRENT_DESKTOP:-?}); live-drive yalnızca orada çalışır" ;;
  esac
  [ -x "$PY" ] || die "$PY yok"
  say "paketler"
  if ! command -v dpkg-query >/dev/null; then
    warn "dpkg yok; şunların karşılıklarını elle kur: $LINUX_PKGS"
    return
  fi
  missing=""
  for p in $LINUX_PKGS; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing="$missing $p"
  done
  if [ -z "$missing" ]; then
    ok "hepsi kurulu"
    return
  fi
  warn "eksik:$missing"
  if [ -t 0 ]; then
    printf '    sudo apt-get install ile kurayım mı? [e/H] '
    read -r ans
    case "$ans" in
      e|E|y|Y) sudo apt-get install -y $missing || die "kurulamadı" ;;
      *) warn "kurulmadı; elle: sudo apt-get install$missing" ;;
    esac
  else
    warn "kurmak için: sudo apt-get install$missing"
  fi
}

linux_shortcuts() {
  say "durdur/duraklat kısayolları (Ctrl+Alt+Shift+S / P)"
  MK=org.gnome.settings-daemon.plugins.media-keys
  BASE=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
  if ! command -v gsettings >/dev/null || ! gsettings list-keys "$MK" >/dev/null 2>&1; then
    warn "GNOME ayarları yok, atlandı"
    return
  fi
  # Komutuna göre arıyor, yola göre değil: aynı kısayol başka bir kurulumca başka yolda tanımlı olabilir.
  list="$(gsettings get "$MK" custom-keybindings)"
  have=""
  for p in $(printf '%s' "$list" | sed -e 's/^@as //' -e "s/[][,']/ /g"); do
    have="$have $(gsettings get "$MK.custom-keybinding:$p" command)"
  done
  add=""
  case "$have" in *live-drive.stop*) ;; *) add="$add stop" ;; esac
  case "$have" in *live-drive.pause*) ;; *) add="$add pause" ;; esac
  if [ -z "$add" ]; then
    ok "zaten tanımlı"
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
  gsettings set "$MK" custom-keybindings "$list" || die "kısayol listesi yazılamadı"
  ok "eklendi:$add"
}

add_rule() {
  if [ "$settings" = 0 ]; then
    warn "--no-settings: izin kuralı eklenmedi"
    return
  fi
  say "Claude Code izin kuralı"
  "$PY" -I - "$HOME/.claude/settings.json" "Bash($PY -I $DEST/scripts/live-drive.py:*)" <<'EOF'
import json, os, sys, tempfile
path, rule = sys.argv[1:]

def manual(why):
    print(f'  ! {why}; elle ekle: {path} → permissions.allow içine "{rule}"')
    sys.exit(0)

# Symlink'in arkasındaki dosya başka bir reponun olabilir; oraya yazmıyoruz.
if os.path.islink(path):
    manual('symlink, dokunulmadı')
data, mode = {}, 0o600
if os.path.exists(path):
    mode = os.stat(path).st_mode & 0o777
    try:
        with open(path) as f:
            data = json.load(f)
    except ValueError as e:
        manual(f'okunamadı ({e})')
perms = data.get('permissions', {}) if isinstance(data, dict) else None
allow = perms.get('allow', []) if isinstance(perms, dict) else None
if not isinstance(allow, list):
    manual('beklenmeyen biçim')
if rule in allow:
    print('  ✓ zaten var')
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
print(f'  ✓ eklendi: {rule}')
EOF
}

# check'te "<ad>...: missing" satırı varsa Sistem Ayarları'nın o bölmesini açıp kullanıcıyı bekler.
# Önce check çalışmış olmalı: LiveDrive listeye ancak izin istediğinde ekleniyor.
mac_grant() {
  printf '%s\n' "$out" | grep -q "^$1.*: missing$" || return 1
  open "x-apple.systempreferences:com.apple.preference.security?$2"
  printf '    Sistem Ayarları → Gizlilik ve Güvenlik → %s açıldı.\n' "$3"
  printf '    LiveDrive'"'"'ı aç (sistem istemi çıktıysa kapatabilirsin), sonra Enter: '
  read -r _
}

run_check() {
  say "denetim"
  out="$("$PY" -I "$DEST/scripts/live-drive.py" check)"
  rc=$?
  printf '%s\n' "$out"
  # check eksik izinler için macOS'un kendi pencerelerini açıyor ve LiveDrive'ı listelere ekliyor;
  # kullanıcı oradan anahtarı açıyor. Hâlâ eksik kalanın bölmesini yedek olarak biz açıyoruz.
  if [ "$rc" != 0 ] && [ "$(uname -s)" = Darwin ] && [ -t 0 ]; then
    echo
    echo "    macOS izin pencereleri açıldı. Her birinde \"Open System Settings\"e bas ve"
    echo "    listede LiveDrive'ın anahtarını aç (Erişilebilirlik, Ekran ve Sistem Ses Kaydı)."
    printf '    İkisi de açıkken Enter: '
    read -r _
    say "yeniden denetim"
    out="$("$PY" -I "$DEST/scripts/live-drive.py" check)"
    rc=$?
    printf '%s\n' "$out"
    if [ "$rc" != 0 ]; then
      asked=0
      mac_grant "Accessibility" Privacy_Accessibility "Erişilebilirlik" && asked=1
      mac_grant "Screen & System Audio Recording" Privacy_ScreenCapture "Ekran ve Sistem Ses Kaydı" && asked=1
      if [ "$asked" = 1 ]; then
        say "son denetim"
        "$PY" -I "$DEST/scripts/live-drive.py" check
        rc=$?
      fi
    fi
  fi
  if [ "$rc" = 0 ]; then
    echo
    echo "Hazır. Claude Code'da: /live-drive-desktop <neyi test edeceğin>"
    exit 0
  fi
  echo
  if [ "$(uname -s)" = Darwin ]; then
    echo "Eksik izin varsa: Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik ile"
    echo "Ekran ve Sistem Ses Kaydı altında LiveDrive'ı aç, sonra ./install.sh'yi yeniden çalıştır."
  else
    echo "MISS satırlarını düzelt, sonra ./install.sh'yi yeniden çalıştır."
  fi
  exit 2
}

case "$(uname -s)" in
  Darwin) mac_prereqs; link_skill; mac_cert; mac_build; add_rule ;;
  Linux)  linux_prereqs; link_skill; linux_shortcuts; add_rule ;;
  *) die "desteklenmeyen sistem: $(uname -s)" ;;
esac
run_check
