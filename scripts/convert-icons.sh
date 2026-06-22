#!/usr/bin/env bash
# Конвертирует SVG-иконки (Resources/icons/*.svg) в PNG через QuickLook (qlmanage),
# т.к. NSImage не грузит произвольный SVG. Результат — Resources/icons/png/<name>.png (96px).
# Запуск: bash scripts/convert-icons.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Resources/icons"
OUT="$SRC/png"
SIZE=96

mkdir -p "$OUT"

for svg in "$SRC"/*.svg; do
  name="$(basename "$svg" .svg)"
  qlmanage -t -s "$SIZE" -o "$OUT" "$svg" >/dev/null 2>&1 || true
  # qlmanage пишет <name>.svg.png — переименуем в <name>.png.
  if [ -f "$OUT/$name.svg.png" ]; then
    mv -f "$OUT/$name.svg.png" "$OUT/$name.png"
    echo "✓ $name.png"
  else
    echo "✗ не конвертировался: $name" >&2
  fi
done

echo "==> готово: $OUT"
