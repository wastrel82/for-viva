#!/bin/sh
# install_usque_l4-socks.sh
# Разово при установке:
#   1) скачивает warpscout (mipsle) в /opt/usr/bin
#   2) делает warpscout register (свой аккаунт, не трогает nativetun)
#   3) сканирует masque-h2 и пишет /opt/etc/usque/masque-h2-config.conf
#   4) создаёт S52usque-l4socks, который запускает usque l4-socks с этим конфигом
# Работает параллельно с S51usque (nativetun). session.conf не используется.

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

USQUE_BIN="/opt/usr/bin/usque"
WARPSCOUT_BIN="/opt/usr/bin/warpscout"
WARPSCOUT_URL="https://raw.githubusercontent.com/wastrel82/for-viva/main/warpscout"
CONFIG_DIR="/opt/etc/usque"
WARPSCOUT_ACCOUNT="${CONFIG_DIR}/warpscout-account.json"
MASQUE_CONF="${CONFIG_DIR}/masque-h2-config.conf"
MASQUE_SNI="ozon.ru"
INIT_SCRIPT="/opt/etc/init.d/S52usque-l4socks"
PIDFILE="/opt/var/run/usque-l4socks.pid"
LOG_FILE="/opt/var/log/usque-l4socks.log"
BIND_IP="192.168.1.1"
BIND_PORT="1080"

echo "============================================"
echo "  Установка usque l4-socks (SOCKS5 прокси)"
echo "  + warpscout (разово: register + scan)"
echo "============================================"
echo ""

# ----- Проверка наличия usque -----
if [ ! -x "$USQUE_BIN" ]; then
    echo -e "${RED}Ошибка: не найден бинарник usque: $USQUE_BIN${NC}"
    echo "Сначала установите usque через основной скрипт установки."
    exit 1
fi
echo -e "${GREEN}[OK]${NC} Найден бинарник: $USQUE_BIN"

# ----- Проверка наличия S51usque (nativetun) — только информация -----
if [ ! -x "/opt/etc/init.d/S51usque" ]; then
    echo -e "${YELLOW}[WARN]${NC} Не найден S51usque (nativetun)."
    echo "Скрипт всё равно будет установлен, но убедитесь, что usque настроен."
else
    echo -e "${GREEN}[OK]${NC} Найден S51usque (nativetun)"
fi

mkdir -p "$CONFIG_DIR"

# ----- Проверка занятости порта -----
if netstat -tln 2>/dev/null | grep -q ":${BIND_PORT} "; then
    echo -e "${YELLOW}[WARN]${NC} Порт ${BIND_PORT} уже занят:"
    netstat -tln | grep ":${BIND_PORT} "
    printf "Продолжить? [y/N]: "
    read -r ans
    case "$ans" in
        y|Y) ;;
        *) echo "Отменено."; exit 1 ;;
    esac
fi

# ----- Проверка, не установлен ли уже S52usque-l4socks -----
if [ -x "$INIT_SCRIPT" ]; then
    echo -e "${YELLOW}[INFO]${NC} Скрипт $INIT_SCRIPT уже существует."
    printf "Перезаписать? [y/N]: "
    read -r ans
    case "$ans" in
        y|Y) ;;
        *) echo "Отменено."; exit 1 ;;
    esac
    if [ -f "$PIDFILE" ]; then
        echo "Останавливаю старый процесс..."
        "$INIT_SCRIPT" stop 2>/dev/null || true
        sleep 1
    fi
fi

# ==============================================
#  1. Установка warpscout
# ==============================================
echo ""
echo -e "${YELLOW}[1/4] Установка warpscout...${NC}"

NEED_DOWNLOAD=1
if [ -x "$WARPSCOUT_BIN" ]; then
    echo -e "${YELLOW}[INFO]${NC} $WARPSCOUT_BIN уже существует."
    printf "Перезаписать? [y/N]: "
    read -r ans
    case "$ans" in
        y|Y) NEED_DOWNLOAD=1 ;;
        *)   NEED_DOWNLOAD=0; echo "Использую существующий." ;;
    esac
fi

if [ "$NEED_DOWNLOAD" = "1" ]; then
    echo "Скачивание: $WARPSCOUT_URL"
    TMP_WC=$(mktemp) || { echo -e "${RED}Не удалось создать tmp${NC}"; exit 1; }
    if ! wget -q -O "$TMP_WC" "$WARPSCOUT_URL"; then
        rm -f "$TMP_WC"
        echo -e "${RED}Ошибка скачивания warpscout.${NC}"
        exit 1
    fi

    # Проверка размера (защита от HTML-страницы ошибки)
    bsz=$(wc -c < "$TMP_WC" 2>/dev/null | tr -d ' \t')
    case "$bsz" in ''|*[!0-9]*) bsz=0 ;; esac
    if [ "$bsz" -lt 1000000 ]; then
        rm -f "$TMP_WC"
        echo -e "${RED}Файл слишком маленький (${bsz} Б) — вероятно, обрыв или ошибка.${NC}"
        exit 1
    fi

    mv "$TMP_WC" "$WARPSCOUT_BIN"
    chmod +x "$WARPSCOUT_BIN"
    echo -e "${GREEN}[OK]${NC} warpscout установлен ($bsz Б)."
fi

# ----- Проверка запуска warpscout -----
if ! "$WARPSCOUT_BIN" version >/dev/null 2>&1; then
    echo -e "${RED}warpscout не запускается (возможно, несовместимая архитектура или битый файл).${NC}"
    exit 1
fi
echo -e "${GREEN}[OK]${NC} warpscout запускается."

# ==============================================
#  2. warpscout register (свой аккаунт)
# ==============================================
echo ""
echo -e "${YELLOW}[2/4] Регистрация аккаунта warpscout...${NC}"

if [ -s "$WARPSCOUT_ACCOUNT" ]; then
    echo -e "${YELLOW}[INFO]${NC} Аккаунт уже существует: $WARPSCOUT_ACCOUNT"
    printf "Перерегистрировать? [y/N]: "
    read -r ans
    case "$ans" in
        y|Y) rm -f "$WARPSCOUT_ACCOUNT" ;;
        *) echo "Использую существующий аккаунт." ;;
    esac
fi

if [ ! -s "$WARPSCOUT_ACCOUNT" ]; then
    # warpscout пишет account в CWD, поэтому cd в CONFIG_DIR
    ( cd "$CONFIG_DIR" && "$WARPSCOUT_BIN" register )
    if [ ! -s "$WARPSCOUT_ACCOUNT" ]; then
        echo -e "${RED}Не удалось создать $WARPSCOUT_ACCOUNT${NC}"
        echo "Попробуйте вручную: cd $CONFIG_DIR && $WARPSCOUT_BIN register"
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC} Аккаунт создан."
fi

# ==============================================
#  3. warpscout scan -> masque-h2-config.conf
# ==============================================
echo ""
echo -e "${YELLOW}[3/4] Сканирование masque-h2 (это займёт ~2-15 минут)...${NC}"

OLD_CONF=""
if [ -s "$MASQUE_CONF" ]; then
    OLD_CONF=$(mktemp)
    cp -a "$MASQUE_CONF" "$OLD_CONF" 2>/dev/null || OLD_CONF=""
    echo -e "${YELLOW}[INFO]${NC} Существующий конфиг сохранён во временную копию."
fi

SCAN_OK=0
( cd "$CONFIG_DIR" && \
  "$WARPSCOUT_BIN" scan \
    -proto masque-h2 \
    -port 4500 \
    -masque-sni "$MASQUE_SNI" \
    -speed \
    -P \
    -ping-target youtube.com \
    -best-by speed \
    -conf "$MASQUE_CONF" ) && SCAN_OK=1

if [ "$SCAN_OK" -ne 1 ]; then
    echo -e "${RED}Сканирование не удалось.${NC}"
    if [ -n "$OLD_CONF" ] && [ -s "$OLD_CONF" ]; then
        cp -a "$OLD_CONF" "$MASQUE_CONF"
        echo -e "${YELLOW}Восстановлен предыдущий конфиг.${NC}"
    fi
    [ -n "$OLD_CONF" ] && rm -f "$OLD_CONF"
    exit 1
fi

[ -n "$OLD_CONF" ] && rm -f "$OLD_CONF"

if [ ! -s "$MASQUE_CONF" ]; then
    echo -e "${RED}Конфиг не создан или пуст: $MASQUE_CONF${NC}"
    exit 1
fi

if ! grep -q '"endpoint_h2_v4"' "$MASQUE_CONF"; then
    echo -e "${RED}В конфиге нет endpoint_h2_v4 — похоже, сканирование шло не в masque-h2.${NC}"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Конфиг создан: $MASQUE_CONF"

# ==============================================
#  4. Создание S52usque-l4socks
# ==============================================
echo ""
echo -e "${YELLOW}[4/4] Создаю $INIT_SCRIPT...${NC}"

cat > "$INIT_SCRIPT" << 'EOF'
#!/bin/sh
# Entware init script for usque l4-socks (SOCKS5 proxy)
# Работает параллельно с S51usque (nativetun)
# Использует masque-h2-config.conf, созданный warpscout.

PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

NAME="usque-l4socks"
USQUE_BIN="/opt/usr/bin/usque"
CONFIG_FILE="/opt/etc/usque/masque-h2-config.conf"
PIDFILE="/opt/var/run/usque-l4socks.pid"
LOG_FILE="/opt/var/log/usque-l4socks.log"
BIND_IP="192.168.1.1"
BIND_PORT="1080"

start() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
        echo "$NAME already running (PID $(cat $PIDFILE))."
        return 0
    fi

    if [ ! -x "$USQUE_BIN" ]; then
        echo "Error: $USQUE_BIN not found or not executable." >&2
        return 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: $CONFIG_FILE not found." >&2
        return 1
    fi

    echo "Starting $NAME on ${BIND_IP}:${BIND_PORT}..."
    $USQUE_BIN l4-socks --config "$CONFIG_FILE" --bind "$BIND_IP" --port "$BIND_PORT" >> "$LOG_FILE" 2>&1 &
    echo $! > "$PIDFILE"

    sleep 1
    if ! kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
        echo "Failed to start $NAME." >&2
        rm -f "$PIDFILE"
        return 1
    fi

    echo "$NAME started (PID $(cat $PIDFILE))."
}

stop() {
    if [ -f "$PIDFILE" ]; then
        local pid=$(cat "$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Stopping $NAME (PID $pid)..."
            kill "$pid" 2>/dev/null
            sleep 1
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$PIDFILE"
    fi
    echo "$NAME stopped."
}

status() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
        echo "$NAME is running (PID $(cat $PIDFILE))."
        echo "Listen: ${BIND_IP}:${BIND_PORT}"
        echo "Config: $CONFIG_FILE"
        echo "Log: $LOG_FILE"
    else
        echo "$NAME is stopped."
    fi
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    *)       echo "Usage: $0 {start|stop|restart|status}" ;;
esac
EOF

chmod +x "$INIT_SCRIPT"
echo -e "${GREEN}[OK]${NC} Скрипт создан и сделан исполняемым."

# ----- Создание файла логов -----
mkdir -p /opt/var/log
touch "$LOG_FILE"

# ----- Запуск -----
echo ""
printf "Запустить сейчас? [Y/n]: "
read -r ans
case "$ans" in
    n|N) echo "Пропущено." ;;
    *)   "$INIT_SCRIPT" start ;;
esac

# ----- Проверка прокси -----
if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
    echo ""
    echo -e "${YELLOW}Проверка прокси через curl...${NC}"
    if command -v curl >/dev/null 2>&1; then
        code=$(curl -sS -o /dev/null -w '%{http_code}' \
            -x "socks5://${BIND_IP}:${BIND_PORT}" \
            --connect-timeout 10 --max-time 20 \
            https://2ip.io/ 2>/dev/null) || code="000"
        case "$code" in
            2??|3??) echo -e "${GREEN}[OK]${NC} Прокси отвечает (HTTP $code)" ;;
            *)       echo -e "${YELLOW}[WARN]${NC} Прокси не ответил (code=$code). Смотрите $LOG_FILE" ;;
        esac
    fi
fi

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Готово!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Управление:"
echo "  $INIT_SCRIPT start|stop|restart|status"
echo ""
echo "Проверка:"
echo "  curl -x socks5://${BIND_IP}:${BIND_PORT} https://2ip.io"
echo ""
echo "Файлы:"
echo "  warpscout:        $WARPSCOUT_BIN"
echo "  account:          $WARPSCOUT_ACCOUNT"
echo "  конфиг l4-socks:  $MASQUE_CONF"
echo "  лог:              $LOG_FILE"
echo ""
echo "Автозапуск: S52usque-l4socks уже в /opt/etc/init.d/, стартует при загрузке."
echo ""