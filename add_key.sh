#!/bin/sh
# add_key.sh — добавляет id_rsa.pub в Dropbear (Entware/Keenetic)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PUB_KEY="$SCRIPT_DIR/id_rsa.pub"
DEST_KEY="/opt/etc/dropbear/authorized_keys"

if [ ! -f "$PUB_KEY" ]; then
    echo "Ошибка: не найден $PUB_KEY"
    exit 1
fi

mv "$PUB_KEY" "$DEST_KEY"
chmod 600 "$DEST_KEY"
chown root:root "$DEST_KEY" 2>/dev/null || true

/opt/etc/init.d/S51dropbear restart

echo "Готово: ключ установлен в $DEST_KEY"