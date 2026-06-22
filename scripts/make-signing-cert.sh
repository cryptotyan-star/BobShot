#!/usr/bin/env bash
# Создаёт self-signed code-signing сертификат "BobShot Dev" в login-связке Keychain
# и кладёт приватный ключ так, чтобы им мог подписывать codesign.
#
# ЗАЧЕМ: ad-hoc подпись (codesign --sign -) меняет cdhash при каждой пересборке,
# из-за чего macOS TCC считает приложение «новым» и разрешение «Запись экрана» слетает.
# Стабильный сертификат даёт стабильный Designated Requirement → grant переживает пересборки.
#
# БЕЗОПАСНОСТЬ: ключ self-signed, только для локальной разработки. Приватный ключ
# импортируется в Keychain; временные файлы (.pem/.p12) удаляются сразу после импорта.
# Ничего секретного в git не попадает.
#
# Запуск разовый:  bash scripts/make-signing-cert.sh
set -euo pipefail

CN="BobShot Dev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Уже есть?
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "✓ Сертификат «$CN» уже в связке — ничего делать не нужно."
  exit 0
fi

echo "==> генерирую self-signed cert «$CN» (codeSigning EKU)"
cat > "$TMP/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CN
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cfg" >/dev/null 2>&1

# -legacy: OpenSSL 3.x иначе пишет PKCS12 с MAC SHA-256, который Apple `security` не верит.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/bobshot-dev.p12" -name "$CN" -passout pass:bobshot >/dev/null 2>&1

KEYCHAIN="$(security default-keychain -d user | tr -d ' "')"
echo "==> импорт в связку: $KEYCHAIN (может попросить пароль Keychain один раз)"
security import "$TMP/bobshot-dev.p12" -k "$KEYCHAIN" -P bobshot -T /usr/bin/codesign

echo "==> доверие сертификату для code signing (пользовательский домен)"
# Без -d (без admin); может показать GUI-запрос пароля один раз.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || \
  echo "   (не удалось добавить доверие автоматически — codesign обычно подписывает и без него)"

echo "==> проверка"
security find-identity -v -p codesigning | grep "$CN" || {
  echo "⚠ Идентичность не показалась как valid. Попробуем подписать всё равно — см. build-app.sh." >&2
}

echo "✓ Готово. Теперь scripts/build-app.sh подпишет приложение этим сертификатом."
