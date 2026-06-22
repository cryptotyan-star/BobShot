#!/usr/bin/env bash
# Иконка приложения: SVG → AppIcon.icns (все размеры iconset).
# Нужен только системный набор macOS (qlmanage + sips + iconutil).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SVG="Resources/icons/appicon.svg"
OUT="Resources/AppIcon.icns"
TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "==> рендер мастера 1024 из $SVG"
qlmanage -t -s 1024 -o "$TMP" "$SVG" >/dev/null 2>&1 || true
MASTER="$TMP/appicon.svg.png"
[ -f "$MASTER" ] || { echo "ОШИБКА: qlmanage не отрендерил SVG" >&2; exit 1; }

gen() { sips -z "$1" "$1" "$MASTER" --out "$ICONSET/$2" >/dev/null; }
gen 16  icon_16x16.png
gen 32  icon_16x16@2x.png
gen 32  icon_32x32.png
gen 64  icon_32x32@2x.png
gen 128 icon_128x128.png
gen 256 icon_128x128@2x.png
gen 256 icon_256x256.png
gen 512 icon_256x256@2x.png
gen 512 icon_512x512.png
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

echo "==> сборка $OUT"
iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$TMP"
echo "==> готово: $OUT"
