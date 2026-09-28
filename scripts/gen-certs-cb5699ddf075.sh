#!/usr/bin/env sh
# Генерация самоподписанного сертификата для TLS-шлюза (dev/test и быстрый старт).
# Для прода используйте Let's Encrypt (certbot) и положите файлы в ./certs:
#   fullchain.pem и privkey.pem
set -e
cd "$(dirname "$0")/.."

DOMAIN=${1:-helpdesk.local}
DAYS=${2:-365}
OUT_DIR=${OUT_DIR:-certs}

command -v openssl > /dev/null 2>&1 || {
  echo "openssl не найден — установите openssl или положите сертификаты вручную" >&2
  exit 1
}

mkdir -p "$OUT_DIR"
if [ -f "$OUT_DIR/fullchain.pem" ] && [ -f "$OUT_DIR/privkey.pem" ]; then
  echo "$OUT_DIR/fullchain.pem и $OUT_DIR/privkey.pem уже существуют — не перезаписываю."
  exit 0
fi

openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days "$DAYS" \
  -keyout "$OUT_DIR/privkey.pem" \
  -out "$OUT_DIR/fullchain.pem" \
  -subj "/CN=$DOMAIN" \
  -addext "subjectAltName=DNS:$DOMAIN,DNS:localhost,IP:127.0.0.1"

chmod 644 "$OUT_DIR/fullchain.pem"
chmod 600 "$OUT_DIR/privkey.pem"
echo "Сертификаты созданы в ./$OUT_DIR (CN=$DOMAIN, $DAYS дней)."
