#!/usr/bin/env bash
# Установка BobShot в /Applications → появляется в Launchpad.
# Собирает бандл (build-app.sh), копирует в /Applications, регистрирует в Launch Services.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"          # по умолчанию release для установки
APP="BobShot.app"
SRC="build/$APP"
DEST="/Applications/$APP"

echo "==> сборка ($CONFIG)"
"$ROOT/scripts/build-app.sh" "$CONFIG"

if [ ! -d "$SRC" ]; then
  echo "ОШИБКА: не собран бандл: $SRC" >&2
  exit 1
fi

echo "==> установка в $DEST"
# Закрываем запущенный экземпляр, чтобы не копировать поверх работающего бинаря.
pkill -x BobShot 2>/dev/null || true
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

# Регистрируем в Launch Services, чтобы Launchpad/Spotlight сразу увидели приложение.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$DEST" || true
fi

echo "==> готово. BobShot в Launchpad и /Applications."
echo "    Первый запуск из /Applications может потребовать заново выдать «Запись экрана»"
echo "    (Системные настройки → Конфиденциальность → Запись экрана) — путь изменился."
