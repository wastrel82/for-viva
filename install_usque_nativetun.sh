#!/bin/sh

# ============================================================
#  Usque-keenetic Universal Installer (nativetun) FINAL
#  База: оригинальный рабочий скрипт.
#  Добавлено:
#   - автоархитектура, latest, очистка, выбор действия
#   - обновление (stop -> download -> replace -> start)
#   - обход TLS-таймаута: статический DNS (ndmc ip host)
#   - повторные попытки register, умная распаковка zip
#   - проверка размера бинарника, бэкап при обновлении
#   - проверка туннеля после старта (curl via iface + trace)
#   - полная зачистка в fn_remove (ip host, S52usque-l4socks)
# ============================================================
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ----- НАСТРОЙКИ -----
SNI="ozon.ru"
USQUE_BIN="/opt/usr/bin/usque"
CONFIG_DIR="/opt/etc/usque"
CONFIG_FILE="${CONFIG_DIR}/usque.conf"
SESSION_FILE="${CONFIG_DIR}/session.conf"
INIT_SCRIPT="/opt/etc/init.d/S51usque"
PIDFILE="/opt/var/run/usque.pid"
LOG_FILE="/opt/var/log/usque.log"
CF_API_HOST="api.cloudflareclient.com"
CF_API_IP="104.16.24.84"

# ==============================================
#  ndmc с системными библиотеками
# ==============================================
fn_ndmc() {
    LD_LIBRARY_PATH=/lib:/usr/lib ndmc -c "$@" 2>/dev/null
}

# ==============================================
#  Статический DNS для CF API
# ==============================================
fn_ensure_cf_dns() {
    command -v ndmc >/dev/null 2>&1 || return 0
    echo -e "${YELLOW}DNS: ${CF_API_HOST} → ${CF_API_IP} (ndmc ip host)${NC}"
    if fn_ndmc "ip host ${CF_API_HOST} ${CF_API_IP}" >/dev/null 2>&1; then
        fn_ndmc "system configuration save" >/dev/null 2>&1 || true
        echo -e "${GREEN}[OK]${NC} ip host сохранён"
    else
        echo -e "${YELLOW}[WARN]${NC} ndmc не принял ip host — возможно, запись уже есть"
    fi
}

# ==============================================
#  Умная распаковка zip
# ==============================================
fn_unzip_smart() {
    local zipfile="$1"
    local dest="$2"
    # 1) python3
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "import zipfile; zipfile.ZipFile(r'$zipfile').extractall(r'$dest')" 2>/dev/null; then
            echo "Распаковано через python3" >&2
            return 0
        fi
    fi
    # 2) python
    if command -v python >/dev/null 2>&1; then
        if python -c "import zipfile; zipfile.ZipFile(r'$zipfile').extractall(r'$dest')" 2>/dev/null; then
            echo "Распаковано через python" >&2
            return 0
        fi
    fi
    # 3) не-busybox unzip
    local real_unzip=""
    for u in /opt/bin/unzip /usr/bin/unzip; do
        [ -x "$u" ] || continue
        if "$u" -v 2>&1 | grep -qi busybox; then
            continue
        fi
        real_unzip="$u"
        break
    done
    if [ -n "$real_unzip" ]; then
        if "$real_unzip" -o -q "$zipfile" -d "$dest" 2>/dev/null; then
            echo "Распаковано через $real_unzip" >&2
            return 0
        fi
    fi
    # 4) opkg install unzip и повторить
    echo "BusyBox unzip не справился — ставлю Info-ZIP unzip..." >&2
    if opkg update >/dev/null 2>&1 && opkg install unzip >/dev/null 2>&1; then
        if unzip -o -q "$zipfile" -d "$dest" 2>/dev/null; then
            echo "Распаковано через unzip (opkg)" >&2
            return 0
        fi
    fi
    return 1
}

# ==============================================
#  Определение архитектуры
# ==============================================
fn_detect_arch() {
    get_endian() {
        if [ -x /opt/usr/bin/busybox ]; then
            dd if=/opt/usr/bin/busybox bs=1 count=6 2>/dev/null | od -b | awk 'NR==1 {print $7}'
        else
            echo "unknown"
        fi
    }

    local OPKG_ARCH
    OPKG_ARCH=$(opkg print-architecture | awk '/arch/ && $2 != "all" && $2 != "noarch" {print $2; exit}')
    echo "Архитектура Entware: $OPKG_ARCH" >&2

    local FILE_ARCH
    case "$OPKG_ARCH" in
        mipsel*) FILE_ARCH="mipsle" ;;
        mips*)
            local ENDIAN
            ENDIAN=$(get_endian)
            if [ "$ENDIAN" = "001" ]; then FILE_ARCH="mipsle"; else FILE_ARCH="mips"; fi
            ;;
        aarch64*) FILE_ARCH="arm64" ;;
        arm*)    FILE_ARCH="armv7" ;;
        x86_64*) FILE_ARCH="amd64" ;;
        *)
            local ARCH
            ARCH=$(uname -m)
            case "$ARCH" in
                aarch64) FILE_ARCH="arm64" ;;
                armv7l|armv6l) FILE_ARCH="armv7" ;;
                x86_64) FILE_ARCH="amd64" ;;
                mipsel) FILE_ARCH="mipsle" ;;
                mips)
                    local ENDIAN
                    ENDIAN=$(get_endian)
                    if [ "$ENDIAN" = "001" ]; then FILE_ARCH="mipsle"; else FILE_ARCH="mips"; fi
                    ;;
                *) echo "Ошибка: архитектура не определена." >&2; return 1 ;;
            esac
            ;;
    esac

    echo "$FILE_ARCH"
}

# ==============================================
#  Скачивание бинарника (умная распаковка + размер)
# ==============================================
fn_download_binary() {
    local FILE_ARCH
    FILE_ARCH=$(fn_detect_arch) || return 1
    echo "Целевая сборка: linux_${FILE_ARCH}" >&2

    local REPO_API="https://api.github.com/repos/Diniboy1123/usque/releases/latest"
    local DOWNLOAD_URL
    DOWNLOAD_URL=$(wget -qO- "$REPO_API" 2>/dev/null | grep "browser_download_url" | grep "linux_${FILE_ARCH}" | head -n 1 | sed 's/.*:[[:space:]]*"\(http[^"]*\)".*/\1/')

    if [ -z "$DOWNLOAD_URL" ]; then
        echo "Не удалось найти пакет для архитектуры ${FILE_ARCH}." >&2
        return 1
    fi
    echo "Ссылка: $DOWNLOAD_URL" >&2

    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR" || return 1

    echo "Скачивание..." >&2
    if ! wget -q --show-progress -O usque.zip "$DOWNLOAD_URL"; then
        echo "Ошибка загрузки архива." >&2
        cd /; rm -rf "$TMP_DIR"
        return 1
    fi

    echo "Распаковка..." >&2
    if ! fn_unzip_smart "$TMP_DIR/usque.zip" "$TMP_DIR"; then
        echo "Не удалось распаковать архив (нужен python3 или unzip)." >&2
        cd /; rm -rf "$TMP_DIR"
        return 1
    fi

    local BINARY_FILE
    BINARY_FILE=$(find . -name "usque" -type f | head -n 1)
    if [ -z "$BINARY_FILE" ]; then
        echo "Бинарник не найден в архиве." >&2
        cd /; rm -rf "$TMP_DIR"
        return 1
    fi

    local bsz
    bsz=$(wc -c < "$BINARY_FILE" 2>/dev/null | tr -d ' \t')
    case "$bsz" in ''|*[!0-9]*) bsz=0 ;; esac
    if [ "$bsz" -lt 1000000 ]; then
        echo "Бинарник слишком маленький (${bsz} Б) — вероятно, обрыв загрузки." >&2
        cd /; rm -rf "$TMP_DIR"
        return 1
    fi
    echo "Размер бинарника: ${bsz} Б" >&2

    mv "$BINARY_FILE" "$USQUE_BIN"
    chmod +x "$USQUE_BIN"

    cd /
    rm -rf "$TMP_DIR"

    echo "Бинарник установлен в ${USQUE_BIN}" >&2
    return 0
}

# ==============================================
#  Проверка туннеля
# ==============================================
fn_check_tunnel() {
    local iface="${1:-opkgtun0}"
    command -v curl >/dev/null 2>&1 || return 0

    echo -e "${YELLOW}Проверка туннеля через ${iface}...${NC}"
    local ok=0
    for url in https://2ip.io/ https://www.google.com/ https://web.telegram.org/; do
        local code
        code=$(curl -sS -o /dev/null -w '%{http_code}' \
            --connect-timeout 5 --max-time 10 \
            --interface "$iface" -L "$url" 2>/dev/null) || code="000"
        case "$code" in
            2??|3??) ok=$((ok + 1)); echo "  $url: OK (HTTP $code)" ;;
            *)       echo "  $url: нет ответа (code=$code)" ;;
        esac
    done

    if [ "$ok" -ge 2 ]; then
        echo -e "${GREEN}Туннель OK: ${ok}/3 хостов доступны через ${iface}${NC}"
    else
        echo -e "${YELLOW}Туннель: слабый ответ (${ok}/3) через ${iface}${NC}"
    fi

    local trace
    trace=$(curl -sS --connect-timeout 5 --max-time 10 --interface "$iface" \
        "https://cloudflare.com/cdn-cgi/trace" 2>/dev/null) || trace=""
    if [ -n "$trace" ]; then
        local cf_ip cf_colo cf_loc cf_warp
        cf_ip=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -1)
        cf_colo=$(printf '%s\n' "$trace" | sed -n 's/^colo=//p' | head -1)
        cf_loc=$(printf '%s\n' "$trace" | sed -n 's/^loc=//p' | head -1)
        cf_warp=$(printf '%s\n' "$trace" | sed -n 's/^warp=//p' | head -1)
        [ -n "$cf_ip" ]   && echo "  trace: ip=$cf_ip"
        [ -n "$cf_colo" ] && echo "  trace: colo=$cf_colo"
        [ -n "$cf_loc" ]  && echo "  trace: loc=$cf_loc"
        [ -n "$cf_warp" ] && echo "  trace: warp=$cf_warp"
    fi

    [ "$ok" -ge 2 ]
}

# ==============================================
#  Регистрация с попытками
# ==============================================
fn_register_with_retries() {
    local attempts="${1:-5}"
    local i=1
    while [ "$i" -le "$attempts" ]; do
        echo -e "${YELLOW}Регистрация (попытка ${i}/${attempts})...${NC}"
        if /opt/usr/bin/usque register --accept-tos --config "$SESSION_FILE" 2>&1; then
            if [ -f "$SESSION_FILE" ] && [ -s "$SESSION_FILE" ]; then
                sed -i 's/"ipv6": ".*"/"ipv6": ""/' "$SESSION_FILE"
                return 0
            fi
        fi
        # fallback: иногда usque пишет config.json в CWD
        if [ ! -f "$SESSION_FILE" ] && [ -f ./config.json ]; then
            mv -f ./config.json "$SESSION_FILE" 2>/dev/null && \
                sed -i 's/"ipv6": ".*"/"ipv6": ""/' "$SESSION_FILE" && \
                return 0
        fi
        [ "$i" -lt "$attempts" ] && sleep 5
        i=$((i + 1))
    done
    return 1
}

# ==============================================
#  Обновление
# ==============================================
fn_update() {
    echo -e "${YELLOW}=== Обновление usque ===${NC}"

    if [ ! -x "$USQUE_BIN" ]; then
        echo -e "${RED}usque не установлен. Сначала выполните установку (опция 1).${NC}"
        return 1
    fi

    echo -e "${YELLOW}Останавливаю сервис...${NC}"
    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" stop 2>/dev/null || true
        sleep 2
    fi
    pkill -f "$USQUE_BIN" 2>/dev/null || true

    echo -e "${YELLOW}Создаю бэкап текущего бинарника...${NC}"
    if [ -f "$USQUE_BIN" ]; then
        cp -a "$USQUE_BIN" "${USQUE_BIN}.bak" 2>/dev/null && \
            echo "  бэкап: ${USQUE_BIN}.bak" || \
            echo -e "${YELLOW}[WARN]${NC} не удалось создать бэкап (мало места?)"
    fi

    if ! fn_download_binary; then
        echo -e "${RED}Обновление не удалось — восстанавливаю старую версию.${NC}"
        if [ -f "${USQUE_BIN}.bak" ]; then
            mv -f "${USQUE_BIN}.bak" "$USQUE_BIN"
            chmod +x "$USQUE_BIN"
            echo -e "${YELLOW}Старая версия восстановлена.${NC}"
        fi
        [ -x "$INIT_SCRIPT" ] && "$INIT_SCRIPT" start
        return 1
    fi

    echo -e "${YELLOW}Запускаю сервис...${NC}"
    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" start
    else
        echo -e "${RED}Скрипт автозапуска не найден: ${INIT_SCRIPT}${NC}"
        return 1
    fi

    sleep 3

    local iface="opkgtun0"
    if [ -f "$CONFIG_FILE" ]; then
        local c
        c=$(sed -n 's/^IFACE="\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -1)
        [ -n "$c" ] && iface="$c"
    fi

    if fn_check_tunnel "$iface"; then
        rm -f "${USQUE_BIN}.bak"
        echo -e "${GREEN}Обновление завершено успешно!${NC}"
        return 0
    fi

    echo -e "${YELLOW}Туннель не отвечает — пробую restart...${NC}"
    "$INIT_SCRIPT" restart 2>/dev/null || {
        "$INIT_SCRIPT" stop 2>/dev/null || true
        sleep 1
        "$INIT_SCRIPT" start 2>/dev/null || true
    }
    sleep 3

    if fn_check_tunnel "$iface"; then
        rm -f "${USQUE_BIN}.bak"
        echo -e "${GREEN}Обновление завершено (после restart).${NC}"
        return 0
    fi

    echo -e "${YELLOW}Туннель всё ещё не отвечает. Оставляю новую версию.${NC}"
    echo "  Бэкап сохранён: ${USQUE_BIN}.bak"
    echo "  Для отката: mv ${USQUE_BIN}.bak ${USQUE_BIN} && $INIT_SCRIPT restart"
    return 0
}

# ==============================================
#  Полное удаление
# ==============================================
fn_remove() {
    echo -e "${YELLOW}=== Полное удаление usque ===${NC}"

    if [ -x "$INIT_SCRIPT" ]; then
        echo "Останавливаю сервис..."
        "$INIT_SCRIPT" stop 2>/dev/null || true
        sleep 1
    fi

    # l4-socks
    if [ -x /opt/etc/init.d/S52usque-l4socks ]; then
        echo "Останавливаю l4-socks сервис..."
        /opt/etc/init.d/S52usque-l4socks stop 2>/dev/null || true
        sleep 1
    fi
    pkill -f "usque l4-socks" 2>/dev/null || true
    rm -f /opt/etc/init.d/S52usque-l4socks
    rm -f /opt/var/run/usque-l4socks.pid
    rm -f /opt/var/log/usque-l4socks.log

    pkill -f "$USQUE_BIN" 2>/dev/null && echo "Остановлены процессы usque." || true

    echo "Удаляю интерфейсы opkgtun из системы..."
    for iface in $(ip link show 2>/dev/null | grep -o 'opkgtun[0-9]*' | sort -u); do
        ip link del "$iface" 2>/dev/null && echo "  Удалён системный $iface" || true
    done

    echo "Удаляю интерфейсы OpkgTun из NDM..."
    for ndm_if in $(fn_ndmc "show interface" 2>/dev/null | grep -o 'OpkgTun[0-9]*' | sort -u); do
        fn_ndmc "no interface $ndm_if" && echo "  Удалён NDM $ndm_if" || true
    done

    if command -v ndmc >/dev/null 2>&1; then
        if fn_ndmc "no ip host ${CF_API_HOST}" >/dev/null 2>&1; then
            echo "  Удалён ip host: ${CF_API_HOST}"
        fi
    fi

    fn_ndmc "system configuration save" >/dev/null 2>&1 || true

    echo "Удаляю файлы..."
    rm -f "$USQUE_BIN"
    rm -f "${USQUE_BIN}.bak"
    rm -rf "$CONFIG_DIR"
    rm -f "$INIT_SCRIPT"
    rm -f "$PIDFILE"
    rm -f "$LOG_FILE"

    if [ -f /opt/etc/sysctl.conf ]; then
        sed -i '/net\.core\.rmem_max=2500000/d; /net\.core\.wmem_max=2500000/d' /opt/etc/sysctl.conf 2>/dev/null || true
    fi

    echo -e "${GREEN}Usque полностью удалён. Рекомендуется перезагрузить роутер.${NC}"
}

# ==============================================
#  0. Выбор действия
# ==============================================
echo "============================================"
echo "  Usque-keenetic (nativetun) - Final"
echo "============================================"
echo ""
echo "Выберите действие:"
echo "  1) Установить usque"
echo "  2) Удалить usque"
echo "  3) Обновить usque"
printf "Введите 1, 2 или 3 [1]: "
read -r ACTION
ACTION=${ACTION:-1}

if [ "$ACTION" = "2" ]; then
    fn_remove
    exit 0
fi

if [ "$ACTION" = "3" ]; then
    fn_update
    exit $?
fi

# ==============================================
#  1. Очистка старых версий (только файлы!)
# ==============================================
echo -e "${YELLOW}=== Очистка старых версий ===${NC}"

for init in /opt/etc/init.d/S51usque /opt/etc/init.d/S99usque; do
    if [ -x "$init" ]; then
        "$init" stop 2>/dev/null || true
        sleep 1
    fi
done

pkill -f "$USQUE_BIN" 2>/dev/null || true

rm -f /opt/etc/init.d/S51usque /opt/etc/init.d/S99usque
rm -f "$PIDFILE" /opt/var/run/usque_monitor.pid
rm -f "${CONFIG_FILE}.run"

echo -e "${GREEN}Очистка завершена.${NC}"
echo ""

# ==============================================
#  2. Установка зависимостей
# ==============================================
echo -e "${YELLOW}[1/6] Установка зависимостей...${NC}"
opkg update > /dev/null 2>&1 || true
for pkg in curl unzip ca-certificates wget-ssl; do
    if ! opkg list-installed | grep -q "^${pkg} -"; then
        opkg install "$pkg" > /dev/null 2>&1
    fi
done
echo -e "${GREEN}Зависимости установлены.${NC}"

export SSL_CERT_FILE=/opt/etc/ssl/certs/ca-certificates.crt

# ==============================================
#  3. Определение архитектуры и скачивание latest
# ==============================================
echo -e "${YELLOW}[2/6] Определение архитектуры и скачивание...${NC}"

if ! fn_download_binary; then
    echo -e "${RED}Установка прервана: не удалось скачать бинарник.${NC}"
    exit 1
fi

# ==============================================
#  4. Создание конфигурации
# ==============================================
echo -e "${YELLOW}[4/6] Создание конфигурации...${NC}"
mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_FILE" << EOF
# Interface for USQUE (e.g., opkgtun0).
IFACE="opkgtun0"

# Interface IP address.
# By default, the first free address in the range
# 172.16.1.100 - 172.16.1.200 will be selected.
# IFACE_IP="172.16.0.1"

# Subnet mask. Default is 255.255.255.255
# IFACE_MASK="255.255.255.255"

# SNI for traffic masking
SNI="${SNI}"

# Configuration version
# DO NOT CHANGE THIS VALUE
CONFIG_VERSION=1
EOF

echo -e "${GREEN}Конфиг создан: ${CONFIG_FILE}${NC}"

# ==============================================
#  5. Создание init-скрипта (оригинал + fn_ensure_cf_dns + LD_LIBRARY_PATH)
# ==============================================
echo -e "${YELLOW}[5/6] Создание скрипта автозапуска...${NC}"

cat > "$INIT_SCRIPT" << 'INITEOF'
#!/bin/sh
# Entware startup script for usque (nativetun mode)

PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

NAME="USQUE"
USQUE_BIN="/opt/usr/bin/usque"
PIDFILE="/opt/var/run/usque.pid"
CONFIG_FILE="/opt/etc/usque/usque.conf"
SESSION_FILE="/opt/etc/usque/session.conf"
LOG_FILE="/opt/var/log/usque.log"
CF_API_HOST="api.cloudflareclient.com"
CF_API_IP="104.16.24.84"

# ==================== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ====================

fn_get_available_tun_interface() {
    local existing=$(ip -o link show | awk -F': ' '{print $2}' | grep '^opkgtun[0-9]*$')
    if [ -z "$existing" ]; then
        echo "opkgtun0"
        return 0
    fi
    local max=$(echo "$existing" | sed 's/opkgtun//' | sort -n | tail -1)
    local next=$((max + 1))
    echo "opkgtun$next"
}

fn_get_available_ip() {
    local subnet="172.16.1"
    local start=100
    local end=200
    for i in $(seq $start $end); do
        local ip="$subnet.$i"
        if ! grep -q "$ip" /proc/net/arp 2>/dev/null &&
            ! ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

fn_net_if_exists() {
    ip link show "$1" 2>/dev/null | grep -q "$1"
}

fn_convert_to_net_if_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

fn_convert_to_ndm_name() {
    echo "$1" | sed 's/^opkg/Opkg/; s/tun/Tun/'
}

fn_ndm_cmd() {
    local out
    out=$(LD_LIBRARY_PATH=/lib:/usr/lib /bin/ndmc -c "$1" 2>&1 >/dev/null) || {
        echo "$2:" >&2
        echo "| $out" >&2
        return 1
    }
}

fn_ndm_if_create() {
    fn_ndm_cmd "interface $1" "Failed to create interface $1"
}

fn_ndm_if_remove() {
    fn_ndm_cmd "no interface $1" "Failed to remove interface $1"
}

fn_ndm_if_set_address() {
    fn_ndm_cmd "interface $1 ip address $2 $3" "Failed to set ip/netmask for interface $1"
}

fn_ndm_if_set_description() {
    fn_ndm_cmd "interface $1 description $2" "Failed to set description for interface $1"
}

fn_ndm_if_up() {
    fn_ndm_cmd "interface $1 up" "Failed to up interface $1"
}

fn_ndm_if_down() {
    fn_ndm_cmd "interface $1 down" "Failed to down interface $1"
}

fn_ndm_if_exists() {
    LD_LIBRARY_PATH=/lib:/usr/lib ndmc -c "show interface $1" >/dev/null
}

fn_ndm_save_system_config() {
    fn_ndm_cmd "system configuration save" "Failed to save system config"
}

fn_ensure_cf_dns() {
    command -v ndmc >/dev/null 2>&1 || return 0
    LD_LIBRARY_PATH=/lib:/usr/lib ndmc -c "ip host ${CF_API_HOST} ${CF_API_IP}" >/dev/null 2>&1 || true
    LD_LIBRARY_PATH=/lib:/usr/lib ndmc -c "system configuration save" >/dev/null 2>&1 || true
}

fn_resolve_tun_interface_config() {
    if [ -z "$IFACE_IP" ]; then
        local val=$(fn_get_available_ip)
        if [ $? -eq 1 ]; then
            echo "Failed to get dynamic ip address for interface $IFACE" >&2
            return 1
        fi
        IFACE_IP="$val"
    fi
    if [ -z "$IFACE_MASK" ]; then
        IFACE_MASK="255.255.255.255"
    fi
    if [ -z "$IFACE_NAME" ]; then
        IFACE_NAME="usque"
    fi
}

fn_check_tun_interface() {
    local iface=$(fn_convert_to_net_if_name "$IFACE")
    if fn_net_if_exists "$iface"; then
        echo "Interface $IFACE is already in use." >&2
        return 1
    fi
}

fn_acquire_tun_inerface() {
    local iface=$(fn_convert_to_ndm_name "$IFACE")
    if ! fn_ndm_if_exists "$iface"; then
        echo "Create tun interface $IFACE"
        fn_ndm_if_create "$iface" || return 1
    fi
}

fn_setup_tun_interface() {
    if [ -z "$IFACE" ]; then
        echo "No interface to work with" >&2
        return 1
    fi
    local iface=$(fn_convert_to_ndm_name "$IFACE")
    echo "Setup tun interface $IFACE ($IFACE_NAME): ip=$IFACE_IP netmask=$IFACE_MASK"
    fn_ndm_if_set_description "$iface" "$IFACE_NAME" || return 1
    fn_ndm_cmd "interface $iface ip global auto" "Failed to perform 'ip global auto'" || return 1
    fn_ndm_cmd "interface $iface ip tcp adjust-mss pmtu" "Failed to set perform 'ip tcp adjust-mss pmtu'" || return 1
    fn_ndm_if_set_address "$iface" "$IFACE_IP" "$IFACE_MASK" || return 1
    fn_ndm_cmd "interface $iface ip mtu 1280" "Failed to set MTU" || return 1
    fn_ndm_if_up "$iface" || return 1
}

fn_release_tun_interface() {
    if [ -z "$IFACE" ]; then
        echo "No interface to work with" >&2
        return 1
    fi
    local iface=$(fn_convert_to_ndm_name "$IFACE")
    fn_ndm_if_down "$iface"
}

fn_has_session() {
    [ -f "$SESSION_FILE" ] && return 0
    return 1
}

fn_create_session() {
    echo "Register a new client and enroll a device key"
    fn_ensure_cf_dns
    $USQUE_BIN register --accept-tos --config "$SESSION_FILE" 2>&1
    if [ -f "$SESSION_FILE" ]; then
        sed -i 's/"ipv6": ".*"/"ipv6": ""/' "$SESSION_FILE"
        echo "Session created, IPv6 disabled"
    fi
}

fn_remove_session() {
    echo "Remove client data and device key"
    rm -f "$SESSION_FILE"
}

fn_create_session_if_required() {
    fn_has_session || fn_create_session || {
        echo "Failed to register a new client and enroll a device key" >&2
        return 1
    }
}

# ==================== ЗАГРУЗКА КОНФИГУРАЦИИ ====================

. "$CONFIG_FILE"
if [ -f "$CONFIG_FILE.run" ]; then
    . "$CONFIG_FILE.run"
fi

# ==================== УПРАВЛЕНИЕ СЕРВИСОМ ====================

fn_is_running() {
    local pid_running=$(pgrep -nf "$USQUE_BIN" 2>/dev/null)
    [ -z "$pid_running" ] && return 1
    [ ! -f "$PIDFILE" ] && return 1
    local pid_saved=$(cat "$PIDFILE" 2>/dev/null)
    [ "$pid_running" -ne "$pid_saved" ] && return 1
    kill -0 $pid_saved 2>/dev/null && return 0
    return 1
}

fn_status() {
    if fn_is_running; then
        echo "Service $NAME is running (PID $(cat $PIDFILE))"
        echo "Log file: $LOG_FILE"
        if [ -f "$LOG_FILE" ]; then
            echo "Last 5 log lines:"
            tail -5 "$LOG_FILE"
        fi
    else
        echo "Service $NAME is stopped"
    fi
}

fn_validate_config() {
    if [ -z "$IFACE" ]; then
        echo "IFACE not specified in config file" >&2
        return 1
    fi
}

fn_create_running_config() {
    echo "IFACE=\"$IFACE\"" >"$CONFIG_FILE.run"
    echo "IFACE_IP=\"$IFACE_IP\"" >>"$CONFIG_FILE.run"
    echo "IFACE_MASK=\"$IFACE_MASK\"" >>"$CONFIG_FILE.run"
}

fn_remove_running_config() {
    rm -f "$CONFIG_FILE.run"
    . "$CONFIG_FILE"
}

fn_daemon_args() {
    local iface=$(echo "$IFACE" | tr '[:upper:]' '[:lower:]')
    local args="nativetun --config "$SESSION_FILE" --interface-name $iface --no-iproute2 --no-tunnel-ipv6 --always-reconnect"
    if [ -n "$SNI" ]; then
        args="$args -s $SNI"
    fi
    echo "$args"
}

fn_start() {
    if fn_is_running; then
        echo "Service $NAME is already running" >&2
        return 1
    fi

    fn_validate_config || return 1
    fn_resolve_tun_interface_config || return 1
    # fn_check_tun_interface || return 1
    fn_create_session_if_required || return 1
    fn_acquire_tun_inerface || return 1

    if [ -f "$SESSION_FILE" ]; then
        sed -i 's/"ipv6": ".*"/"ipv6": ""/' "$SESSION_FILE"
    fi

    sysctl -w net.core.rmem_max=2500000 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=2500000 >/dev/null 2>&1
    if ! grep -q "net.core.rmem_max" /opt/etc/sysctl.conf 2>/dev/null; then
        echo "net.core.rmem_max=2500000" >> /opt/etc/sysctl.conf
        echo "net.core.wmem_max=2500000" >> /opt/etc/sysctl.conf
    fi

    echo "Starting $NAME service..."
    $USQUE_BIN $(fn_daemon_args) >> "$LOG_FILE" 2>&1 &
    echo $! > "$PIDFILE"

    sleep 2

    if ! kill -0 $(cat "$PIDFILE") 2>/dev/null; then
        echo "Failed to start $NAME service" >&2
        rm -f "$PIDFILE"
        fn_stop_internal
        return 1
    fi

    fn_setup_tun_interface || {
        fn_stop_internal
        return 1
    }

    ndmc -c "interface OpkgTun0 ip global 32084" 2>/dev/null
    ndmc -c "system configuration save" 2>/dev/null

    fn_create_running_config
    echo "Started $NAME service"
}

fn_stop_internal() {
    echo "Stopping $NAME service..."
    fn_release_tun_interface
    fn_remove_running_config
    if [ -f "$PIDFILE" ]; then
        kill $(cat "$PIDFILE") 2>/dev/null
        rm -f "$PIDFILE"
    fi
    echo "Stopped $NAME service"
}

fn_stop() {
    if ! fn_is_running; then
        echo "Service $NAME is not running" >&2
        return 1
    fi
    fn_stop_internal
}

case "$1" in
start)   fn_start ;;
stop)    fn_stop ;;
status)  fn_status ;;
restart) fn_stop; fn_start ;;
*)       echo "Usage: $0 {start|stop|restart|status}" ;;
esac
INITEOF

chmod +x "$INIT_SCRIPT"
echo -e "${GREEN}Скрипт автозапуска создан: ${INIT_SCRIPT}${NC}"

# ==============================================
#  6. Регистрация и запуск сервиса
# ==============================================
echo -e "${YELLOW}[6/6] Регистрация и запуск сервиса...${NC}"

if [ ! -f "$SESSION_FILE" ]; then
    fn_ensure_cf_dns
    if ! fn_register_with_retries 5; then
        echo -e "${RED}Не удалось зарегистрироваться после 5 попыток.${NC}"
        echo "Можно попробовать вручную:"
        echo "  $USQUE_BIN register --accept-tos --config $SESSION_FILE"
        exit 1
    fi
fi

"$INIT_SCRIPT" start || {
    echo -e "${RED}Сервис не запустился. Смотрите лог: $LOG_FILE${NC}"
    exit 1
}

sleep 3

# Читаем IFACE из конфига
iface="opkgtun0"
if [ -f "$CONFIG_FILE" ]; then
    _c=$(sed -n 's/^IFACE="\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -1)
    [ -n "$_c" ] && iface="$_c"
fi

fn_check_tunnel "$iface" || {
    echo -e "${YELLOW}Интерфейс поднят, но трафик не идёт.${NC}"
    echo "  Проверьте политики маршрутизации в веб-интерфейсе Keenetic."
    echo "  Логи: $LOG_FILE"
}

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Установка завершена!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "${YELLOW}Дальнейшие шаги:${NC}"
echo "  1. В веб-интерфейсе Keenetic:"
echo "     «Интернет» → «Политики маршрутизации» → выбрать OpkgTun0"
echo "  2. Проверка: curl --interface ${iface} https://ifconfig.me"
echo "  3. Управление: $INIT_SCRIPT {start|stop|restart|status}"
echo "  4. Логи: cat $LOG_FILE"
echo "  5. Обновление: запустите скрипт и выберите опцию 3"
echo ""
