#!/usr/bin/env bash
set -Eeuo pipefail

REPO="https://github.com/telegramdesktop/tproxy-server.git"
INSTALL_DIR="/opt/tproxy-server"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[+]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $*"
}

die() {
    echo -e "${RED}[ERROR]${NC} $*"
    exit 1
}

trap 'die "Ошибка на строке $LINENO"' ERR

# --------------------------------------------------
# Root
# --------------------------------------------------

[[ $EUID -eq 0 ]] || die "Запусти скрипт от root"

# --------------------------------------------------
# OS
# --------------------------------------------------

source /etc/os-release

[[ "${ID}" == "ubuntu" ]] || die "Поддерживается только Ubuntu"

if [[ "${VERSION_ID}" != "24.04" ]]; then
    warn "Рекомендуется Ubuntu 24.04, обнаружена ${PRETTY_NAME}"
    read -rp "Продолжить? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 0
fi

# --------------------------------------------------
# Input
# --------------------------------------------------

echo
echo "========================================"
echo " Telegram Proxy Installer"
echo "========================================"
echo

read -rp "Hostname: " HOSTNAME
[[ -n "$HOSTNAME" ]] || die "Hostname не указан"

read -rp "ACME email: " EMAIL
[[ -n "$EMAIL" ]] || die "Email не указан"

echo
echo "MTProxy secret:"
echo "  32 hex characters"
echo "  Enter = generate automatically"
echo

read -rp "Secret: " SECRET

if [[ -z "$SECRET" ]]; then
    SECRET="$(openssl rand -hex 16)"
    log "Secret сгенерирован автоматически"
else
    [[ "$SECRET" =~ ^[0-9a-fA-F]{32}$ ]] \
        || die "Secret должен содержать ровно 32 hex-символа"

    SECRET="${SECRET,,}"
fi

echo
echo "Hostname : $HOSTNAME"
echo "Email    : $EMAIL"
echo "Secret   : $SECRET"
echo

read -rp "Начать установку? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"

[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

# --------------------------------------------------
# Packages
# --------------------------------------------------

log "Устанавливаем зависимости..."

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git \
    curl \
    openssl \
    ufw \
    ca-certificates \
    jq

# --------------------------------------------------
# Firewall
# --------------------------------------------------

log "Настраиваем UFW..."

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8443/tcp

ufw --force enable

# --------------------------------------------------
# Download official tproxy-server
# --------------------------------------------------

log "Загружаем официальный Telegram tproxy-server..."

rm -rf "$INSTALL_DIR"

git clone --depth 1 "$REPO" "$INSTALL_DIR"

# --------------------------------------------------
# Temporary website
# --------------------------------------------------

mkdir -p /tmp/tproxy-site

cat > /tmp/tproxy-site/index.html <<'EOF'
<!doctype html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Welcome</title>
</head>
<body>
    <h1>Welcome</h1>
</body>
</html>
EOF

# --------------------------------------------------
# Official Web MTProto installation
# --------------------------------------------------

log "Устанавливаем Web MTProto..."

"$INSTALL_DIR/deploy/install.sh" \
    --hostname "$HOSTNAME" \
    --email "$EMAIL" \
    --site-dir /tmp/tproxy-site

# --------------------------------------------------
# Replace generated secret with requested one
# --------------------------------------------------

log "Настраиваем MTProxy secret..."

ENV_FILE="/etc/mtproxy/mtproxy.env"

[[ -f "$ENV_FILE" ]] || die "$ENV_FILE не найден"

if grep -q '^MTPROXY_SECRET=' "$ENV_FILE"; then
    sed -i "s/^MTPROXY_SECRET=.*/MTPROXY_SECRET=$SECRET/" "$ENV_FILE"
else
    echo "MTPROXY_SECRET=$SECRET" >> "$ENV_FILE"
fi

chmod 600 "$ENV_FILE"

# --------------------------------------------------
# Restart Web MTProto backend
# --------------------------------------------------

systemctl restart mtproxy

# --------------------------------------------------
# External MTProxy
# --------------------------------------------------

log "Создаём внешний MTProxy на порту 8443..."

cat > /etc/systemd/system/mtproxy-external.service <<'EOF'
[Unit]
Description=Official Telegram MTProxy external
After=network-online.target tproxy-firewall.service
Wants=network-online.target
Requires=tproxy-firewall.service

[Service]
Type=simple
User=mtproxy
Group=mtproxy

EnvironmentFile=/etc/mtproxy/mtproxy.env
Environment=MTPROXY_WORKERS=1
Environment=MTPROXY_MAX_CONNECTIONS=4096

WorkingDirectory=/opt/MTProxy

ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy \
    -u mtproxy \
    -p 8888 \
    -H 8443 \
    -S ${MTPROXY_SECRET} \
    $MTPROXY_NAT_ARGS \
    --aes-pwd /etc/mtproxy/proxy-secret \
    /etc/mtproxy/proxy-multi.conf \
    -M ${MTPROXY_WORKERS} \
    -C ${MTPROXY_MAX_CONNECTIONS}

Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectHome=true
ProtectProc=invisible
ProcSubset=pid
ProtectSystem=strict
ReadOnlyPaths=/etc/mtproxy
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mtproxy-external

sleep 3

# --------------------------------------------------
# Checks
# --------------------------------------------------

log "Проверяем сервисы..."

systemctl is-active --quiet caddy \
    || die "Caddy не запущен"

systemctl is-active --quiet mtproxy \
    || die "Web MTProxy backend не запущен"

systemctl is-active --quiet mtproxy-external \
    || die "External MTProxy не запущен"

# --------------------------------------------------
# Ports
# --------------------------------------------------

log "Проверяем порты..."

ss -lnt | grep -qE '0\.0\.0\.0:8443\b' \
    || die "Порт 8443 не слушается"

ss -lnt | grep -qE '(\*:443|0\.0\.0\.0:443)\b' \
    || die "Порт 443 не слушается"

# --------------------------------------------------
# Web proxy URL
# --------------------------------------------------

WEB_PATH=""

if [[ -f /etc/tproxy-server/config.json ]]; then
    WEB_PATH="$(jq -r '.public.path // empty' /etc/tproxy-server/config.json 2>/dev/null || true)"
fi

if [[ -z "$WEB_PATH" ]]; then
    WEB_PATH="$(grep -RhoE '/[A-Za-z0-9]{10,}' /etc/tproxy-server 2>/dev/null | head -1 || true)"
fi

# --------------------------------------------------
# Final
# --------------------------------------------------

echo
echo "========================================"
echo " INSTALLATION COMPLETE"
echo "========================================"
echo

echo "Hostname:"
echo "  $HOSTNAME"
echo

echo "Secret:"
echo "  $SECRET"
echo

echo "MTProto:"
echo "  tg://proxy?server=$HOSTNAME&port=8443&secret=$SECRET"
echo

if [[ -n "$WEB_PATH" ]]; then
    echo "Web MTProto:"
    echo "  https://$HOSTNAME$WEB_PATH"
    echo
else
    echo "Web MTProto:"
    echo "  https://$HOSTNAME/"
    echo
fi

echo "Ports:"
echo "  443   Web MTProto"
echo "  8443  MTProto"
echo

echo "Services:"
echo "  caddy              $(systemctl is-active caddy)"
echo "  mtproxy            $(systemctl is-active mtproxy)"
echo "  mtproxy-external   $(systemctl is-active mtproxy-external)"
echo

echo "========================================"
echo
