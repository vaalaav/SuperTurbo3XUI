#!/usr/bin/env bash
set -eu

# ============================================================================
# Интерактивный установщик 3x-ui + Nginx Multi-SNI + Sysctl + Security Stack
# Поддержка: Ubuntu 24.04 / 26.04 LTS | Маска: iqubik/myfakesite / Reverse Proxy
# Защита: UFW + Fail2Ban + CrowdSec + CyberOK_Skipa_ips + CLI-утилита my3xui
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
echo -e "${BOLD}   Установка 3x-ui + Nginx Multi-SNI + Security & CLI my3xui     ${NC}"
echo -e "${BOLD}${CYAN}=================================================================${NC}\n"

# 2. Интерактивный ввод параметров
while true; do
    read -erp "1. Введите ваш основной домен (например, node.example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | LC_ALL=C tr -cd "a-zA-Z0-9.-" | tr "A-Z" "a-z")
    [[ -n "$DOMAIN" && "$DOMAIN" == *.* ]] && break
    echo -e "${RED}Некорректный домен. Попробуйте снова.${NC}"
done

read -erp "2. Введите Email для Let's Encrypt [admin@${DOMAIN}]: " LE_EMAIL
LE_EMAIL=${LE_EMAIL:-"admin@${DOMAIN}"}

echo -e "\n3. SNI-домены для Reality (можно указать несколько через запятую):"
read -erp "   [taxi.yandex.ru,www.amd.com,f1tv.formula1.com]: " REALITY_SNI_RAW
REALITY_SNI_RAW=${REALITY_SNI_RAW:-"taxi.yandex.ru,www.amd.com,f1tv.formula1.com"}
REALITY_SNI_CLEAN=$(echo "$REALITY_SNI_RAW" | LC_ALL=C tr -cd "a-zA-Z0-9.,-" | tr "A-Z" "a-z")
IFS=',' read -ra SNI_ARRAY <<< "$REALITY_SNI_CLEAN"
PRIMARY_SNI="${SNI_ARRAY[0]}"

echo -e "\n4. Режим маскировки основного домена (${DOMAIN}):"
echo -e "   ${BOLD}[Enter]${NC} — Локальный портал-заглушка (iqubik/myfakesite, рекомендуется)"
echo -e "   ${BOLD}[URL]${NC}   — Введите URL сайта для Reverse Proxy (например, https://example.org)"
read -erp "   Ваш выбор [myfakesite]: " REVERSE_PROXY_URL
REVERSE_PROXY_URL=$(echo "$REVERSE_PROXY_URL" | tr -d '[:space:]')

# Генерация случайных логина, пароля, портов (40000-56000) и секретных путей
RAND_USER="u$(openssl rand -hex 5)"
read -erp "5. Логин администратора 3x-ui [${RAND_USER}]: " PANEL_USER
PANEL_USER=${PANEL_USER:-"$RAND_USER"}

RAND_PASS=$(openssl rand -hex 8)
read -erp "6. Пароль администратора 3x-ui [${RAND_PASS}]: " PANEL_PASS
PANEL_PASS=${PANEL_PASS:-"$RAND_PASS"}

echo -e "\n7. Блокировать IP/подсети сканеров CyberOK Skipa / ГРЧЦ / НКЦКИ на уровне nftables?"
read -erp "   (Рекомендуется, автообновление раз в сутки) [Y/n]: " ENABLE_SKIPA
ENABLE_SKIPA=${ENABLE_SKIPA:-"Y"}

PANEL_PORT=$(shuf -i 40000-48000 -n 1)
SUB_PORT=$(shuf -i 48001-56000 -n 1)
PANEL_PATH=$(openssl rand -hex 9)
SUB_PATH=$(openssl rand -hex 12)
XHTTP_UP_PATH="media/ts/$(openssl rand -hex 4)"
WS_PATH="media/ts/720/$(openssl rand -hex 4)"
XHTTP_ONE_PATH="media/ts/1080/$(openssl rand -hex 4)"

SSH_PORT=$(ss -tlnp 2>/dev/null | awk '/sshd|ssh\.socket/ {split($4,a,":"); print a[length(a)]; exit}')
if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2; exit}')
fi
SSH_PORT=${SSH_PORT:-22}

echo -e "\n${YELLOW}Сводка параметров перед установкой:${NC}"
echo "  • Домен:          ${DOMAIN}"
echo "  • Reality SNI:    ${REALITY_SNI_CLEAN} (основной dest: ${PRIMARY_SNI})"
echo "  • Маскировка:     ${REVERSE_PROXY_URL:-Локальный сайт iqubik/myfakesite}"
echo "  • Порт панели:    127.0.0.1:${PANEL_PORT} (путь /${PANEL_PATH}/)"
echo "  • Порт подписки:  127.0.0.1:${SUB_PORT} (путь /${SUB_PATH}/)"
echo "  • Логин панели:   ${PANEL_USER}"
echo "  • Безопасность:   UFW (SSH:${SSH_PORT}, 80, 443) + Fail2Ban + CrowdSec"
echo "  • CyberOK Skipa:  $([[ "$ENABLE_SKIPA" =~ ^[Yy]$ ]] && echo 'Включено (nftables)' || echo 'Отключено')"
echo "  • CLI-утилита:    my3xui (инфо, чтение БД, crowdsec, полная очистка)"
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
sysctl --system >/dev/null

# 5. Настройка UFW
log_info "Настройка файрвола UFW (SSH: ${SSH_PORT}, HTTP: 80, HTTPS: 443)..."
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP ACME' >/dev/null
ufw allow 443/tcp comment 'HTTPS Proxy' >/dev/null
ufw allow 443/udp comment 'QUIC / HTTP3' >/dev/null
ufw --force enable >/dev/null
log_ok "UFW активирован."

# 6. Выпуск SSL-сертификата Let's Encrypt
log_info "Получение SSL-сертификата для ${DOMAIN}..."
systemctl stop nginx || true
mkdir -p "/root/cert/${DOMAIN}" /var/www/html

certbot certonly --standalone --non-interactive --agree-tos \
    --email "${LE_EMAIL}" -d "${DOMAIN}" --key-type ecdsa

ln -sf "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "/root/cert/${DOMAIN}/fullchain.pem"
ln -sf "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "/root/cert/${DOMAIN}/privkey.pem"

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat <<'EOF' > /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh
#!/bin/bash
systemctl reload nginx
systemctl restart x-ui
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh

# 7. Подготовка сайта-заглушки (адаптированный iqubik/myfakesite или Reverse Proxy)
log_info "Настройка маскировочного сайта..."
mkdir -p /var/cache/nginx/img_cache /var/cache/nginx/html_cache /var/www/myfakesite /var/www/html

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

chown -R www-data:www-data /var/cache/nginx /var/www

# 8. Установка 3x-ui и автоматический патчинг базы /etc/x-ui/x-ui.db
log_info "Установка панели 3x-ui..."
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<EOF
n
EOF
systemctl stop x-ui

log_info "Генерация ключей Reality и патчинг базы данных 3x-ui..."
XRAY_BIN=$(find /usr/local/x-ui/bin -name "xray-linux-*" | head -n 1)
[[ -z "$XRAY_BIN" ]] && log_err "Бинарный файл Xray не найден в /usr/local/x-ui/bin!"

KEYS_OUT=$("$XRAY_BIN" x25519)
PRIVATE_KEY=$(echo "$KEYS_OUT" | awk '/Private/ {print $NF}')
PUBLIC_KEY=$(echo "$KEYS_OUT" | awk '/Public|Password/ {print $NF}' | head -n 1)
SHORT_ID=$(openssl rand -hex 8)

UUID_REALITY=$("$XRAY_BIN" uuid)
UUID_XHTTP_UP=$("$XRAY_BIN" uuid)
UUID_WS=$("$XRAY_BIN" uuid)
UUID_XHTTP_ONE=$("$XRAY_BIN" uuid)

python3 - <<PYEOF
import sqlite3, json

db_path = "/etc/x-ui/x-ui.db"
conn = sqlite3.connect(db_path)
cur = conn.cursor()

sni_list = [s.strip() for s in "${REALITY_SNI_CLEAN}".split(",") if s.strip()]
primary_sni = sni_list[0]

settings_map = {
    "webPort": "${PANEL_PORT}",
    "webListen": "127.0.0.1",
    "webBasePath": "/${PANEL_PATH}/",
    "webCertFile": "/root/cert/${DOMAIN}/fullchain.pem",
    "webKeyFile": "/root/cert/${DOMAIN}/privkey.pem",
    "subEnable": "true",
    "subListen": "127.0.0.1",
    "subPort": "${SUB_PORT}",
    "subPath": "/${SUB_PATH}/",
    "subCertFile": "/root/cert/${DOMAIN}/fullchain.pem",
    "subKeyFile": "/root/cert/${DOMAIN}/privkey.pem",
    "subURI": "https://${DOMAIN}/${SUB_PATH}/",
    "twoFactorEnable": "false"
}

for k, v in settings_map.items():
    cur.execute("SELECT id FROM settings WHERE key = ?", (k,))
    if cur.fetchone():
        cur.execute("UPDATE settings SET value = ? WHERE key = ?", (v, k))
    else:
        cur.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (k, v))

cur.execute("DELETE FROM inbounds")

inbounds = [
    {
        "user_id": 1,
        "up": 0,
        "down": 0,
        "total": 0,
        "remark": "VLESS-Reality-MultiSNI",
        "enable": 1,
        "expiry_time": 0,
        "listen": "127.0.0.1",
        "port": 10443,
        "protocol": "vless",
        "settings": json.dumps({
            "clients": [{
                "id": "${UUID_REALITY}",
                "flow": "xtls-rprx-vision",
                "email": "reality_${DOMAIN}",
                "limitIp": 0,
                "totalGB": 0,
                "expiryTime": 0,
                "enable": True,
                "subId": "main_sub"
            }],
            "decryption": "none",
            "fallbacks": []
        }),
        "stream_settings": json.dumps({
            "network": "tcp",
            "security": "reality",
            "externalProxy": [{
                "forceTls": "same",
                "dest": "${DOMAIN}",
                "port": 443,
                "remark": ""
            }],
            "realitySettings": {
                "show": False,
                "xver": 1,
                "dest": f"{primary_sni}:443",
                "serverNames": sni_list,
                "privateKey": "${PRIVATE_KEY}",
                "minClient": "",
                "maxClient": "",
                "maxTimediff": 0,
                "shortIds": ["${SHORT_ID}"],
                "settings": {
                    "publicKey": "${PUBLIC_KEY}",
                    "fingerprint": "chrome",
                    "serverName": primary_sni,
                    "spiderX": "/"
                }
            },
            "tcpSettings": {
                "acceptProxyProtocol": True,
                "header": {"type": "none"}
            }
        }),
        "tag": "inbound-reality-main",
        "sniffing": json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic"]})
    },
    {
        "user_id": 1,
        "up": 0,
        "down": 0,
        "total": 0,
        "remark": "VLESS-XHTTP-PacketUP",
        "enable": 1,
        "expiry_time": 0,
        "listen": "127.0.0.1",
        "port": 11443,
        "protocol": "vless",
        "settings": json.dumps({
            "clients": [{
                "id": "${UUID_XHTTP_UP}",
                "flow": "",
                "email": "xhttp_up_${DOMAIN}",
                "enable": True,
                "subId": "main_sub"
            }],
            "decryption": "none"
        }),
        "stream_settings": json.dumps({
            "network": "xhttp",
            "security": "none",
            "externalProxy": [{
                "forceTls": "tls",
                "dest": "${DOMAIN}",
                "port": 443,
                "remark": ""
            }],
            "xhttpSettings": {
                "path": "/${XHTTP_UP_PATH}/",
                "host": "${DOMAIN}",
                "mode": "packet-up"
            }
        }),
        "tag": "inbound-xhttp-up",
        "sniffing": json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic"]})
    },
    {
        "user_id": 1,
        "up": 0,
        "down": 0,
        "total": 0,
        "remark": "VLESS-WS",
        "enable": 1,
        "expiry_time": 0,
        "listen": "127.0.0.1",
        "port": 9443,
        "protocol": "vless",
        "settings": json.dumps({
            "clients": [{
                "id": "${UUID_WS}",
                "flow": "",
                "email": "ws_${DOMAIN}",
                "enable": True,
                "subId": "main_sub"
            }],
            "decryption": "none"
        }),
        "stream_settings": json.dumps({
            "network": "ws",
            "security": "none",
            "externalProxy": [{
                "forceTls": "tls",
                "dest": "${DOMAIN}",
                "port": 443,
                "remark": ""
            }],
            "wsSettings": {
                "acceptProxyProtocol": False,
                "path": "/${WS_PATH}/",
                "headers": {"Host": "${DOMAIN}"}
            }
        }),
        "tag": "inbound-ws",
        "sniffing": json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic"]})
    },
    {
        "user_id": 1,
        "up": 0,
        "down": 0,
        "total": 0,
        "remark": "VLESS-XHTTP-StreamOne",
        "enable": 1,
        "expiry_time": 0,
        "listen": "127.0.0.1",
        "port": 7443,
        "protocol": "vless",
        "settings": json.dumps({
            "clients": [{
                "id": "${UUID_XHTTP_ONE}",
                "flow": "",
                "email": "xhttp_one_${DOMAIN}",
                "enable": True,
                "subId": "main_sub"
            }],
            "decryption": "none"
        }),
        "stream_settings": json.dumps({
            "network": "xhttp",
            "security": "none",
            "externalProxy": [{
                "forceTls": "tls",
                "dest": "${DOMAIN}",
                "port": 443,
                "remark": ""
            }],
            "xhttpSettings": {
                "path": "/${XHTTP_ONE_PATH}/",
                "host": "${DOMAIN}",
                "mode": "stream-one"
            }
        }),
        "tag": "inbound-xhttp-one",
        "sniffing": json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic"]})
    }
]

for ib in inbounds:
    cur.execute("""
        INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
        VALUES (:user_id, :up, :down, :total, :remark, :enable, :expiry_time, :listen, :port, :protocol, :settings, :stream_settings, :tag, :sniffing)
    """, ib)

conn.commit()
conn.close()
PYEOF

rm -f /usr/local/x-ui/bin/config.json
/usr/local/x-ui/x-ui setting -username "${PANEL_USER}" -password "${PANEL_PASS}" -port "${PANEL_PORT}" -webBasePath "/${PANEL_PATH}/" >/dev/null

# 9. Формирование /etc/nginx/nginx.conf
SNI_MAP_LINES=""
for sni in "${SNI_ARRAY[@]}"; do
    [[ -n "$sni" ]] && SNI_MAP_LINES+="        ${sni}         127.0.0.1:10443;"$'\n'
done

log_info "Генерация /etc/nginx/nginx.conf с поддержкой Multi-SNI..."
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

stream {
    map \$ssl_preread_server_name \$backend_gate {
        hostnames;
        ${DOMAIN}              nginx_http_backend;
${SNI_MAP_LINES}        default                nginx_http_backend;
    }

    upstream nginx_http_backend {
        server unix:/dev/shm/nginx-http.sock;
    }

    server {
        listen 443 backlog=65535 reuseport so_keepalive=75s:5s:3;
        listen [::]:443 backlog=65535 reuseport so_keepalive=75s:5s:3;

        proxy_timeout 1h;
        proxy_connect_timeout 5s;
        proxy_buffer_size 16k;
        proxy_socket_keepalive on;
        proxy_protocol on;
        proxy_pass \$backend_gate;
        ssl_preread on;
    }
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

    map \$proxy_protocol_addr \$ak_real_ip {
        ""      \$remote_addr;
        default \$proxy_protocol_addr;
    }

    map \$ak_real_ip \$limit_ip {
        default \$ak_real_ip;
    }

    upstream panel_3xui {
        server 127.0.0.1:${PANEL_PORT};
        keepalive 30;
    }
    upstream xray_vless {
        server 127.0.0.1:11443;
        keepalive 64;
        keepalive_timeout 1h;
        keepalive_requests 100000;
    }
    upstream xray_vless2 {
        server 127.0.0.1:9443;
        keepalive 64;
        keepalive_timeout 1h;
        keepalive_requests 100000;
    }
    upstream xray_vless3 {
        server 127.0.0.1:7443;
        keepalive 64;
        keepalive_timeout 1h;
        keepalive_requests 100000;
    }

    proxy_cache_path /var/cache/nginx/img_cache levels=1:2 keys_zone=img_zone:10m max_size=1g inactive=7d use_temp_path=off;
    proxy_cache_path /var/cache/nginx/html_cache levels=1:2 keys_zone=html_zone:20m max_size=500m inactive=30d use_temp_path=off;

    log_format main '\$ak_real_ip [\$time_local] "\$request" \$status \$body_bytes_sent "\$http_user_agent"';
    access_log /var/log/nginx/access.log main buffer=32k flush=60s;

    keepalive_timeout 75s;
    keepalive_requests 100000;
    client_body_timeout 60s;
    client_header_timeout 60s;
    send_timeout 60s;
    reset_timedout_connection on;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from unix:;

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

    server {
        listen unix:/dev/shm/nginx-http.sock ssl default_server proxy_protocol;
        server_name _;

        ssl_reject_handshake on;
        ssl_session_tickets off;

        ssl_certificate /root/cert/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /root/cert/${DOMAIN}/privkey.pem;
    }

    server {
        listen unix:/dev/shm/nginx-http.sock ssl proxy_protocol;
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
            proxy_set_header X-Real-IP \$ak_real_ip;
            proxy_set_header X-Forwarded-For \$ak_real_ip;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_buffering off;
            proxy_request_buffering off;
            access_log off;
            add_header Cache-Control "no-store, no-cache, must-revalidate";
        }

        location ^~ /${SUB_PATH}/ {
            proxy_pass https://127.0.0.1:${SUB_PORT}/${SUB_PATH}/;
            proxy_ssl_verify off;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$ak_real_ip;
            proxy_set_header X-Forwarded-For \$ak_real_ip;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            add_header Cache-Control "no-store, no-cache, must-revalidate";
        }

        location /${XHTTP_UP_PATH}/ {
            set \$limit_ip "";
            if (\$ssl_early_data) { return 425; }

            proxy_pass http://xray_vless;
            proxy_http_version 2;
            proxy_buffering off;
            proxy_request_buffering off;
            gzip off;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$ak_real_ip;
            proxy_set_header X-Forwarded-For \$ak_real_ip;
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

        location /${WS_PATH}/ {
            set \$limit_ip "";
            if (\$ssl_early_data) { return 425; }

            proxy_pass http://xray_vless2;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$ak_real_ip;
            proxy_set_header X-Forwarded-For \$ak_real_ip;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_buffering off;
            proxy_request_buffering off;
            gzip off;
            proxy_socket_keepalive on;
            proxy_read_timeout 1h;
            proxy_send_timeout 1h;
            send_timeout 1h;
            client_max_body_size 0;
            access_log off;
            error_log /dev/null crit;
            error_page 400 502 503 504 =404 @notfound;
        }

        location /${XHTTP_ONE_PATH}/ {
            set \$limit_ip "";
            if (\$ssl_early_data) { return 425; }

            proxy_pass http://xray_vless3;
            proxy_http_version 2;
            proxy_buffering off;
            proxy_request_buffering off;
            gzip off;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$ak_real_ip;
            proxy_set_header X-Forwarded-For \$ak_real_ip;
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

# 11. Настройка Fail2Ban (systemd backend для Ubuntu 24.04/26.04)
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

[nginx-botsearch]
enabled = true
port = http,https
backend = auto
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

cscli bouncers delete firewall-bouncer 2>/dev/null || true
BOUNCER_KEY=$(cscli bouncers add firewall-bouncer -o raw)
sed -i "s|^api_key:.*|api_key: ${BOUNCER_KEY}|" /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
sed -i "s|^mode:.*|mode: nftables|" /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml

systemctl enable --now crowdsec crowdsec-firewall-bouncer
systemctl restart crowdsec crowdsec-firewall-bouncer

# 13. Интеграция CyberOK_Skipa_ips на уровне nftables (с автообновлением)
if [[ "$ENABLE_SKIPA" =~ ^[Yy]$ ]]; then
    log_info "Настройка блокировки сканеров CyberOK_Skipa_ips в nftables..."
    cat <<'EOF' > /usr/local/sbin/update-skipa-blocklist.sh
#!/usr/bin/env python3
import os
import re
import ipaddress
import urllib.request
import subprocess

NFT_FILE = "/etc/nftables.d/skipa_block.nft"
os.makedirs("/etc/nftables.d", exist_ok=True)

urls = [
    "https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/main/lists/cidr.txt",
    "https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/main/README.md"
]

raw_text = ""
for u in urls:
    try:
        req = urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw_text += "\n" + resp.read().decode("utf-8", errors="ignore")
    except Exception:
        pass

candidates = re.findall(r'\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b', raw_text)
valid_nets = set()
for item in candidates:
    try:
        net = ipaddress.ip_network(item, strict=False)
        if net.is_global:
            valid_nets.add(str(net))
    except ValueError:
        continue

if len(valid_nets) < 10:
    raise SystemExit("Error: too few valid IPs fetched, aborting update.")

elements = ",\n        ".join(sorted(valid_nets))
nft_config = f"""table inet skipa_block
delete table inet skipa_block

table inet skipa_block {{
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
        ip saddr @scanners_v4 counter drop
    }}
}}
"""

with open(NFT_FILE, "w", encoding="utf-8") as f:
    f.write(nft_config)

subprocess.run(["nft", "-f", NFT_FILE], check=True)
EOF
    chmod +x /usr/local/sbin/update-skipa-blocklist.sh
    /usr/local/sbin/update-skipa-blocklist.sh

    cat <<'EOF' > /etc/systemd/system/skipa-blocklist.service
[Unit]
Description=Apply CyberOK Skipa nftables blocklist
After=network-online.target nftables.service ufw.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/nftables.d/skipa_block.nft
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable skipa-blocklist.service >/dev/null

    echo "15 4 * * * root /usr/local/sbin/update-skipa-blocklist.sh >/dev/null 2>&1" > /etc/cron.d/skipa-blocklist
    chmod 644 /etc/cron.d/skipa-blocklist
    log_ok "Блокировка CyberOK_Skipa_ips активирована."
fi

# 14. Установка CLI-утилиты my3xui (/usr/local/bin/my3xui) с прямым чтением БД
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
for row in cur.execute("SELECT remark, settings, stream_settings FROM inbounds WHERE enable = 1"):
    remark, st_raw, sst_raw = row
    st = json.loads(st_raw)
    sst = json.loads(sst_raw)
    clients = st.get("clients", [])
    if not clients:
        continue

    client = clients[0]
    uuid = client["id"]
    flow = client.get("flow", "")
    net = sst.get("network", "tcp")
    sec = sst.get("security", "none")

    params = {"type": net, "encryption": "none"}

    if sec == "reality":
        rs = sst["realitySettings"]
        params.update({
            "security": "reality",
            "pbk": rs["settings"]["publicKey"],
            "fp": rs["settings"].get("fingerprint", "chrome"),
            "sni": rs["serverNames"][0],
            "sid": rs["shortIds"][0],
            "spx": rs["settings"].get("spiderX", "/")
        })
        if flow:
            params["flow"] = flow
    elif net == "xhttp":
        xs = sst["xhttpSettings"]
        params.update({
            "security": "tls",
            "sni": domain,
            "host": xs.get("host", domain),
            "path": xs.get("path", "/"),
            "mode": xs.get("mode", "auto"),
            "fp": "chrome"
        })
    elif net == "ws":
        ws = sst["wsSettings"]
        params.update({
            "security": "tls",
            "sni": domain,
            "host": ws.get("headers", {}).get("Host", domain),
            "path": ws.get("path", "/"),
            "fp": "chrome"
        })

    query_str = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    link = f"vless://{uuid}@{domain}:443?{query_str}#{urllib.parse.quote(remark)}"
    print(f"\n[{remark}]")
    print(link)

conn.close()
DBEOF
    echo ""
}

show_crowdsec() {
    echo -e "\n${BOLD}${CYAN}=== СОСТОЯНИЕ CROWDSEC И БЛОКИРОВОК ===${NC}"
    echo -e "${BOLD}1. Активные решения CrowdSec (cscli decisions list):${NC}"
    cscli decisions list || true
    echo -e "\n${BOLD}2. Статус баунсеров (cscli bouncers list):${NC}"
    cscli bouncers list || true
    if nft list table inet skipa_block &>/dev/null; then
        PKTS=$(nft list chain inet skipa_block prerouting 2>/dev/null | grep -oE 'packets [0-9]+' || echo "packets 0")
        echo -e "\n${BOLD}3. CyberOK Skipa nftables:${NC} активен (${PKTS} отброшено)"
    fi
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
    systemctl stop skipa-blocklist.service 2>/dev/null || true
    systemctl disable skipa-blocklist.service 2>/dev/null || true
    nft delete table inet skipa_block 2>/dev/null || true
    rm -f /etc/nftables.d/skipa_block.nft /usr/local/sbin/update-skipa-blocklist.sh \
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
    1|info)     show_sysinfo ;;
    2|creds)    show_creds ;;
    3|crowdsec) show_crowdsec ;;
    4|clean)    clean_server ;;
    *)
        while true; do
            echo -e "${BOLD}${CYAN}==================================================${NC}"
            echo -e "${BOLD}   Управление сервером (my3xui CLI)               ${NC}"
            echo -e "${BOLD}${CYAN}==================================================${NC}"
            echo "  1. Информация о системе (CPU, RAM, тип и размер дисков)"
            echo "  2. Данные для входа в панель 3x-ui и ссылки VLESS"
            echo "  3. Состояние CrowdSec (cscli decisions list)"
            echo -e "  4. ${RED}Очистка сервера (полное удаление всех компонентов)${NC}"
            echo "  0. Выход"
            echo ""
            read -erp "Выберите пункт [0-4]: " CHOICE
            case "$CHOICE" in
                1) show_sysinfo ;;
                2) show_creds ;;
                3) show_crowdsec ;;
                4) clean_server ;;
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
cat <<EOF > "$INFO_FILE"
Ссылка на панель 3x-ui:  https://${DOMAIN}/${PANEL_PATH}/
Логин:                   ${PANEL_USER}
Пароль:                  ${PANEL_PASS}
Единая подписка:         https://${DOMAIN}/${SUB_PATH}/main_sub
EOF
chmod 600 "$INFO_FILE"

echo -e "\n${GREEN}${BOLD}=================================================================${NC}"
echo -e "${GREEN}${BOLD}  УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                                   ${NC}"
echo -e "${GREEN}${BOLD}=================================================================${NC}"
echo -e "  • UFW:           активен (открыты только SSH:${SSH_PORT}, 80, 443)"
echo -e "  • Fail2Ban:      активен (sshd + nginx-botsearch через nftables)"
echo -e "  • CrowdSec:      активен (crowdsec + nftables firewall bouncer)"
echo -e "  • CyberOK Skipa: $([[ "$ENABLE_SKIPA" =~ ^[Yy]$ ]] && echo 'активен (nftables prerouting drop)' || echo 'отключен')"
echo -e "  • CLI-утилита:   my3xui (info | creds | crowdsec | clean)"

my3xui creds