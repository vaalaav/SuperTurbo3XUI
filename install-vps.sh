#!/usr/bin/env bash
set -eu

# ============================================================================
# Интерактивный установщик 3x-ui 3.11+ + Nginx HTTP/2 XHTTP + Security Stack
# Инбаунды: XHTTP Packet-UP ("Мобилы") + Stream-One ("Домашний") + анти-ТСПУ
# Маршрутизация: api->api, блокировка BitTorrent, Private IPs, Ads, Malware
# Поддержка: Ubuntu 24.04 / 26.04 LTS | Маска: iqubik/myfakesite / Reverse Proxy
# Защита: UFW + Fail2Ban + CrowdSec + C24Be AS_Network_List + CyberOK_Skipa_ips
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 1. Проверка прав и ОС
[[ $EUID -ne 0 ]] && log_err "Запустите скрипт от имени root (sudo bash $0)."

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]] || [[ ! "$VERSION_ID" =~ ^(24\.04|26\.04)$ ]]; then
        log_warn "Обнаружена ОС: ${PRETTY_NAME:-Unknown}. Скрипт протестирован на Ubuntu 24.04 и 26.04."
        read -erp "Продолжить на свой страх и риск? [y/N]: " cont
        [[ ! "$cont" =~ ^[Yy]$ ]] && exit 1
    fi
else
    log_err "Не удалось определить ОС (/etc/os-release не найден)."
fi

clear
echo -e "${BOLD}${CYAN}=================================================================${NC}"
echo -e "${BOLD}   Установка 3x-ui (XHTTP Packet-UP + Stream-One) + Security      ${NC}"
echo -e "${BOLD}${CYAN}=================================================================${NC}\n"

# 2. Интерактивный ввод параметров и предварительная проверка DNS
while true; do
    read -erp "1. Введите ваш основной домен (например, node.example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | LC_ALL=C tr -cd "a-zA-Z0-9.-" | tr "A-Z" "a-z")
    [[ -n "$DOMAIN" && "$DOMAIN" == *.* ]] && break
    echo -e "${RED}Некорректный домен. Попробуйте снова.${NC}"
done

SERVER_IP=$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -fsSL --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)
DOMAIN_IPS=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)
if [[ -z "$DOMAIN_IPS" ]]; then
    log_warn "Домен ${DOMAIN} сейчас не резолвится в IPv4 (A-запись не найдена)!"
    read -erp "Certbot не сможет выпустить сертификат без DNS. Всё равно продолжить? [y/N]: " dns_cont
    [[ ! "$dns_cont" =~ ^[Yy]$ ]] && exit 1
elif [[ -n "$SERVER_IP" ]] && ! grep -qx "$SERVER_IP" <<< "$DOMAIN_IPS"; then
    log_warn "Домен ${DOMAIN} указывает на (${DOMAIN_IPS//$'\n'/, }), а IP этого сервера: ${SERVER_IP}!"
    read -erp "Выпуск SSL-сертификата Let's Encrypt упадёт, если включен прокси/CDN или неверный IP. Продолжить? [y/N]: " dns_cont
    [[ ! "$dns_cont" =~ ^[Yy]$ ]] && exit 1
else
    log_ok "DNS-проверка пройдена: ${DOMAIN} -> ${SERVER_IP:-OK}"
fi

read -erp "2. Введите Email для Let's Encrypt [admin@${DOMAIN}]: " LE_EMAIL
LE_EMAIL=${LE_EMAIL:-"admin@${DOMAIN}"}

echo -e "\n3. Режим маскировки основного домена (${DOMAIN}):"
echo -e "   ${BOLD}[Enter]${NC} — Локальный портал-заглушка (iqubik/myfakesite, рекомендуется)"
echo -e "   ${BOLD}[URL]${NC}   — Введите URL сайта для Reverse Proxy (например, https://example.org)"
read -erp "   Ваш выбор [myfakesite]: " REVERSE_PROXY_URL
REVERSE_PROXY_URL=$(echo "$REVERSE_PROXY_URL" | tr -d '[:space:]')

# Генерация сложных случайных логина (12 симв.) и пароля (20 симв. со спецсимволами)
RAND_USER=$(python3 -c 'import secrets, string; alphabet = string.ascii_letters + string.digits; print("".join(secrets.choice(alphabet) for _ in range(12)))')
read -erp "4. Логин администратора 3x-ui [${RAND_USER}]: " PANEL_USER
PANEL_USER=${PANEL_USER:-"$RAND_USER"}

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
read -erp "5. Пароль администратора 3x-ui [${RAND_PASS}]: " PANEL_PASS
PANEL_PASS=${PANEL_PASS:-"$RAND_PASS"}

echo -e "\n6. Блокировать IP/подсети сканеров и госструктур РФ (C24Be AS_Network_List + CyberOK Skipa) в nftables?"
read -erp "   (Рекомендуется, сжатие CIDR + автообновление раз в сутки; также управляемо через my3xui) [Y/n]: " ENABLE_SCANNERS_BLOCK
ENABLE_SCANNERS_BLOCK=${ENABLE_SCANNERS_BLOCK:-"Y"}

PANEL_PORT=$(shuf -i 40000-48000 -n 1)
SUB_PORT=$(shuf -i 48001-56000 -n 1)
PANEL_PATH=$(openssl rand -hex 9)
SUB_PATH=$(openssl rand -hex 12)
XHTTP_UP_PATH="media/ts/$(openssl rand -hex 4)"
XHTTP_ONE_PATH="media/ts/1080/$(openssl rand -hex 4)"

# Надёжное определение порта SSH и IP текущей сессии администратора
SSH_PORT=""
if command -v sshd >/dev/null 2>&1; then
    SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)
fi
if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=$(systemctl show ssh.socket -p Listen 2>/dev/null | grep -oE '[0-9]+$' | head -n 1 || true)
fi
if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=$(ss -tlnp 2>/dev/null | awk '/sshd|ssh\.socket/ {split($4,a,":"); print a[length(a)]; exit}' || true)
fi
SSH_PORT=${SSH_PORT:-22}
ACTIVE_SSH_PORT=$(awk '{print $4}' <<< "${SSH_CONNECTION:-}" 2>/dev/null || true)
ADMIN_SSH_IP=$(awk '{print $1}' <<< "${SSH_CONNECTION:-}" 2>/dev/null || true)

echo -e "\n${YELLOW}Сводка параметров перед установкой:${NC}"
echo "  • Домен:          ${DOMAIN}"
echo "  • Протоколы:      XHTTP Packet-UP («Мобилы») + XHTTP Stream-One («Домашний»)"
echo "  • Роутинг Xray:   api->api + блокировка BitTorrent, Private IPs, Ads, Malware/Phishing"
echo "  • Маскировка:     ${REVERSE_PROXY_URL:-Локальный сайт iqubik/myfakesite}"
echo "  • Порт панели:    127.0.0.1:${PANEL_PORT} (путь /${PANEL_PATH}/)"
echo "  • Порт подписки:  127.0.0.1:${SUB_PORT} (путь /${SUB_PATH}/)"
echo "  • Логин панели:   ${PANEL_USER}"
echo "  • Безопасность:   UFW (SSH:${SSH_PORT}, 80, 443) + Fail2Ban + CrowdSec"
echo "  • Блок сканеров:  $([[ "$ENABLE_SCANNERS_BLOCK" =~ ^[Yy]$ ]] && echo 'C24Be + CyberOK Skipa (nftables)' || echo 'Отключено (доступно в my3xui)')"
echo "  • CLI-утилита:    my3xui (info, creds, crowdsec, blocklist, clean)"
echo ""
read -erp "Начать установку? [Y/n]: " START_CONFIRM
[[ "$START_CONFIRM" =~ ^[Nn]$ ]] && exit 0

# 3. Установка базовых пакетов и официального Nginx
log_info "Обновление пакетов и установка базовых утилит..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget gnupg2 ca-certificates lsb-release ubuntu-keyring \
    sqlite3 python3 jq socat certbot ufw fail2ban nftables

log_info "Подключение официального репозитория nginx.org..."
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg --yes
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
printf "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" > /etc/apt/preferences.d/99nginx
apt-get update -qq
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
ufw allow 443/udp comment 'QUIC / HTTP3' >/dev/null
ufw --force enable >/dev/null
log_ok "UFW активирован."

# 6. Выпуск SSL-сертификата Let's Encrypt и настройка webroot для автопродления без остановки Nginx
log_info "Получение SSL-сертификата для ${DOMAIN}..."
systemctl stop nginx || true
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

# 7. Подготовка сайта-заглушки (адаптированный iqubik/myfakesite или Reverse Proxy)
log_info "Настройка маскировочного сайта..."
mkdir -p /var/cache/nginx/img_cache /var/cache/nginx/html_cache /var/www/myfakesite /var/www/html /var/log/nginx
touch /var/log/nginx/access.log /var/log/nginx/error.log

if [[ -z "$REVERSE_PROXY_URL" ]]; then
    log_info "Загрузка фронтенда iqubik/myfakesite (без Docker/PHP)..."
    BASE_RAW="https://raw.githubusercontent.com/iqubik/myfakesite/main/data"
    curl -fsSL "${BASE_RAW}/index.html" -o /var/www/myfakesite/index.html
    curl -fsSL "${BASE_RAW}/favicon.ico" -o /var/www/myfakesite/favicon.ico || true
    curl -fsSL "${BASE_RAW}/apple-touch-icon.png" -o /var/www/myfakesite/apple-touch-icon.png || true
    cp /var/www/myfakesite/favicon.ico /var/www/html/favicon.ico 2>/dev/null || true

    sed -i "s/YOUDOMEN\.XXX/${DOMAIN}/g" /var/www/myfakesite/index.html

    MASK_LOCATION_BLOCK=$(cat <<'EOF'
        # Адаптированный Mock API из iqubik/myfakesite
        location = /api/status {
            default_type application/json;
            return 200 '{"status":"operational","version":"2.4.1","region":"eu-central"}';
        }
        location = /api/auth {
            default_type application/json;
            return 401 '{"error":"invalid_credentials","message":"Authentication required"}';
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
else
    RP_HOST=$(echo "$REVERSE_PROXY_URL" | sed -E 's|^https?://||; s|/.*$||')
    RP_SCHEME=$(echo "$REVERSE_PROXY_URL" | grep -oE '^https?' || echo "https")
    [[ -z "$RP_SCHEME" ]] && RP_SCHEME="https"

    MASK_LOCATION_BLOCK=$(cat <<EOF
        # Reverse Proxy маскировка на ${RP_SCHEME}://${RP_HOST}
        location / {
            limit_req zone=bot burst=20 nodelay;
            limit_conn addr 20;

            proxy_pass ${RP_SCHEME}://${RP_HOST};
            proxy_ssl_server_name on;
            proxy_ssl_name ${RP_HOST};
            proxy_http_version 1.1;
            proxy_ssl_session_reuse off;
            proxy_buffering on;
            proxy_cache html_zone;
            proxy_cache_valid 200 1d;

            proxy_set_header Host ${RP_HOST};
            proxy_set_header Referer ${RP_SCHEME}://${RP_HOST}/;
            proxy_set_header User-Agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36";
            proxy_set_header Accept-Encoding "";
            proxy_set_header X-Real-IP "";
            proxy_set_header X-Forwarded-For "";

            sub_filter '${RP_SCHEME}://${RP_HOST}' 'https://\$host';
            sub_filter '//${RP_HOST}' '//\$host';
            sub_filter_once off;
            sub_filter_types text/html;
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

# 8. Установка 3x-ui, загрузка расширенных баз geosite и патчинг /etc/x-ui/x-ui.db
log_info "Установка панели 3x-ui..."
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<EOF
n
EOF
systemctl stop x-ui

log_info "Загрузка баз geosite_IR.dat и geosite_RU.dat для фильтрации рекламы, фишинга и майнеров..."
curl -fsSL "https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geosite.dat" -o /usr/local/x-ui/bin/geosite_IR.dat || log_warn "Не удалось скачать geosite_IR.dat"
curl -fsSL "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat" -o /usr/local/x-ui/bin/geosite_RU.dat || log_warn "Не удалось скачать geosite_RU.dat"

log_info "Определение геолокации IP сервера, генерация UUID, настройка роутинга и патчинг базы 3x-ui..."
XRAY_BIN=$(find /usr/local/x-ui/bin -name "xray-linux-*" | head -n 1)
[[ -z "$XRAY_BIN" ]] && log_err "Бинарный файл Xray не найден в /usr/local/x-ui/bin!"

UUID_XHTTP_UP=$("$XRAY_BIN" uuid)
UUID_XHTTP_ONE=$("$XRAY_BIN" uuid)

DOMAIN="$DOMAIN" \
PANEL_PORT="$PANEL_PORT" \
PANEL_PATH="$PANEL_PATH" \
SUB_PORT="$SUB_PORT" \
SUB_PATH="$SUB_PATH" \
UUID_XHTTP_UP="$UUID_XHTTP_UP" \
UUID_XHTTP_ONE="$UUID_XHTTP_ONE" \
XHTTP_UP_PATH="$XHTTP_UP_PATH" \
XHTTP_ONE_PATH="$XHTTP_ONE_PATH" \
python3 - <<'PYEOF'
import sqlite3, json, urllib.request, os, time

domain = os.environ["DOMAIN"]
panel_port = os.environ["PANEL_PORT"]
panel_path = os.environ["PANEL_PATH"]
sub_port = os.environ["SUB_PORT"]
sub_path = os.environ["SUB_PATH"]
uuid_up = os.environ["UUID_XHTTP_UP"]
uuid_one = os.environ["UUID_XHTTP_ONE"]
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

base_remark = detect_server_country()
print(f"Определено базовое имя локации: {base_remark}")

db_path = "/etc/x-ui/x-ui.db"
bin_dir = "/usr/local/x-ui/bin"
conn = sqlite3.connect(db_path)
cur = conn.cursor()

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
    "twoFactorEnable": "false"
}

for k, v in settings_map.items():
    cur.execute("SELECT id FROM settings WHERE key = ?", (k,))
    if cur.fetchone():
        cur.execute("UPDATE settings SET value = ? WHERE key = ?", (v, k))
    else:
        cur.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (k, v))

# Полный системный каркас xrayTemplateConfig (сохраняет работу gRPC API статистики 3x-ui)
domain_blocks = ["geosite:category-ads-all"]
if os.path.exists(os.path.join(bin_dir, "geosite_RU.dat")):
    domain_blocks.append("ext:geosite_RU.dat:category-ads-all")
if os.path.exists(os.path.join(bin_dir, "geosite_IR.dat")):
    domain_blocks.extend([
        "ext:geosite_IR.dat:malware",
        "ext:geosite_IR.dat:phishing",
        "ext:geosite_IR.dat:cryptominers",
        "ext:geosite_IR.dat:category-ads-all"
    ])

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

# Очистка старых таблиц клиентов и инбаундов + сброс флага сидера ClientsTable,
# чтобы при запуске 3x-ui 3.11+ сама мигрировала клиентов из inbounds.settings в таблицы clients и client_inbounds
for tbl in ("inbounds", "client_traffics", "client_inbounds", "clients", "seeders"):
    try:
        cur.execute(f"DELETE FROM {tbl}")
    except sqlite3.OperationalError:
        pass

browser_headers = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
    "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7"
}

now_ms = int(time.time() * 1000)

inbounds = [
    # Inbound 1: VLESS XHTTP Packet-UP (127.0.0.1:11443) -> Мобилы
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
        "client_id": uuid_up,
        "client_email": f"xhttp_up_{domain}",
        "settings": json.dumps({
            "clients": [{
                "id": uuid_up,
                "flow": "",
                "email": f"xhttp_up_{domain}",
                "limitIp": 0,
                "totalGB": 0,
                "expiryTime": 0,
                "enable": True,
                "tgId": 0,
                "subId": "main_sub",
                "comment": "",
                "reset": 0,
                "created_at": now_ms,
                "updated_at": now_ms
            }],
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
        "sniffing": json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "metadataOnly": False, "routeOnly": False})
    },
    # Inbound 2: VLESS XHTTP Stream-One (127.0.0.1:7443) -> Домашний
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
        "client_id": uuid_one,
        "client_email": f"xhttp_one_{domain}",
        "settings": json.dumps({
            "clients": [{
                "id": uuid_one,
                "flow": "",
                "email": f"xhttp_one_{domain}",
                "limitIp": 0,
                "totalGB": 0,
                "expiryTime": 0,
                "enable": True,
                "tgId": 0,
                "subId": "main_sub",
                "comment": "",
                "reset": 0,
                "created_at": now_ms,
                "updated_at": now_ms
            }],
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
                "noGRPCHeader": True,
                "xPaddingBytes": "100-1000",
                "scStreamUpServerSecs": "30-120",
                "headers": browser_headers
            }
        }),
        "tag": "inbound-xhttp-one",
        "sniffing": json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "metadataOnly": False, "routeOnly": False})
    }
]

for ib in inbounds:
    cur.execute("""
        INSERT INTO inbounds (id, user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
        VALUES (:id, :user_id, :up, :down, :total, :remark, :enable, :expiry_time, :listen, :port, :protocol, :settings, :stream_settings, :tag, :sniffing)
    """, ib)
    try:
        cur.execute("""
            INSERT INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset)
            VALUES (?, 1, ?, 0, 0, 0, 0, 0)
        """, (ib["id"], ib["client_email"]))
    except sqlite3.OperationalError:
        pass

conn.commit()
conn.close()
PYEOF

rm -f /usr/local/x-ui/bin/config.json
/usr/local/x-ui/x-ui setting -username "${PANEL_USER}" -password "${PANEL_PASS}" -port "${PANEL_PORT}" -webBasePath "/${PANEL_PATH}/" >/dev/null

# 9. Формирование /etc/nginx/nginx.conf (прямой HTTP/2 на 443 порту + стандартный combined лог для Fail2Ban)
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
        ~^.*:/robots\.txt(\?|\$) 0;
        ~^.*:/\.well-known/security\.txt(\?|\$) 0;
        ~^.*:/${PANEL_PATH}(/|\$) 0;
        ~^.*:/${SUB_PATH}(/|\$) 0;
        ~(^1:|:1) 1;
        default 0;
    }

    limit_req_zone \$limit_ip zone=bot:1m rate=4r/s;
    limit_req_zone \$limit_ip zone=panel:10m rate=30r/s;
    limit_req_zone \$limit_ip zone=subs:1m rate=5r/m;
    limit_req_zone \$limit_ip zone=scan:1m rate=1r/s;
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

        location ^~ /.well-known/acme-challenge/ {
            root /var/www/html;
        }

        if (\$badbot) { return 444; }
        if (\$host != "${DOMAIN}") { return 444; }
        return 301 https://${DOMAIN}\$request_uri;
    }

    # Защита от сканеров по IP-адресу сервера (сброс TLS handshake)
    server {
        listen 443 ssl default_server reuseport;
        listen [::]:443 ssl default_server reuseport;
        server_name _;

        ssl_reject_handshake on;
        ssl_session_tickets off;

        ssl_certificate /root/cert/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /root/cert/${DOMAIN}/privkey.pem;
    }

    server {
        listen 443 ssl;
        listen [::]:443 ssl;
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
        proxy_set_header Early-Data \$ssl_early_data;

        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
        add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

        if (\$is_scan_attempt) { return 404; }
        if (\$badbot) { return 404; }
        if (\$request_method !~ ^(GET|HEAD|POST)\$) { return 405; }
        if (\$host != '${DOMAIN}') { return 444; }

        proxy_intercept_errors on;
        error_page 400 403 404 405 @notfound;

        # Панель 3x-ui
        location = /${PANEL_PATH} {
            return 301 /${PANEL_PATH}/;
        }
        location /${PANEL_PATH}/ {
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
            add_header Cache-Control "no-store, no-cache, must-revalidate";
        }

        # Единая подписка 3x-ui
        location ^~ /${SUB_PATH}/ {
            proxy_pass https://127.0.0.1:${SUB_PORT}/${SUB_PATH}/;
            proxy_ssl_verify off;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            add_header Cache-Control "no-store, no-cache, must-revalidate";
        }

        # Inbound 1: VLESS XHTTP Packet-UP (Мобилы)
        location /${XHTTP_UP_PATH}/ {
            set \$limit_ip "";
            if (\$ssl_early_data) { return 425; }

            proxy_pass http://xray_xhttp_up;
            proxy_http_version 2;
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
            error_page 400 502 503 504 =404 @notfound;
        }

        # Inbound 2: VLESS XHTTP Stream-One (Домашний)
        location /${XHTTP_ONE_PATH}/ {
            set \$limit_ip "";
            if (\$ssl_early_data) { return 425; }

            proxy_pass http://xray_xhttp_one;
            proxy_http_version 2;
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
            error_page 400 502 503 504 =404 @notfound;
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

# 11. Настройка Fail2Ban (systemd с явным journalmatch для ssh.service + polling для combined лога nginx)
log_info "Настройка Fail2Ban..."
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 3
backend = systemd
banaction = nftables-multiport

[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd

[nginx-botsearch]
enabled = true
port = http,https
backend = polling
logpath = /var/log/nginx/access.log
maxretry = 10
findtime = 5m
bantime = 12h
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# 12. Установка и настройка CrowdSec + nftables bouncer
log_info "Установка CrowdSec и nftables firewall bouncer..."
curl -s https://install.crowdsec.net | sh >/dev/null
apt-get install -y -qq crowdsec crowdsec-firewall-bouncer-nftables

cscli collections install crowdsecurity/linux crowdsecurity/sshd crowdsecurity/nginx --force >/dev/null 2>&1 || true
rm -f /etc/crowdsec/acquis.d/nginx.yaml

cscli bouncers delete firewall-bouncer >/dev/null 2>&1 || true
BOUNCER_KEY=$(cscli bouncers add firewall-bouncer -o raw)
sed -i "s|^api_key:.*|api_key: ${BOUNCER_KEY}|" /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
sed -i "s|^mode:.*|mode: nftables|" /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml

systemctl enable --now crowdsec crowdsec-firewall-bouncer
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
    raw_text = ""
    for u in urls:
        try:
            req = urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=20) as resp:
                raw_text += "\n" + resp.read().decode("utf-8", errors="ignore")
        except Exception:
            pass

    candidates = re.findall(r'\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b', raw_text)
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
elements = ",\n        ".join(str(net) for net in collapsed)

wl_ips = set()
if os.path.exists(WL_FILE):
    with open(WL_FILE, "r", encoding="utf-8") as wf:
        for line in wf:
            line = line.strip()
            try:
                ip = ipaddress.ip_address(line)
                if ip.version == 4:
                    wl_ips.add(str(ip))
            except ValueError:
                pass

wl_rule = ""
if wl_ips:
    wl_elems = ", ".join(sorted(wl_ips))
    wl_rule = f"        ip saddr {{ {wl_elems} }} accept\n"

nft_config = f"""# Sources: C24Be={stats.get('C24Be_AS_Network_List', 0)}, CyberOK={stats.get('CyberOK_Skipa_ips', 0)}, Collapsed={len(collapsed)}
table inet scanners_block
delete table inet scanners_block

table inet scanners_block {{
    set scanners_v4 {{
        type ipv4_addr
        flags interval
        auto-merge
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

subprocess.run(["nft", "-f", NFT_FILE], check=True)
print(f"OK: Loaded {len(collapsed)} collapsed IPv4 CIDRs (C24Be: {stats.get('C24Be_AS_Network_List', 0)}, CyberOK: {stats.get('CyberOK_Skipa_ips', 0)})")
EOF
chmod +x /usr/local/sbin/update-scanners-blocklist.sh

cat <<'EOF' > /etc/systemd/system/scanners-blocklist.service
[Unit]
Description=Apply C24Be AS_Network_List & CyberOK Skipa nftables blocklist
After=network-online.target nftables.service ufw.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/nftables.d/scanners_block.nft
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

if [[ "$ENABLE_SCANNERS_BLOCK" =~ ^[Yy]$ ]]; then
    log_info "Загрузка и применение списков C24Be + CyberOK Skipa в nftables..."
    if /usr/local/sbin/update-scanners-blocklist.sh; then
        systemctl enable scanners-blocklist.service >/dev/null
        echo "15 4 * * * root /usr/local/sbin/update-scanners-blocklist.sh >/dev/null 2>&1" > /etc/cron.d/scanners-blocklist
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
set -eu

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}Запустите команду от имени root: sudo my3xui${NC}"; exit 1; }

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

    echo -e "  • ${BOLD}Процессор:${NC}      ${CPU_MODEL:-Unknown} (${CPU_CORES} vCPU @ ${CPU_FREQ})"
    echo -e "  • ${BOLD}Оперативная пам.:${NC} ${MEM_INFO}"
    echo -e "  • ${BOLD}Swap:${NC}           ${SWAP_INFO}"
    echo -e "  • ${BOLD}Диски:${NC}"
    lsblk -d -n -o NAME,SIZE,ROTA,TRAN,MODEL | while read -r line; do
        DEV_NAME=$(echo "$line" | awk '{print $1}')
        [[ "$DEV_NAME" =~ ^(loop|ram|sr) ]] && continue
        DEV_SIZE=$(echo "$line" | awk '{print $2}')
        DEV_ROTA=$(echo "$line" | awk '{print $3}')
        DEV_TRAN=$(echo "$line" | awk '{print $4}')
        if [[ "$DEV_NAME" == nvme* || "$DEV_TRAN" == "nvme" ]]; then
            DISK_TYPE="NVMe SSD"
        elif [[ "$DEV_ROTA" == "0" ]]; then
            DISK_TYPE="SSD (Virtual/SATA)"
        else
            DISK_TYPE="HDD"
        fi
        MOUNT_USAGE=$(df -h --output=used,size,pcent "/dev/${DEV_NAME}" 2>/dev/null | tail -n 1 | xargs || true)
        [[ -z "$MOUNT_USAGE" ]] && MOUNT_USAGE=$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')
        echo -e "      - /dev/${DEV_NAME}: ${BOLD}${DEV_SIZE}${NC} [${DISK_TYPE}] — занято на /: ${MOUNT_USAGE}"
    done
    echo ""
}

show_creds() {
    echo -e "\n${BOLD}${CYAN}=== ДАННЫЕ ДЛЯ ВХОДА В ПАНЕЛЬ И ССЫЛКИ (ИЗ БАЗЫ 3X-UI) ===${NC}"
    python3 - <<'DBEOF'
import sqlite3, json, urllib.parse, os

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
if sub_uri:
    print(f"  Единая подписка:         {sub_uri}main_sub")

print("\n--- АКТИВНЫЕ КЛЮЧИ VLESS:// ---")
for row in cur.execute("SELECT id, remark, settings, stream_settings FROM inbounds WHERE enable = 1"):
    ib_id, remark, st_raw, sst_raw = row
    st = json.loads(st_raw)
    sst = json.loads(sst_raw)
    clients = st.get("clients", [])
    uuid = None
    if clients:
        uuid = clients[0].get("id")
    if not uuid:
        try:
            r_cl = cur.execute("""
                SELECT c.id FROM clients c
                JOIN client_inbounds ci ON ci.client_uid = c.uid
                WHERE ci.inbound_id = ? LIMIT 1
            """, (ib_id,)).fetchone()
            if r_cl:
                uuid = r_cl[0]
        except Exception:
            pass
    if not uuid:
        continue

    net = sst.get("network", "xhttp")
    xs = sst.get("xhttpSettings", {})

    params = {
        "type": net,
        "encryption": "none",
        "security": "tls",
        "sni": domain,
        "host": xs.get("host", domain),
        "path": xs.get("path", "/"),
        "mode": xs.get("mode", "auto"),
        "fp": "randomized"
    }

    extra_keys = [
        "noGRPCHeader", "xPaddingBytes", "scMaxEachPostBytes",
        "scMinPostsIntervalMs", "scMaxBufferedPosts", "scStreamUpServerSecs", "headers"
    ]
    extra_obj = {k: xs[k] for k in extra_keys if k in xs}
    if extra_obj:
        params["extra"] = json.dumps(extra_obj, separators=(",", ":"))

    query_str = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    link = f"vless://{uuid}@{domain}:443?{query_str}#{urllib.parse.quote(remark)}"
    print(f"\n[{remark}]")
    print(link)

conn.close()
DBEOF
    echo ""
}

blocklist_status() {
    if nft list table inet scanners_block &>/dev/null; then
        PKTS=$(nft list chain inet scanners_block prerouting 2>/dev/null | grep -oE 'packets [0-9]+' | tail -n 1 || echo "packets 0")
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
    systemctl enable scanners-blocklist.service >/dev/null 2>&1 || true
    echo "15 4 * * * root /usr/local/sbin/update-scanners-blocklist.sh >/dev/null 2>&1" > /etc/cron.d/scanners-blocklist
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
    echo -e "${GREEN}[OK] Списки успешно обновлены и применены в nftables.${NC}"
}

blocklist_remove() {
    echo -e "${YELLOW}[INFO] Удаление блокировки C24Be + CyberOK из nftables...${NC}"
    systemctl stop scanners-blocklist.service skipa-blocklist.service 2>/dev/null || true
    systemctl disable scanners-blocklist.service skipa-blocklist.service 2>/dev/null || true
    nft delete table inet scanners_block 2>/dev/null || true
    nft delete table inet skipa_block 2>/dev/null || true
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

clean_server() {
    echo -e "\n${RED}${BOLD}ВНИМАНИЕ! ПОЛНАЯ ОЧИСТКА СЕРВЕРА!${NC}"
    echo "Будут полностью удалены: 3x-ui, Xray, Nginx, CrowdSec, Fail2Ban, сертификаты,"
    echo "веб-заглушка, sysctl-тюнинг, правила nftables/UFW, cron-задачи и команда my3xui."
    read -erp "Вы уверены? Введите YES для подтверждения: " CONFIRM1
    [[ "$CONFIRM1" != "YES" ]] && { echo "Отменено."; return; }

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
           /usr/share/keyrings/nginx-archive-keyring.gpg /etc/apt/preferences.d/99nginx

    echo -e "${YELLOW}[3/6] Удаление CrowdSec и Fail2Ban...${NC}"
    systemctl stop crowdsec crowdsec-firewall-bouncer fail2ban 2>/dev/null || true
    apt-get purge -y -qq crowdsec crowdsec-firewall-bouncer-nftables fail2ban >/dev/null 2>&1 || true
    rm -rf /etc/crowdsec /var/lib/crowdsec /etc/fail2ban /etc/apt/sources.list.d/crowdsec*

    echo -e "${YELLOW}[4/6] Очистка правил nftables и отключение UFW...${NC}"
    systemctl stop scanners-blocklist.service skipa-blocklist.service 2>/dev/null || true
    systemctl disable scanners-blocklist.service skipa-blocklist.service 2>/dev/null || true
    nft delete table inet scanners_block 2>/dev/null || true
    nft delete table inet skipa_block 2>/dev/null || true
    rm -f /etc/nftables.d/scanners_block.nft /etc/nftables.d/whitelist_ips.txt \
          /usr/local/sbin/update-scanners-blocklist.sh \
          /etc/systemd/system/scanners-blocklist.service /etc/cron.d/scanners-blocklist \
          /etc/nftables.d/skipa_block.nft /usr/local/sbin/update-skipa-blocklist.sh \
          /etc/systemd/system/skipa-blocklist.service /etc/cron.d/skipa-blocklist
    ufw --force disable >/dev/null 2>&1 || true
    ufw --force reset >/dev/null 2>&1 || true

    echo -e "${YELLOW}[5/6] Удаление сертификатов, sysctl-тюнинга и логов установки...${NC}"
    rm -rf /root/cert /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh \
           /etc/sysctl.d/99-xray-custom.conf /root/vps-credentials.txt
    sysctl --system >/dev/null 2>&1 || true
    apt-get autoremove -y -qq >/dev/null 2>&1 || true
    systemctl daemon-reload

    echo -e "${YELLOW}[6/6] Удаление утилиты my3xui...${NC}"
    rm -f /usr/local/bin/my3xui
    echo -e "${GREEN}${BOLD}Очистка полностью завершена. Сервер возвращён в исходное состояние.${NC}"
    exit 0
}

case "${1:-}" in
    1|info)      show_sysinfo ;;
    2|creds)     show_creds ;;
    3|crowdsec)  show_crowdsec ;;
    4|blocklist) manage_blocklist "${2:-}" ;;
    5|clean)     clean_server ;;
    *)
        while true; do
            echo -e "${BOLD}${CYAN}==================================================${NC}"
            echo -e "${BOLD}   Управление сервером (my3xui CLI)               ${NC}"
            echo -e "${BOLD}${CYAN}==================================================${NC}"
            echo "  1. Информация о системе (CPU, RAM, тип и размер дисков)"
            echo "  2. Данные для входа в панель 3x-ui и ссылки VLESS"
            echo "  3. Состояние CrowdSec и активных блокировок"
            echo "  4. Блокировка сканеров (установить / обновить / удалить C24Be + CyberOK)"
            echo -e "  5. ${RED}Очистка сервера (полное удаление всех компонентов)${NC}"
            echo "  0. Выход"
            echo ""
            read -erp "Выберите пункт [0-5]: " CHOICE
            case "$CHOICE" in
                1) show_sysinfo ;;
                2) show_creds ;;
                3) show_crowdsec ;;
                4) manage_blocklist ;;
                5) clean_server ;;
                0) exit 0 ;;
                *) echo -e "${RED}Неверный выбор.${NC}" ;;
            esac
        done
        ;;
esac
EOF
chmod +x /usr/local/bin/my3xui

# 15. Сохранение резервной копии учетных данных и финальный вывод
INFO_FILE="/root/vps-credentials.txt"
printf "Ссылка на панель 3x-ui:  https://%s/%s/\nЛогин:                   %s\nПароль:                  %s\nЕдиная подписка:         https://%s/%s/main_sub\n" \
    "${DOMAIN}" "${PANEL_PATH}" "${PANEL_USER}" "${PANEL_PASS}" "${DOMAIN}" "${SUB_PATH}" > "$INFO_FILE"
chmod 600 "$INFO_FILE"

echo -e "\n${GREEN}${BOLD}=================================================================${NC}"
echo -e "${GREEN}${BOLD}  УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                                   ${NC}"
echo -e "${GREEN}${BOLD}=================================================================${NC}"
echo -e "  • Протоколы:     XHTTP Packet-UP («Мобилы») + XHTTP Stream-One («Домашний»)"
echo -e "  • Роутинг Xray:  api->api + блокировка BitTorrent, Private IPs, Ads, Malware/Phishing"
echo -e "  • UFW:           активен (открыты только SSH:${SSH_PORT}, 80, 443)"
echo -e "  • Fail2Ban:      активен (sshd + nginx-botsearch через nftables)"
echo -e "  • CrowdSec:      активен (crowdsec + nftables firewall bouncer)"
echo -e "  • Блок сканеров: $([[ "$ENABLE_SCANNERS_BLOCK" =~ ^[Yy]$ ]] && echo 'C24Be + CyberOK Skipa (nftables prerouting drop)' || echo 'отключен (my3xui blocklist install)')"
echo -e "  • CLI-утилита:   my3xui (info | creds | crowdsec | blocklist | clean)"

my3xui creds