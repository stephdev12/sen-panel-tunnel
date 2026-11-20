#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# SEN PANEL TUNNEL INSTALLER
# Ubuntu 24.04
# Node.js + systemd + Nginx + Let's Encrypt
# ==========================================================

# ================= CONFIGURATION =================

APP_DIR="/opt/nova-x-tunnel/web-panel"
APP_ENTRY="server.js"
APP_PORT="3000"

SERVICE_NAME="novaxpanel"
NGINX_SITE="nova-panel"

NODE_MAJOR="20"

# ==================================================

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

trap 'error "Échec à la ligne ${LINENO}. Consulte les messages précédents."' ERR

# ================= PRECHECKS =================

[[ "$EUID" -eq 0 ]] || error "Exécute ce script avec sudo."

source /etc/os-release

[[ "$ID" == "ubuntu" ]] || error "Ubuntu uniquement."

[[ -d "$APP_DIR" ]] || error "Dossier absent : $APP_DIR"
[[ -f "$APP_DIR/package.json" ]] || error "package.json absent."
[[ -f "$APP_DIR/$APP_ENTRY" ]] || error "Entrée Node absente."

[[ "$APP_PORT" =~ ^[0-9]+$ ]] || error "Port invalide."

echo
echo "=========================================="
echo "       SEN PANEL TUNNEL INSTALLER"
echo "=========================================="

read -rp "Domaine du panel : " DOMAIN
read -rp "Email Let's Encrypt : " EMAIL

[[ -n "$DOMAIN" ]] || error "Domaine obligatoire."
[[ -n "$EMAIL" ]] || error "Email obligatoire."

# ================= BACKUP =================

BACKUP_DIR="/root/senpanel-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

for FILE in \
    "/etc/nginx/sites-available/$NGINX_SITE" \
    "/etc/systemd/system/$SERVICE_NAME.service"
do
    [[ -f "$FILE" ]] && cp -a "$FILE" "$BACKUP_DIR/"
done

info "Sauvegarde : $BACKUP_DIR"

# ================= DEPENDENCIES =================

info "Installation des dépendances..."

apt-get update

# NodeSource fournit npm avec Node.js.
apt-get install -y \
    ca-certificates \
    curl \
    nginx \
    nodejs \
    certbot \
    python3-certbot-nginx

command -v node >/dev/null || error "Node.js absent."
command -v npm >/dev/null || error "npm absent."

info "Node : $(node --version)"
info "npm : $(npm --version)"

# ================= APPLICATION =================

info "Installation des dépendances Node..."

cd "$APP_DIR"

if [ -f .env.example ] && [ ! -f .env ]; then
    cp .env.example .env
    SESSION_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "senpanel-session-secret-$(date +%s)")
    sed -i "s|^SESSION_SECRET=.*|SESSION_SECRET=${SESSION_SECRET}|" .env
    sed -i "s|^PORT=.*|PORT=${APP_PORT}|" .env
    sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" .env
fi

npm install --omit=dev

# ================= SYSTEMD =================

info "Configuration du service systemd..."

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=SEN Panel Tunnel Web Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=$(command -v node) ${APP_DIR}/${APP_ENTRY}
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=${APP_PORT}
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

sleep 3

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager
    error "Le panel ne démarre pas."
fi

# ================= NGINX =================

info "Configuration Nginx..."

# On ne supprime et ne désactive aucun site existant.

NGINX_AVAILABLE="/etc/nginx/sites-available/${NGINX_SITE}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE}"

if [[ -e "$NGINX_ENABLED" && ! -L "$NGINX_ENABLED" ]]; then
    error "$NGINX_ENABLED existe déjà et n'est pas un lien symbolique."
fi

if [[ -L "$NGINX_ENABLED" ]]; then
    CURRENT_TARGET="$(readlink -f "$NGINX_ENABLED" || true)"
    [[ "$CURRENT_TARGET" == "$NGINX_AVAILABLE" ]] || \
        error "Le nom de site ${NGINX_SITE} est déjà utilisé."
fi

cat > "$NGINX_AVAILABLE" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF

ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"

nginx -t || error "Configuration Nginx invalide."

systemctl enable nginx
systemctl reload nginx

# ================= DNS =================

info "Vérification DNS..."

PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)"
DOMAIN_IP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}' || true)"

[[ -n "$PUBLIC_IP" ]] || error "Impossible de récupérer l'IP publique."
[[ -n "$DOMAIN_IP" ]] || error "Le domaine ne possède aucune résolution IPv4."

echo "IP publique : $PUBLIC_IP"
echo "IP domaine : $DOMAIN_IP"

[[ "$PUBLIC_IP" == "$DOMAIN_IP" ]] || \
    error "Le domaine ne pointe pas vers ce VPS."

# ================= SSL =================

info "Obtention du certificat SSL..."

certbot --nginx \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    --redirect \
    --email "$EMAIL"

# ================= FINAL CHECK =================

info "Vérification finale..."

nginx -t

systemctl is-active --quiet nginx || error "Nginx arrêté."
systemctl is-active --quiet "$SERVICE_NAME" || error "Panel arrêté."

HTTP_CODE="$(curl -k -s -o /dev/null -w '%{http_code}' \
    --max-time 10 "https://${DOMAIN}/" || true)"

echo
echo "=========================================="
echo "       INSTALLATION TERMINEE"
echo "=========================================="
echo "Domaine : https://${DOMAIN}"
echo "Service : ${SERVICE_NAME}"
echo "Node : $(node --version)"
echo "npm : $(npm --version)"
echo "Port : ${APP_PORT}"
echo "HTTP : ${HTTP_CODE}"
echo "Backup : ${BACKUP_DIR}"
echo
echo "Logs : journalctl -u ${SERVICE_NAME} -f"
echo "SSL : certbot certificates"
echo "=========================================="
