#!/bin/sh
# install-log-cleaner.sh
# Устанавливает/удаляет S54log-cleaner — фоновую очистку логов в /opt/var/log/.
# Раз в неделю обнуляет .log файлы больше 0.5 МБ (включая свой лог).
# Без cron. Меню: 1) Установить  2) Удалить

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

LOG_DIR="/opt/var/log"
CLEANER_INIT="/opt/etc/init.d/S54log-cleaner"
CLEANER_PID="/opt/var/run/log-cleaner.pid"
CLEANER_LOG="${LOG_DIR}/log-cleaner.log"
INTERVAL=604800      # 7 дней в секундах
MAX_SIZE=524288      # 0.5 МБ

# ==============================================
#  Удаление
# ==============================================
fn_remove() {
    echo -e "${YELLOW}=== Удаление S54log-cleaner ===${NC}"
    if [ -x "$CLEANER_INIT" ]; then
        "$CLEANER_INIT" stop 2>/dev/null || true
        sleep 1
    fi
    if [ -f "$CLEANER_PID" ]; then
        kill "$(cat "$CLEANER_PID")" 2>/dev/null || true
        rm -f "$CLEANER_PID"
    fi
    rm -f "$CLEANER_INIT"
    rm -f "$CLEANER_PID"
    rm -f "$CLEANER_LOG"
    echo -e "${GREEN}Log-cleaner удалён. Логи в $LOG_DIR не тронуты.${NC}"
}

# ==============================================
#  Установка
# ==============================================
fn_install() {
    echo "============================================"
    echo "  Установка S54log-cleaner"
    echo "============================================"
    echo ""

    if [ ! -d "$LOG_DIR" ]; then
        echo -e "${RED}Ошибка: директория $LOG_DIR не существует.${NC}"
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC} Директория логов найдена"

    if [ -x "$CLEANER_INIT" ]; then
        echo -e "${YELLOW}[INFO]${NC} $CLEANER_INIT уже существует."
        printf "Перезаписать? [y/N]: "
        read -r ans
        case "$ans" in
            y|Y) "$CLEANER_INIT" stop 2>/dev/null || true; sleep 1 ;;
            *) echo "Отменено."; exit 1 ;;
        esac
    fi

    echo ""
    echo -e "${YELLOW}Создаю $CLEANER_INIT...${NC}"

    cat > "$CLEANER_INIT" << 'EOF'
#!/bin/sh
# S54log-cleaner — раз в неделю обнуляет .log файлы > 0.5 МБ в /opt/var/log/.
# Включая свой собственный лог. Без cron.

PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

NAME="log-cleaner"
LOG_DIR="/opt/var/log"
PIDFILE="/opt/var/run/log-cleaner.pid"
SELF_LOG="/opt/var/log/log-cleaner.log"
INTERVAL=604800
MAX_SIZE=524288

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$SELF_LOG"
}

clean_logs() {
    local cleaned=0
    for log_file in "$LOG_DIR"/*.log; do
        [ -f "$log_file" ] || continue
        size=$(wc -c < "$log_file" 2>/dev/null)
        case "$size" in ''|*[!0-9]*) continue ;; esac
        if [ "$size" -gt "$MAX_SIZE" ]; then
            name=$(basename "$log_file")
            kb=$((size / 1024))
            > "$log_file"
            log "cleaned $name (${kb}KB)"
            cleaned=$((cleaned + 1))
        fi
    done
    [ "$cleaned" -gt 0 ] || log "no logs over limit"
}

run_loop() {
    log "log-cleaner started (interval=${INTERVAL}s, max=${MAX_SIZE}B)"
    while :; do
        sleep "$INTERVAL"
        clean_logs
    done
}

start() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "$NAME already running (PID $(cat "$PIDFILE"))."
        return 0
    fi
    mkdir -p /opt/var/log
    : > "$SELF_LOG"
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
        echo "Log: $SELF_LOG"
        if [ -f "$SELF_LOG" ]; then
            echo "Last 5 log lines:"
            tail -5 "$SELF_LOG"
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

    chmod +x "$CLEANER_INIT"
    echo -e "${GREEN}[OK]${NC} Скрипт создан и сделан исполняемым."

    mkdir -p /opt/var/log
    touch "$CLEANER_LOG"

    echo ""
    printf "Запустить сейчас? [Y/n]: "
    read -r ans
    case "$ans" in
        n|N) echo "Пропущено." ;;
        *)   "$CLEANER_INIT" start ;;
    esac

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Готово!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo "Управление:"
    echo "  $CLEANER_INIT start|stop|restart|status"
    echo ""
    echo "Лог:"
    echo "  cat $CLEANER_LOG"
    echo ""
    echo "Удаление: запустите этот установщик и выберите 2"
    echo ""
}

# ==============================================
#  Меню
# ==============================================
echo "============================================"
echo "  Log Cleaner (S54) для /opt/var/log/"
echo "============================================"
echo ""
echo "Выберите действие:"
echo "  1) Установить"
echo "  2) Удалить"
printf "Введите 1 или 2 [1]: "
read -r ACTION
ACTION=${ACTION:-1}

case "$ACTION" in
    1) fn_install ;;
    2) fn_remove ;;
    *) echo "Неверный выбор."; exit 1 ;;
esac