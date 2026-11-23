#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# SEN PANEL TUNNEL INSTALLER
# Ubuntu 24.04
# Node.js + systemd + Nginx (Port 2045) + Let's Encrypt / SSL
# ==========================================================

# ================= CONFIGURATION =================

APP_DIR="/opt/nova-x-tunnel/web-panel"
[[ ! -d "$APP_DIR" && -d "/opt/senpanel/web-panel" ]] && APP_DIR="/opt/senpanel/web-panel"

APP_ENTRY="server.js"
APP_PORT="3000"         # Port interne Node.js (reverse proxy)
PANEL_PORT="${PANEL_PORT:-2045}" # Port public externe (Nginx)

SERVICE_NAME="novaxpanel"
NGINX_SITE="senpanel"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

trap 'error "Échec à la ligne ${LINENO}. Consulte les messages précédents."' ERR

# ================= PRECHECKS =================

[[ "$EUID" -eq 0 ]] || error "Exécute ce script avec sudo (en root)."

source /etc/os-release
[[ "$ID" == "ubuntu" || "$ID" == "debian" ]] || warn "Testé principalement sur Ubuntu / Debian."

[[ -d "$APP_DIR" ]] || error "Dossier du panel web introuvable : $APP_DIR"
[[ -f "$APP_DIR/package.json" ]] || error "package.json absent dans $APP_DIR."
[[ -f "$APP_DIR/$APP_ENTRY" ]] || error "Fichier principal $APP_ENTRY absent."

echo
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}       SEN PANEL TUNNEL INSTALLER         ${NC}"
echo -e "${CYAN}    Panel Web sur le port ${PANEL_PORT} par défaut ${NC}"
echo -e "${CYAN}==========================================${NC}"

read_tty() {
  if [ -r /dev/tty ]; then
    read "$@" < /dev/tty
  else
    read "$@" < /dev/null
  fi
}

PUBLIC_IP="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 6 icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')"

read_tty -rp "👉 Domaine du panel (ou laisser vide pour utiliser l'IP $PUBLIC_IP) : " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  DOMAIN="$PUBLIC_IP"
  EMAIL=""
else
  read_tty -rp "👉 Email pour le certificat Let's Encrypt : " EMAIL
fi

# ================= BACKUP =================

BACKUP_DIR="/root/senpanel-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

for FILE in \
    "/etc/nginx/sites-available/$NGINX_SITE" \
    "/etc/nginx/sites-available/nova-panel" \
    "/etc/systemd/system/$SERVICE_NAME.service" \
    "$APP_DIR/.env" \
    "$APP_DIR/db/panel.sqlite3"
do
    [[ -f "$FILE" ]] && cp -a "$FILE" "$BACKUP_DIR/" 2>/dev/null || true
done

info "Sauvegarde de sécurité créée dans : $BACKUP_DIR"

# ================= DEPENDENCIES =================

info "Installation / Vérification des dépendances système..."
apt-get update -y

apt-get install -y \
    ca-certificates \
    curl \
    nginx \
    certbot \
    ufw \
    iptables \
    openssl

# Vérification et installation de Node.js et npm
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    info "Configuration de Node.js 20 et npm via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi

# Sécurité supplémentaire : si npm n'est toujours pas disponible, l'installer directement via apt
if ! command -v npm >/dev/null 2>&1; then
    info "Installation du paquet npm via apt..."
    apt-get install -y npm
fi

command -v node >/dev/null 2>&1 || error "Node.js est introuvable."
command -v npm >/dev/null 2>&1 || error "npm est introuvable."

info "Node.js version : $(node --version)"
info "npm version     : $(npm --version)"

# ================= APPLICATION SETUP =================

info "Configuration de l'application Node.js..."
cd "$APP_DIR"

if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
    else
        touch .env
    fi
    SESSION_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "senpanel-session-secret-$(date +%s)")
    echo "SESSION_SECRET=${SESSION_SECRET}" >> .env
fi

# Configuration des variables d'environnement pour le port 2045
sed -i '/^PORT=/d' .env && echo "PORT=${APP_PORT}" >> .env
sed -i '/^PUBLIC_PORT=/d' .env && echo "PUBLIC_PORT=${PANEL_PORT}" >> .env
sed -i '/^DOMAIN=/d' .env && echo "DOMAIN=${DOMAIN}" >> .env
sed -i '/^BEHIND_TLS_PROXY=/d' .env && echo "BEHIND_TLS_PROXY=true" >> .env
sed -i '/^TLS_MODE=/d' .env && echo "TLS_MODE=nginx" >> .env

info "Installation des dépendances npm..."
npm install --omit=dev --silent 2>/dev/null || npm install --omit=dev

# ================= SYSTEMD =================

info "Configuration du service systemd ($SERVICE_NAME)..."

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

sleep 2

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager
    error "Le panel Node.js n'a pas pu démarrer."
fi
info "Service systemd $SERVICE_NAME actif."

# ================= CERTIFICAT SSL =================

SSL_CERT=""
SSL_KEY=""

if [[ "$DOMAIN" != "$PUBLIC_IP" && -n "$EMAIL" ]]; then
    info "Tentative d'obtention du certificat SSL Let's Encrypt pour $DOMAIN..."
    
    # Arrêter temporairement HAProxy/Nginx pendant le standalone ACME port 80 si nécessaire
    HAPROXY_WAS_RUNNING=false
    if systemctl is-active --quiet haproxy 2>/dev/null; then
        HAPROXY_WAS_RUNNING=true
        systemctl stop haproxy 2>/dev/null || true
    fi
    systemctl stop nginx 2>/dev/null || true

    if certbot certonly --standalone \
        -d "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        --email "$EMAIL" 2>/dev/null; then
        
        SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
        info "Certificat Let's Encrypt obtenu avec succès."
    else
        warn "Échec Let's Encrypt (DNS non encore propagé ou derrière proxy Cloudflare)."
    fi

    if [[ "$HAPROXY_WAS_RUNNING" == true ]]; then
        systemctl start haproxy 2>/dev/null || true
    fi
fi

# Fallback sur certificat SSL auto-signé fort si pas de Let's Encrypt
if [[ -z "$SSL_CERT" || ! -f "$SSL_CERT" ]]; then
    info "Génération d'un certificat SSL auto-signé dédié pour le port ${PANEL_PORT}..."
    SSL_DIR="/etc/ssl/senpanel"
    mkdir -p "$SSL_DIR"
    SSL_CERT="$SSL_DIR/cert.pem"
    SSL_KEY="$SSL_DIR/key.pem"
    
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$SSL_KEY" \
        -out "$SSL_CERT" \
        -subj "/C=FR/ST=Global/L=Cloud/O=SenPanel/CN=${DOMAIN}" 2>/dev/null
    chmod 600 "$SSL_KEY"
fi

# ================= NGINX SUR LE PORT 2045 =================

info "Configuration de Nginx sur le port ${PANEL_PORT}..."

# Désactiver le site par défaut de Nginx qui squatte le port 80 si présent
if [[ -L "/etc/nginx/sites-enabled/default" ]]; then
    rm -f "/etc/nginx/sites-enabled/default"
fi

NGINX_AVAILABLE="/etc/nginx/sites-available/${NGINX_SITE}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE}"

cat > "$NGINX_AVAILABLE" <<EOF
server {
    listen ${PANEL_PORT} ssl;
    listen [::]:${PANEL_PORT} ssl;

    server_name ${DOMAIN};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

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
# Nettoyer l'ancien lien nova-panel s'il existe
rm -f "/etc/nginx/sites-enabled/nova-panel" 2>/dev/null || true

nginx -t || error "Erreur dans la configuration Nginx générée."

systemctl enable nginx
systemctl restart nginx

# ================= OUVERTURE DU PORT PARE-FEU =================

info "Ouverture automatique du port ${PANEL_PORT} dans le pare-feu..."

if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
        ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
        ufw allow 80/tcp >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
        info "[OK] Port ${PANEL_PORT}/tcp autorisé dans UFW."
    else
        info "UFW installé mais inactif."
    fi
fi

if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "${PANEL_PORT}" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "${PANEL_PORT}" -j ACCEPT 2>/dev/null || true
    info "[OK] Port ${PANEL_PORT}/tcp autorisé dans iptables."
fi

# Relancer HAProxy s'il est configuré pour s'assurer qu'il a les ports 80/443
if systemctl list-unit-files 2>/dev/null | grep -q '^haproxy'; then
    systemctl restart haproxy 2>/dev/null || true
fi

# ================= RESUME FINAL =================

echo
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}       INSTALLATION DU PANEL REUSSIE      ${NC}"
echo -e "${GREEN}==========================================${NC}"
echo -e " URL du Panel   : ${CYAN}https://${DOMAIN}:${PANEL_PORT}${NC}"
echo -e " Port Web Nginx : ${CYAN}${PANEL_PORT}${NC} (ports 80 & 443 libres pour les tunnels)"
echo -e " Port Node.js   : ${APP_PORT} (interne)"
echo -e " Service        : ${SERVICE_NAME} (systemctl status ${SERVICE_NAME})"
echo -e " Sauvegarde     : ${BACKUP_DIR}"
echo
echo -e " Pour gérer le panel, tapez : ${CYAN}novaxpanel${NC} ou connectez-vous sur ${CYAN}https://${DOMAIN}:${PANEL_PORT}${NC}"
echo -e "${GREEN}==========================================${NC}"
