#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# SEN PANEL TUNNEL INSTALLER
# Ubuntu 24.04
# Node.js + systemd + Nginx (Port 2045) + Let's Encrypt / SSL
# ==========================================================

# ================= CONFIGURATION =================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="/opt/nova-x-tunnel/web-panel"
if [[ -d "/opt/nova-x-tunnel/web-panel" ]]; then
  APP_DIR="/opt/nova-x-tunnel/web-panel"
elif [[ -d "/opt/senpanel/web-panel" ]]; then
  APP_DIR="/opt/senpanel/web-panel"
elif [[ -f "$SCRIPT_DIR/package.json" && -f "$SCRIPT_DIR/server.js" ]]; then
  APP_DIR="$SCRIPT_DIR"
fi

APP_ENTRY="server.js"
APP_PORT="3000"         # Port interne Node.js (reverse proxy)
PANEL_PORT="${PANEL_PORT:-2045}" # Port public externe (Nginx)

SERVICE_NAME="novaxpanel"
NGINX_SITE="senpanel"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
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

# Configuration des identifiants Administrateur
read_tty -rp "👉 Nom d'utilisateur administrateur [admin] : " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

while true; do
  read_tty -rsp "👉 Mot de passe administrateur (laisser vide pour générer aléatoirement) : " ADMIN_PASS
  echo
  if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS=$(openssl rand -base64 12 | tr -d '=+/')
    info "Mot de passe généré automatiquement : $ADMIN_PASS"
    break
  fi
  if [[ ${#ADMIN_PASS} -lt 6 ]]; then
    warn "Le mot de passe doit comporter au moins 6 caractères."
    continue
  fi
  read_tty -rsp "👉 Confirmez le mot de passe : " ADMIN_PASS_CONFIRM
  echo
  if [[ "$ADMIN_PASS" != "$ADMIN_PASS_CONFIRM" ]]; then
    warn "Les mots de passe ne correspondent pas. Réessayez."
    continue
  fi
  break
done

# Configuration du chemin WebSocket personnalisé (ex: /sen, /tieme, /jean)
DEFAULT_WS_PATH="${WS_PATH:-}"
if [[ -z "$DEFAULT_WS_PATH" && -f /etc/novaxtunnel/wspath ]]; then
  DEFAULT_WS_PATH=$(cat /etc/novaxtunnel/wspath 2>/dev/null | tr -d '[:space:]')
fi
DEFAULT_WS_PATH="${DEFAULT_WS_PATH:-/sen}"

read_tty -rp "👉 Chemin WebSocket personnalisé (ex: /sen, /tieme, /jean) [$DEFAULT_WS_PATH] : " WS_PATH_INPUT
WS_PATH="${WS_PATH_INPUT:-$DEFAULT_WS_PATH}"
[[ "$WS_PATH" =~ ^/ ]] || WS_PATH="/$WS_PATH"
mkdir -p /etc/novaxtunnel
echo "$WS_PATH" > /etc/novaxtunnel/wspath
info "Chemin WebSocket retenu : $WS_PATH"

# ================= BACKUP =================

BACKUP_DIR="/root/senpanel-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

for FILE in \
    "/etc/nginx/sites-available/$NGINX_SITE" \
    "/etc/nginx/sites-available/nova-panel" \
    "/etc/nginx/sites-available/novaxpanel" \
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
mkdir -p "$APP_DIR/db"

if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
    else
        touch .env
    fi
    SESSION_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "senpanel-session-secret-$(date +%s)")
    echo "SESSION_SECRET=${SESSION_SECRET}" >> .env
fi

# Configuration des variables d'environnement
sed -i '/^PORT=/d' .env && echo "PORT=${APP_PORT}" >> .env
sed -i '/^PUBLIC_PORT=/d' .env && echo "PUBLIC_PORT=${PANEL_PORT}" >> .env
sed -i '/^DOMAIN=/d' .env && echo "DOMAIN=${DOMAIN}" >> .env
sed -i '/^BEHIND_TLS_PROXY=/d' .env && echo "BEHIND_TLS_PROXY=true" >> .env
sed -i '/^TLS_MODE=/d' .env && echo "TLS_MODE=nginx" >> .env
sed -i '/^DEFAULT_ADMIN_USER=/d' .env && echo "DEFAULT_ADMIN_USER=${ADMIN_USER}" >> .env
sed -i '/^DEFAULT_ADMIN_PASS=/d' .env && echo "DEFAULT_ADMIN_PASS=${ADMIN_PASS}" >> .env
sed -i '/^WS_PATH=/d' .env && echo "WS_PATH=${WS_PATH}" >> .env

info "Installation des dépendances npm..."
npm install --omit=dev --silent 2>/dev/null || npm install --omit=dev

info "Configuration du compte administrateur ($ADMIN_USER)..."
node "$APP_DIR/deploy/admin-tool.js" upsert "$ADMIN_USER" "$ADMIN_PASS"

# Mise à jour des profils de connexion existants avec le chemin WebSocket
if [[ -f "$APP_DIR/db/panel.sqlite3" ]]; then
    node -e "
    try {
        const Database = require('better-sqlite3');
        const db = new Database('$APP_DIR/db/panel.sqlite3');
        const profiles = db.prepare('SELECT id, params FROM connection_profiles WHERE type = \"ssh\"').all();
        for (const p of profiles) {
            try {
                const params = JSON.parse(p.params);
                if (params.payload && params.payload.includes('Upgrade: websocket')) {
                    params.payload = params.payload.replace(/GET \/[^ ]+ HTTP\/1\.1/, 'GET ' + process.argv[1] + ' HTTP/1.1');
                    db.prepare('UPDATE connection_profiles SET params = ? WHERE id = ?').run(JSON.stringify(params), p.id);
                }
            } catch(e) {}
        }
    } catch(e) {}
    " "$WS_PATH" 2>/dev/null || true
fi

# ================= SYSTEMD =================

info "Configuration du service systemd ($SERVICE_NAME)..."

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=SEN Panel Tunnel Web Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=-${APP_DIR}/.env
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

# Installer la commande CLI novaxpanel
if [[ -f "$APP_DIR/deploy/novaxpanel-cli.sh" ]]; then
    info "Installation de la commande CLI 'novaxpanel'..."
    sed -e "s|__PROJECT_DIR__|$APP_DIR|g" "$APP_DIR/deploy/novaxpanel-cli.sh" > /usr/local/bin/novaxpanel
    chmod +x /usr/local/bin/novaxpanel
fi

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
    chmod 755 "$SSL_DIR"
    SSL_CERT="$SSL_DIR/cert.pem"
    SSL_KEY="$SSL_DIR/key.pem"
    
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$SSL_KEY" \
        -out "$SSL_CERT" \
        -subj "/C=FR/ST=Global/L=Cloud/O=SenPanel/CN=${DOMAIN}" 2>/dev/null
    chmod 644 "$SSL_KEY"
    chmod 644 "$SSL_CERT"
fi

# ================= NGINX SUR LE PORT 2045 =================

info "Configuration de Nginx sur le port ${PANEL_PORT}..."

# Désactiver les sites par défaut et anciens liens
rm -f "/etc/nginx/sites-enabled/default" 2>/dev/null || true
rm -f "/etc/nginx/sites-enabled/nova-panel" 2>/dev/null || true
rm -f "/etc/nginx/sites-enabled/novaxpanel" 2>/dev/null || true
rm -f "/etc/nginx/conf.d/default.conf" 2>/dev/null || true

NGINX_AVAILABLE="/etc/nginx/sites-available/${NGINX_SITE}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE}"

IPV6_DIRECTIVE=""
if [ -f /proc/net/if_inet6 ] && ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    IPV6_DIRECTIVE="listen [::]:${PANEL_PORT} ssl default_server ipv6only=on;"
fi

NGINX_CONF_CONTENT="server {
    listen ${PANEL_PORT} ssl default_server;
    ${IPV6_DIRECTIVE}

    server_name ${DOMAIN} _ localhost \"\";

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;

    # Redirection automatique en HTTPS si requête HTTP ordinaire reçue sur le port SSL
    error_page 497 https://\$http_host\$request_uri;

    client_max_body_size 20M;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";

        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}"

# Déterminer si Nginx charge sites-enabled ou uniquement conf.d
if grep -q "sites-enabled" /etc/nginx/nginx.conf 2>/dev/null; then
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    echo "$NGINX_CONF_CONTENT" > "/etc/nginx/sites-available/${NGINX_SITE}"
    ln -sfn "/etc/nginx/sites-available/${NGINX_SITE}" "/etc/nginx/sites-enabled/${NGINX_SITE}"
    rm -f "/etc/nginx/conf.d/${NGINX_SITE}.conf" 2>/dev/null || true
else
    mkdir -p /etc/nginx/conf.d
    echo "$NGINX_CONF_CONTENT" > "/etc/nginx/conf.d/${NGINX_SITE}.conf"
    rm -f "/etc/nginx/sites-enabled/${NGINX_SITE}" 2>/dev/null || true
fi

nginx -t || error "Erreur dans la configuration Nginx générée."

systemctl enable nginx
systemctl restart nginx
systemctl restart "$SERVICE_NAME"

# Double vérification : si Nginx n'écoute toujours pas sur le port PANEL_PORT, forcer dans conf.d
sleep 1
if ! ss -tulpn 2>/dev/null | grep -q ":${PANEL_PORT} "; then
    warn "Port ${PANEL_PORT} non détecté via sites-enabled. Tentative d'activation via /etc/nginx/conf.d/${NGINX_SITE}.conf..."
    mkdir -p /etc/nginx/conf.d
    echo "$NGINX_CONF_CONTENT" > "/etc/nginx/conf.d/${NGINX_SITE}.conf"
    rm -f "/etc/nginx/sites-enabled/${NGINX_SITE}" 2>/dev/null || true
    nginx -t && systemctl restart nginx || true
fi

# ================= OUVERTURE DU PORT PARE-FEU =================

info "Ouverture automatique du port ${PANEL_PORT} dans le pare-feu..."

if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
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
    iptables -I INPUT 1 -p tcp --dport "${PANEL_PORT}" -j ACCEPT 2>/dev/null || true
    info "[OK] Port ${PANEL_PORT}/tcp autorisé dans iptables."
fi

if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C INPUT -p tcp --dport "${PANEL_PORT}" -j ACCEPT 2>/dev/null || \
    ip6tables -I INPUT 1 -p tcp --dport "${PANEL_PORT}" -j ACCEPT 2>/dev/null || true
fi

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "[OK] Port ${PANEL_PORT}/tcp autorisé dans firewalld."
fi

# Relancer HAProxy s'il est configuré pour s'assurer qu'il a les ports 80/443
if systemctl list-unit-files 2>/dev/null | grep -q '^haproxy'; then
    systemctl restart haproxy 2>/dev/null || true
fi

# ================= VERIFICATION DE FONCTIONNEMENT =================

info "Vérification locale de l'accessibilité du panel (attente du démarrage)..."
PANEL_READY=false
for i in {1..8}; do
    if curl -k -fsS "https://127.0.0.1:${PANEL_PORT}/login" >/dev/null 2>&1 || curl -k -s "https://127.0.0.1:${PANEL_PORT}/" | grep -qi "login\|html"; then
        PANEL_READY=true
        break
    fi
    sleep 1
done

if [[ "$PANEL_READY" == true ]]; then
    info "[OK] Le panel répond correctement sur https://127.0.0.1:${PANEL_PORT}"
else
    warn "Le test local immédiat n'a pas répondu. Diagnostic automatique :"
    echo -e "${CYAN}--- État de $SERVICE_NAME ---${NC}"
    systemctl status "$SERVICE_NAME" --no-pager -n 10 2>/dev/null || true
    echo -e "${CYAN}--- État de nginx ---${NC}"
    systemctl status nginx --no-pager -n 10 2>/dev/null || true
fi

# ================= RESUME FINAL =================

echo
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}       INSTALLATION DU PANEL REUSSIE      ${NC}"
echo -e "${GREEN}==========================================${NC}"
echo -e " URL du Panel      : ${CYAN}https://${DOMAIN}:${PANEL_PORT}${NC}"
echo -e " Nom d'utilisateur : ${CYAN}${ADMIN_USER}${NC}"
echo -e " Mot de passe      : ${CYAN}${ADMIN_PASS}${NC}"
echo -e " Port Web Nginx    : ${CYAN}${PANEL_PORT}${NC} (ports 80 & 443 libres pour les tunnels)"
echo -e " Port Node.js      : ${APP_PORT} (interne)"
echo -e " Service           : ${SERVICE_NAME} (systemctl status ${SERVICE_NAME})"
echo -e " Sauvegarde        : ${BACKUP_DIR}"
echo
if [[ -z "$EMAIL" || "$DOMAIN" == "$PUBLIC_IP" ]]; then
echo -e "${YELLOW}⚠️  NOTE IMPORTANTE CONNEXION :${NC}"
echo -e " Le panel utilise un certificat SSL direct sur IP/domaine."
echo -e " Votre navigateur affichera un avertissement : ${YELLOW}'Votre connexion n'est pas privée'${NC}."
echo -e " 👉 Cliquez sur ${BOLD}'Paramètres avancés'${NC} puis sur ${BOLD}'Continuer vers le site'${NC}."
echo
fi
echo -e " Pour gérer le panel en console à tout moment : tapez ${CYAN}novaxpanel${NC}"
echo -e "${GREEN}==========================================${NC}"
