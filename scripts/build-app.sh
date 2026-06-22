#!/usr/bin/env bash
# Сборка BobShot.app из SwiftPM-вывода БЕЗ полного Xcode (только Command Line Tools).
# Собирает бинарь, упаковывает в .app-бандл, ad-hoc подписывает (Sign to Run Locally).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-debug}"          # debug | release
APP="BobShot.app"
APP_DIR="build/$APP"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/BobShot"
if [ ! -x "$BIN_PATH" ]; then
  echo "ОШИБКА: не найден собранный бинарь: $BIN_PATH" >&2
  exit 1
fi

echo "==> сборка бандла $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/BobShot"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

# Иконки панели редактора (PNG из qlmanage) → в бандл.
if [ -d Resources/icons/png ]; then
  mkdir -p "$APP_DIR/Contents/Resources/icons"
  cp Resources/icons/png/*.png "$APP_DIR/Contents/Resources/icons/"
  echo "==> иконки скопированы: $(ls Resources/icons/png/*.png | wc -l | tr -d ' ') шт."
fi

# Стабильная подпись self-signed сертификатом, если он есть в связке — TCC grant
# (Screen Recording) тогда переживает пересборки. Иначе fallback на ad-hoc.
SIGN_ID="${BOBSHOT_SIGN_ID:-BobShot Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "==> codesign «$SIGN_ID» (стабильная подпись, App Sandbox выкл)"
  codesign --force --sign "$SIGN_ID" --identifier com.bobshot.app "$APP_DIR"
else
  echo "==> ad-hoc codesign (нет «$SIGN_ID» — grant будет слетать; см. scripts/make-signing-cert.sh)"
  codesign --force --sign - --identifier com.bobshot.app "$APP_DIR"
fi

echo "==> готово: $APP_DIR"
echo "    запуск: open \"$APP_DIR\"   (или: \"$APP_DIR/Contents/MacOS/BobShot\")"
