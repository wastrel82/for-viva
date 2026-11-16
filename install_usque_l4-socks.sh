#!/bin/sh
# install_usque_socks5.sh
# Устанавливает init-скрипт S52usque-l4socks для запуска usque в режиме l4-socks
# Проверяет наличие бинарника, session.conf и init-скрипта S51usque

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

USQUE_BIN="/opt/usr/bin/usque"
SESSION_FILE="/opt/etc/usque/session.conf"
INIT_SCRIPT="/opt/etc/init.d/S52usque-l4socks"
PIDFILE="/opt/var/run/usque-l4socks.pid"
LOG_FILE="/opt/var/log/usque-l4socks.log"
BIND_IP="192.168.1.1"
BIND_PORT="1080"

echo "============================================"
echo "  Установка usque l4-socks (SOCKS5 прокси)"
echo "============================================"
echo ""

# ----- Проверка наличия usque -----
if [ ! -x "$USQUE_BIN" ]; then
    echo -e "${RED}Ошибка: не найден бинарник usque: $USQUE_BIN${NC}"
    echo "Сначала установите usque через основной скрипт установки."
    exit 1
fi
echo -e "${GREEN}[OK]${NC} Найден бинарник: $USQUE_BIN"

# ----- Проверка наличия session.conf -----
if [ ! -f "$SESSION_FILE" ]; then
    echo -e "${RED}Ошибка: не найден файл сессии: $SESSION_FILE${NC}"
    echo "Сначала установите и запустите usque через основной скрипт."
    exit 1
fi
echo -e "${GREEN}[OK]${NC} Найден session.conf"

# ----- Проверка наличия init-скрипта S51usque (nativetun) -----
if [ ! -x "/opt/etc/init.d/S51usque" ]; then
    echo -e "${YELLOW}[WARN]${NC} Не найден S51usque (nativetun)."
    echo "Скрипт всё равно будет установлен, но убедитесь, что usque настроен."
else
    echo -e "${GREEN}[OK]${NC} Найден S51usque (nativetun)"
fi

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

# ----- Проверка, не установлен ли уже скрипт -----
if [ -x "$INIT_SCRIPT" ]; then
    echo -e "${YELLOW}[INFO]${NC} Скрипт $INIT_SCRIPT уже существует."
    printf "Перезаписать? [y/N]: "
    read -r ans
    case "$ans" in
        y|Y) ;;
        *) echo "Отменено."; exit 1 ;;
    esac
    # Останавливаем старый процесс перед перезаписью
    if [ -f "$PIDFILE" ]; then
        echo "Останавливаю старый процесс..."
        "$INIT_SCRIPT" stop 2>/dev/null || true
        sleep 1
    fi
fi

# ----- Создание init-скрипта -----
echo ""
echo -e "${YELLOW}Создаю $INIT_SCRIPT...${NC}"

cat > "$INIT_SCRIPT" << 'EOF'
#!/bin/sh
# Entware init script for usque l4-socks (SOCKS5 proxy)
# Работает параллельно с S51usque (nativetun)

PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

NAME="usque-l4socks"
USQUE_BIN="/opt/usr/bin/usque"
CONFIG_FILE="/opt/etc/usque/session.conf"
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
echo "Логи:"
echo "  cat $LOG_FILE"
echo ""
echo "Автозапуск: скрипт уже в /opt/etc/init.d/, стартует при загрузке роутера."
echo ""