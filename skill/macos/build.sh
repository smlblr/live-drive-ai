#!/bin/bash
# LiveDrive.app'i derler, imzalar ve ~/Applications'a koyar (live-drive-desktop, macOS).
# Normalde install.sh çağırır; imza sertifikasını da o oluşturur.
#
#   build.sh            kaynak değiştiyse derler; değişmediyse dokunmaz
#   build.sh --force    yine de derler
#   build.sh --adhoc    sertifikasız, geçici imza (her derlemede iki izin yeniden verilir)
#
# Değişmeyen kaynağı yeniden derlememe sebebi TCC: izin paket kimliğine VE imzaya bağlı.
# Geçici imzada imza = cdhash, yani her derleme izinleri düşürür. Kendinden imzalı sertifikada
# gereksinim sertifikanın parmak izi; izin yeniden derlemeden sonra kalıyor (docs/decisions.md).
# Sertifika adı LIVEDRIVE_SIGN_ID ile değiştirilebilir.
#
# macOS /bin/bash 3.2 ile çalışır: bash 4+ sözdizimi yok.

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/LiveDrive.app"
STAMP="$HOME/.cache/live-drive.build"
SIGN_ID="${LIVEDRIVE_SIGN_ID:-live-drive-codesign}"
BUNDLE_ID=io.github.smlblr.LiveDrive

force=0
adhoc=0
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    --adhoc) adhoc=1 ;;
    *) echo "bilinmeyen seçenek: $a" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = Darwin ] || { echo "LiveDrive yalnızca macOS'ta" >&2; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc yok: xcode-select --install" >&2; exit 1; }

# -v yok: betikle oluşturulan sertifika "güvenilir" işaretli değil (CSSMERR_TP_NOT_TRUSTED),
# -v onu listelemiyor, ama codesign onunla imzalıyor.
if [ "$adhoc" = 1 ]; then
  SIGN_ID="-"
elif ! security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
  echo "\"$SIGN_ID\" imza kimliği yok (security find-identity -p codesigning)." >&2
  echo "install.sh sertifikayı oluşturur; ya da --adhoc ile derle." >&2
  exit 1
fi

# Damga: kaynak + imza kimliği. İmzalı paketin içine yazılamaz (imzayı bozar), bu yüzden dışarıda.
sum="$(cat "$SRC/LiveDrive.swift" "$SRC/icon.swift" "$SRC/Info.plist" "$SRC/build.sh" | shasum -a 256 | cut -d' ' -f1)-$SIGN_ID"
if [ "$force" = 0 ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$sum" ] \
   && codesign --verify "$APP" 2>/dev/null; then
  echo "LiveDrive.app güncel: $APP"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/LiveDrive.app/Contents/MacOS" "$tmp/LiveDrive.app/Contents/Resources"
cp "$SRC/Info.plist" "$tmp/LiveDrive.app/Contents/Info.plist"
swift "$SRC/icon.swift" "$tmp/LiveDrive.iconset" \
  && iconutil -c icns -o "$tmp/LiveDrive.app/Contents/Resources/LiveDrive.icns" "$tmp/LiveDrive.iconset" \
  || echo "ikon üretilemedi; LiveDrive.app genel ikonla kuruluyor" >&2
# Swift 5 dil kipi: global durum (adım iş parçacığı ↔ ana iş parçacığı) tek NSLock ile korunuyor;
# Swift 6'nın katı eşzamanlılık denetimi bunu derleme hatası sayardı.
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework Carbon -framework ScreenCaptureKit \
  -o "$tmp/LiveDrive.app/Contents/MacOS/LiveDrive" "$SRC/LiveDrive.swift" || exit 1
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$tmp/LiveDrive.app" || exit 1

mkdir -p "$HOME/Applications" "$HOME/.cache"
rm -rf "$APP"
mv "$tmp/LiveDrive.app" "$APP"
echo "$sum" > "$STAMP"
echo "LiveDrive.app kuruldu: $APP (imza: $SIGN_ID)"
