#!/bin/sh
# install_usque_watchdog.sh
# Устанавливает/удаляет S53usque-watchdog — сторож для usque l4-socks.
# Не качает warpscout и не создаёт S52: только использует уже установленное.
# Меню: 1) Установить  2) Удалить

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

WARPSCOUT_BIN="/opt/usr/bin/warpscout"
USQUE_INIT="/opt/etc/init.d/S52usque-l4socks"
MASQUE_CONF="/opt/etc/usque/masque-h2-config.conf"
WATCHDOG_INIT="/opt/etc/init.d/S53usque-watchdog"
WATCHDOG_PID="/opt/var/run/usque-watchdog.pid"
WATCHDOG_LOG="/opt/var/log/usque-watchdog.log"
BIND_IP="192.168.1.1"
BIND_PORT="1080"
CHECK_URL="https://2ip.io/"
INTERVAL=600
CURL_TIMEOUT=15
SCAN_TIMEOUT=120
STORM_PAUSE=1800
MAX_FAILS=5
MASQUE_SNI="ozon.ru"

# ==============================================
#  Удаление
# ==============================================
fn_remove() {
    echo -e "${YELLOW}=== Удаление S53usque-watchdog ===${NC}"
    if [ -x "$WATCHDOG_INIT" ]; then
        "$WATCHDOG_INIT" stop 2>/dev/null || true
        sleep 1
    fi
    if [ -f "$WATCHDOG_PID" ]; then
        kill "$(cat "$WATCHDOG_PID")" 2>/dev/null || true
        rm -f "$WATCHDOG_PID"
    fi
    rm -f "$WATCHDOG_INIT"
    rm -f "$WATCHDOG_PID"
    rm -f "$WATCHDOG_LOG"
    echo -e "${GREEN}Watchdog удалён. S52, usque, warpscout и конфиг не тронуты.${NC}"
}

# ==============================================
#  Установка
# ==============================================
fn_install() {
    echo "============================================"
    echo "  Установка S53usque-watchdog"
    echo "============================================"
    echo ""

    # ----- Проверки -----
    if [ ! -x "$WARPSCOUT_BIN" ]; then
        echo -e "${RED}Ошибка: не найден warpscout: $WARPSCOUT_BIN${NC}"
        echo "Сначала установите l4-socks (install_usque_l4-socks.sh)."
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC} warpscout найден"

    if [ ! -x "$USQUE_INIT" ]; then
        echo -e "${RED}Ошибка: не найден $USQUE_INIT${NC}"
        echo "Сначала установите l4-socks."
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC} S52usque-l4socks найден"

    if ! "$USQUE_INIT" status 2>/dev/null | grep -q "running"; then
        echo -e "${RED}Ошибка: S52usque-l4socks не запущен.${NC}"
        echo "Watchdog не имеет смысла без работающего l4-socks."
        echo "Запустите: $USQUE_INIT start"
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC} S52usque-l4socks запущен"

    if [ ! -s "$MASQUE_CONF" ] || ! grep -q '"endpoint_h2_v4"' "$MASQUE_CONF"; then
        echo -e "${RED}Ошибка: конфиг $MASQUE_CONF отсутствует или не содержит endpoint_h2_v4.${NC}"
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC} Конфиг l4-socks валиден"

    if [ -x "$WATCHDOG_INIT" ]; then
        echo -e "${YELLOW}[INFO]${NC} $WATCHDOG_INIT уже существует."
        printf "Перезаписать? [y/N]: "
        read -r ans
        case "$ans" in
            y|Y) "$WATCHDOG_INIT" stop 2>/dev/null || true; sleep 1 ;;
            *) echo "Отменено."; exit 1 ;;
        esac
    fi

    # ----- Создание S53usque-watchdog -----
    echo ""
    echo -e "${YELLOW}Создаю $WATCHDOG_INIT...${NC}"

    cat > "$WATCHDOG_INIT" << 'EOF'
#!/bin/sh
# S53usque-watchdog — сторож для usque l4-socks.
# Проверяет прокси, при сбое: restart S52 -> скан warpscout -> restart S52.
# После MAX_FAILS подряд завершается. Не трогает S52 напрямую, только вызывает.

PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

NAME="usque-watchdog"
WARPSCOUT_BIN="/opt/usr/bin/warpscout"
USQUE_INIT="/opt/etc/init.d/S52usque-l4socks"
MASQUE_CONF="/opt/etc/usque/masque-h2-config.conf"
PIDFILE="/opt/var/run/usque-watchdog.pid"
LOG_FILE="/opt/var/log/usque-watchdog.log"
BIND_IP="192.168.1.1"
BIND_PORT="1080"
CHECK_URL="https://2ip.io/"
INTERVAL=600
CURL_TIMEOUT=15
SCAN_TIMEOUT=120
STORM_PAUSE=1800
MAX_FAILS=5
MASQUE_SNI="ozon.ru"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

check_proxy() {
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' \
        -x "socks5://${BIND_IP}:${BIND_PORT}" \
        --connect-timeout 10 --max-time "$CURL_TIMEOUT" \
        "$CHECK_URL" 2>/dev/null) || code="000"
    case "$code" in
        2??|3??) return 0 ;;
        *)       return 1 ;;
    esac
}

run_loop() {
    local fails=0
    local storm_until=0

    log "watchdog started (interval=${INTERVAL}s, max_fails=${MAX_FAILS})"

    while :; do
        sleep "$INTERVAL"

        if check_proxy; then
            if [ "$fails" -ne 0 ]; then
                log "proxy OK (fails reset from $fails)"
            fi
            fails=0
            storm_until=0
            continue
        fi

        log "check failed"

        # мягкий рестарт
        "$USQUE_INIT" restart >/dev/null 2>&1 || true
        sleep 5
        if check_proxy; then
            log "restart fixed it"
            fails=0
            storm_until=0
            continue
        fi
        log "restart didn't help"

        # шторм-пауза
        now=$(date +%s)
        if [ "$now" -lt "$storm_until" ]; then
            log "storm pause active, skipping regen"
            fails=$((fails + 1))
            if [ "$fails" -ge "$MAX_FAILS" ]; then
                log "MAX_FAILS reached, giving up"
                rm -f "$PIDFILE"
                exit 0
            fi
            continue
        fi

        # перегенерация во временный файл
        TMP_CONF="/tmp/masque-new.$$"
        rm -f "$TMP_CONF"
        timeout "$SCAN_TIMEOUT" "$WARPSCOUT_BIN" scan \
            -proto masque-h2 \
            -port 4500 \
            -masque-sni "$MASQUE_SNI" \
            -speed \
            -P \
            -ping-target youtube.com \
            -best-by speed \
            -conf "$TMP_CONF" >/dev/null 2>&1 || true

        if [ -s "$TMP_CONF" ] && grep -q '"endpoint_h2_v4"' "$TMP_CONF"; then
            mv -f "$TMP_CONF" "$MASQUE_CONF"
            log "config regenerated"
            "$USQUE_INIT" restart >/dev/null 2>&1 || true
            sleep 5
            if check_proxy; then
                log "regen fixed it"
                fails=0
                storm_until=0
                continue
            fi
            log "regen didn't help"
        else
            log "scan failed, keeping old config"
        fi

        rm -f "$TMP_CONF"
        fails=$((fails + 1))
        storm_until=$(( $(date +%s) + STORM_PAUSE ))

        if [ "$fails" -ge "$MAX_FAILS" ]; then
            log "MAX_FAILS reached, giving up"
            rm -f "$PIDFILE"
            exit 0
        fi
    done
}

start() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "$NAME already running (PID $(cat "$PIDFILE"))."
        return 0
    fi
    if [ ! -x "$WARPSCOUT_BIN" ]; then
        echo "Error: $WARPSCOUT_BIN not found." >&2
        return 1
    fi
    if [ ! -x "$USQUE_INIT" ]; then
        echo "Error: $USQUE_INIT not found." >&2
        return 1
    fi
    mkdir -p /opt/var/log
    : > "$LOG_FILE"
    log "starting"
    run_loop &
    echo $! > "$PIDFILE"
    echo "$NAME started (PID $(cat "$PIDFILE"))."
}

stop() {
    if [ -f "$PIDFILE" ]; then
        local pid
        pid=$(cat "$PIDFILE")
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
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "$NAME is running (PID $(cat "$PIDFILE"))."
        echo "Log: $LOG_FILE"
        if [ -f "$LOG_FILE" ]; then
            echo "Last 5 log lines:"
            tail -5 "$LOG_FILE"
        fi
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

    chmod +x "$WATCHDOG_INIT"
    echo -e "${GREEN}[OK]${NC} Скрипт создан и сделан исполняемым."

    mkdir -p /opt/var/log
    touch "$WATCHDOG_LOG"

    echo ""
    printf "Запустить сейчас? [Y/n]: "
    read -r ans
    case "$ans" in
        n|N) echo "Пропущено." ;;
        *)   "$WATCHDOG_INIT" start ;;
    esac

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Готово!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo "Управление:"
    echo "  $WATCHDOG_INIT start|stop|restart|status"
    echo ""
    echo "Лог:"
    echo "  cat $WATCHDOG_LOG"
    echo ""
    echo "Удаление: запустите этот установщик и выберите 2"
    echo ""
}

# ==============================================
#  Меню
# ==============================================
echo "============================================"
echo "  Usque Watchdog (S53) для l4-socks"
echo "============================================"
echo ""
echo "Выберите действие:"
echo "  1) Установить watchdog"
echo "  2) Удалить watchdog"
printf "Введите 1 или 2 [1]: "
read -r ACTION
ACTION=${ACTION:-1}

case "$ACTION" in
    1) fn_install ;;
    2) fn_remove ;;
    *) echo "Неверный выбор."; exit 1 ;;
esac