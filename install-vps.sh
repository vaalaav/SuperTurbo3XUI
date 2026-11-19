#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Установщик 3x-ui 3.11+ + Nginx HTTP/2 XHTTP + Security Stack (v7)
# Инбаунды: XHTTP Packet-UP ("Мобилы") + Stream-One ("Домашний") + TCP Reality Self-Steal ("Reality") без клиентов
# Маршрутизация: api->api, блокировка BitTorrent, Private IPs, Ads, Malware
# Поддержка: Ubuntu 24.04 LTS | Маска: CloudDisk (mock API) / VAPEN Cloud Storage (S3) / Reverse Proxy
# Защита: UFW + Fail2Ban + CrowdSec + C24Be AS_Network_List + CyberOK_Skipa_ips
#
# Неинтерактивный запуск (пример):
#   NON_INTERACTIVE=1 DOMAIN=node.example.com MASK_MODE=vapen COMPANY_NAME="VAPEN" \
#   ENABLE_SCANNERS_BLOCK=Y SKIP_UPGRADE=1 bash install-vps-v7.sh
# Доступные переменные окружения:
#   NON_INTERACTIVE=1, AUTO_CONFIRM=1, SKIP_UPGRADE=1, AUTO_UPGRADE=1,
#   IGNORE_DNS_CHECK=1, SSH_NEW_PORT=2222, DOMAIN, LE_EMAIL, MASK_MODE (disk|vapen|proxy),
#   COMPANY_NAME, REVERSE_PROXY_URL, PANEL_USER, PANEL_PASS, ENABLE_SCANNERS_BLOCK (Y|N)
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOG_FILE="/var/log/my3xui-install.log"
LOG_STREAM_ACTIVE=0
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
AUTO_CONFIRM="${AUTO_CONFIRM:-$NON_INTERACTIVE}"

_log_file_write() {
    if [[ "${LOG_STREAM_ACTIVE}" -eq 0 && -w "${LOG_FILE}" ]]; then
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "${LOG_FILE}" || true
    fi
}

log_info()  { echo -e "${CYAN}[INFO]${NC} $1";  _log_file_write "[INFO] $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1";   _log_file_write "[OK] $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; _log_file_write "[WARN] $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1";  _log_file_write "[ERROR] $1"; exit 1; }

# 1. Проверка прав, инициализация лога и проверка ОС (только Ubuntu 24.04 LTS)
[[ $EUID -ne 0 ]] && log_err "Запустите скрипт от имени root (sudo bash $0)."

touch "${LOG_FILE}" && chmod 600 "${LOG_FILE}"
_log_file_write "=== Запуск установщика 3x-ui v7 ==="

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]] || [[ "$VERSION_ID" != "24.04" ]]; then
        log_warn "Обнаружена ОС: ${PRETTY_NAME:-Unknown}. Скрипт предназначен для Ubuntu 24.04 LTS."
        if [[ "${NON_INTERACTIVE}" == "1" ]]; then
            log_err "Неинтерактивный режим прерван: неподдерживаемая ОС."
        fi
        read -erp "Продолжить на свой страх и риск? [y/N]: " cont
        [[ ! "$cont" =~ ^[Yy]$ ]] && exit 1
    fi
else
    log_err "Не удалось определить ОС (/etc/os-release не найден)."
fi

# Защита нестандартного порта SSH на Ubuntu 24.04 (отключение ssh.socket -> ssh.service)
ensure_ssh_service_mode() {
    mkdir -p /run/sshd
    local cfg_port=""
    if command -v sshd >/dev/null 2>&1; then
        cfg_port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)
    fi
    cfg_port=${cfg_port:-22}

    # Опциональная смена порта SSH через переменную окружения SSH_NEW_PORT
    if [[ -n "${SSH_NEW_PORT:-}" ]]; then
        if ! [[ "${SSH_NEW_PORT}" =~ ^[0-9]+$ ]] || [[ "${SSH_NEW_PORT}" -lt 1 || "${SSH_NEW_PORT}" -gt 65535 ]]; then
            log_err "Некорректный порт SSH_NEW_PORT=${SSH_NEW_PORT} (допустимо 1..65535)."
        fi
        if [[ "${SSH_NEW_PORT}" != "${cfg_port}" ]]; then
            log_info "Настройка порта SSH на ${SSH_NEW_PORT} (/etc/ssh/sshd_config.d/99-custom-port.conf)..."
            mkdir -p /etc/ssh/sshd_config.d
            printf "Port %s\n" "${SSH_NEW_PORT}" > /etc/ssh/sshd_config.d/99-custom-port.conf
            if ! sshd -t 2>/dev/null; then
                rm -f /etc/ssh/sshd_config.d/99-custom-port.conf
                log_err "Ошибка проверки конфигурации sshd после смены порта на ${SSH_NEW_PORT}."
            fi
            cfg_port="${SSH_NEW_PORT}"
        fi
    fi

    # Если задан нестандартный порт SSH, отключаем ssh.socket и переводим на ssh.service,
    # иначе после apt upgrade или перезагрузки Ubuntu 24.04 сбросит порт обратно на 22.
    if [[ "${cfg_port}" != "22" ]]; then
        if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
            log_warn "Обнаружен нестандартный порт SSH (${cfg_port}) при активном ssh.socket (Ubuntu 24.04)."
            log_info "Отключение ssh.socket и перевод SSH на ssh.service для сохранения порта после перезагрузки..."
            if sshd -t 2>/dev/null; then
                systemctl disable --now ssh.socket >/dev/null 2>&1 || true
                systemctl enable --now ssh.service >/dev/null 2>&1 || true
                systemctl restart ssh.service
                log_ok "SSH переведён на ssh.service (порт ${cfg_port} зафиксирован)."
            else
                log_warn "sshd -t вернул ошибку — ssh.socket не изменён. Проверьте /etc/ssh/sshd_config вручную!"
            fi
        elif [[ -n "${SSH_NEW_PORT:-}" ]]; then
            systemctl enable --now ssh.service >/dev/null 2>&1 || true
            systemctl restart ssh.service
            log_ok "SSH перезапущен на порту ${cfg_port}."
        fi
    fi
}

ensure_ssh_service_mode

# Защита APT от зависаний (ForceIPv4, отключение pipelining, таймаут 15с)
configure_apt_resilience() {
    cat <<'EOF' > /etc/apt/apt.conf.d/99fix-apt-hang
Acquire::ForceIPv4 "true";
Acquire::http::Pipeline-Depth "0";
Acquire::http::No-Cache "true";
Acquire::BrokenProxy "true";
Acquire::http::Timeout "15";
Acquire::https::Timeout "15";
Acquire::Retries "2";
EOF
}

# Надёжное обновление списков APT с таймаутом и автопереключением archive.ubuntu.com -> nl.archive.ubuntu.com
safe_apt_update() {
    export DEBIAN_FRONTEND=noninteractive
    if timeout 45 apt-get update -qq; then
        return 0
    fi

    log_warn "apt-get update завис или завершился ошибкой. Проверяем зеркало Ubuntu..."
    rm -rf /var/lib/apt/lists/partial/* 2>/dev/null || true

    local switched=0
    for f in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do
        if [[ -f "$f" ]] && grep -qE 'https?://archive\.ubuntu\.com/ubuntu' "$f"; then
            sed -i -E 's|https?://archive\.ubuntu\.com/ubuntu|http://nl.archive.ubuntu.com/ubuntu|g' "$f"
            switched=1
        fi
    done

    if [[ "$switched" -eq 1 ]]; then
        log_info "Зеркало переключено на http://nl.archive.ubuntu.com/ubuntu — повторный apt-get update..."
        rm -rf /var/lib/apt/lists/* 2>/dev/null || true
    else
        log_info "Повторный запуск apt-get update после очистки partial-кэша..."
    fi

    timeout 60 apt-get update -qq || log_err "Не удалось выполнить apt-get update (проверьте сеть или зеркала в /etc/apt/)."
}

configure_apt_resilience

check_system_updates() {
    if [[ "${SKIP_UPGRADE:-0}" == "1" ]]; then
        log_info "Проверка обновлений системы пропущена (SKIP_UPGRADE=1)."
        return 0
    fi
    log_info "Проверка наличия обновлений системы..."
    export DEBIAN_FRONTEND=noninteractive
    safe_apt_update
    local upgradable_count
    upgradable_count=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true)
    if [[ "${upgradable_count}" -gt 0 ]]; then
        log_warn "Доступно обновлений пакетов: ${upgradable_count}."
        local do_upgrade="Y"
        if [[ "${NON_INTERACTIVE}" == "1" ]]; then
            do_upgrade=$( [[ "${AUTO_UPGRADE:-0}" == "1" ]] && echo "Y" || echo "N" )
        else
            read -erp "Установить системные обновления перед началом установки? [Y/n]: " do_upgrade
            do_upgrade=${do_upgrade:-"Y"}
        fi
        if [[ "$do_upgrade" =~ ^[Yy]$ ]]; then
            log_info "Установка обновлений системы..."
            apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
            log_ok "Система успешно обновлена."
            # Повторная проверка после обновления openssh-server, чтобы ssh.socket не включился обратно
            ensure_ssh_service_mode
            if [[ -f /var/run/reboot-required ]]; then
                log_warn "Обновление затронуло ядро или системные библиотеки — рекомендуется перезагрузка."
                if [[ "${NON_INTERACTIVE}" != "1" ]]; then
                    read -erp "Перезагрузить сервер сейчас (после перезагрузки запустите скрипт снова)? [y/N]: " DO_REBOOT
                    if [[ "$DO_REBOOT" =~ ^[Yy]$ ]]; then
                        log_info "Перезагрузка сервера..."
                        reboot
                        exit 0
                    fi
                fi
            fi
        else
            log_info "Обновление системы пропущено."
        fi
    else
        log_ok "Система актуальна, обновлений не требуется."
    fi
}

check_system_updates

# Предварительная проверка наличия python3, openssl и curl для генерации учётных данных
if ! command -v python3 >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    log_info "Установка базовых зависимостей (python3, openssl, curl)..."
    export DEBIAN_FRONTEND=noninteractive
    safe_apt_update
    apt-get install -y -qq python3 openssl curl ca-certificates
fi

[[ "${NON_INTERACTIVE}" != "1" ]] && clear
echo -e "${BOLD}${CYAN}=================================================================${NC}"
echo -e "${BOLD}   Установка 3x-ui (XHTTP + TCP Reality Self-Steal) + Security      ${NC}"
echo -e "${BOLD}${CYAN}=================================================================${NC}\n"

# 2. Ввод параметров (интерактивно или через переменные окружения) и проверка DNS
if [[ -n "${DOMAIN:-}" ]]; then
    DOMAIN=$(echo "$DOMAIN" | LC_ALL=C tr -cd "a-zA-Z0-9.-" | tr "A-Z" "a-z")
    [[ -z "$DOMAIN" || "$DOMAIN" != *.* ]] && log_err "Передан некорректный DOMAIN=${DOMAIN}."
    log_info "Используется домен из окружения: ${DOMAIN}"
else
    [[ "${NON_INTERACTIVE}" == "1" ]] && log_err "Для NON_INTERACTIVE=1 необходимо указать переменную DOMAIN."
    while true; do
        read -erp "1. Введите ваш основной домен (например, node.example.com): " DOMAIN
        DOMAIN=$(echo "$DOMAIN" | LC_ALL=C tr -cd "a-zA-Z0-9.-" | tr "A-Z" "a-z")
        [[ -n "$DOMAIN" && "$DOMAIN" == *.* ]] && break
        echo -e "${RED}Некорректный домен. Попробуйте снова.${NC}"
    done
fi

SERVER_IP=$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -fsSL --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)
DOMAIN_IPS=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)
if [[ -z "$DOMAIN_IPS" ]]; then
    log_warn "Домен ${DOMAIN} сейчас не резолвится в IPv4 (A-запись не найдена)!"
    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        [[ "${IGNORE_DNS_CHECK:-0}" != "1" ]] && log_err "DNS-проверка не пройдена (укажите IGNORE_DNS_CHECK=1 для пропуска)."
    else
        read -erp "Certbot не сможет выпустить сертификат без DNS. Всё равно продолжить? [y/N]: " dns_cont
        [[ ! "$dns_cont" =~ ^[Yy]$ ]] && exit 1
    fi
elif [[ -n "$SERVER_IP" ]] && ! grep -qx "$SERVER_IP" <<< "$DOMAIN_IPS"; then
    log_warn "Домен ${DOMAIN} указывает на (${DOMAIN_IPS//$'\n'/, }), а IP этого сервера: ${SERVER_IP}!"
    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        [[ "${IGNORE_DNS_CHECK:-0}" != "1" ]] && log_err "IP домена не совпадает с IP сервера (укажите IGNORE_DNS_CHECK=1 для пропуска)."
    else
        read -erp "Выпуск SSL-сертификата Let's Encrypt упадёт, если включен прокси/CDN или неверный IP. Продолжить? [y/N]: " dns_cont
        [[ ! "$dns_cont" =~ ^[Yy]$ ]] && exit 1
    fi
else
    log_ok "DNS-проверка пройдена: ${DOMAIN} -> ${SERVER_IP:-OK}"
fi

if [[ -n "${LE_EMAIL:-}" ]]; then
    log_info "Email Let's Encrypt из окружения: ${LE_EMAIL}"
elif [[ "${NON_INTERACTIVE}" == "1" ]]; then
    LE_EMAIL="admin@${DOMAIN}"
else
    read -erp "2. Введите Email для Let's Encrypt [admin@${DOMAIN}]: " LE_EMAIL
    LE_EMAIL=${LE_EMAIL:-"admin@${DOMAIN}"}
fi

REVERSE_PROXY_URL="${REVERSE_PROXY_URL:-}"
if [[ -n "${MASK_MODE:-}" ]]; then
    case "${MASK_MODE,,}" in
        1|disk)  MASK_MODE="disk" ;;
        2|vapen) MASK_MODE="vapen" ;;
        proxy)
            if [[ ! "$REVERSE_PROXY_URL" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/.*)?$ ]]; then
                log_err "Для MASK_MODE=proxy укажите корректный REVERSE_PROXY_URL (например, https://example.org)."
            fi
            MASK_MODE="proxy"
            MASK_LABEL="Reverse Proxy → ${REVERSE_PROXY_URL}"
            ;;
        *) log_err "Некорректный MASK_MODE=${MASK_MODE} (допустимо: disk, vapen, proxy)." ;;
    esac
elif [[ "${NON_INTERACTIVE}" == "1" ]]; then
    MASK_MODE="disk"
else
    echo -e "\n3. Режим маскировки основного домена (${DOMAIN}):"
    printf "   ${BOLD}%-13s${NC} — %s\n" "[Enter] / 1" "«CloudDisk»: mock API и форма входа (рекомендуется)"
    printf "   ${BOLD}%-13s${NC} — %s\n" "2 / vapen"   "Портал облачного хранилища под вашим названием (S3: /s3, /api/v1/health)"
    printf "   ${BOLD}%-13s${NC} — %s\n" "[URL]"       "Reverse Proxy на другой сайт (например, https://example.org)"
    while true; do
        read -erp "   Ваш выбор [1]: " MASK_INPUT
        MASK_INPUT=$(echo "$MASK_INPUT" | tr -d '[:space:]')
        case "${MASK_INPUT,,}" in
            ""|1|disk)
                MASK_MODE="disk"
                break
                ;;
            2|vapen)
                MASK_MODE="vapen"
                break
                ;;
            http://*|https://*)
                if [[ "$MASK_INPUT" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/.*)?$ ]]; then
                    MASK_MODE="proxy"
                    REVERSE_PROXY_URL="$MASK_INPUT"
                    MASK_LABEL="Reverse Proxy → ${MASK_INPUT}"
                    break
                fi
                echo -e "   ${RED}Некорректный URL. Укажите адрес вида https://example.org${NC}"
                ;;
            *)
                echo -e "   ${RED}Неверный выбор. Введите 1, 2 или корректный URL (https://...).${NC}"
                ;;
        esac
    done
fi

COMPANY_NAME="${COMPANY_NAME:-}"; COMPANY_SLUG="STORAGE"
if [[ "$MASK_MODE" == "vapen" || "$MASK_MODE" == "disk" ]]; then
    COMPANY_RE='^[A-Za-z0-9][A-Za-z0-9 ._-]{1,31}$'
    DEFAULT_CO=$( [[ "$MASK_MODE" == "vapen" ]] && echo "VAPEN" || echo "CloudDisk" )
    if [[ -n "$COMPANY_NAME" ]]; then
        COMPANY_NAME=$(echo "$COMPANY_NAME" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed -E 's/[[:space:]]+[Cc]loud[[:space:]]+[Ss]torage$//')
        [[ ! "$COMPANY_NAME" =~ $COMPANY_RE ]] && log_err "COMPANY_NAME должен быть на английском (латиница, цифры, . _ -, 2..32 символа)."
    elif [[ "${NON_INTERACTIVE}" == "1" ]]; then
        COMPANY_NAME="${DEFAULT_CO}"
    else
        while true; do
            read -erp "   Название компании на английском (например, Nimbus Labs) [${DEFAULT_CO}]: " COMPANY_NAME
            COMPANY_NAME=$(echo "$COMPANY_NAME" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            COMPANY_NAME=$(echo "$COMPANY_NAME" | sed -E 's/[[:space:]]+[Cc]loud[[:space:]]+[Ss]torage$//')  # суффикс добавляется автоматически
            COMPANY_NAME=${COMPANY_NAME:-${DEFAULT_CO}}
            [[ "$COMPANY_NAME" =~ $COMPANY_RE ]] && break
            echo -e "   ${RED}Только английский (латиница), цифры, пробел и символы . _ - (от 2 до 32 символов).${NC}"
        done
    fi
    COMPANY_SLUG=$(echo "$COMPANY_NAME" | tr -cd 'A-Za-z0-9' | tr 'a-z' 'A-Z' | cut -c1-16)
    COMPANY_SLUG=${COMPANY_SLUG:-STORAGE}
    if [[ "$MASK_MODE" == "vapen" ]]; then
        MASK_LABEL="Локальный портал «${COMPANY_NAME} Cloud Storage»"
    else
        MASK_LABEL="Локальный сайт «${COMPANY_NAME}» (mock API)"
    fi
fi

# Генерация сложных случайных логина (12 симв.) и пароля (20 симв. со спецсимволами)
RAND_USER=$(python3 -c 'import secrets, string; alphabet = string.ascii_letters + string.digits; print("".join(secrets.choice(alphabet) for _ in range(12)))')
if [[ -z "${PANEL_USER:-}" ]]; then
    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        PANEL_USER="$RAND_USER"
    else
        read -erp "4. Логин администратора 3x-ui [${RAND_USER}]: " PANEL_USER
        PANEL_USER=${PANEL_USER:-"$RAND_USER"}
    fi
fi

RAND_PASS=$(python3 -c '
import secrets, string
upper, lower, digits, syms = string.ascii_uppercase, string.ascii_lowercase, string.digits, "!@#%^&*_-+="
alphabet = upper + lower + digits + syms
while True:
    pwd = "".join(secrets.choice(alphabet) for _ in range(20))
    if (any(c in upper for c in pwd) and any(c in lower for c in pwd)
        and any(c in digits for c in pwd) and any(c in syms for c in pwd)):
        print(pwd)
        break
')
if [[ -z "${PANEL_PASS:-}" ]]; then
    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        PANEL_PASS="$RAND_PASS"
    else
        read -erp "5. Пароль администратора 3x-ui [${RAND_PASS}]: " PANEL_PASS
        PANEL_PASS=${PANEL_PASS:-"$RAND_PASS"}
    fi
fi

if [[ -z "${ENABLE_SCANNERS_BLOCK:-}" ]]; then
    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        ENABLE_SCANNERS_BLOCK="Y"
    else
        echo -e "\n6. Блокировать IP/подсети сканеров и госструктур РФ (C24Be AS_Network_List + CyberOK Skipa) в nftables?"
        read -erp "   (Рекомендуется, сжатие CIDR + автообновление раз в сутки; также управляемо через my3xui) [Y/n]: " ENABLE_SCANNERS_BLOCK
        ENABLE_SCANNERS_BLOCK=${ENABLE_SCANNERS_BLOCK:-"Y"}
    fi
fi

PANEL_PORT=$(shuf -i 40000-48000 -n 1)
SUB_PORT=$(shuf -i 48001-56000 -n 1)
PANEL_PATH=$(openssl rand -hex 9)
SUB_PATH=$(openssl rand -hex 12)
XHTTP_UP_PATH="media/ts/$(openssl rand -hex 4)"
XHTTP_ONE_PATH="media/ts/1080/$(openssl rand -hex 4)"

# Надёжное определение порта SSH и IP текущей сессии администратора
mkdir -p /run/sshd
SSH_PORT=""
if command -v sshd >/dev/null 2>&1; then
    SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)
fi
if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=$(systemctl show ssh.socket -p Listen 2>/dev/null | grep -oE ':[0-9]+' | tr -d ':' | head -n 1 || true)
fi
if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=$(ss -tlnp 2>/dev/null | awk '/sshd|ssh\.socket/ {split($4,a,":"); print a[length(a)]; exit}' || true)
fi
SSH_PORT=${SSH_PORT:-22}
ACTIVE_SSH_PORT=$(awk '{print $4}' <<< "${SSH_CONNECTION:-}" 2>/dev/null || true)
ADMIN_SSH_IP=$(awk '{print $1}' <<< "${SSH_CONNECTION:-}" 2>/dev/null || true)

echo -e "\n${YELLOW}Сводка параметров перед установкой:${NC}"
echo "  • ОС:             Ubuntu 24.04 LTS"
echo "  • Домен:          ${DOMAIN}"
echo "  • Инбаунды:       XHTTP («Мобилы» + «Домашний») + TCP Reality Self-Steal («Reality») [без клиентов]"
echo "  • Роутинг Xray:   api->api + блокировка BitTorrent, Private IPs, Ads, Malware/Phishing"
echo "  • Маскировка:     ${MASK_LABEL}"
echo "  • Порт панели:    127.0.0.1:${PANEL_PORT} (путь /${PANEL_PATH}/)"
echo "  • Порт подписки:  127.0.0.1:${SUB_PORT} (путь /${SUB_PATH}/)"
echo "  • Логин панели:   ${PANEL_USER}"
echo "  • Безопасность:   UFW (SSH:${SSH_PORT}, 80, 443) + Fail2Ban + CrowdSec"
echo "  • Блок сканеров:  $([[ "$ENABLE_SCANNERS_BLOCK" =~ ^[Yy]$ ]] && echo 'C24Be + CyberOK Skipa (nftables)' || echo 'Отключено (доступно в my3xui)')"
echo "  • Лог установки:  ${LOG_FILE}"
echo "  • CLI-утилита:    my3xui (status, info, creds, crowdsec, blocklist, whitelist, backup, restore, inbounds, clean)"
echo ""
if [[ "${AUTO_CONFIRM}" != "1" ]]; then
    read -erp "Начать установку? [Y/n]: " START_CONFIRM
    [[ "$START_CONFIRM" =~ ^[Nn]$ ]] && exit 0
fi

LOG_STREAM_ACTIVE=1
exec > >(tee -a "${LOG_FILE}") 2>&1

# 3. Установка базовых пакетов и официального Nginx
log_info "Обновление пакетов и установка базовых утилит..."
export DEBIAN_FRONTEND=noninteractive
safe_apt_update
apt-get install -y -qq curl wget gnupg2 ca-certificates lsb-release ubuntu-keyring \
    sqlite3 python3 jq socat certbot ufw fail2ban nftables

log_info "Подключение официального репозитория nginx.org (Ubuntu 24.04 noble)..."
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg --yes
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
printf "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" > /etc/apt/preferences.d/99nginx
safe_apt_update
apt-get install -y -qq nginx

id -u www-data &>/dev/null || useradd -r -s /usr/sbin/nologin www-data

# 4. Применение системного тюнинга ядра (99-xray-custom.conf)
log_info "Применение сетевых оптимизаций sysctl (BBR, буферы, MTU probing)..."
cat <<'EOF' > /etc/sysctl.d/99-xray-custom.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
vm.swappiness = 10

net.ipv4.ip_local_port_range = 1024 65535
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_tw_buckets = 524288
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_slow_start_after_idle = 0

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 212992
net.core.wmem_default = 212992
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

vm.dirty_ratio = 6
vm.dirty_background_ratio = 3

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_mtu_probe_floor = 1024

fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
net.ipv4.tcp_notsent_lowat = 16384
EOF
sysctl --system >/dev/null 2>&1 || log_warn "Часть параметров sysctl пропущена (ограничения виртуализации)."

# 5. Настройка UFW
log_info "Настройка файрвола UFW (SSH: ${SSH_PORT}, HTTP: 80, HTTPS: 443)..."
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
if [[ -n "$ACTIVE_SSH_PORT" && "$ACTIVE_SSH_PORT" != "$SSH_PORT" ]]; then
    ufw allow "${ACTIVE_SSH_PORT}/tcp" comment 'SSH Active Session' >/dev/null
fi
ufw allow 80/tcp comment 'HTTP ACME' >/dev/null
ufw allow 443/tcp comment 'HTTPS Proxy' >/dev/null
ufw --force enable >/dev/null
log_ok "UFW активирован."

# 6. Выпуск SSL-сертификата Let's Encrypt и настройка webroot для автопродления без остановки Nginx
log_info "Получение SSL-сертификата для ${DOMAIN}..."
systemctl stop nginx >/dev/null 2>&1 || true
BUSY_PORTS=$(ss -tlnp 2>/dev/null | grep -E ':(80|443)[[:space:]]' || true)
if [[ -n "$BUSY_PORTS" ]]; then
    log_warn "Порты 80 или 443 заняты другим процессом:\n${BUSY_PORTS}"
    if systemctl is-active --quiet apache2 2>/dev/null; then
        if [[ "${NON_INTERACTIVE}" == "1" ]]; then
            STOP_APACHE="Y"
        else
            read -erp "Обнаружен работающий apache2. Остановить и отключить его? [Y/n]: " STOP_APACHE
            STOP_APACHE=${STOP_APACHE:-"Y"}
        fi
        if [[ "$STOP_APACHE" =~ ^[Yy]$ ]]; then
            systemctl disable --now apache2 >/dev/null 2>&1 || true
            log_ok "apache2 остановлен и отключён."
        fi
    else
        if [[ "${NON_INTERACTIVE}" == "1" ]]; then
            log_err "Порты 80/443 заняты другим процессом — автоматический выпуск SSL невозможен."
        fi
        read -erp "Certbot не сможет выпустить сертификат при занятом порте 80. Продолжить? [y/N]: " PORT_CONT
        [[ ! "$PORT_CONT" =~ ^[Yy]$ ]] && exit 1
    fi
fi
mkdir -p "/root/cert/${DOMAIN}" /var/www/html

if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    certbot certonly --standalone --non-interactive --agree-tos \
        --email "${LE_EMAIL}" -d "${DOMAIN}" --key-type ecdsa
else
    log_info "Сертификат для ${DOMAIN} уже существует, используем его."
fi

ln -sf "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "/root/cert/${DOMAIN}/fullchain.pem"
ln -sf "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "/root/cert/${DOMAIN}/privkey.pem"

# Перевод конфигурации продления certbot с standalone на webroot (/var/www/html), чтобы Nginx на 80 порту не мешал renew
RENEW_CONF="/etc/letsencrypt/renewal/${DOMAIN}.conf"
if [[ -f "$RENEW_CONF" ]]; then
    sed -i 's|^authenticator = standalone|authenticator = webroot|' "$RENEW_CONF"
    if ! grep -q '^webroot_path' "$RENEW_CONF"; then
        sed -i '/^authenticator = webroot/a webroot_path = /var/www/html,' "$RENEW_CONF"
    fi
    if ! grep -q '^\[\[webroot_map\]\]' "$RENEW_CONF"; then
        printf "\n[[webroot_map]]\n%s = /var/www/html\n" "${DOMAIN}" >> "$RENEW_CONF"
    fi
fi

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat <<'EOF' > /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh
#!/bin/bash
systemctl reload nginx
systemctl restart x-ui
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh

# 7. Подготовка сайта-заглушки («Облачный диск», «VAPEN Cloud Storage» или Reverse Proxy)
log_info "Настройка маскировочного сайта..."
mkdir -p /var/cache/nginx/img_cache /var/cache/nginx/html_cache /var/www/myfakesite /var/www/html /var/log/nginx
touch /var/log/nginx/access.log /var/log/nginx/error.log

if [[ "$MASK_MODE" == "disk" ]]; then
    log_info "Установка локального сайта-заглушки «${COMPANY_NAME}» (mock API, без Docker/PHP)..."
    cat <<'FS_HTML_EOF' > /var/www/myfakesite/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>@@DISK_COMPANY@@ — вход</title>
<link rel="icon" href="/favicon.svg">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<main>
  <div class="wrap">
    <section class="intro" aria-label="О сервисе">
      <div class="brand">
        <svg viewBox="0 0 64 64" aria-hidden="true"><path fill="var(--accent)" d="M18 50a13 13 0 0 1-1.5-25.9A17 17 0 0 1 49 27a11 11 0 0 1-1 23z"/><path fill="var(--surface)" d="M32 28l-8 9h5v8h6v-8h5z"/></svg>
        <span>@@DISK_COMPANY@@</span>
      </div>
      <h1>Ваши файлы всегда под рукой</h1>
      <p>Храните документы, фото и архивы в одном месте и делитесь ссылками с коллегами. Доступ только по приглашению.</p>
      <div class="files" aria-hidden="true">
        <div class="row"><i></i><b>Проекты</b><span>12 файлов</span></div>
        <div class="row"><i></i><b>Бухгалтерия</b><span class="lock">закрыто</span></div>
        <div class="row"><i class="f"></i><b>Договор_2026.pdf</b><span>2,4 МБ</span></div>
        <div class="row"><i class="f"></i><b>Резервная_копия.zip</b><span>148 МБ</span></div>
      </div>
    </section>

    <section class="panel" aria-labelledby="t">
      <h2 id="t">Вход в аккаунт</h2>
      <p class="sub">Введите данные, которые вам выдал администратор.</p>
      <form id="f" autocomplete="on" novalidate>
        <div class="field">
          <label for="u">Логин или email</label>
          <input id="u" name="username" type="text" autocomplete="username" autocapitalize="off" spellcheck="false" required>
        </div>
        <div class="field">
          <label for="p">Пароль</label>
          <div class="pw">
            <input id="p" name="password" type="password" autocomplete="current-password" required>
            <button type="button" id="show" aria-pressed="false">Показать</button>
          </div>
        </div>
        <div class="opts">
          <label><input type="checkbox" name="remember"> Запомнить меня</label>
          <a href="#" id="forgot">Забыли пароль?</a>
        </div>
        <button class="btn" id="go" type="submit">Войти</button>
        <p class="msg" id="msg" role="alert" aria-live="polite"></p>
      </form>
      <p class="alt">Нет аккаунта? Регистрация закрыта. Обратитесь к администратору вашего пространства.</p>
    </section>
  </div>
</main>
<footer>
  <a href="#" data-note="Политика конфиденциальности недоступна без входа.">Конфиденциальность</a>
  <a href="#" data-note="Условия использования доступны после входа в аккаунт.">Условия</a>
  <a href="#" data-note="Справка доступна после входа в аккаунт.">Помощь</a>
  <div class="ver"><span class="dot" id="dot"></span><span id="ver">Проверка сервиса…</span></div>
</footer>

<script src="/app.js" defer></script>
</body>
</html>
FS_HTML_EOF
    cat <<'FS_CSS_EOF' > /var/www/myfakesite/style.css
:root{
  --bg:#eef1ee; --surface:#ffffff; --ink:#18262b; --muted:#5d6b70; --line:#d5dcd8;
  --accent:#0f7b6c; --accent-ink:#ffffff; --danger:#b3261e; --field:#f7f9f7;
  --shadow:0 1px 2px rgba(24,38,43,.06),0 12px 32px rgba(24,38,43,.08);
}
:root:not([data-theme="light"]){}
@media (prefers-color-scheme:dark){
  :root:not([data-theme="light"]){
    --bg:#0f1a1c; --surface:#16252a; --ink:#e6eeec; --muted:#93a5a8; --line:#264047;
    --accent:#2fb59f; --accent-ink:#06201c; --danger:#ff8a80; --field:#102024;
    --shadow:0 1px 2px rgba(0,0,0,.3),0 12px 32px rgba(0,0,0,.35);
  }
}
:root[data-theme="dark"]{
  --bg:#0f1a1c; --surface:#16252a; --ink:#e6eeec; --muted:#93a5a8; --line:#264047;
  --accent:#2fb59f; --accent-ink:#06201c; --danger:#ff8a80; --field:#102024;
  --shadow:0 1px 2px rgba(0,0,0,.3),0 12px 32px rgba(0,0,0,.35);
}
*{box-sizing:border-box}
html,body{height:100%}
body{
  margin:0; background:var(--bg); color:var(--ink);
  font:16px/1.5 "Segoe UI",system-ui,-apple-system,"Helvetica Neue",Roboto,Arial,sans-serif;
  display:flex; flex-direction:column; min-height:100vh;
  background-image:
    radial-gradient(60rem 30rem at 85% -10%,color-mix(in srgb,var(--accent) 14%,transparent),transparent 70%),
    radial-gradient(40rem 24rem at -10% 110%,color-mix(in srgb,var(--accent) 10%,transparent),transparent 70%);
}
main{flex:1; display:grid; place-items:center; padding:32px 20px}
.wrap{width:100%; max-width:880px; display:grid; grid-template-columns:1.05fr 1fr; background:var(--surface); border:1px solid var(--line); border-radius:14px; box-shadow:var(--shadow); overflow:hidden}
.intro{padding:40px 36px; border-right:1px solid var(--line); display:flex; flex-direction:column; gap:28px; background:var(--field)}
.brand{display:flex; align-items:center; gap:12px; font-weight:650; font-size:1.2rem; letter-spacing:.1px}
.brand svg{width:34px; height:34px; flex:none}
.intro h1{font-size:1.55rem; line-height:1.25; margin:0; font-weight:650; max-width:18ch}
.intro p{margin:0; color:var(--muted); max-width:38ch}
.files{margin-top:auto; border:1px solid var(--line); border-radius:10px; background:var(--surface); padding:6px 0; font-size:.9rem}
.row{display:flex; align-items:center; gap:10px; padding:8px 14px; color:var(--muted)}
.row b{color:var(--ink); font-weight:500; flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis}
.row i{width:16px; height:12px; border-radius:2px; background:color-mix(in srgb,var(--accent) 55%,var(--surface)); flex:none}
.row i.f{height:16px; width:12px; background:var(--line)}
.row .lock{font-size:.78rem}
.panel{padding:40px 36px; display:flex; flex-direction:column; justify-content:center}
.panel h2{margin:0 0 4px; font-size:1.3rem; font-weight:650}
.panel .sub{margin:0 0 24px; color:var(--muted); font-size:.95rem}
label{display:block; font-size:.88rem; font-weight:600; margin:0 0 6px}
.field{margin-bottom:16px}
input[type=text],input[type=password]{
  width:100%; padding:11px 12px; font:inherit; color:var(--ink); background:var(--field);
  border:1px solid var(--line); border-radius:8px; transition:border-color .15s, box-shadow .15s;
}
input:focus{outline:none; border-color:var(--accent); box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 25%,transparent)}
.pw{position:relative}
.pw button{position:absolute; right:6px; top:50%; transform:translateY(-50%); background:none; border:0; color:var(--muted); font:inherit; font-size:.82rem; padding:6px 8px; cursor:pointer; border-radius:6px}
.pw button:hover{color:var(--ink)}
.opts{display:flex; justify-content:space-between; align-items:center; margin:2px 0 20px; font-size:.9rem}
.opts label{display:flex; align-items:center; gap:8px; font-weight:400; margin:0; cursor:pointer}
.opts input{accent-color:var(--accent); width:16px; height:16px; margin:0}
a{color:var(--accent); text-decoration:none}
a:hover{text-decoration:underline}
:where(a,button,input):focus-visible{outline:2px solid var(--accent); outline-offset:2px}
.btn{width:100%; padding:12px 16px; font:inherit; font-weight:600; border:0; border-radius:8px; background:var(--accent); color:var(--accent-ink); cursor:pointer; transition:filter .15s}
.btn:hover{filter:brightness(1.08)}
.btn[disabled]{opacity:.7; cursor:progress}
.msg{min-height:1.4em; margin:14px 0 0; font-size:.9rem; color:var(--danger)}
.msg.info{color:var(--muted)}
.alt{margin-top:22px; padding-top:18px; border-top:1px solid var(--line); font-size:.9rem; color:var(--muted)}
footer{padding:18px 20px 26px; text-align:center; font-size:.82rem; color:var(--muted)}
footer a{color:var(--muted); margin:0 8px}
@media (max-width:760px){
  .wrap{grid-template-columns:1fr}
  .intro{border-right:0; border-bottom:1px solid var(--line); padding:28px 24px; gap:18px}
  .files{display:none}
  .panel{padding:28px 24px}
}
@media (prefers-reduced-motion:reduce){*{transition:none!important}}
.ver{margin-top:8px;display:flex;justify-content:center;align-items:center;gap:6px}
.dot{width:8px;height:8px;border-radius:50%;background:var(--line)}
.dot.ok{background:var(--accent)}
.dot.err{background:var(--danger)}
FS_CSS_EOF
    cat <<'FS_JS_EOF' > /var/www/myfakesite/app.js
(function () {
  var f = document.getElementById('f'), u = document.getElementById('u'), p = document.getElementById('p'),
      msg = document.getElementById('msg'), go = document.getElementById('go'), show = document.getElementById('show'),
      ver = document.getElementById('ver'), dot = document.getElementById('dot'),
      remember = f.querySelector('[name=remember]');

  function say(t, info) { msg.textContent = t; msg.className = 'msg' + (info ? ' info' : ''); }

  show.addEventListener('click', function () {
    var hidden = p.type === 'password';
    p.type = hidden ? 'text' : 'password';
    show.textContent = hidden ? 'Скрыть' : 'Показать';
    show.setAttribute('aria-pressed', String(hidden));
  });

  // Проверка доступности сервиса: GET /api/status
  fetch('/api/status', { cache: 'no-store' })
    .then(function (r) { if (!r.ok) throw 0; return r.json(); })
    .then(function (d) { ver.textContent = 'Версия ' + d.version + ' · сервис доступен'; dot.className = 'dot ok'; })
    .catch(function () { ver.textContent = 'Сервис недоступен'; dot.className = 'dot err'; });

  // Вход: POST /api/auth (401 — неверные данные, 429 — слишком много попыток)
  f.addEventListener('submit', function (e) {
    e.preventDefault();
    if (!u.value.trim() || !p.value) { say('Введите логин и пароль.'); (u.value.trim() ? p : u).focus(); return; }
    go.disabled = true; go.textContent = 'Проверяем…'; say('');
    fetch('/api/auth', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({ username: u.value.trim(), password: p.value, remember: !!(remember && remember.checked) })
    }).then(function (r) {
      if (r.status === 429) say('Слишком много попыток входа. Повторите через минуту.');
      else if (r.status === 401) say('Неверный логин или пароль. Проверьте данные и попробуйте снова.');
      else say('Сервис временно недоступен. Повторите попытку позже.');
    }).catch(function () {
      say('Нет соединения с сервером. Проверьте интернет и повторите попытку.');
    }).then(function () {
      go.disabled = false; go.textContent = 'Войти'; p.value = ''; p.focus();
    });
  });

  document.getElementById('forgot').addEventListener('click', function (e) {
    e.preventDefault(); say('Восстановление пароля выполняет администратор вашего пространства.', true);
  });
  Array.prototype.forEach.call(document.querySelectorAll('[data-note]'), function (a) {
    a.addEventListener('click', function (e) { e.preventDefault(); say(a.getAttribute('data-note'), true); });
  });
})();
FS_JS_EOF

    sed -i "s|@@DISK_COMPANY@@|${COMPANY_NAME}|g" /var/www/myfakesite/index.html

    # Генерируем favicon.svg с первой буквой названия компании (как в VAPEN-режиме)
    FAVICON_LETTER="${COMPANY_NAME:0:1}"
    cat > /var/www/myfakesite/favicon.svg <<FAVEOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="100" height="100" rx="20" fill="#0f7b6c"/>
  <text x="50" y="68" font-size="62" font-family="system-ui,sans-serif" font-weight="700"
        text-anchor="middle" fill="#ffffff">${FAVICON_LETTER}</text>
</svg>
FAVEOF

    MASK_LOCATION_BLOCK=$(cat <<'EOF'
        location = /favicon.svg {
            root /var/www/myfakesite;
            access_log off;
            expires 7d;
            add_header Cache-Control "public, immutable" always;
        }

        # Mock API «облачного диска» (ответы отдаёт сам nginx)
        location = /api/status {
            default_type application/json;
            expires -1;
            return 200 '{"ok":true,"service":"storage","version":"3.2.1"}';
        }
        location = /api/files {
            default_type application/json;
            return 401 '{"ok":false,"error":"unauthorized"}';
        }
        location = /api/settings {
            default_type application/json;
            return 401 '{"ok":false,"error":"unauthorized"}';
        }
        # Вход: limit_req срабатывает раньше try_files, поэтому 401 отдаёт именованный location
        # (return прямо в location выполняется до limit_req и лимит бы не работал)
        location = /api/auth {
            default_type application/json;
            root /var/www/myfakesite;
            if ($request_method != POST) { return 405 '{"ok":false,"error":"method_not_allowed"}'; }
            limit_req zone=fs_auth burst=3 nodelay;
            error_page 429 = @fs_too_many;
            try_files /__none @fs_auth_fail;
        }
        location @fs_auth_fail {
            default_type application/json;
            return 401 '{"ok":false,"error":"invalid_credentials"}';
        }
        location @fs_too_many {
            default_type application/json;
            add_header Retry-After 60 always;
            return 429 '{"ok":false,"error":"too_many_requests"}';
        }
        location ^~ /api/ {
            default_type application/json;
            return 404 '{"ok":false,"error":"not_found"}';
        }
        location / {
            limit_req zone=bot burst=20 nodelay;
            limit_conn addr 20;
            root /var/www/myfakesite;
            index index.html;
            try_files $uri $uri/ /index.html;
        }
EOF
)
elif [[ "$MASK_MODE" == "vapen" ]]; then
    log_info "Установка локального портала «${COMPANY_NAME} Cloud Storage» (S3-эмуляция, без Docker/PHP)..."
    cat <<'FS_VAPEN_INDEX_EOF' > /var/www/myfakesite/index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="description" content="@@COMPANY@@ Cloud Storage — Enterprise S3-Compatible Object Storage, Distributed NVMe Clusters, and Global Edge Content Delivery.">
  <meta name="keywords" content="@@COMPANY@@ Cloud Storage, S3 Object Storage, NVMe Cloud, Distributed Storage, Zero-Knowledge Encryption, Edge CDN">
  <meta name="robots" content="noindex, nofollow">
  <meta property="og:title" content="@@COMPANY@@ Cloud Storage | Enterprise Object Storage & Edge Network">
  <meta property="og:description" content="High-throughput S3-compatible NVMe object storage with immutable backups and global Anycast replication.">
  <meta property="og:type" content="website">
  <title>@@COMPANY@@ Cloud Storage | Enterprise NVMe Object Storage & Edge Telemetry</title>
  <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>☁️</text></svg>">
  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@type": "Organization",
    "name": "@@COMPANY@@ Cloud Storage",
    "description": "Enterprise S3 Object Storage and Distributed Edge Infrastructure",
    "url": "https://vapen-storage.internal"
  }
  </script>
  <style>
    :root {
      --bg-main: #060911;
      --bg-card: #0f1626;
      --bg-card-hover: #151f36;
      --border: #1e293b;
      --text-main: #f8fafc;
      --text-muted: #94a3b8;
      --accent: #3b82f6;
      --accent-glow: rgba(59, 130, 246, 0.25);
      --success: #10b981;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background-color: var(--bg-main);
      color: var(--text-main);
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      line-height: 1.6;
    }
    header {
      border-bottom: 1px solid var(--border);
      background: rgba(6, 9, 17, 0.85);
      backdrop-filter: blur(10px);
      position: sticky;
      top: 0;
      z-index: 100;
    }
    .container { max-width: 1200px; margin: 0 auto; padding: 0 1.5rem; }
    .nav-bar { display: flex; justify-content: space-between; align-items: center; height: 70px; }
    .logo { font-weight: 700; font-size: 1.25rem; display: flex; align-items: center; gap: 10px; color: var(--text-main); text-decoration: none; letter-spacing: 0.02em; }
    .logo-badge { background: var(--accent); color: #fff; font-size: 0.7rem; padding: 2px 7px; border-radius: 4px; text-transform: uppercase; }
    nav ul { display: flex; list-style: none; gap: 2rem; }
    nav a { color: var(--text-muted); text-decoration: none; font-size: 0.95rem; transition: color 0.2s; }
    nav a:hover { color: var(--text-main); }
    .nav-actions { display: flex; align-items: center; gap: 1rem; }
    .btn { padding: 0.5rem 1.1rem; border-radius: 6px; font-size: 0.9rem; font-weight: 500; cursor: pointer; border: 1px solid transparent; transition: all 0.2s; text-decoration: none; }
    .btn-outline { border-color: var(--border); background: transparent; color: var(--text-main); }
    .btn-outline:hover { background: var(--bg-card); }
    .btn-primary { background: var(--accent); color: #fff; box-shadow: 0 0 15px var(--accent-glow); }
    .btn-primary:hover { background: #2563eb; }
    .hero { padding: 4.5rem 0 3rem; border-bottom: 1px solid var(--border); background: radial-gradient(circle at 50% 0%, #111d38 0%, var(--bg-main) 70%); }
    .hero-grid { display: grid; grid-template-columns: 1.2fr 0.8fr; gap: 3rem; align-items: center; }
    .status-pill { display: inline-flex; align-items: center; gap: 10px; background: rgba(16, 185, 129, 0.1); border: 1px solid rgba(16, 185, 129, 0.3); padding: 6px 14px; border-radius: 999px; font-size: 0.85rem; color: #34d399; margin-bottom: 1.5rem; }
    .dot { width: 9px; height: 9px; background-color: var(--success); border-radius: 50%; display: inline-block; animation: pulse 2s infinite; }
    @keyframes pulse {
      0% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7); }
      70% { transform: scale(1); box-shadow: 0 0 0 8px rgba(16, 185, 129, 0); }
      100% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0); }
    }
    h1 { font-size: 2.75rem; line-height: 1.2; margin-bottom: 1.25rem; letter-spacing: -0.02em; }
    .hero p { color: var(--text-muted); font-size: 1.1rem; margin-bottom: 2rem; max-width: 580px; }
    .telemetry-card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 1.5rem; box-shadow: 0 20px 40px rgba(0,0,0,0.4); }
    .telemetry-header { display: flex; justify-content: space-between; align-items: center; padding-bottom: 1rem; border-bottom: 1px solid var(--border); margin-bottom: 1rem; font-size: 0.9rem; }
    .metric-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 1rem; margin-bottom: 1rem; }
    .metric-box { background: rgba(255,255,255,0.02); border: 1px solid var(--border); padding: 0.85rem; border-radius: 8px; }
    .metric-label { font-size: 0.75rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.05em; }
    .metric-val { font-size: 1.35rem; font-weight: 700; font-family: monospace; color: var(--text-main); margin-top: 4px; }
    .clock-bar { font-family: monospace; font-size: 0.82rem; color: var(--text-muted); display: flex; justify-content: space-between; padding-top: 0.75rem; border-top: 1px solid var(--border); }
    .section { padding: 4rem 0; border-bottom: 1px solid var(--border); }
    .section-title { font-size: 1.75rem; margin-bottom: 0.5rem; }
    .section-sub { color: var(--text-muted); margin-bottom: 2rem; }
    .table-wrap { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; overflow: hidden; }
    table { width: 100%; border-collapse: collapse; text-align: left; font-size: 0.92rem; }
    th, td { padding: 1rem 1.25rem; border-bottom: 1px solid var(--border); }
    th { background: rgba(255,255,255,0.02); color: var(--text-muted); font-weight: 600; font-size: 0.8rem; text-transform: uppercase; }
    tr:last-child td { border-bottom: none; }
    .badge-ok { background: rgba(16, 185, 129, 0.15); color: #34d399; padding: 3px 8px; border-radius: 4px; font-size: 0.78rem; font-family: monospace; }
    .grid-3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1.5rem; }
    .card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 10px; padding: 1.5rem; transition: background 0.2s; }
    .card:hover { background: var(--bg-card-hover); }
    .card h3 { font-size: 1.15rem; margin-bottom: 0.6rem; }
    .card p { color: var(--text-muted); font-size: 0.9rem; }
    .calc-box { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 2rem; margin-top: 2rem; display: flex; justify-content: space-between; align-items: center; gap: 2rem; }
    input[type="range"] { width: 100%; accent-color: var(--accent); margin-top: 0.75rem; }
    .modal-backdrop { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.75); z-index: 200; align-items: center; justify-content: center; }
    .modal { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; width: 100%; max-width: 400px; padding: 2rem; }
    .modal input { width: 100%; padding: 0.65rem; margin: 0.5rem 0 1rem; background: var(--bg-main); border: 1px solid var(--border); color: #fff; border-radius: 6px; }
    footer { padding: 3rem 0; color: var(--text-muted); font-size: 0.85rem; }
    .footer-grid { display: grid; grid-template-columns: 2fr 1fr 1fr 1fr; gap: 2rem; margin-bottom: 2rem; }
    .footer-col h4 { color: var(--text-main); margin-bottom: 0.75rem; font-size: 0.95rem; }
    .footer-col ul { list-style: none; }
    .footer-col li { margin-bottom: 0.4rem; }
    .footer-col a { color: var(--text-muted); text-decoration: none; }
    @media (max-width: 768px) {
      .hero-grid, .grid-3, .footer-grid, .calc-box { grid-template-columns: 1fr; flex-direction: column; }
      nav ul { display: none; }
    }
  </style>
</head>
<body>
<header>
  <div class="container nav-bar">
    <a href="#" class="logo">☁️ @@COMPANY@@ Cloud Storage <span class="logo-badge">S3 Edge v4.2</span></a>
    <nav>
      <ul>
        <li><a href="#network">Storage Clusters</a></li>
        <li><a href="#products">Architecture</a></li>
        <li><a href="#calculator">Volume Pricing</a></li>
        <li><a href="/api/v1/health" target="_blank">API Health</a></li>
        <li><a href="#docs" onclick="openModal(); return false;">S3 API Docs</a></li>
      </ul>
    </nav>
    <div class="nav-actions">
      <button class="btn btn-outline" onclick="openModal()">Tenant SSO</button>
      <button class="btn btn-primary" onclick="openModal()">Storage Console</button>
    </div>
  </div>
</header>
<section class="hero">
  <div class="container hero-grid">
    <div>
      <div class="status-pill">
        <span class="dot"></span>
        <span>All NVMe Object Clusters Operational • TLS 1.3 Enforced</span>
      </div>
      <h1>High-Throughput S3 Object Storage & Edge Fabric</h1>
      <p>Deploy immutable enterprise backups, zero-egress distributed buckets, and low-latency edge caching with 99.999999999% (11 9s) data durability across global availability zones.</p>
      <div style="display: flex; gap: 1rem;">
        <a href="#network" class="btn btn-primary">Cluster Telemetry</a>
        <a href="#calculator" class="btn btn-outline">Estimate Storage Cost</a>
      </div>
    </div>
    <div class="telemetry-card">
      <div class="telemetry-header">
        <strong>⚡ Local Storage Node Telemetry</strong>
        <span class="badge-ok">S3 / HTTP3 QUIC</span>
      </div>
      <div class="metric-grid">
        <div class="metric-box">
          <div class="metric-label">Cluster Egress</div>
          <div class="metric-val" id="m-bw">44.2 Gbps</div>
        </div>
        <div class="metric-box">
          <div class="metric-label">S3 PUT/GET IOPS</div>
          <div class="metric-val" id="m-req">24,810 ops</div>
        </div>
        <div class="metric-box">
          <div class="metric-label">NVMe Pool Load</div>
          <div class="metric-val" id="m-cpu">16.4%</div>
        </div>
        <div class="metric-box">
          <div class="metric-label">Time to First Byte</div>
          <div class="metric-val" id="m-ping">1.9 ms</div>
        </div>
      </div>
      <div class="clock-bar">
        <span id="clock">Syncing NTP...</span>
        <span id="ray-id">NodeID: initializing...</span>
      </div>
    </div>
  </div>
</section>
<section id="network" class="section">
  <div class="container">
    <h2 class="section-title">Multi-Region Replication Status</h2>
    <p class="section-sub">Real-time erasure coding health and backbone synchronization across primary Tier-4 @@COMPANY@@ storage vaults.</p>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Vault ID</th>
            <th>Availability Zone</th>
            <th>Replication Mode</th>
            <th>NVMe Latency</th>
            <th>Cluster State</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><strong>VLT-FRA-01</strong></td>
            <td>Frankfurt, DE (EU-Central)</td>
            <td>S3 Multi-AZ / AES-256-GCM</td>
            <td>1.8 ms</td>
            <td><span class="badge-ok">200 OK • Synced</span></td>
          </tr>
          <tr>
            <td><strong>VLT-AMS-04</strong></td>
            <td>Amsterdam, NL (EU-West)</td>
            <td>S3 Multi-AZ / AES-256-GCM</td>
            <td>2.9 ms</td>
            <td><span class="badge-ok">200 OK • Synced</span></td>
          </tr>
          <tr>
            <td><strong>VLT-HEL-02</strong></td>
            <td>Helsinki, FI (Nordic-Core)</td>
            <td>S3 Multi-AZ / AES-256-GCM</td>
            <td>4.6 ms</td>
            <td><span class="badge-ok">200 OK • Synced</span></td>
          </tr>
          <tr>
            <td><strong>VLT-IAD-09</strong></td>
            <td>Ashburn, US (US-East)</td>
            <td>S3 Cross-Region / Async</td>
            <td>17.4 ms</td>
            <td><span class="badge-ok">200 OK • Synced</span></td>
          </tr>
          <tr>
            <td><strong>VLT-SIN-03</strong></td>
            <td>Singapore (APAC-Hub)</td>
            <td>S3 Cross-Region / Async</td>
            <td>29.8 ms</td>
            <td><span class="badge-ok">200 OK • Synced</span></td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</section>
<section id="products" class="section">
  <div class="container">
    <h2 class="section-title">@@COMPANY@@ Enterprise Storage Stack</h2>
    <p class="section-sub">Engineered for AI dataset training, Kubernetes persistent volumes, and immutable archival.</p>
    <div class="grid-3">
      <div class="card">
        <h3>🗄️ 100% S3-Compatible API</h3>
        <p>Drop-in replacement for AWS S3. Native support for Terraform, rclone, Veeam, and Kubernetes CSI drivers with zero code changes.</p>
      </div>
      <div class="card">
        <h3>⚡ All-NVMe Erasure Coding</h3>
        <p>Distributed Reed-Solomon parity across independent fault domains guarantees instant recovery without degraded read performance.</p>
      </div>
      <div class="card">
        <h3>🔒 Object Lock & Zero-Trust</h3>
        <p>WORM (Write-Once-Read-Many) ransomware protection, client-side KMS encryption keys, and hardware mTLS bucket policies.</p>
      </div>
    </div>
    <div id="calculator" class="calc-box">
      <div style="flex: 1;">
        <h3>Enterprise Storage Volume Estimator</h3>
        <p style="color: var(--text-muted); font-size: 0.9rem;">Slide to calculate monthly flat-rate provisioning for dedicated NVMe object storage (zero egress fees).</p>
        <input type="range" id="bw-slider" min="10" max="1000" step="10" value="150" oninput="updateCalc(this.value)">
      </div>
      <div style="text-align: right; min-width: 240px;">
        <div class="metric-label">Reserved Capacity</div>
        <div class="metric-val" id="calc-out" style="color: var(--accent);">150 TB / $1,050 mo</div>
      </div>
    </div>
  </div>
</section>
<footer>
  <div class="container">
    <div class="footer-grid">
      <div class="footer-col">
        <h4>☁️ @@COMPANY@@ Cloud Storage</h4>
        <p>Enterprise distributed NVMe object storage, S3 edge caching, and encrypted archival infrastructure. ISO/IEC 27001 & SOC2 Type II Certified.</p>
      </div>
      <div class="footer-col">
        <h4>Infrastructure</h4>
        <ul>
          <li><a href="#network">S3 Object Storage</a></li>
          <li><a href="#products">NVMe Block Volumes</a></li>
          <li><a href="/api/v1/health" target="_blank">Node Health API</a></li>
        </ul>
      </div>
      <div class="footer-col">
        <h4>Compliance</h4>
        <ul>
          <li><a href="#" onclick="openModal(); return false;">GDPR Data Processing</a></li>
          <li><a href="#" onclick="openModal(); return false;">99.999% SLA Policy</a></li>
          <li><a href="#" onclick="openModal(); return false;">Security Whitepaper</a></li>
        </ul>
      </div>
      <div class="footer-col">
        <h4>Network</h4>
        <ul>
          <li>NOC: 24/7/365 Active</li>
          <li>AS-Number: AS398102</li>
          <li>S3 Endpoint: Active</li>
        </ul>
      </div>
    </div>
    <div style="border-top: 1px solid var(--border); padding-top: 1.5rem; display: flex; justify-content: space-between;">
      <span>© 2026 @@COMPANY@@ Cloud Storage. All rights reserved.</span>
      <span>TLS 1.3 End-to-End Encrypted Session</span>
    </div>
  </div>
</footer>
<div class="modal-backdrop" id="auth-modal">
  <div class="modal">
    <h3 style="margin-bottom: 0.5rem;">@@COMPANY@@ Storage Console</h3>
    <p style="color: var(--text-muted); font-size: 0.85rem; margin-bottom: 1rem;">Sign in with your Tenant Access Key or Corporate SAML 2.0 SSO.</p>
    <form onsubmit="handleAuth(event)">
      <label style="font-size: 0.8rem; color: var(--text-muted);">Tenant ID / Corporate Email</label>
      <input type="email" required placeholder="admin@tenant-storage.io">
      <label style="font-size: 0.8rem; color: var(--text-muted);">Secret Access Key / YubiKey OTP</label>
      <input type="password" required placeholder="••••••••••••••••">
      <p id="auth-err" style="color: #f87171; font-size: 0.8rem; display: none; margin-bottom: 0.75rem;">Error 403 (AccessDenied): Client IP is not authorized in this bucket's VPC policy.</p>
      <div style="display: flex; justify-content: flex-end; gap: 0.5rem;">
        <button type="button" class="btn btn-outline" onclick="closeModal()">Cancel</button>
        <button type="submit" class="btn btn-primary">Authenticate</button>
      </div>
    </form>
  </div>
</div>
<script>
  const rayHex = Array.from({length: 16}, () => Math.floor(Math.random()*16).toString(16)).join('');
  document.getElementById('ray-id').textContent = 'ReqID: ' + rayHex.toUpperCase();
  function updateClock() {
    const now = new Date();
    document.getElementById('clock').textContent = now.toISOString().replace('T', ' ').substring(0, 19) + ' UTC';
  }
  setInterval(updateClock, 1000);
  updateClock();
  setInterval(() => {
    const bw = (42 + Math.random() * 4.5).toFixed(1);
    const req = Math.floor(24100 + Math.random() * 1800).toLocaleString();
    const cpu = (14 + Math.random() * 5).toFixed(1);
    const ping = (1.7 + Math.random() * 0.4).toFixed(1);
    document.getElementById('m-bw').textContent = bw + ' Gbps';
    document.getElementById('m-req').textContent = req + ' ops';
    document.getElementById('m-cpu').textContent = cpu + '%';
    document.getElementById('m-ping').textContent = ping + ' ms';
  }, 2500);
  function updateCalc(val) {
    const price = (val * 7).toLocaleString();
    document.getElementById('calc-out').textContent = val + ' TB / $' + price + ' mo';
  }
  function openModal() {
    document.getElementById('auth-err').style.display = 'none';
    document.getElementById('auth-modal').style.display = 'flex';
  }
  function closeModal() {
    document.getElementById('auth-modal').style.display = 'none';
  }
  function handleAuth(e) {
    e.preventDefault();
    document.getElementById('auth-err').style.display = 'block';
  }
</script>
</body>
</html>
FS_VAPEN_INDEX_EOF
    cat <<'FS_VAPEN_ERR_EOF' > /var/www/myfakesite/error.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="robots" content="noindex, nofollow">
  <title>@@COMPANY@@ Cloud Storage | S3 Gateway Security Exception</title>
  <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🛡️</text></svg>">
  <style>
    :root {
      --bg-main: #060911;
      --bg-card: #0f1626;
      --border: #1e293b;
      --text-main: #f8fafc;
      --text-muted: #94a3b8;
      --accent: #3b82f6;
      --warn: #f59e0b;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background-color: var(--bg-main);
      color: var(--text-main);
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      background-image: radial-gradient(circle at 50% 0%, #17152b 0%, var(--bg-main) 65%);
    }
    header { border-bottom: 1px solid var(--border); padding: 1.2rem 2rem; display: flex; justify-content: space-between; align-items: center; }
    .logo { font-weight: 700; font-size: 1.15rem; color: var(--text-main); text-decoration: none; display: flex; align-items: center; gap: 8px; }
    .badge { background: rgba(245, 158, 11, 0.15); border: 1px solid rgba(245, 158, 11, 0.4); color: var(--warn); font-size: 0.75rem; padding: 3px 10px; border-radius: 999px; font-family: monospace; }
    main { max-width: 680px; width: 100%; margin: 3rem auto; padding: 0 1.5rem; }
    .waf-card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 2.25rem; box-shadow: 0 20px 45px rgba(0,0,0,0.5); }
    .code-row { display: flex; align-items: center; gap: 12px; margin-bottom: 1rem; }
    .status-dot { width: 12px; height: 12px; border-radius: 50%; background: var(--warn); box-shadow: 0 0 12px var(--warn); }
    h1 { font-size: 1.65rem; letter-spacing: -0.01em; }
    p.desc { color: var(--text-muted); font-size: 0.95rem; line-height: 1.6; margin-bottom: 1.5rem; }
    .diag-box { background: #090d16; border: 1px solid var(--border); border-radius: 8px; padding: 1.1rem; font-family: monospace; font-size: 0.82rem; color: #cbd5e1; margin-bottom: 1.5rem; line-height: 1.7; overflow-x: auto; }
    .diag-key { color: var(--text-muted); display: inline-block; width: 160px; }
    .actions { display: flex; gap: 1rem; align-items: center; }
    .btn { padding: 0.6rem 1.25rem; border-radius: 6px; font-size: 0.9rem; font-weight: 500; text-decoration: none; transition: all 0.2s; }
    .btn-primary { background: var(--accent); color: #fff; }
    .btn-primary:hover { background: #2563eb; }
    .btn-outline { border: 1px solid var(--border); color: var(--text-muted); }
    .btn-outline:hover { color: var(--text-main); background: rgba(255,255,255,0.03); }
    footer { border-top: 1px solid var(--border); padding: 1.25rem 2rem; text-align: center; color: var(--text-muted); font-size: 0.8rem; }
  </style>
</head>
<body>
<header>
  <a href="/" class="logo">☁️ @@COMPANY@@ Cloud Storage <span style="color: var(--text-muted); font-weight: 400;">| S3 WAF</span></a>
  <span class="badge">ERR_CODE: NoSuchBucketOrPolicy</span>
</header>
<main>
  <div class="waf-card">
    <div class="code-row">
      <span class="status-dot"></span>
      <h1>S3 Bucket Route Restricted / Unmapped URI</h1>
    </div>
    <p class="desc">
      The requested object key or endpoint does not exist on this storage gateway, or your request lacks a valid AWS4-HMAC-SHA256 authorization signature.
    </p>
    <div class="diag-box">
      <div><span class="diag-key">Gateway Status:</span> <span style="color: #f87171;">403 / 404 Filtered by S3 Object Policy</span></div>
      <div><span class="diag-key">Requested Object:</span> <span id="req-path">/</span></div>
      <div><span class="diag-key">WAF Action:</span> <span>DENY_UNSIGNED_S3_REQUEST</span></div>
      <div><span class="diag-key">@@COMPANY@@ Trace ID:</span> <span id="trace-id">generating...</span></div>
      <div><span class="diag-key">Timestamp (UTC):</span> <span id="ts">syncing...</span></div>
    </div>
    <div class="actions">
      <a href="/" class="btn btn-primary">← Return to Storage Portal</a>
      <a href="/" class="btn btn-outline">Check Cluster Status</a>
    </div>
  </div>
</main>
<footer>
  Protected by @@COMPANY@@ Cloud Storage Autonomous WAF • TLS 1.3 Strict Enforcement • AS398102
</footer>
<script>
  document.getElementById('req-path').textContent = window.location.pathname;
  const trace = Array.from({length: 20}, () => Math.floor(Math.random()*16).toString(16)).join('').toUpperCase();
  document.getElementById('trace-id').textContent = 'VLT-' + trace.slice(0,8) + '-' + trace.slice(8,16);
  document.getElementById('ts').textContent = new Date().toISOString();
</script>
</body>
</html>
FS_VAPEN_ERR_EOF
    sed -i "s|https://vapen-storage.internal|https://${DOMAIN}|g" /var/www/myfakesite/index.html
    sed -i "s|@@COMPANY@@|${COMPANY_NAME}|g" /var/www/myfakesite/index.html /var/www/myfakesite/error.html

    MASK_LOCATION_BLOCK=$(cat <<'EOF'
        # Эмуляция S3 Object Storage API: AccessDenied в XML (Resource собирается только из безопасных символов)
        location ~ ^/(?:s3|buckets)(?<s3path>/[A-Za-z0-9._~/-]*)?$ {
            default_type application/xml;
            limit_req zone=bot burst=20 nodelay;
            add_header x-amz-request-id $request_id always;
            add_header x-amz-id-2 "MzRISOwyjmnup+$request_id/s3-eu-central-1" always;
            add_header x-amz-bucket-region "eu-central-1" always;
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
            add_header X-Content-Type-Options "nosniff" always;
            return 403 '<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>AccessDenied</Code>
  <Message>Access Denied. Unsigned request or missing AWS4-HMAC-SHA256 authorization header.</Message>
  <Resource>/s3$s3path</Resource>
  <RequestId>$request_id</RequestId>
  <HostId>MzRISOwyjmnup+$request_id/@@SLUG@@-S3-FRA01</HostId>
</Error>
';
        }

        # Эмуляция JSON-эндпоинта статуса узла
        location = /api/v1/health {
            default_type application/json;
            limit_req zone=bot burst=20 nodelay;
            add_header Cache-Control "no-store, no-cache, must-revalidate" always;
            add_header X-Request-ID $request_id always;
            add_header X-S3-Storage-Node "VLT-FRA-01" always;
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
            add_header X-Content-Type-Options "nosniff" always;
            return 200 '{"status":"healthy","service":"@@COMPANY@@ Cloud Storage S3 Gateway","version":"4.2.1-enterprise","node_id":"VLT-FRA-01","region":"eu-central-1","storage_engine":"nvme-erasure-coding-v4","replication":"synced","tls_protocol":"$ssl_protocol","timestamp":"$time_iso8601","request_id":"$request_id"}';
        }

        # Страница WAF-ошибки портала (только для внутренних редиректов)
        location = /error.html {
            root /var/www/myfakesite;
            internal;
        }

        location / {
            limit_req zone=bot burst=20 nodelay;
            limit_conn addr 20;
            root /var/www/myfakesite;
            index index.html;
            try_files $uri $uri/ =404;
            error_page 400 403 404 405 /error.html;
        }
EOF
)
    MASK_LOCATION_BLOCK=${MASK_LOCATION_BLOCK//@@COMPANY@@/${COMPANY_NAME}}
    MASK_LOCATION_BLOCK=${MASK_LOCATION_BLOCK//@@SLUG@@/${COMPANY_SLUG}}
else
    RP_HOST=$(echo "$REVERSE_PROXY_URL" | sed -E 's|^https?://||; s|/.*$||')
    RP_SCHEME=$(echo "$REVERSE_PROXY_URL" | grep -oE '^https?' || echo "https")
    [[ -z "$RP_SCHEME" ]] && RP_SCHEME="https"

    MASK_LOCATION_BLOCK=$(cat <<EOF
        # Reverse Proxy маскировка на ${RP_SCHEME}://${RP_HOST}
        location / {
            limit_req zone=bot burst=20 nodelay;
            limit_conn addr 20;

            set \$rp_upstream "${RP_SCHEME}://${RP_HOST}";
            proxy_pass \$rp_upstream;
            proxy_ssl_server_name on;
            proxy_ssl_name ${RP_HOST};
            proxy_http_version 1.1;
            proxy_ssl_session_reuse off;
            proxy_buffering on;
            proxy_cache html_zone;
            proxy_cache_valid 200 1d;
            proxy_ignore_headers Set-Cookie;
            proxy_hide_header Set-Cookie;
            proxy_intercept_errors on;

            proxy_set_header Host ${RP_HOST};
            proxy_set_header Referer ${RP_SCHEME}://${RP_HOST}/;
            proxy_set_header User-Agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36";
            proxy_set_header Accept-Encoding "";
            proxy_set_header X-Real-IP "";
            proxy_set_header X-Forwarded-For "";

            sub_filter '${RP_SCHEME}://${RP_HOST}' 'https://\$host';
            sub_filter '//${RP_HOST}' '//\$host';
            sub_filter_once off;
        }
EOF
)
fi

cat <<'EOF' > /var/www/html/404.html
<!DOCTYPE html><html><head><title>404 Not Found</title></head>
<body style="font-family:sans-serif;text-align:center;padding-top:10%">
<h1>404 Not Found</h1><hr><p>nginx</p></body></html>
EOF

chown -R www-data:www-data /var/cache/nginx /var/www /var/log/nginx

# 8. Установка 3x-ui, загрузка расширенных баз geosite и патчинг /etc/x-ui/x-ui.db (без создания пользователей)
log_info "Установка панели 3x-ui..."
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<EOF
n
EOF
systemctl stop x-ui

log_info "Загрузка баз geosite_IR.dat и geosite_RU.dat для фильтрации рекламы, фишинга и майнеров..."
curl -fsSL "https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geosite.dat" -o /usr/local/x-ui/bin/geosite_IR.dat || log_warn "Не удалось скачать geosite_IR.dat"
curl -fsSL "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat" -o /usr/local/x-ui/bin/geosite_RU.dat || log_warn "Не удалось скачать geosite_RU.dat"

log_info "Определение геолокации IP сервера, настройка роутинга и создание чистых инбаундов в 3x-ui..."
/usr/local/x-ui/x-ui setting -username "${PANEL_USER}" -password "${PANEL_PASS}" -port "${PANEL_PORT}" -webBasePath "/${PANEL_PATH}/" >/dev/null

DOMAIN="$DOMAIN" \
PANEL_PORT="$PANEL_PORT" \
PANEL_PATH="$PANEL_PATH" \
SUB_PORT="$SUB_PORT" \
SUB_PATH="$SUB_PATH" \
XHTTP_UP_PATH="$XHTTP_UP_PATH" \
XHTTP_ONE_PATH="$XHTTP_ONE_PATH" \
python3 - <<'PYEOF'
import sqlite3, json, urllib.request, os, glob, subprocess, base64, secrets

domain = os.environ["DOMAIN"]
panel_port = os.environ["PANEL_PORT"]
panel_path = os.environ["PANEL_PATH"]
sub_port = os.environ["SUB_PORT"]
sub_path = os.environ["SUB_PATH"]
xhttp_up_path = os.environ["XHTTP_UP_PATH"]
xhttp_one_path = os.environ["XHTTP_ONE_PATH"]

def detect_server_country():
    country_names_ru = {
        "NL": "Нидерланды", "DE": "Германия", "FR": "Франция", "FI": "Финляндия",
        "SE": "Швеция", "NO": "Норвегия", "DK": "Дания", "GB": "Великобритания",
        "UK": "Великобритания", "IE": "Ирландия", "PL": "Польша", "CZ": "Чехия",
        "AT": "Австрия", "CH": "Швейцария", "BE": "Бельгия", "LU": "Люксембург",
        "ES": "Испания", "IT": "Италия", "PT": "Португалия", "GR": "Греция",
        "BG": "Болгария", "RO": "Румыния", "HU": "Венгрия", "SK": "Словакия",
        "SI": "Словения", "HR": "Хорватия", "RS": "Сербия", "EE": "Эстония",
        "LV": "Латвия", "LT": "Литва", "MD": "Молдова", "UA": "Украина",
        "BY": "Беларусь", "RU": "Россия", "KZ": "Казахстан", "AM": "Армения",
        "GE": "Грузия", "AZ": "Азербайджан", "UZ": "Узбекистан", "TR": "Турция",
        "AE": "ОАЭ", "IL": "Израиль", "CY": "Кипр", "US": "США", "CA": "Канада",
        "BR": "Бразилия", "AR": "Аргентина", "CL": "Чили", "JP": "Япония",
        "KR": "Южная Корея", "SG": "Сингапур", "HK": "Гонконг", "TW": "Тайвань",
        "IN": "Индия", "AU": "Австралия", "NZ": "Новая Зеландия", "ZA": "ЮАР"
    }

    ip = ""
    for ip_url in ("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com"):
        try:
            req = urllib.request.Request(ip_url, headers={"User-Agent": "curl/8.0"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                ip = resp.read().decode("utf-8").strip()
                if ip:
                    break
        except Exception:
            pass

    code = ""
    fallback_name = ""
    if ip:
        try:
            req = urllib.request.Request(f"http://ip-api.com/json/{ip}?fields=status,country,countryCode", headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=6) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if data.get("status") == "success":
                    code = (data.get("countryCode") or "").upper()
                    fallback_name = data.get("country") or ""
        except Exception:
            pass

    if not code:
        try:
            url = f"https://ipinfo.io/{ip}/json" if ip else "https://ipinfo.io/json"
            req = urllib.request.Request(url, headers={"User-Agent": "curl/8.0"})
            with urllib.request.urlopen(req, timeout=6) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                code = (data.get("country") or "").upper()
        except Exception:
            pass

    if len(code) == 2 and code.isalpha():
        flag = "".join(chr(0x1F1E6 + ord(c) - ord("A")) for c in code)
        name = country_names_ru.get(code) or fallback_name or code
        return f"{flag} {name}"

    return "🌐 Сервер"

def has_geosite_tag(dat_path, tag):
    if not os.path.exists(dat_path) or os.path.getsize(dat_path) < 1024:
        return False
    marker = b"\x0a" + bytes([len(tag)]) + tag.upper().encode("ascii")
    try:
        with open(dat_path, "rb") as f:
            return marker in f.read()
    except Exception:
        return False

def generate_x25519_keys(bin_dir):
    priv_key, pub_key = "", ""
    for xbin in sorted(glob.glob(os.path.join(bin_dir, "xray*"))):
        if os.path.isfile(xbin) and os.access(xbin, os.X_OK):
            try:
                out = subprocess.check_output([xbin, "x25519"], text=True, timeout=5)
                for line in out.splitlines():
                    if ":" not in line:
                        continue
                    k, v = [p.strip() for p in line.split(":", 1)]
                    kl = k.lower()
                    if "private" in kl:
                        priv_key = v
                    elif "public" in kl or "password" in kl:
                        pub_key = v
                if priv_key and pub_key:
                    return priv_key, pub_key
            except Exception:
                pass
    pem = subprocess.check_output(["openssl", "genpkey", "-algorithm", "X25519"])
    der_priv = subprocess.check_output(["openssl", "pkey", "-outform", "DER"], input=pem)
    der_pub = subprocess.check_output(["openssl", "pkey", "-pubout", "-outform", "DER"], input=pem)
    priv_key = base64.urlsafe_b64encode(der_priv[-32:]).decode().rstrip("=")
    pub_key = base64.urlsafe_b64encode(der_pub[-32:]).decode().rstrip("=")
    return priv_key, pub_key

base_remark = detect_server_country()
print(f"Определено базовое имя локации: {base_remark}")

db_path = "/etc/x-ui/x-ui.db"
bin_dir = "/usr/local/x-ui/bin"
conn = sqlite3.connect(db_path)
cur = conn.cursor()

per_app_list = "org.telegram.messenger, com.whatsapp, com.instagram.android, com.google.android.youtube, com.twitter.android, com.facebook.katana, com.google.android.apps.youtube.music, com.spotify.music, com.netflix.mediaclient"

settings_map = {
    "webPort": panel_port,
    "webListen": "127.0.0.1",
    "webBasePath": f"/{panel_path}/",
    "webCertFile": f"/root/cert/{domain}/fullchain.pem",
    "webKeyFile": f"/root/cert/{domain}/privkey.pem",
    "subEnable": "true",
    "subListen": "127.0.0.1",
    "subPort": sub_port,
    "subPath": f"/{sub_path}/",
    "subCertFile": f"/root/cert/{domain}/fullchain.pem",
    "subKeyFile": f"/root/cert/{domain}/privkey.pem",
    "subURI": f"https://{domain}/{sub_path}/",
    "twoFactorEnable": "false",

    # Общие настройки подписки
    "subUpdates": "2",
    "subHideSettings": "true",
    "subHostSortMode": "inbound-first",
    "subProfileMode": "none",
    "subInfoNodeEnable": "false",
    "subShowIdentityOnAllLinks": "false",
    "subCalendarExpireInclusive": "false",
    "subExpiredTemplate": "⛔ {{EMAIL}} | Expired: {{EXPIRE_DATE}}",
    "subTrafficDepletedTemplate": "🚫 {{EMAIL}} | Traffic Depleted | {{TRAFFIC_USED}}/{{TRAFFIC_TOTAL}}",

    # Вкладка HAPP
    "happLinkEnable": "true",
    "subEnableRouting": "true",
    "subHappAutoDetect": "true",
    "subHappAlwaysHwid": "false",
    "subHappAutoConnect": "false",
    "subHappAutoConnectType": "lowestdelay",
    "subHappExcludeApns": "true",
    "subHappNoLimit": "false",
    "subHappNotificationExpire": "true",
    "subHappSubExpire": "true",
    "subHappSubInfoColor": "blue",
    "subHappPerAppMode": "on",
    "subHappPerAppList": per_app_list,
    "subRoutingRules": "happ://routing/onadd/eyJOYW1lIjoiUm9zY29tVlBOIiwiR2xvYmFsUHJveHkiOiJ0cnVlIiwiVXNlQ2h1bmtGaWxlcyI6InRydWUiLCJSZW1vdGVEbnMiOiI4LjguOC44IiwiRG9tZXN0aWNEbnMiOiI3Ny44OC44LjgiLCJSZW1vdGVETlNUeXBlIjoiRG9IIiwiUmVtb3RlRE5TRG9tYWluIjoiaHR0cHM6Ly84LjguOC44L2Rucy1xdWVyeSIsIlJlbW90ZUROU0lQIjoiOC44LjguOCIsIkRvbWVzdGljRE5TVHlwZSI6IkRvSCIsIkRvbWVzdGljRE5TRG9tYWluIjoiaHR0cHM6Ly83Ny44OC44LjgvZG5zLXF1ZXJ5IiwiRG9tZXN0aWNETlNJUCI6Ijc3Ljg4LjguOCIsIkdlb2lwdXJsIjoiaHR0cHM6Ly9jZG4uanNkZWxpdnIubmV0L2doL2h5ZHJhcG9uaXF1ZS9yb3Njb212cG4tZ2VvaXBAMjAyNjExMTcxMTQ1L3JlbGVhc2UvZ2VvaXAuZGF0IiwiR2Vvc2l0ZXVybCI6Imh0dHBzOi8vY2RuLmpzZGVsaXZyLm5ldC9naC9oeWRyYXBvbmlxdWUvcm9zY29tdnBuLWdlb3NpdGVAMjAyNjEwMTIwOTQ4L3JlbGVhc2UvZ2Vvc2l0ZS5kYXQiLCJMYXN0VXBkYXRlZCI6IjE3OTQ5MTU5NjkiLCJEbnNIb3N0cyI6eyJsa2ZsMi5uYWxvZy5ydSI6IjIxMy4yNC42NC4xNzUiLCJsa25wZC5uYWxvZy5ydSI6IjIxMy4yNC42NC4xODEifSwiUm91dGVPcmRlciI6ImJsb2NrLXByb3h5LWRpcmVjdCIsIkRpcmVjdFNpdGVzIjpbImdlb3NpdGU6cHJpdmF0ZSIsImdlb3NpdGU6Y2F0ZWdvcnktcnUiLCJnZW9zaXRlOndoaXRlbGlzdCIsImdlb3NpdGU6bWljcm9zb2Z0IiwiZ2Vvc2l0ZTphcHBsZSIsImdlb3NpdGU6ZXBpY2dhbWVzIiwiZ2Vvc2l0ZTpyaW90IiwiZ2Vvc2l0ZTplc2NhcGVmcm9tdGFya292IiwiZ2Vvc2l0ZTpzdGVhbSIsImdlb3NpdGU6dHdpdGNoIiwiZ2Vvc2l0ZTpwaW50ZXJlc3QiLCJnZW9zaXRlOmZhY2VpdCJdLCJEaXJlY3RJcCI6WyJnZW9pcDpwcml2YXRlIiwiZ2VvaXA6ZGlyZWN0Il0sIlByb3h5U2l0ZXMiOlsiZ2Vvc2l0ZTpnb29nbGUtcGxheSIsImdlb3NpdGU6Z2l0aHViIiwiZ2Vvc2l0ZTp0d2l0Y2gtYWRzIiwiZ2Vvc2l0ZTp5b3V0dWJlIiwiZ2Vvc2l0ZTp0ZWxlZ3JhbSJdLCJQcm94eUlwIjpbXSwiQmxvY2tTaXRlcyI6WyJnZW9zaXRlOndpbi1zcHkiLCJnZW9zaXRlOnRvcnJlbnQiLCJnZW9zaXRlOmNhdGVnb3J5LWFkcyJdLCJCbG9ja0lwIjpbXSwiRG9tYWluU3RyYXRlZ3kiOiJJUElmTm9uTWF0Y2giLCJGYWtlRE5TIjoiZmFsc2UifQo=",

    # Вкладка INCY
    "subIncyAppAutoDetect": "true",
    "subIncyEnableRouting": "true",
    "subIncyHideUrl": "1",
    "subIncyNoLimitEnabled": "1",
    "subIncyPerAppEnable": "1",
    "subIncyPerAppMode": "proxy",
    "subIncyPerAppList": per_app_list,
    "subIncyRoutingRules": "incy://routing/onadd/eyJOYW1lIjoiUm9zY29tVlBOIiwiR2xvYmFsUHJveHkiOiJ0cnVlIiwiVXNlQ2h1bmtGaWxlcyI6InRydWUiLCJSZW1vdGVEbnMiOiI4LjguOC44IiwiRG9tZXN0aWNEbnMiOiI3Ny44OC44LjgiLCJSZW1vdGVETlNUeXBlIjoiRG9IIiwiUmVtb3RlRE5TRG9tYWluIjoiaHR0cHM6Ly84LjguOC44L2Rucy1xdWVyeSIsIlJlbW90ZUROU0lQIjoiOC44LjguOCIsIkRvbWVzdGljRE5TVHlwZSI6IkRvSCIsIkRvbWVzdGljRE5TRG9tYWluIjoiaHR0cHM6Ly83Ny44OC44LjgvZG5zLXF1ZXJ5IiwiRG9tZXN0aWNETlNJUCI6Ijc3Ljg4LjguOCIsIkdlb2lwdXJsIjoiaHR0cHM6Ly9jZG4uanNkZWxpdnIubmV0L2doL2h5ZHJhcG9uaXF1ZS9yb3Njb212cG4tZ2VvaXAvcmVsZWFzZS9nZW9pcC5kYXQiLCJHZW9zaXRldXJsIjoiaHR0cHM6Ly9jZG4uanNkZWxpdnIubmV0L2doL2h5ZHJhcG9uaXF1ZS9yb3Njb212cG4tZ2Vvc2l0ZS9yZWxlYXNlL2dlb3NpdGUuZGF0IiwiTGFzdFVwZGF0ZWQiOiIxNzk0OTE1OTcwIiwiRG5zSG9zdHMiOnsibGtmbDIubmFsb2cucnUiOiIyMTMuMjQuNjQuMTc1IiwibGtucGQubmFsb2cucnUiOiIyMTMuMjQuNjQuMTgxIn0sIlJvdXRlT3JkZXIiOiJibG9jay1wcm94eS1kaXJlY3QiLCJEaXJlY3RTaXRlcyI6WyJnZW9zaXRlOnByaXZhdGUiLCJnZW9zaXRlOmNhdGVnb3J5LXJ1IiwiZ2Vvc2l0ZTp3aGl0ZWxpc3QiLCJnZW9zaXRlOm1pY3Jvc29mdCIsImdlb3NpdGU6YXBwbGUiLCJnZW9zaXRlOmVwaWNnYW1lcyIsImdlb3NpdGU6cmlvdCIsImdlb3NpdGU6ZXNjYXBlZnJvbXRhcmtvdiIsImdlb3NpdGU6c3RlYW0iLCJnZW9zaXRlOnR3aXRjaCIsImdlb3NpdGU6cGludGVyZXN0IiwiZ2Vvc2l0ZTpmYWNlaXQiXSwiRGlyZWN0SXAiOlsiZ2VvaXA6cHJpdmF0ZSIsImdlb2lwOmRpcmVjdCJdLCJQcm94eVNpdGVzIjpbImdlb3NpdGU6Z29vZ2xlLXBsYXkiLCJnZW9zaXRlOmdpdGh1YiIsImdlb3NpdGU6dHdpdGNoLWFkcyIsImdlb3NpdGU6eW91dHViZSIsImdlb3NpdGU6dGVsZWdyYW0iXSwiUHJveHlJcCI6W10sIkJsb2NrU2l0ZXMiOlsiZ2Vvc2l0ZTp3aW4tc3B5IiwiZ2Vvc2l0ZTp0b3JyZW50IiwiZ2Vvc2l0ZTpjYXRlZ29yeS1hZHMiXSwiQmxvY2tJcCI6W10sIkRvbWFpblN0cmF0ZWd5IjoiSVBJZk5vbk1hdGNoIiwiRmFrZUROUyI6ImZhbHNlIn0K"
}

for k, v in settings_map.items():
    cur.execute("SELECT id FROM settings WHERE key = ?", (k,))
    if cur.fetchone():
        cur.execute("UPDATE settings SET value = ? WHERE key = ?", (v, k))
    else:
        cur.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (k, v))

# Полный системный каркас xrayTemplateConfig с проверкой наличия тегов в .dat файлах
domain_blocks = ["geosite:category-ads-all"]

ru_dat = os.path.join(bin_dir, "geosite_RU.dat")
for ru_tag in ("category-ads-all", "category-ads"):
    if has_geosite_tag(ru_dat, ru_tag):
        domain_blocks.append(f"ext:geosite_RU.dat:{ru_tag}")
        break

ir_dat = os.path.join(bin_dir, "geosite_IR.dat")
for ir_tag in ("malware", "phishing", "cryptominers", "category-ads-all"):
    if has_geosite_tag(ir_dat, ir_tag):
        domain_blocks.append(f"ext:geosite_IR.dat:{ir_tag}")

tpl = {
    "log": {
        "loglevel": "warning"
    },
    "api": {
        "tag": "api",
        "services": ["HandlerService", "LoggerService", "StatsService"]
    },
    "inbounds": [
        {
            "tag": "api",
            "listen": "127.0.0.1",
            "port": 62789,
            "protocol": "dokodemo-door",
            "settings": {"address": "127.0.0.1"}
        }
    ],
    "outbounds": [
        {"tag": "direct", "protocol": "freedom", "settings": {}},
        {"tag": "blocked", "protocol": "blackhole", "settings": {}}
    ],
    "policy": {
        "levels": {
            "0": {"statsUserDownlink": True, "statsUserUplink": True}
        },
        "system": {
            "statsInboundDownlink": True,
            "statsInboundUplink": True,
            "statsOutboundDownlink": True,
            "statsOutboundUplink": True
        }
    },
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {
                "type": "field",
                "inboundTag": ["api"],
                "outboundTag": "api"
            },
            {
                "type": "field",
                "outboundTag": "blocked",
                "protocol": ["bittorrent"]
            },
            {
                "type": "field",
                "outboundTag": "blocked",
                "ip": ["geoip:private"]
            },
            {
                "type": "field",
                "outboundTag": "blocked",
                "domain": domain_blocks
            }
        ]
    },
    "stats": {}
}

tpl_val = json.dumps(tpl, indent=2)
row = cur.execute("SELECT id FROM settings WHERE key = 'xrayTemplateConfig'").fetchone()
if row:
    cur.execute("UPDATE settings SET value = ? WHERE key = 'xrayTemplateConfig'", (tpl_val,))
else:
    cur.execute("INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)", (tpl_val,))

# Очистка таблиц инбаундов и клиентов (инбаунды создаются без пользователей)
for tbl in ("inbounds", "client_traffics", "client_inbounds", "clients"):
    try:
        cur.execute(f"DELETE FROM {tbl}")
    except sqlite3.OperationalError:
        pass

browser_headers = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
    "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7"
}

default_allocate = json.dumps({
    "strategy": "always",
    "refresh": 5,
    "concurrency": 3
})

default_sniffing = json.dumps({
    "enabled": True,
    "destOverride": ["http", "tls", "quic", "fakedns"],
    "metadataOnly": False,
    "routeOnly": False
})

inbounds = [
    # Inbound 1: VLESS XHTTP Packet-UP (127.0.0.1:11443) -> Мобилы (без клиентов)
    {
        "id": 1,
        "user_id": 1,
        "up": 0,
        "down": 0,
        "total": 0,
        "remark": f"{base_remark} - Мобилы",
        "enable": 1,
        "expiry_time": 0,
        "listen": "127.0.0.1",
        "port": 11443,
        "protocol": "vless",
        "settings": json.dumps({
            "clients": [],
            "decryption": "none",
            "fallbacks": []
        }),
        "stream_settings": json.dumps({
            "network": "xhttp",
            "security": "none",
            "externalProxy": [{
                "forceTls": "tls",
                "dest": domain,
                "port": 443,
                "remark": ""
            }],
            "xhttpSettings": {
                "path": f"/{xhttp_up_path}/",
                "host": domain,
                "mode": "packet-up",
                "noGRPCHeader": True,
                "xPaddingBytes": "100-1000",
                "scMaxEachPostBytes": "500000-1000000",
                "scMinPostsIntervalMs": "10-50",
                "scMaxBufferedPosts": 30,
                "scStreamUpServerSecs": "20-80",
                "headers": browser_headers
            }
        }),
        "tag": "inbound-xhttp-up",
        "sniffing": default_sniffing,
        "allocate": default_allocate
    },
    # Inbound 2: VLESS XHTTP  (127.0.0.1:7443) -> Домашний (без клиентов)
    {
        "id": 2,
        "user_id": 1,
        "up": 0,
        "down": 0,
        "total": 0,
        "remark": f"{base_remark} - Домашний",
        "enable": 1,
        "expiry_time": 0,
        "listen": "127.0.0.1",
        "port": 7443,
        "protocol": "vless",
        "settings": json.dumps({
            "clients": [],
            "decryption": "none",
            "fallbacks": []
        }),
        "stream_settings": json.dumps({
            "network": "xhttp",
            "security": "none",
            "externalProxy": [{
                "forceTls": "tls",
                "dest": domain,
                "port": 443,
                "remark": ""
            }],
            "xhttpSettings": {
                "path": f"/{xhttp_one_path}/",
                "host": domain,
                "mode": "stream-one",
                "noGRPCHeader": False,
                "xPaddingBytes": "100-1000",
                "headers": browser_headers
            }
        }),
        "tag": "inbound-xhttp-one",
        "sniffing": default_sniffing,
        "allocate": default_allocate
    }
]

reality_priv_key, reality_pub_key = generate_x25519_keys(bin_dir)
reality_short_ids = [
    secrets.token_hex(2),
    secrets.token_hex(4),
    secrets.token_hex(6),
    secrets.token_hex(8)
]

inbounds.append({
    # Inbound 3: VLESS TCP Reality Self-Steal (127.0.0.1:9443 -> 127.0.0.1:8443) -> Reality Vision (без клиентов)
    "id": 3,
    "user_id": 1,
    "up": 0,
    "down": 0,
    "total": 0,
    "remark": f"{base_remark} - Reality",
    "enable": 1,
    "expiry_time": 0,
    "listen": "127.0.0.1",
    "port": 9443,
    "protocol": "vless",
    "settings": json.dumps({
        "clients": [],
        "decryption": "none",
        "fallbacks": []
    }),
    "stream_settings": json.dumps({
        "network": "tcp",
        "security": "reality",
        "externalProxy": [{
            "forceTls": "same",
            "dest": domain,
            "port": 443,
            "remark": ""
        }],
        "realitySettings": {
            "show": False,
            "xver": 1,
            "target": "127.0.0.1:8443",
            "serverNames": [domain],
            "privateKey": reality_priv_key,
            "minClientVer": "",
            "maxClientVer": "",
            "maxTimediff": 0,
            "shortIds": reality_short_ids,
            "mldsa65Seed": "",
            "settings": {
                "publicKey": reality_pub_key,
                "fingerprint": "chrome",
                "serverName": "",
                "spiderX": "/",
                "mldsa65Verify": ""
            }
        },
        "tcpSettings": {
            "acceptProxyProtocol": True,
            "header": {
                "type": "none"
            }
        }
    }),
    "tag": "inbound-reality",
    "sniffing": default_sniffing,
    "allocate": default_allocate
})

extra_defaults = {
    "all_time": 0,
    "traffic_reset": "never",
    "last_traffic_reset_time": 0,
    "node_id": None
}
existing_cols = {row[1] for row in cur.execute("PRAGMA table_info(inbounds)").fetchall()}
for ib in inbounds:
    merged_ib = {**extra_defaults, **ib}
    valid_ib = {k: v for k, v in merged_ib.items() if k in existing_cols}
    cols_sql = ", ".join(valid_ib.keys())
    vals_sql = ", ".join(f":{k}" for k in valid_ib.keys())
    cur.execute(f"INSERT INTO inbounds ({cols_sql}) VALUES ({vals_sql})", valid_ib)

conn.commit()
conn.close()
PYEOF

rm -f /usr/local/x-ui/bin/config.json

# 9. Формирование /etc/nginx/nginx.conf (HTTP/2 на 443 порту + корректное проксирование XHTTP + лог для Fail2Ban/CrowdSec)
log_info "Генерация /etc/nginx/nginx.conf..."
cat <<EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
worker_rlimit_nofile 524288;

error_log /var/log/nginx/error.log warn;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    server_tokens off;
    etag off;
    charset utf-8;
    resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;
    resolver_timeout 5s;
    http2_recv_buffer_size 4m;

    map \$remote_addr \$limit_ip {
        default \$remote_addr;
    }

    upstream panel_3xui {
        server 127.0.0.1:${PANEL_PORT};
        keepalive 30;
    }
    upstream xray_xhttp_up {
        server 127.0.0.1:11443;
        keepalive 64;
        keepalive_timeout 1h;
        keepalive_requests 100000;
    }
    upstream xray_xhttp_one {
        server 127.0.0.1:7443;
        keepalive 64;
        keepalive_timeout 1h;
        keepalive_requests 100000;
    }

    proxy_cache_path /var/cache/nginx/img_cache levels=1:2 keys_zone=img_zone:10m max_size=1g inactive=7d use_temp_path=off;
    proxy_cache_path /var/cache/nginx/html_cache levels=1:2 keys_zone=html_zone:20m max_size=500m inactive=30d use_temp_path=off;

    # Стандартный формат combined для 100% совместимости с фильтрами Fail2Ban и CrowdSec
    access_log /var/log/nginx/access.log combined buffer=32k flush=5s;

    keepalive_timeout 75s;
    keepalive_requests 100000;
    client_body_timeout 60s;
    client_header_timeout 60s;
    send_timeout 60s;
    reset_timedout_connection on;

    client_max_body_size 8m;
    client_body_buffer_size 128k;
    large_client_header_buffers 4 16k;
    client_header_buffer_size 1k;

    open_file_cache max=1000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;

    gzip on;
    gzip_vary on;
    gzip_comp_level 2;
    gzip_min_length 512;
    gzip_proxied any;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        "" close;
    }

    map \$http_user_agent \$badbot_raw {
        default 0;
        "" 1;
        ~*(?:httpclient|lwp-request|go-http-client|axios|fetch|insomnia|postman|libwww-perl|java|php|ruby|nuclei|httpx|ffuf|dirsearch|gobuster) 1;
        ~*(?:sqlmap|nikto|masscan|zgrab|zmap|acunetix|dirbuster|wpscan|nmap|hydra|bfexam|censys|shodan|dirb|feroxbuster|katana) 1;
        ~*(?:ahrefs|semrush|mj12bot|dotbot|rogerbot|exabot|sogou|bytespider|yandexbot|pinterest|baidu|duckduckgo|bingbot|googlebot) 1;
        ~*(?:gptbot|claudebot|chatgpt|cohere|omgili|anthropic|google-extended|applebot-extended|meta-externalagent|ccbot|perplexity|openai|gemini|bard|commoncrawl|diffbot) 1;
        ~*(?:facebookexternalhit|twitterbot|linkedinbot|slackbot|discordbot) 1;
    }

    map \$request_uri \$is_scan_attempt {
        default 0;
        ~*\.(?:php|php5|phtml|asp|aspx|jsp|do|action|cgi|pl|py|rb)\$ 1;
        ~*(\.env|\.git|\.config|\.htaccess|\.sql|\.bak|\.old|\.swp|\.ini|config\.php|web\.config|settings\.py)\$ 1;
        ~*^/(?:admin|administrator|wp-admin|wp-login|phpmyadmin|sqladmin|setup|install|dashboard|manager|controlpanel|config|auth|backend|logs)/ 1;
        ~*(\.\./|\.\.\\\\|/etc/passwd|/boot/|/windows/|/proc/) 1;
        ~*\.(?:zip|tar\.gz|rar|7z)\$ 1;
    }

    map "\$badbot_raw:\$is_scan_attempt:\$request_uri" \$badbot {
        ~^.*:/\.well-known/acme-challenge/ 0;
        ~^.*:/robots\.txt(\?|\$) 0;
        ~^.*:/\.well-known/security\.txt(\?|\$) 0;
        ~^.*:/${PANEL_PATH}(/|\$) 0;
        ~^.*:/${SUB_PATH}/ 0;
        ~^.*:/${XHTTP_UP_PATH}/ 0;
        ~^.*:/${XHTTP_ONE_PATH}/ 0;
        ~(^1:|:1) 1;
        default 0;
    }

    limit_req_zone \$limit_ip zone=bot:1m rate=4r/s;
    limit_req_zone \$limit_ip zone=panel:10m rate=30r/s;
    limit_req_zone \$limit_ip zone=subs:1m rate=5r/m;
    limit_req_zone \$limit_ip zone=scan:1m rate=1r/s;
    limit_req_zone \$limit_ip zone=fs_auth:10m rate=5r/m;
    limit_conn_zone \$limit_ip zone=addr:1m;
    limit_req_status 429;

    proxy_hide_header Server;
    proxy_hide_header X-Powered-By;
    proxy_hide_header Via;
    proxy_hide_header X-Frame-Options;
    proxy_hide_header Strict-Transport-Security;
    proxy_hide_header Referrer-Policy;
    proxy_hide_header Permissions-Policy;

    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        access_log off;

        if (\$host != "${DOMAIN}") { return 444; }

        location ^~ /.well-known/acme-challenge/ {
            root /var/www/html;
        }

        location / {
            if (\$badbot) { return 444; }
            return 301 https://${DOMAIN}\$request_uri;
        }
    }

    port_in_redirect off;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    # Защита от сканеров по IP-адресу сервера и чужому SNI (сброс TLS handshake)
    server {
        listen 127.0.0.1:8443 ssl default_server proxy_protocol reuseport;
        server_name _;

        ssl_reject_handshake on;
        ssl_session_tickets off;

        ssl_certificate /root/cert/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /root/cert/${DOMAIN}/privkey.pem;
    }

    server {
        listen 127.0.0.1:8443 ssl proxy_protocol;
        http2 on;
        http2_max_concurrent_streams 1024;
        http2_chunk_size 16k;
        server_name ${DOMAIN};

        ssl_certificate /root/cert/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /root/cert/${DOMAIN}/privkey.pem;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_buffer_size 4k;
        ssl_prefer_server_ciphers off;
        ssl_session_tickets on;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 15m;
        ssl_early_data on;
        ssl_stapling off;

        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
        add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

        if (\$badbot) { return 404; }
        if (\$request_method !~ ^(GET|HEAD|POST|OPTIONS)\$) { return 405; }
        if (\$host != '${DOMAIN}') { return 444; }

        error_page 400 403 404 405 @notfound;

        # Панель 3x-ui
        location = /${PANEL_PATH} {
            return 301 /${PANEL_PATH}/;
        }
        location ^~ /${PANEL_PATH}/ {
            proxy_pass https://panel_3xui/${PANEL_PATH}/;
            proxy_ssl_verify off;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_buffering off;
            proxy_request_buffering off;
            access_log off;
            expires -1;
        }

        # Сервис подписок 3x-ui
        location ^~ /${SUB_PATH}/ {
            proxy_pass https://127.0.0.1:${SUB_PORT}/${SUB_PATH}/;
            proxy_ssl_verify off;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            expires -1;
        }

        # Inbound 1: VLESS XHTTP Packet-UP (Мобилы)
        location ^~ /${XHTTP_UP_PATH}/ {
            set \$limit_ip "";

            proxy_pass http://xray_xhttp_up;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_buffering off;
            proxy_request_buffering off;
            gzip off;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_read_timeout 1h;
            proxy_send_timeout 1h;
            client_body_timeout 1h;
            send_timeout 1h;
            proxy_socket_keepalive on;
            proxy_next_upstream off;
            client_max_body_size 0;
            proxy_max_temp_file_size 0;
            access_log off;
            error_log /dev/null crit;
        }

        # Inbound 2: VLESS XHTTP Stream-One (Домашний)
        location ^~ /${XHTTP_ONE_PATH}/ {
         set \$limit_ip "";

         grpc_pass grpc://xray_xhttp_one;
         grpc_set_header Host \$host;
         grpc_set_header X-Real-IP \$remote_addr;
         grpc_set_header X-Forwarded-For \$remote_addr;
         grpc_read_timeout 1h;
         grpc_send_timeout 1h;
         grpc_socket_keepalive on;
         client_body_timeout 1h;
         client_max_body_size 0;
         access_log off;
         error_log /dev/null crit;
        }

${MASK_LOCATION_BLOCK}

        location = /robots.txt {
            default_type text/plain;
            access_log off;
            return 200 "User-agent: *\nDisallow: /\n";
        }
        location = /favicon.ico {
            root /var/www/html;
            expires 30d;
            access_log off;
        }
        location = /.well-known/security.txt {
            default_type text/plain;
            access_log off;
            return 200 "Contact: mailto:admin@${DOMAIN}\nPreferred-Languages: ru,en\n";
        }
        location @notfound {
            limit_req zone=scan burst=3 nodelay;
            root /var/www/html;
            rewrite ^ /404.html break;
        }
    }
}

# L4 маршрутизатор на порту 443 (SNI preread -> VLESS TCP Reality Self-Steal -> Nginx HTTPS)
stream {
    map \$ssl_preread_server_name \$stream_backend {
        ${DOMAIN} xray_reality;
        default   nginx_https_reject;
    }

    upstream xray_reality {
        server 127.0.0.1:9443 max_fails=2 fail_timeout=2s;
        server 127.0.0.1:8443 backup;
    }

    upstream nginx_https_reject {
        server 127.0.0.1:8443;
    }

    server {
        listen 443 reuseport;
        listen [::]:443 reuseport;
        ssl_preread on;
        preread_buffer_size 64k;
        proxy_protocol on;
        proxy_pass \$stream_backend;
        proxy_connect_timeout 3s;
        proxy_timeout 1h;
        proxy_buffer_size 16k;
    }
}
EOF

# 10. Systemd лимиты дескрипторов для Nginx и 3x-ui
mkdir -p /etc/systemd/system/nginx.service.d /etc/systemd/system/x-ui.service.d
cat <<'EOF' > /etc/systemd/system/nginx.service.d/limits.conf
[Service]
LimitNOFILE=524288
EOF
cp /etc/systemd/system/nginx.service.d/limits.conf /etc/systemd/system/x-ui.service.d/limits.conf

systemctl daemon-reload
nginx -t || log_err "Ошибка в сгенерированном конфиге Nginx!"

systemctl enable --now x-ui
sleep 2
systemctl enable --now nginx
systemctl restart x-ui nginx

# Дополнительная привязка certbot к webroot после запуска Nginx
certbot reconfigure --cert-name "${DOMAIN}" --authenticator webroot --webroot-path /var/www/html --non-interactive >/dev/null 2>&1 || true

# 11. Настройка Fail2Ban (systemd для ssh.service + кастомный фильтр для сканеров Nginx)
log_info "Настройка Fail2Ban..."
mkdir -p /etc/fail2ban/filter.d
cat <<'EOF' > /etc/fail2ban/filter.d/nginx-scanners.conf
[Definition]
failregex = ^<HOST> - \S+ \[.*?\] "(?:GET|POST|HEAD|OPTIONS|PUT|DELETE) .+ HTTP/\d\.\d" (?:404|405|429|444) \d+
ignoreregex =
EOF

cat <<'EOF' > /etc/fail2ban/filter.d/myfakesite-auth.conf
[Definition]
failregex = ^<HOST> - \S+ \[.*?\] "POST /api/auth(?:\?\S*)? HTTP/\d(?:\.\d)?" (?:401|429) \d+
ignoreregex =
EOF

cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1${ADMIN_SSH_IP:+ ${ADMIN_SSH_IP}}
bantime = 24h
findtime = 10m
maxretry = 3
backend = systemd
banaction = nftables-multiport

[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service

[nginx-scanners]
enabled = true
filter = nginx-scanners
port = http,https
backend = polling
logpath = /var/log/nginx/access.log
maxretry = 10
findtime = 5m
bantime = 12h

[myfakesite-auth]
enabled = true
filter = myfakesite-auth
port = http,https
backend = polling
logpath = /var/log/nginx/access.log
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# 12. Установка и настройка CrowdSec + nftables bouncer
log_info "Установка CrowdSec и nftables firewall bouncer..."
curl -s https://install.crowdsec.net | sh >/dev/null 2>&1 || log_warn "Репозиторий CrowdSec недоступен, используем пакеты Ubuntu 24.04..."
safe_apt_update
apt-get install -y -qq crowdsec crowdsec-firewall-bouncer-nftables

cscli collections install crowdsecurity/linux crowdsecurity/sshd crowdsecurity/nginx --force >/dev/null 2>&1 || true

mkdir -p /etc/crowdsec/acquis.d

# Гарантируем, что CrowdSec читает логи Nginx без дублирования
if grep -q "/var/log/nginx/access.log" /etc/crowdsec/acquis.yaml 2>/dev/null; then
    rm -f /etc/crowdsec/acquis.d/nginx.yaml
else
    cat <<'EOF' > /etc/crowdsec/acquis.d/nginx.yaml
filenames:
  - /var/log/nginx/access.log
  - /var/log/nginx/error.log
labels:
  type: nginx
EOF
fi

# Гарантируем чтение логов sshd из systemd journal на Ubuntu 24.04 (если нет /var/log/auth.log)
if [[ ! -f /var/log/auth.log ]] && ! grep -rq "_SYSTEMD_UNIT=ssh.service" /etc/crowdsec/acquis* 2>/dev/null; then
    cat <<'EOF' > /etc/crowdsec/acquis.d/sshd-journal.yaml
source: journalctl
journalctl_filter:
  - "_SYSTEMD_UNIT=ssh.service"
labels:
  type: syslog
EOF
fi

# Запускаем CrowdSec LAPI до регистрации баунсера, чтобы избежать гонки запуска
systemctl enable --now crowdsec
for _ in $(seq 1 10); do
    cscli bouncers list >/dev/null 2>&1 && break
    sleep 1
done

# Удаляем автосозданные и старые firewall-баунсеры, чтобы не оставлять дубликаты
for OLD_B in $(cscli bouncers list -o json 2>/dev/null | jq -r '.[].name // empty' 2>/dev/null || true); do
    if [[ "$OLD_B" == "firewall-bouncer" || "$OLD_B" == cs-firewall-bouncer* ]]; then
        cscli bouncers delete "$OLD_B" >/dev/null 2>&1 || true
    fi
done

BOUNCER_KEY=$(cscli bouncers add firewall-bouncer -o raw)
rm -f /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.local
sed -i "s|^api_key:.*|api_key: ${BOUNCER_KEY}|" /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
sed -i "s|^mode:.*|mode: nftables|" /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml

systemctl enable --now crowdsec-firewall-bouncer
systemctl restart crowdsec crowdsec-firewall-bouncer

# 13. Подготовка генератора объединённой блокировки C24Be + CyberOK Skipa в nftables (с защитой SSH и белым списком IP)
log_info "Подготовка модуля блокировки сканеров (C24Be AS_Network_List + CyberOK Skipa)..."
mkdir -p /etc/nftables.d
touch /etc/nftables.d/whitelist_ips.txt
if [[ -n "$ADMIN_SSH_IP" ]]; then
    echo "$ADMIN_SSH_IP" >> /etc/nftables.d/whitelist_ips.txt
    sort -u /etc/nftables.d/whitelist_ips.txt -o /etc/nftables.d/whitelist_ips.txt
fi

cat <<EOF > /usr/local/sbin/update-scanners-blocklist.sh
#!/usr/bin/env python3
import os
import re
import ipaddress
import urllib.request
import subprocess

NFT_FILE = "/etc/nftables.d/scanners_block.nft"
WL_FILE = "/etc/nftables.d/whitelist_ips.txt"
SSH_PORT = ${SSH_PORT}
os.makedirs("/etc/nftables.d", exist_ok=True)

sources = {
    "C24Be_AS_Network_List": [
        "https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists/blacklist-v4.txt"
    ],
    "CyberOK_Skipa_ips": [
        "https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/main/lists/skipa_cidr.txt",
        "https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/main/lists/skipa_ips.txt"
    ]
}

valid_nets = set()
stats = {}

for name, urls in sources.items():
    raw_lines = []
    for u in urls:
        try:
            req = urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=20) as resp:
                text = resp.read().decode("utf-8", errors="ignore")
                for line in text.splitlines():
                    clean_line = line.split("#", 1)[0].strip()
                    if clean_line:
                        raw_lines.append(clean_line)
        except Exception:
            pass

    cleaned_text = "\\n".join(raw_lines)
    candidates = re.findall(r'\\b(?:\\d{1,3}\\.){3}\\d{1,3}(?:/\\d{1,2})?\\b', cleaned_text)
    source_nets = set()
    for item in candidates:
        try:
            net = ipaddress.ip_network(item, strict=False)
            if net.version == 4 and net.is_global and net.prefixlen >= 8:
                source_nets.add(net)
        except ValueError:
            continue
    stats[name] = len(source_nets)
    valid_nets.update(source_nets)

if len(valid_nets) < 100:
    raise SystemExit(f"Error: too few valid CIDRs fetched ({len(valid_nets)}), aborting update.")

collapsed = list(ipaddress.collapse_addresses(sorted(valid_nets)))
elements = ",\\n        ".join(str(net) for net in collapsed)

wl_ips = set()
if os.path.exists(WL_FILE):
    with open(WL_FILE, "r", encoding="utf-8") as wf:
        for line in wf:
            line = line.split("#", 1)[0].strip()
            try:
                ip = ipaddress.ip_address(line)
                if ip.version == 4:
                    wl_ips.add(str(ip))
            except ValueError:
                pass

wl_rule = ""
if wl_ips:
    wl_elems = ", ".join(sorted(wl_ips))
    wl_rule = f"        ip saddr {{ {wl_elems} }} accept\\n"

nft_config = f"""# Sources: C24Be={stats.get('C24Be_AS_Network_List', 0)}, CyberOK={stats.get('CyberOK_Skipa_ips', 0)}, Collapsed={len(collapsed)}
table inet scanners_block
delete table inet scanners_block

table inet scanners_block {{
    set scanners_v4 {{
        type ipv4_addr
        flags interval
        elements = {{
        {elements}
        }}
    }}

    chain prerouting {{
        type filter hook prerouting priority -150; policy accept;
        ct state established,related accept
        tcp dport {SSH_PORT} accept
{wl_rule}        ip saddr @scanners_v4 counter drop
    }}
}}
"""

with open(NFT_FILE, "w", encoding="utf-8") as f:
    f.write(nft_config)

subprocess.run(["/usr/sbin/nft", "-f", NFT_FILE], check=True)
print(f"OK: Loaded {len(collapsed)} collapsed IPv4 CIDRs (C24Be: {stats.get('C24Be_AS_Network_List', 0)}, CyberOK: {stats.get('CyberOK_Skipa_ips', 0)})")
EOF
chmod +x /usr/local/sbin/update-scanners-blocklist.sh

cat <<'EOF' > /etc/systemd/system/scanners-blocklist.service
[Unit]
Description=Apply C24Be AS_Network_List & CyberOK Skipa nftables blocklist
After=network-online.target nftables.service ufw.service
Wants=network-online.target
PartOf=nftables.service ufw.service

[Service]
Type=oneshot
ExecStartPre=/bin/sh -c '[ -s /etc/nftables.d/scanners_block.nft ] || /usr/local/sbin/update-scanners-blocklist.sh'
ExecStart=/usr/sbin/nft -f /etc/nftables.d/scanners_block.nft
ExecReload=/usr/sbin/nft -f /etc/nftables.d/scanners_block.nft
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target nftables.service ufw.service
EOF
systemctl daemon-reload

if [[ "$ENABLE_SCANNERS_BLOCK" =~ ^[Yy]$ ]]; then
    log_info "Загрузка и применение списков C24Be + CyberOK Skipa в nftables..."
    if /usr/local/sbin/update-scanners-blocklist.sh; then
        systemctl enable --now scanners-blocklist.service >/dev/null
        cat <<'CRON_EOF' > /etc/cron.d/scanners-blocklist
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 4 * * * root /usr/local/sbin/update-scanners-blocklist.sh >/dev/null 2>&1
CRON_EOF
        chmod 644 /etc/cron.d/scanners-blocklist
        log_ok "Объединённая блокировка C24Be + CyberOK Skipa активирована."
    else
        log_warn "Не удалось загрузить списки сканеров (проверьте связь с GitHub). Позже выполните: my3xui blocklist install"
    fi
fi

# 14. Установка CLI-утилиты my3xui (/usr/local/bin/my3xui)
log_info "Установка CLI-утилиты управления my3xui..."
cat <<'EOF' > /usr/local/bin/my3xui
#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}Запустите команду от имени root: sudo my3xui${NC}"; exit 1; }

show_status() {
    echo -e "\n${BOLD}${CYAN}=== СТАТУС СЕРВИСОВ И SSL ===${NC}"
    for svc in x-ui nginx fail2ban crowdsec crowdsec-firewall-bouncer scanners-blocklist; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            printf "  • %-28s ${GREEN}active${NC}\n" "${svc}:"
        elif systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
            printf "  • %-28s ${YELLOW}inactive${NC}\n" "${svc}:"
        else
            printf "  • %-28s ${RED}not installed${NC}\n" "${svc}:"
        fi
    done

    CERT_FILE=$(find /root/cert -maxdepth 2 -name fullchain.pem 2>/dev/null | head -n 1 || true)
    if [[ -n "$CERT_FILE" && -f "$CERT_FILE" ]]; then
        EXP_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$EXP_DATE" ]]; then
            EXP_EPOCH=$(date -d "$EXP_DATE" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$(date +%s)
            DAYS_LEFT=$(( (EXP_EPOCH - NOW_EPOCH) / 86400 ))
            if [[ "$DAYS_LEFT" -le 14 ]]; then
                COLOR="$RED"
            elif [[ "$DAYS_LEFT" -le 30 ]]; then
                COLOR="$YELLOW"
            else
                COLOR="$GREEN"
            fi
            echo -e "  • ${BOLD}SSL-сертификат:${NC}             ${COLOR}осталось ${DAYS_LEFT} дн.${NC} (до ${EXP_DATE})"
        fi
    else
        echo -e "  • ${BOLD}SSL-сертификат:${NC}             ${YELLOW}не найден в /root/cert${NC}"
    fi
    echo ""
}

show_sysinfo() {
    echo -e "\n${BOLD}${CYAN}=== ИНФОРМАЦИЯ О СИСТЕМЕ ===${NC}"
    CPU_MODEL=$(awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)
    CPU_CORES=$(nproc)
    CPU_MHZ=$(awk -F: '/cpu MHz/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]]; then
        CUR_KHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
        CPU_FREQ="$(awk "BEGIN {printf \"%.0f MHz\", ${CUR_KHZ}/1000}")"
    else
        CPU_FREQ="${CPU_MHZ:-N/A} MHz"
    fi

    MEM_INFO=$(free -h | awk '/^Mem:/ {print $3 " / " $2 " (доступно: " $7 ")"}')
    SWAP_INFO=$(free -h | awk '/^Swap:/ {print $3 " / " $2}')
    ROOT_USAGE=$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')

    echo -e "  • ${BOLD}Процессор:${NC}      ${CPU_MODEL:-Unknown} (${CPU_CORES} vCPU @ ${CPU_FREQ})"
    echo -e "  • ${BOLD}Оперативная пам.:${NC} ${MEM_INFO}"
    echo -e "  • ${BOLD}Swap:${NC}           ${SWAP_INFO}"
    echo -e "  • ${BOLD}Корень (/):${NC}     ${ROOT_USAGE}"
    echo -e "  • ${BOLD}Диски:${NC}"
    lsblk -d -n -o NAME,SIZE | while read -r DEV_NAME DEV_SIZE; do
        [[ -z "$DEV_NAME" || "$DEV_NAME" =~ ^(loop|ram|sr|fd|zram) ]] && continue
        ROTA=$(cat "/sys/block/${DEV_NAME}/queue/rotational" 2>/dev/null || echo "1")
        DISC=$(cat "/sys/block/${DEV_NAME}/queue/discard_max_bytes" 2>/dev/null || echo "0")
        MODEL=$(cat "/sys/block/${DEV_NAME}/device/model" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//' || true)
        TRAN=$(lsblk -d -n -o TRAN "/dev/${DEV_NAME}" 2>/dev/null | xargs || true)

        if [[ "$DEV_NAME" == nvme* || "$TRAN" == "nvme" || "${MODEL,,}" == *nvme* ]]; then
            DISK_TYPE="NVMe SSD"
        elif [[ "$ROTA" == "0" ]]; then
            DISK_TYPE="SSD"
        elif [[ "$DEV_NAME" == vd* || "${DISC:-0}" -gt 0 || "${MODEL,,}" == *ssd* || "${MODEL,,}" == *qemu* || "${MODEL,,}" == *virtio* ]]; then
            DISK_TYPE="SSD / NVMe (Virtual)"
        else
            DISK_TYPE="HDD"
        fi
        [[ -n "$MODEL" ]] && DISK_TYPE="${DISK_TYPE} (${MODEL})"

        MOUNTS=$(lsblk -ln -o MOUNTPOINT "/dev/${DEV_NAME}" 2>/dev/null | awk 'NF && $1 != "[SWAP]"' | paste -sd, - || true)
        if [[ -n "$MOUNTS" ]]; then
            echo -e "      - /dev/${DEV_NAME}: ${BOLD}${DEV_SIZE}${NC} [${DISK_TYPE}] — точки монтирования: ${MOUNTS}"
        else
            echo -e "      - /dev/${DEV_NAME}: ${BOLD}${DEV_SIZE}${NC} [${DISK_TYPE}]"
        fi
    done
    echo ""
}

show_creds() {
    echo -e "\n${BOLD}${CYAN}=== ДАННЫЕ ДЛЯ ВХОДА В ПАНЕЛЬ 3X-UI ===${NC}"
    python3 - <<'DBEOF'
import sqlite3, urllib.parse, os

db_path = "/etc/x-ui/x-ui.db"
if not os.path.exists(db_path):
    print("База данных /etc/x-ui/x-ui.db не найдена.")
    raise SystemExit(1)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

user, pwd_hash = cur.execute("SELECT username, password FROM users LIMIT 1").fetchone()
settings = dict(cur.execute("SELECT key, value FROM settings").fetchall())

web_path = settings.get("webBasePath", "/")
sub_uri = settings.get("subURI", "")
domain = urllib.parse.urlparse(sub_uri).hostname
if not domain:
    cert_file = settings.get("webCertFile", "")
    parts = cert_file.split("/")
    domain = parts[3] if len(parts) > 3 and parts[2] == "cert" else "localhost"

plain_pwd = None
if os.path.exists("/root/vps-credentials.txt"):
    with open("/root/vps-credentials.txt", "r", encoding="utf-8") as cf:
        lines = cf.readlines()
    file_user = None
    file_pwd = None
    for line in lines:
        if line.strip().startswith("Логин:"):
            file_user = line.split(":", 1)[1].strip()
        elif line.strip().startswith("Пароль:"):
            file_pwd = line.split(":", 1)[1].strip()
    if file_user == user and file_pwd and not file_pwd.startswith("$2"):
        plain_pwd = file_pwd

print(f"  Ссылка на панель 3x-ui:  https://{domain}{web_path}")
print(f"  Логин:                   {user}")
if plain_pwd:
    print(f"  Пароль:                  {plain_pwd}")
else:
    print("  Пароль:                  [зашифрован bcrypt в БД] (сброс: /usr/local/x-ui/x-ui setting -password НОВЫЙ_ПАРОЛЬ)")

print("\n  Созданные инбаунды (пользователи добавляются вручную в панели):")
for remark, port, tag in cur.execute("SELECT remark, port, tag FROM inbounds WHERE enable = 1"):
    extra = " [при добавлении клиента выберите Flow: xtls-rprx-vision]" if tag == "inbound-reality" else ""
    print(f"    • {remark} (локальный порт 127.0.0.1:{port} -> внешний 443){extra}")

conn.close()
DBEOF
    echo ""
}

sync_f2b_whitelist() {
    local wl_file="/etc/nftables.d/whitelist_ips.txt"
    local jail_file="/etc/fail2ban/jail.local"
    [[ ! -f "$jail_file" ]] && return 0
    local ips=""
    if [[ -f "$wl_file" ]]; then
        ips=$(grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$wl_file" | sort -u | paste -sd' ' - || true)
    fi
    local ignore_line="ignoreip = 127.0.0.1/8 ::1${ips:+ ${ips}}"
    if grep -q '^ignoreip =' "$jail_file"; then
        sed -i "s|^ignoreip =.*|${ignore_line}|" "$jail_file"
    else
        sed -i "/^\[DEFAULT\]/a ${ignore_line}" "$jail_file"
    fi
    systemctl reload fail2ban >/dev/null 2>&1 || systemctl restart fail2ban >/dev/null 2>&1 || true
}

manage_whitelist() {
    local wl_file="/etc/nftables.d/whitelist_ips.txt"
    mkdir -p /etc/nftables.d
    touch "$wl_file"
    local action="${1:-}"
    local target_ip="${2:-}"

    case "$action" in
        list)
            echo -e "\n${BOLD}${CYAN}=== БЕЛЫЙ СПИСОК IP (nftables + Fail2Ban) ===${NC}"
            if [[ -s "$wl_file" ]]; then
                nl -ba "$wl_file"
            else
                echo "  Список пуст."
            fi
            echo ""
            ;;
        add)
            [[ -z "$target_ip" ]] && read -erp "Введите IPv4 для добавления в белый список: " target_ip
            if ! [[ "$target_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                echo -e "${RED}Некорректный IPv4-адрес.${NC}"
                return 1
            fi
            echo "$target_ip" >> "$wl_file"
            sort -u "$wl_file" -o "$wl_file"
            sync_f2b_whitelist
            if /usr/sbin/nft list table inet scanners_block &>/dev/null; then
                /usr/local/sbin/update-scanners-blocklist.sh >/dev/null 2>&1 || true
            fi
            echo -e "${GREEN}[OK] IP ${target_ip} добавлен в белый список (nftables + Fail2Ban).${NC}"
            ;;
        del|remove)
            [[ -z "$target_ip" ]] && read -erp "Введите IPv4 для удаления из белого списка: " target_ip
            grep -vxF "$target_ip" "$wl_file" > "${wl_file}.tmp" || true
            mv "${wl_file}.tmp" "$wl_file"
            sync_f2b_whitelist
            if /usr/sbin/nft list table inet scanners_block &>/dev/null; then
                /usr/local/sbin/update-scanners-blocklist.sh >/dev/null 2>&1 || true
            fi
            echo -e "${GREEN}[OK] IP ${target_ip} удалён из белого списка.${NC}"
            ;;
        *)
            while true; do
                echo -e "\n${BOLD}${CYAN}=== БЕЛЫЙ СПИСОК IP (nftables + Fail2Ban) ===${NC}"
                if [[ -s "$wl_file" ]]; then
                    sed 's/^/  • /' "$wl_file"
                else
                    echo "  (пусто)"
                fi
                echo ""
                echo "  1. Добавить IPv4 в белый список"
                echo "  2. Удалить IPv4 из белого списка"
                echo "  0. Назад в главное меню"
                echo ""
                read -erp "Выберите действие [0-2]: " WL_CHOICE
                case "$WL_CHOICE" in
                    1) manage_whitelist add ;;
                    2) manage_whitelist del ;;
                    0) break ;;
                    *) echo -e "${RED}Неверный выбор.${NC}" ;;
                esac
            done
            ;;
    esac
}

create_backup() {
    local bdir="/root/backups"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local archive="${bdir}/my3xui-backup-${ts}.tar.gz"
    mkdir -p "$bdir"
    local files=()
    for f in /etc/x-ui/x-ui.db /etc/nginx/nginx.conf /etc/fail2ban/jail.local /etc/nftables.d/whitelist_ips.txt /root/vps-credentials.txt; do
        [[ -f "$f" ]] && files+=("$f")
    done
    if [[ ${#files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Файлы для резервного копирования не найдены.${NC}"
        return 1
    fi
    tar -czf "$archive" "${files[@]}" 2>/dev/null
    chmod 600 "$archive"
    echo -e "${GREEN}[OK] Бэкап создан: ${archive}${NC}"
}

restore_backup() {
    local bdir="/root/backups"
    local archive="${1:-}"

    if [[ -n "$archive" ]]; then
        if [[ ! -f "$archive" && -f "${bdir}/${archive}" ]]; then
            archive="${bdir}/${archive}"
        fi
        if [[ ! -f "$archive" ]]; then
            echo -e "${RED}[ERROR] Файл бэкапа не найден: ${archive}${NC}"
            return 1
        fi
    else
        mapfile -t archives < <(ls -1t "${bdir}"/my3xui-backup-*.tar.gz 2>/dev/null || true)
        if [[ ${#archives[@]} -eq 0 ]]; then
            echo -e "${YELLOW}Резервные копии в ${bdir} не найдены.${NC}"
            return 1
        fi

        echo -e "\n${BOLD}${CYAN}=== ВОССТАНОВЛЕНИЕ ИЗ РЕЗЕРВНОЙ КОПИИ ===${NC}"
        local i=1
        for a in "${archives[@]}"; do
            local sz dt
            sz=$(du -h "$a" 2>/dev/null | awk '{print $1}')
            dt=$(date -r "$a" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
            printf "  %d. %s (%s, %s)\n" "$i" "$(basename "$a")" "${sz:-?}" "${dt:-?}"
            ((i++))
        done
        echo "  0. Отмена"
        echo ""
        read -erp "Выберите номер бэкапа [0-${#archives[@]}]: " b_choice
        if [[ "$b_choice" == "0" || -z "$b_choice" ]]; then
            echo "Отменено."
            return 0
        fi
        if ! [[ "$b_choice" =~ ^[0-9]+$ ]] || [[ "$b_choice" -lt 1 || "$b_choice" -gt ${#archives[@]} ]]; then
            echo -e "${RED}Неверный выбор.${NC}"
            return 1
        fi
        archive="${archives[$((b_choice - 1))]}"
    fi

    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] Архив повреждён или не является корректным .tar.gz: ${archive}${NC}"
        return 1
    fi

    echo -e "\nВыбран архив: ${BOLD}${archive}${NC}"
    echo "  1. Полное восстановление (БД 3x-ui, Nginx, Fail2Ban, белый список, учётные данные)"
    echo "  2. Восстановить только базу данных 3x-ui (/etc/x-ui/x-ui.db)"
    echo "  0. Отмена"
    read -erp "Режим восстановления [1]: " r_mode
    r_mode=${r_mode:-1}
    case "$r_mode" in
        0) echo "Отменено."; return 0 ;;
        1|2) ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; return 1 ;;
    esac

    read -erp "Подтвердить восстановление из $(basename "$archive")? [y/N]: " r_confirm
    if [[ ! "$r_confirm" =~ ^[Yy]$ ]]; then
        echo "Отменено."
        return 0
    fi

    if [[ "$r_mode" == "2" ]]; then
        echo -e "${CYAN}[INFO] Остановка x-ui и восстановление /etc/x-ui/x-ui.db...${NC}"
        systemctl stop x-ui 2>/dev/null || true
        if ! tar -xzf "$archive" -C / etc/x-ui/x-ui.db 2>/dev/null; then
            systemctl start x-ui 2>/dev/null || true
            echo -e "${RED}[ERROR] Файл etc/x-ui/x-ui.db не найден в архиве или ошибка распаковки.${NC}"
            return 1
        fi
        rm -f /usr/local/x-ui/bin/config.json
        systemctl start x-ui
        echo -e "${GREEN}[OK] База данных 3x-ui восстановлена, сервис x-ui перезапущен.${NC}"
    else
        echo -e "${CYAN}[INFO] Остановка x-ui, nginx, fail2ban и полное восстановление...${NC}"
        systemctl stop x-ui nginx fail2ban 2>/dev/null || true
        tar -xzf "$archive" -C /
        rm -f /usr/local/x-ui/bin/config.json
        if nginx -t >/dev/null 2>&1; then
            systemctl start x-ui nginx fail2ban
            if /usr/sbin/nft list table inet scanners_block &>/dev/null; then
                /usr/local/sbin/update-scanners-blocklist.sh >/dev/null 2>&1 || true
            fi
            echo -e "${GREEN}[OK] Полное восстановление завершено, сервисы запущены.${NC}"
        else
            systemctl start x-ui fail2ban 2>/dev/null || true
            echo -e "${RED}[WARN] Архив распакован, но nginx -t вернул ошибку! Проверьте /etc/nginx/nginx.conf.${NC}"
            nginx -t || true
            return 1
        fi
    fi
}

blocklist_status() {
    if /usr/sbin/nft list table inet scanners_block &>/dev/null; then
        PKTS=$(/usr/sbin/nft list chain inet scanners_block prerouting 2>/dev/null | grep -oE 'packets [0-9]+' | tail -n 1 || echo "packets 0")
        META=$(head -n 1 /etc/nftables.d/scanners_block.nft 2>/dev/null | sed 's/^# //' || echo "active")
        echo -e "  • ${BOLD}Статус nftables:${NC} ${GREEN}активен${NC} (${PKTS} отброшено)"
        echo -e "  • ${BOLD}Списки (C24Be + CyberOK + Collapsed):${NC} ${META}"
    else
        echo -e "  • ${BOLD}Статус nftables:${NC} ${YELLOW}не установлен / отключен${NC}"
    fi
}

blocklist_install() {
    echo -e "${CYAN}[INFO] Загрузка и установка списков C24Be + CyberOK Skipa (сжатие Collapsed)...${NC}"
    CURRENT_IP=$(awk '{print $1}' <<< "${SSH_CONNECTION:-}" 2>/dev/null || true)
    if [[ -n "$CURRENT_IP" ]]; then
        mkdir -p /etc/nftables.d
        echo "$CURRENT_IP" >> /etc/nftables.d/whitelist_ips.txt
        sort -u /etc/nftables.d/whitelist_ips.txt -o /etc/nftables.d/whitelist_ips.txt
    fi
    /usr/local/sbin/update-scanners-blocklist.sh
    systemctl enable --now scanners-blocklist.service >/dev/null 2>&1 || true
    cat <<'CRON_EOF' > /etc/cron.d/scanners-blocklist
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 4 * * * root /usr/local/sbin/update-scanners-blocklist.sh >/dev/null 2>&1
CRON_EOF
    chmod 644 /etc/cron.d/scanners-blocklist
    echo -e "${GREEN}[OK] Блокировка C24Be + CyberOK + Collapsed установлена, автообновление в cron (04:15) включено.${NC}"
}

blocklist_update() {
    echo -e "${CYAN}[INFO] Обновление списков C24Be + CyberOK Skipa...${NC}"
    CURRENT_IP=$(awk '{print $1}' <<< "${SSH_CONNECTION:-}" 2>/dev/null || true)
    if [[ -n "$CURRENT_IP" ]]; then
        mkdir -p /etc/nftables.d
        echo "$CURRENT_IP" >> /etc/nftables.d/whitelist_ips.txt
        sort -u /etc/nftables.d/whitelist_ips.txt -o /etc/nftables.d/whitelist_ips.txt
    fi
    /usr/local/sbin/update-scanners-blocklist.sh
    systemctl start scanners-blocklist.service >/dev/null 2>&1 || true
    echo -e "${GREEN}[OK] Списки успешно обновлены и применены в nftables.${NC}"
}

blocklist_remove() {
    echo -e "${YELLOW}[INFO] Удаление блокировки C24Be + CyberOK из nftables...${NC}"
    systemctl stop scanners-blocklist.service skipa-blocklist.service 2>/dev/null || true
    systemctl disable scanners-blocklist.service skipa-blocklist.service 2>/dev/null || true
    /usr/sbin/nft delete table inet scanners_block 2>/dev/null || true
    /usr/sbin/nft delete table inet skipa_block 2>/dev/null || true
    rm -f /etc/nftables.d/scanners_block.nft /etc/cron.d/scanners-blocklist \
          /etc/nftables.d/skipa_block.nft /etc/cron.d/skipa-blocklist
    echo -e "${GREEN}[OK] Блокировка сканеров полностью удалена из nftables и автозагрузки.${NC}"
}

manage_blocklist() {
    case "${1:-}" in
        install) blocklist_install ;;
        update)  blocklist_update ;;
        remove)  blocklist_remove ;;
        status)  echo ""; blocklist_status; echo "" ;;
        *)
            while true; do
                echo -e "\n${BOLD}${CYAN}=== БЛОКИРОВКА СКАНЕРОВ (C24Be + CyberOK + Collapsed) ===${NC}"
                blocklist_status
                echo ""
                echo "  1. Установить / включить блокировку (nftables + cron)"
                echo "  2. Обновить списки C24Be и CyberOK прямо сейчас"
                echo "  3. Удалить / отключить блокировку"
                echo "  0. Назад в главное меню"
                echo ""
                read -erp "Выберите действие [0-3]: " BL_CHOICE
                case "$BL_CHOICE" in
                    1) blocklist_install ;;
                    2) blocklist_update ;;
                    3) blocklist_remove ;;
                    0) break ;;
                    *) echo -e "${RED}Неверный выбор.${NC}" ;;
                esac
            done
            ;;
    esac
}

show_crowdsec() {
    echo -e "\n${BOLD}${CYAN}=== СОСТОЯНИЕ CROWDSEC И БЛОКИРОВОК ===${NC}"
    echo -e "${BOLD}1. Активные решения CrowdSec (cscli decisions list):${NC}"
    cscli decisions list || true
    echo -e "\n${BOLD}2. Статус баунсеров (cscli bouncers list):${NC}"
    cscli bouncers list || true
    echo -e "\n${BOLD}3. Блокировка сканеров (C24Be + CyberOK + Collapsed):${NC}"
    blocklist_status
    echo ""
}

recreate_inbounds_exec() {
    local mode="${1:-restore}"
    if [[ ! -f /etc/x-ui/x-ui.db ]]; then
        echo -e "${RED}[ERROR] База данных /etc/x-ui/x-ui.db не найдена.${NC}"
        return 1
    fi
    if [[ ! -f /etc/nginx/nginx.conf ]]; then
        echo -e "${RED}[ERROR] Конфиг /etc/nginx/nginx.conf не найден — невозможно определить пути XHTTP.${NC}"
        return 1
    fi

    echo -e "${CYAN}[INFO] Создание автоматического бэкапа перед изменением инбаундов...${NC}"
    create_backup || true

    echo -e "${CYAN}[INFO] Остановка x-ui и пересоздание инбаундов (режим: ${mode})...${NC}"
    systemctl stop x-ui 2>/dev/null || true

    if ! RECREATE_MODE="${mode}" python3 - <<'IBEOF'
import sqlite3, json, urllib.request, urllib.parse, os, re, glob, subprocess, base64, secrets

mode = os.environ.get("RECREATE_MODE", "restore")
db_path = "/etc/x-ui/x-ui.db"
nginx_conf_path = "/etc/nginx/nginx.conf"
bin_dir = "/usr/local/x-ui/bin"

def detect_server_country():
    country_names_ru = {
        "NL": "Нидерланды", "DE": "Германия", "FR": "Франция", "FI": "Финляндия",
        "SE": "Швеция", "NO": "Норвегия", "DK": "Дания", "GB": "Великобритания",
        "UK": "Великобритания", "IE": "Ирландия", "PL": "Польша", "CZ": "Чехия",
        "AT": "Австрия", "CH": "Швейцария", "BE": "Бельгия", "LU": "Люксембург",
        "ES": "Испания", "IT": "Италия", "PT": "Португалия", "GR": "Греция",
        "BG": "Болгария", "RO": "Румыния", "HU": "Венгрия", "SK": "Словакия",
        "SI": "Словения", "HR": "Хорватия", "RS": "Сербия", "EE": "Эстония",
        "LV": "Латвия", "LT": "Литва", "MD": "Молдова", "UA": "Украина",
        "BY": "Беларусь", "RU": "Россия", "KZ": "Казахстан", "AM": "Армения",
        "GE": "Грузия", "AZ": "Азербайджан", "UZ": "Узбекистан", "TR": "Турция",
        "AE": "ОАЭ", "IL": "Израиль", "CY": "Кипр", "US": "США", "CA": "Канада",
        "BR": "Бразилия", "AR": "Аргентина", "CL": "Чили", "JP": "Япония",
        "KR": "Южная Корея", "SG": "Сингапур", "HK": "Гонконг", "TW": "Тайвань",
        "IN": "Индия", "AU": "Австралия", "NZ": "Новая Зеландия", "ZA": "ЮАР"
    }
    ip = ""
    for ip_url in ("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com"):
        try:
            req = urllib.request.Request(ip_url, headers={"User-Agent": "curl/8.0"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                ip = resp.read().decode("utf-8").strip()
                if ip:
                    break
        except Exception:
            pass
    code, fallback_name = "", ""
    if ip:
        try:
            req = urllib.request.Request(f"http://ip-api.com/json/{ip}?fields=status,country,countryCode", headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=6) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if data.get("status") == "success":
                    code = (data.get("countryCode") or "").upper()
                    fallback_name = data.get("country") or ""
        except Exception:
            pass
    if not code:
        try:
            url = f"https://ipinfo.io/{ip}/json" if ip else "https://ipinfo.io/json"
            req = urllib.request.Request(url, headers={"User-Agent": "curl/8.0"})
            with urllib.request.urlopen(req, timeout=6) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                code = (data.get("country") or "").upper()
        except Exception:
            pass
    if len(code) == 2 and code.isalpha():
        flag = "".join(chr(0x1F1E6 + ord(c) - ord("A")) for c in code)
        name = country_names_ru.get(code) or fallback_name or code
        return f"{flag} {name}"
    return "🌐 Сервер"

def generate_x25519_keys(bdir):
    priv_key, pub_key = "", ""
    for xbin in sorted(glob.glob(os.path.join(bdir, "xray*"))):
        if os.path.isfile(xbin) and os.access(xbin, os.X_OK):
            try:
                out = subprocess.check_output([xbin, "x25519"], text=True, timeout=5)
                for line in out.splitlines():
                    if ":" not in line:
                        continue
                    k, v = [p.strip() for p in line.split(":", 1)]
                    kl = k.lower()
                    if "private" in kl:
                        priv_key = v
                    elif "public" in kl or "password" in kl:
                        pub_key = v
                if priv_key and pub_key:
                    return priv_key, pub_key
            except Exception:
                pass
    pem = subprocess.check_output(["openssl", "genpkey", "-algorithm", "X25519"])
    der_priv = subprocess.check_output(["openssl", "pkey", "-outform", "DER"], input=pem)
    der_pub = subprocess.check_output(["openssl", "pkey", "-pubout", "-outform", "DER"], input=pem)
    priv_key = base64.urlsafe_b64encode(der_priv[-32:]).decode().rstrip("=")
    pub_key = base64.urlsafe_b64encode(der_pub[-32:]).decode().rstrip("=")
    return priv_key, pub_key

with open(nginx_conf_path, "r", encoding="utf-8") as nf:
    nginx_conf = nf.read()

m_up = re.search(r"location\s+\^~\s+(/[^/\s][^\s{;]*)\s*\{[^}]*proxy_pass\s+http://xray_xhttp_up;", nginx_conf, re.S)
m_one = re.search(r"location\s+\^~\s+(/[^/\s][^\s{;]*)\s*\{[^}]*grpc_pass\s+grpc://xray_xhttp_one;", nginx_conf, re.S)
if not m_up or not m_one:
    raise SystemExit("Не удалось извлечь пути XHTTP (xray_xhttp_up / xray_xhttp_one) из /etc/nginx/nginx.conf.")

xhttp_up_path = m_up.group(1)
xhttp_one_path = m_one.group(1)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

settings = dict(cur.execute("SELECT key, value FROM settings").fetchall())
domain = urllib.parse.urlparse(settings.get("subURI", "")).hostname
if not domain:
    cert_file = settings.get("webCertFile", "")
    parts = cert_file.split("/")
    domain = parts[3] if len(parts) > 3 and parts[2] == "cert" else ""
if not domain:
    m_dom = re.search(r"server_name\s+([a-zA-Z0-9.-]+\.[a-zA-Z0-9.-]+)\s*;", nginx_conf)
    domain = m_dom.group(1) if m_dom else ""
if not domain:
    conn.close()
    raise SystemExit("Не удалось определить домен сервера из БД 3x-ui или nginx.conf.")

user_row = cur.execute("SELECT id FROM users LIMIT 1").fetchone()
user_id = user_row[0] if user_row else 1

base_remark = detect_server_country()
reality_priv_key, reality_pub_key = generate_x25519_keys(bin_dir)
reality_short_ids = [secrets.token_hex(2), secrets.token_hex(4), secrets.token_hex(6), secrets.token_hex(8)]

browser_headers = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
    "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7"
}
default_allocate = json.dumps({"strategy": "always", "refresh": 5, "concurrency": 3})
default_sniffing = json.dumps({
    "enabled": True,
    "destOverride": ["http", "tls", "quic", "fakedns"],
    "metadataOnly": False,
    "routeOnly": False
})

inbounds = [
    {
        "user_id": user_id,
        "up": 0, "down": 0, "total": 0,
        "remark": f"{base_remark} - Мобилы",
        "enable": 1, "expiry_time": 0,
        "listen": "127.0.0.1", "port": 11443,
        "protocol": "vless",
        "settings": json.dumps({"clients": [], "decryption": "none", "fallbacks": []}),
        "stream_settings": json.dumps({
            "network": "xhttp", "security": "none",
            "externalProxy": [{"forceTls": "tls", "dest": domain, "port": 443, "remark": ""}],
            "xhttpSettings": {
                "path": xhttp_up_path, "host": domain, "mode": "packet-up",
                "noGRPCHeader": True, "xPaddingBytes": "100-1000",
                "scMaxEachPostBytes": "500000-1000000", "scMinPostsIntervalMs": "10-50",
                "scMaxBufferedPosts": 30, "scStreamUpServerSecs": "20-80",
                "headers": browser_headers
            }
        }),
        "tag": "inbound-xhttp-up",
        "sniffing": default_sniffing, "allocate": default_allocate
    },
    {
        "user_id": user_id,
        "up": 0, "down": 0, "total": 0,
        "remark": f"{base_remark} - Домашний",
        "enable": 1, "expiry_time": 0,
        "listen": "127.0.0.1", "port": 7443,
        "protocol": "vless",
        "settings": json.dumps({"clients": [], "decryption": "none", "fallbacks": []}),
        "stream_settings": json.dumps({
            "network": "xhttp", "security": "none",
            "externalProxy": [{"forceTls": "tls", "dest": domain, "port": 443, "remark": ""}],
            "xhttpSettings": {
                "path": xhttp_one_path, "host": domain, "mode": "stream-one",
                "noGRPCHeader": False, "xPaddingBytes": "100-1000",
                "headers": browser_headers
            }
        }),
        "tag": "inbound-xhttp-one",
        "sniffing": default_sniffing, "allocate": default_allocate
    },
    {
        "user_id": user_id,
        "up": 0, "down": 0, "total": 0,
        "remark": f"{base_remark} - Reality",
        "enable": 1, "expiry_time": 0,
        "listen": "127.0.0.1", "port": 9443,
        "protocol": "vless",
        "settings": json.dumps({"clients": [], "decryption": "none", "fallbacks": []}),
        "stream_settings": json.dumps({
            "network": "tcp", "security": "reality",
            "externalProxy": [{"forceTls": "same", "dest": domain, "port": 443, "remark": ""}],
            "realitySettings": {
                "show": False, "xver": 1, "target": "127.0.0.1:8443",
                "serverNames": [domain], "privateKey": reality_priv_key,
                "minClientVer": "", "maxClientVer": "", "maxTimediff": 0,
                "shortIds": reality_short_ids, "mldsa65Seed": "",
                "settings": {
                    "publicKey": reality_pub_key, "fingerprint": "chrome",
                    "serverName": "", "spiderX": "/", "mldsa65Verify": ""
                }
            },
            "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}}
        }),
        "tag": "inbound-reality",
        "sniffing": default_sniffing, "allocate": default_allocate
    }
]

extra_defaults = {
    "all_time": 0,
    "traffic_reset": "never",
    "last_traffic_reset_time": 0,
    "node_id": None
}
existing_cols = {row[1] for row in cur.execute("PRAGMA table_info(inbounds)").fetchall()}

if mode == "reset":
    for tbl in ("inbounds", "client_traffics", "client_inbounds", "clients"):
        try:
            cur.execute(f"DELETE FROM {tbl}")
        except sqlite3.OperationalError:
            pass
    created = 0
    for idx, ib in enumerate(inbounds, 1):
        merged_ib = {**extra_defaults, "id": idx, **ib}
        valid_ib = {k: v for k, v in merged_ib.items() if k in existing_cols}
        cols_sql = ", ".join(valid_ib.keys())
        vals_sql = ", ".join(f":{k}" for k in valid_ib.keys())
        cur.execute(f"INSERT INTO inbounds ({cols_sql}) VALUES ({vals_sql})", valid_ib)
        print(f"  + Создан: {ib['remark']} (127.0.0.1:{ib['port']})")
        created += 1
    print(f"Пересоздано инбаундов: {created} (домен: {domain}, XHTTP-пути сохранены из nginx.conf).")
else:
    existing_tags = {r[0] for r in cur.execute("SELECT tag FROM inbounds").fetchall()}
    existing_ports = {r[0] for r in cur.execute("SELECT port FROM inbounds").fetchall()}
    created = 0
    for ib in inbounds:
        if ib["tag"] in existing_tags or ib["port"] in existing_ports:
            print(f"  = Пропущен (уже существует): {ib['remark']} (порт {ib['port']})")
            continue
        merged_ib = {**extra_defaults, **ib}
        valid_ib = {k: v for k, v in merged_ib.items() if k in existing_cols}
        cols_sql = ", ".join(valid_ib.keys())
        vals_sql = ", ".join(f":{k}" for k in valid_ib.keys())
        cur.execute(f"INSERT INTO inbounds ({cols_sql}) VALUES ({vals_sql})", valid_ib)
        print(f"  + Восстановлен: {ib['remark']} (127.0.0.1:{ib['port']})")
        created += 1
    if created == 0:
        print("Все 3 стандартных инбаунда уже существуют — изменений не требуется.")
    else:
        print(f"Восстановлено инбаундов: {created} (домен: {domain}, XHTTP-пути синхронизированы с nginx.conf).")

conn.commit()
conn.close()
IBEOF
    then
        systemctl start x-ui 2>/dev/null || true
        echo -e "${RED}[ERROR] Не удалось пересоздать инбаунды. Сервис x-ui запущен обратно.${NC}"
        return 1
    fi

    rm -f /usr/local/x-ui/bin/config.json
    systemctl start x-ui
    echo -e "${GREEN}[OK] Сервис x-ui перезапущен с обновлёнными инбаундами.${NC}"
}

manage_inbounds() {
    case "${1:-}" in
        restore)
            recreate_inbounds_exec "restore"
            ;;
        reset)
            echo -e "${YELLOW}ВНИМАНИЕ: Все текущие инбаунды и клиенты в 3x-ui будут удалены и заменены 3 стандартными!${NC}"
            read -erp "Продолжить? Введите YES для подтверждения: " IB_CONFIRM
            [[ "$IB_CONFIRM" != "YES" ]] && { echo "Отменено."; return 0; }
            recreate_inbounds_exec "reset"
            ;;
        *)
            while true; do
                echo -e "\n${BOLD}${CYAN}=== УПРАВЛЕНИЕ СТАНДАРТНЫМИ ИНБАУНДАМИ 3X-UI ===${NC}"
                echo "  1. Восстановить только отсутствующие стандартные инбаунды (безопасно, не трогает существующих)"
                echo -e "  2. ${YELLOW}Полностью пересоздать все 3 инбаунда с нуля (удалит текущие инбаунды и клиентов)${NC}"
                echo "  0. Назад в главное меню"
                echo ""
                read -erp "Выберите действие [0-2]: " IB_CHOICE
                case "$IB_CHOICE" in
                    1) recreate_inbounds_exec "restore" ;;
                    2)
                        echo -e "${YELLOW}ВНИМАНИЕ: Все текущие инбаунды и клиенты в 3x-ui будут удалены!${NC}"
                        read -erp "Продолжить? Введите YES для подтверждения: " IB_CONFIRM
                        [[ "$IB_CONFIRM" == "YES" ]] && recreate_inbounds_exec "reset" || echo "Отменено."
                        ;;
                    0) break ;;
                    *) echo -e "${RED}Неверный выбор.${NC}" ;;
                esac
            done
            ;;
    esac
}

clean_server() {
    echo -e "\n${RED}${BOLD}ВНИМАНИЕ! ПОЛНАЯ ОЧИСТКА СЕРВЕРА!${NC}"
    echo "Будут полностью удалены: 3x-ui, Xray, Nginx, CrowdSec, Fail2Ban, симлинки /root/cert,"
    echo "веб-заглушка, sysctl-тюнинг, правила nftables/UFW, cron-задачи и команда my3xui."
    echo "(Сертификаты в /etc/letsencrypt по умолчанию сохраняются, чтобы не упереться в лимиты LE.)"
    read -erp "Вы уверены? Введите YES для подтверждения: " CONFIRM1
    [[ "$CONFIRM1" != "YES" ]] && { echo "Отменено."; return; }
    read -erp "Удалить также сертификаты Let's Encrypt (/etc/letsencrypt)? [y/N]: " DEL_LE

    echo -e "${YELLOW}[1/6] Остановка и удаление 3x-ui...${NC}"
    systemctl stop x-ui 2>/dev/null || true
    systemctl disable x-ui 2>/dev/null || true
    if [[ -x /usr/local/x-ui/x-ui ]]; then
        printf "y\n" | /usr/local/x-ui/x-ui uninstall >/dev/null 2>&1 || true
    fi
    rm -rf /usr/local/x-ui /etc/x-ui /etc/systemd/system/x-ui.service /etc/systemd/system/x-ui.service.d

    echo -e "${YELLOW}[2/6] Удаление Nginx и файлов маскировки...${NC}"
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    apt-get purge -y -qq nginx nginx-common nginx-core >/dev/null 2>&1 || true
    rm -rf /etc/nginx /var/log/nginx /var/cache/nginx /var/www/myfakesite /var/www/html/404.html \
           /etc/systemd/system/nginx.service.d /etc/apt/sources.list.d/nginx.list \
           /usr/share/keyrings/nginx-archive-keyring.gpg /etc/apt/preferences.d/99nginx /etc/apt/apt.conf.d/99fix-apt-hang

    echo -e "${YELLOW}[3/6] Удаление CrowdSec и Fail2Ban...${NC}"
    systemctl stop crowdsec crowdsec-firewall-bouncer fail2ban 2>/dev/null || true
    apt-get purge -y -qq crowdsec crowdsec-firewall-bouncer-nftables fail2ban >/dev/null 2>&1 || true
    rm -rf /etc/crowdsec /var/lib/crowdsec /etc/fail2ban /etc/apt/sources.list.d/crowdsec*

    echo -e "${YELLOW}[4/6] Очистка правил nftables и отключение UFW...${NC}"
    systemctl stop scanners-blocklist.service skipa-blocklist.service 2>/dev/null || true
    systemctl disable scanners-blocklist.service skipa-blocklist.service 2>/dev/null || true
    /usr/sbin/nft delete table inet scanners_block 2>/dev/null || true
    /usr/sbin/nft delete table inet skipa_block 2>/dev/null || true
    rm -f /etc/nftables.d/scanners_block.nft /etc/nftables.d/whitelist_ips.txt \
          /usr/local/sbin/update-scanners-blocklist.sh \
          /etc/systemd/system/scanners-blocklist.service /etc/cron.d/scanners-blocklist \
          /etc/nftables.d/skipa_block.nft /usr/local/sbin/update-skipa-blocklist.sh \
          /etc/systemd/system/skipa-blocklist.service /etc/cron.d/skipa-blocklist
    ufw --force disable >/dev/null 2>&1 || true
    ufw --force reset >/dev/null 2>&1 || true

    echo -e "${YELLOW}[5/6] Удаление сертификатов, sysctl-тюнинга и логов установки...${NC}"
    rm -rf /root/cert /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh \
           /etc/sysctl.d/99-xray-custom.conf /root/vps-credentials.txt /var/log/my3xui-install.log
    if [[ "${DEL_LE:-}" =~ ^[Yy]$ ]]; then
        rm -rf /etc/letsencrypt
    fi
    sysctl --system >/dev/null 2>&1 || true
    apt-get autoremove -y -qq >/dev/null 2>&1 || true
    systemctl daemon-reload

    echo -e "${YELLOW}[6/6] Удаление утилиты my3xui...${NC}"
    rm -f /usr/local/bin/my3xui
    echo -e "${GREEN}${BOLD}Очистка полностью завершена. Сервер возвращён в исходное состояние.${NC}"
    exit 0
}

case "${1:-}" in
    1|status)    show_status ;;
    2|info)      show_sysinfo ;;
    3|creds)     show_creds ;;
    4|crowdsec)  show_crowdsec ;;
    5|blocklist) manage_blocklist "${2:-}" ;;
    6|whitelist) manage_whitelist "${2:-}" "${3:-}" ;;
    7|backup)    create_backup ;;
    8|restore)   restore_backup "${2:-}" ;;
    9|inbounds)  manage_inbounds "${2:-}" ;;
    10|clean)    clean_server ;;
    *)
        while true; do
            echo -e "${BOLD}${CYAN}==================================================${NC}"
            echo -e "${BOLD}   Управление сервером (my3xui CLI)               ${NC}"
            echo -e "${BOLD}${CYAN}==================================================${NC}"
            echo "  1. Статус сервисов и SSL-сертификата"
            echo "  2. Информация о системе (CPU, RAM, тип и размер дисков)"
            echo "  3. Данные для входа в панель 3x-ui"
            echo "  4. Состояние CrowdSec и активных блокировок"
            echo "  5. Блокировка сканеров (установить / обновить / удалить C24Be + CyberOK)"
            echo "  6. Белый список IP (nftables + Fail2Ban)"
            echo "  7. Создать резервную копию конфигов и БД"
            echo "  8. Восстановить из резервной копии (БД / конфиги)"
            echo "  9. Пересоздать / восстановить стандартные инбаунды 3x-ui"
            echo -e "  10. ${RED}Очистка сервера (полное удаление всех компонентов)${NC}"
            echo "  0. Выход"
            echo ""
            read -erp "Выберите пункт [0-10]: " CHOICE
            case "$CHOICE" in
                1) show_status ;;
                2) show_sysinfo ;;
                3) show_creds ;;
                4) show_crowdsec ;;
                5) manage_blocklist ;;
                6) manage_whitelist ;;
                7) create_backup ;;
                8) restore_backup ;;
                9) manage_inbounds ;;
                10) clean_server ;;
                0) exit 0 ;;
                *) echo -e "${RED}Неверный выбор.${NC}" ;;
            esac
        done
        ;;
esac
EOF
chmod +x /usr/local/bin/my3xui
# 15. Сохранение резервной копии учетных данных и финальный вывод (без пользователей и ссылок подписки)
INFO_FILE="/root/vps-credentials.txt"
printf "Ссылка на панель 3x-ui:  https://%s/%s/\nЛогин:                   %s\nПароль:                  %s\n" \
    "${DOMAIN}" "${PANEL_PATH}" "${PANEL_USER}" "${PANEL_PASS}" > "$INFO_FILE"
chmod 600 "$INFO_FILE"

echo -e "\n${GREEN}${BOLD}=================================================================${NC}"
echo -e "${GREEN}${BOLD}  УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                                   ${NC}"
echo -e "${GREEN}${BOLD}=================================================================${NC}"
echo -e "  • ОС:            Ubuntu 24.04 LTS"
echo -e "  • Инбаунды:      XHTTP Packet-UP («Мобилы») + XHTTP Stream-One («Домашний») + TCP Reality («Reality»)"
echo -e "  • Пользователи:  не создавались (добавьте их в веб-панели 3x-ui)"
echo -e "  • Роутинг Xray:  api->api + блокировка BitTorrent, Private IPs, Ads, Malware/Phishing"
echo -e "  • UFW:           активен (открыты только SSH:${SSH_PORT}, 80, 443)"
echo -e "  • Fail2Ban:      активен (sshd + nginx-scanners + myfakesite-auth через nftables)"
echo -e "  • CrowdSec:      активен (crowdsec + nftables firewall bouncer)"
echo -e "  • Блок сканеров: $([[ "$ENABLE_SCANNERS_BLOCK" =~ ^[Yy]$ ]] && echo 'C24Be + CyberOK Skipa (nftables prerouting drop)' || echo 'отключен (my3xui blocklist install)')"
echo -e "  • Лог установки: ${LOG_FILE}"
echo -e "  • CLI-утилита:   my3xui (status | info | creds | crowdsec | blocklist | whitelist | backup | restore | inbounds | clean)"

my3xui creds
